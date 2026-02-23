import React, { useState } from 'react';
import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import { GoogleGenAI, Type } from "@google/genai";
import { getApiKey, getTavilyApiKey } from '../services/apiKey';
import { MarketSearchResponse, MarketSummaryRow } from '../types';

interface TavilyResult {
  title: string;
  url: string;
  content: string;
  score: number;
}

interface TavilySearchResponse {
  results: TavilyResult[];
}

interface SearchSourceStatus {
  gemini: 'idle' | 'loading' | 'done' | 'error';
  tavily: 'idle' | 'loading' | 'done' | 'error';
  merging: 'idle' | 'loading' | 'done' | 'error';
}

const MarketSearchPage: React.FC = () => {
  const [query, setQuery] = useState('');
  const [isLoading, setIsLoading] = useState(false);
  const [results, setResults] = useState<MarketSearchResponse | null>(null);
  const [groundingLinks, setGroundingLinks] = useState<{ title: string, uri: string }[]>([]);
  const [sourceStatus, setSourceStatus] = useState<SearchSourceStatus>({
    gemini: 'idle', tavily: 'idle', merging: 'idle'
  });

  const searchWithGemini = async (searchQuery: string): Promise<{ prices: string; grounding: { title: string, uri: string }[] }> => {
    const ai = new GoogleGenAI({ apiKey: getApiKey() });
    const prompt = `
      作为一名专业的市场销售调研员，请帮我查找产品"${searchQuery}"在全网主要渠道的当前实时价格。
      
      重点覆盖以下六大类平台（共30+个渠道）：
      
      1. **综合型传统电商**：淘宝(taobao.com)、天猫(tmall.com)、京东(jd.com)、拼多多(pinduoduo.com)、亚马逊(amazon.com)
      2. **内容/兴趣电商**：抖音(douyin.com)、快手(kuaishou.com)、小红书(xiaohongshu.com)
      3. **即时零售**：美团(meituan.com)、京东到家(jddj.com)
      4. **综合B2B/批发**：1688(1688.com)、阿里巴巴国际站(alibaba.com)、慧聪网(hc360.com)、中国制造网(made-in-china.com)、马可波罗(makepolo.com)、百度爱采购(b2b.baidu.com)、义乌购(yiwugo.com)
      5. **垂直行业批发**：
         - 服装鞋包：17网(17zwd.com)、3e3e(3e3e.cn)、衣联网(eelly.com)、网商园(wsy.com)、PP(pp.cn)
         - 电子元器件：华强电子网(hqew.com)、Digi-Key(digikey.cn)、Mouser(mouser.cn)
         - 农业：一亩田(ymt.com)、惠农网(cnhnb.com)
         - 工业MRO：震坤行(ehsy.com)、工邦邦(gongbangbang.com)、Grainger(grainger.com)、ThomasNet(thomasnet.com)
      6. **跨境/海外平台**：
         - B2B：Global Sources(globalsources.com)、DHgate(dhgate.com)、TradeKey(tradekey.com)
         - B2C：eBay(ebay.com)、AliExpress(aliexpress.com)、Walmart(walmart.com)、Shopee(shopee.com)、Lazada(lazada.com)
      7. **二手/回收**：爱回收(aihuishou.com)、找靓机(zhaoliangji.com)

      请提供一份结构清晰的【市场分析报告】，包含以下 Markdown 章节：

      ### 1. 📊 价格行情
      - **最低价**：[平台] ￥xx
      - **最高价**：[平台] ￥xx
      - **主流价格区间**：￥xx - ￥xx

      ### 2. 💡 销售建议 (针对卖家)
      - **定价策略**：...
      - **渠道推荐**：...

      ### 3. 🛍️ 购买建议 (针对买家)
      - **最佳入手渠道**：...
      - **避坑指南**：...

      请务必使用搜索功能获取最新数据。返回结果请尽量包含具体价格数字和来源平台。不要返回 Markdown代码块标记，直接返回内容。
    `;

    const response = await ai.models.generateContent({
      model: "gemini-3-pro-preview",
      contents: prompt,
      config: {
        tools: [{ googleSearch: {} }],
      }
    });

    const text = response.text || '';
    const grounding: { title: string, uri: string }[] = [];
    const chunks = response.candidates?.[0]?.groundingMetadata?.groundingChunks;
    if (chunks) {
      for (const chunk of chunks) {
        if (chunk.web) {
          grounding.push({
            title: chunk.web.title || '参考来源',
            uri: chunk.web.uri
          });
        }
      }
    }

    return { prices: text, grounding };
  };

  const searchWithTavily = async (searchQuery: string): Promise<TavilySearchResponse> => {
    const tavilyKey = getTavilyApiKey();
    const response = await fetch('https://api.tavily.com/search', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        api_key: tavilyKey,
        query: `${searchQuery} 最新价格 批发价 零售价 成交价 市场行情 2026`,
        search_depth: 'advanced',
        max_results: 15,
        include_answer: false,
      }),
    });

    if (!response.ok) {
      throw new Error(`Tavily API error: ${response.status} `);
    }

    return response.json();
  };

  const mergeWithGemini = async (
    geminiRaw: string,
    tavilyResults: TavilyResult[]
  ): Promise<MarketSearchResponse> => {
    const ai = new GoogleGenAI({ apiKey: getApiKey() });

    const tavilySummary = tavilyResults.map((r, i) =>
      `[Tavily结果${i + 1}]标题: ${r.title} \n内容摘要: ${r.content} \n来源: ${r.url} `
    ).join('\n\n');

    const prompt = `
    你是一名专业的市场销售调研员。我通过两个搜索引擎查找了产品的市场价格信息，请你整合分析这些数据。

## 搜索引擎 1: Google Search(Gemini Grounding) 返回结果
    涵盖领域：综合零售(淘宝 / 京东 / 拼多多 / 亚马逊)、B2B批发(1688 / 慧聪 / 中国制造网 / 义乌购)、内容电商(抖音 / 快手 / 小红书)、即时零售(美团 / 京东到家)、垂直行业(17网 / 3e3e / 华强电子 / 一亩田 / 惠农 / 工邦邦 / 震坤行)、二手(爱回收 / 找靓机)。
${geminiRaw}

## 搜索引擎 2: Tavily 搜索引擎返回结果
${tavilySummary}

    请完成以下任务：
    1. ** 合并去重 **：将两个引擎的价格数据合并，去掉明显重复的条目。
    2. ** summaryTable 汇总表格 **：生成一个关键数据汇总表，每行包含 label 和 value。包含：
    - "最低价" → 最低价格及平台
      - "最高价" → 最高价格及平台
        - "价格区间" → 如 "18.0 - 65.0 元"
          - "市场均价" → 如 "32.5 元"
            - "推荐对标平台" → 综合竞争最激烈的平台
              - "数据来源数量" → 如 "Google: 5条, Tavily: 4条"
    如有其他有价值的统计数据也请加入。
    3. ** analysis 综合分析报告 **：请生成一份结构清晰的 Markdown 格式分析报告，必须包含以下三个章节：
       - ### 📊 价格行情：简述主流价格区间和市场均价。
       - ### 💡 销售建议 (卖家)：定价策略、渠道选择、竞争对手分析。
       - ### 🛍️ 购买建议 (买家)：最佳入手渠道、避坑指南、促销建议。
       请使用列表和加粗增强可读性。禁止使用三个星号 (***)，仅使用两个星号 (**)。不要返回 Markdown代码块标记，直接返回内容。
    4. ** 输出格式 **：按指定 JSON Schema 返回，prices 数组中每条记录的 platform 字段请在平台名后标注数据来源（如 "京东 [Google]" 或 "1688 [Tavily]"）。

    请确保分析专业、数据准确。
    `;

    const response = await ai.models.generateContent({
      model: "gemini-3-pro-preview",
      contents: prompt,
      config: {
        responseMimeType: "application/json",
        responseSchema: {
          type: Type.OBJECT,
          properties: {
            analysis: { type: Type.STRING, description: "结构化的Markdown分析报告(含价格行情、销售建议、购买建议)" },
            summaryTable: {
              type: Type.ARRAY,
              description: "关键数据汇总表格，每行一个 label-value 对",
              items: {
                type: Type.OBJECT,
                properties: {
                  label: { type: Type.STRING, description: "指标名称，如 最低价、均价、价格区间" },
                  value: { type: Type.STRING, description: "指标值，如 18.0元 (1688)" },
                },
                required: ["label", "value"]
              }
            },
            prices: {
              type: Type.ARRAY,
              items: {
                type: Type.OBJECT,
                properties: {
                  platform: { type: Type.STRING },
                  title: { type: Type.STRING },
                  price: { type: Type.NUMBER },
                  link: { type: Type.STRING },
                },
                required: ["platform", "title", "price", "link"]
              }
            }
          },
          required: ["analysis", "prices", "summaryTable"]
        }
      }
    });

    const text = response.text || '{}';
    return JSON.parse(text) as MarketSearchResponse;
  };

  const handleSearch = async (e?: React.FormEvent) => {
    if (e) e.preventDefault();
    if (!query.trim() || isLoading) return;

    setIsLoading(true);
    setResults(null);
    setGroundingLinks([]);
    setSourceStatus({ gemini: 'loading', tavily: 'loading', merging: 'idle' });

    try {
      const [geminiResult, tavilyResult] = await Promise.allSettled([
        searchWithGemini(query).then(r => {
          setSourceStatus(prev => ({ ...prev, gemini: 'done' }));
          return r;
        }),
        searchWithTavily(query).then(r => {
          setSourceStatus(prev => ({ ...prev, tavily: 'done' }));
          return r;
        }),
      ]);

      if (geminiResult.status === 'rejected') {
        console.error("Gemini search failed:", geminiResult.reason);
        setSourceStatus(prev => ({ ...prev, gemini: 'error' }));
      }
      if (tavilyResult.status === 'rejected') {
        console.error("Tavily search failed:", tavilyResult.reason);
        setSourceStatus(prev => ({ ...prev, tavily: 'error' }));
      }

      const geminiRaw = geminiResult.status === 'fulfilled' ? geminiResult.value.prices : '{"analysis":"搜索失败","prices":[]}';
      const geminiGrounding = geminiResult.status === 'fulfilled' ? geminiResult.value.grounding : [];
      const tavilyData = tavilyResult.status === 'fulfilled' ? tavilyResult.value.results : [];

      setGroundingLinks(geminiGrounding);

      if (geminiResult.status === 'rejected' && tavilyResult.status === 'rejected') {
        throw new Error('两个搜索引擎均失败，请检查网络或 API 配置。');
      }

      setSourceStatus(prev => ({ ...prev, merging: 'loading' }));
      const merged = await mergeWithGemini(geminiRaw, tavilyData);
      setSourceStatus(prev => ({ ...prev, merging: 'done' }));
      setResults(merged);
    } catch (error) {
      console.error("Market Search Failed:", error);
      alert(`搜索失败：${error instanceof Error ? error.message : '未知错误'} `);
    } finally {
      setIsLoading(false);
    }
  };

  const statusIcon = (status: string) => {
    switch (status) {
      case 'loading': return <i className="fas fa-spinner animate-spin text-amber-400"></i>;
      case 'done': return <i className="fas fa-check-circle text-emerald-400"></i>;
      case 'error': return <i className="fas fa-times-circle text-red-400"></i>;
      default: return <i className="fas fa-circle text-[#7a7a78] text-[8px]"></i>;
    }
  };

  const renderSummaryTable = (table: MarketSummaryRow[]) => (
    <div className="overflow-hidden rounded-lg border border-[#e0ddd5]">
      <table className="w-full text-sm">
        <thead>
          <tr className="bg-[#f0eeeb]">
            <th className="text-left px-4 py-2.5 text-[10px] font-bold text-[#4a4a48] uppercase tracking-widest">指标</th>
            <th className="text-left px-4 py-2.5 text-[10px] font-bold text-[#4a4a48] uppercase tracking-widest">数据</th>
          </tr>
        </thead>
        <tbody>
          {table.map((row, idx) => (
            <tr key={idx} className={idx % 2 === 0 ? 'bg-white' : 'bg-[#f9f9f8]'}>
              <td className="px-4 py-2.5 text-[#4a4a48] font-medium whitespace-nowrap">{row.label}</td>
              <td className="px-4 py-2.5 text-[#191918] font-semibold">{row.value}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );

  return (
    <div className="max-w-7xl mx-auto space-y-8 animate-in fade-in duration-500">
      {/* Hero Search Section */}
      <div className="bg-[#f9f9f8] border border-[#e0ddd5] rounded-xl p-12 relative overflow-hidden text-center" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.06)' }}>
        <div className="absolute -top-24 -left-24 w-64 h-64 bg-[#d97757]/5 blur-[100px] rounded-full"></div>
        <div className="relative z-10">
          <h2 className="text-3xl font-semibold text-[#191918] mb-2 tracking-tight">市场聚合价格搜索</h2>
          <p className="text-[#5c5c5a] mt-2 text-sm">双引擎驱动：Gemini 3 Pro + Google Search Grounding & Tavily，覆盖 30+ 平台</p>

          <form onSubmit={handleSearch} className="max-w-2xl mx-auto relative group">
            <input
              type="text"
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder="输入产品名称，如：不锈钢 304 卷板、iPhone 16 Pro..."
              className="w-full bg-white border border-[#e0ddd5] rounded-xl py-5 pl-8 pr-32 text-[#191918] placeholder:text-[#7a7a78] outline-none focus:border-[#d97757] transition-all group-hover:border-[#d1cdc4]"
            />
            <button
              type="submit"
              disabled={isLoading || !query.trim()}
              className="absolute right-3 top-1/2 -translate-y-1/2 px-8 py-3 bg-[#d97757] hover:bg-[#c4694d] disabled:opacity-50 disabled:bg-[#f0eeeb] text-white font-semibold rounded-lg transition-all active:scale-95"
            >
              {isLoading ? <i className="fas fa-spinner animate-spin"></i> : '立即搜索'}
            </button>
          </form>

          <div className="mt-6 flex justify-center items-center space-x-6">
            <div className="flex items-center text-[10px] text-[#5c5c5a] font-bold uppercase tracking-widest">
              <span className="w-1.5 h-1.5 bg-[#d97757] rounded-full mr-2"></span> Google Grounding
            </div>
            <div className="flex items-center text-[10px] text-[#5c5c5a] font-bold uppercase tracking-widest">
              <span className="w-1.5 h-1.5 bg-teal-500 rounded-full mr-2"></span> Tavily Search
            </div>
            <div className="flex items-center text-[10px] text-[#5c5c5a] font-bold uppercase tracking-widest">
              <span className="w-1.5 h-1.5 bg-amber-500 rounded-full mr-2"></span> AI 合并分析
            </div>
          </div>
        </div>
      </div>

      {/* Loading State with Pipeline Status */}
      {isLoading && (
        <div className="py-12 flex flex-col items-center justify-center space-y-8">
          <div className="relative">
            <div className="w-16 h-16 border-4 border-[#d97757]/20 border-t-[#d97757] rounded-full animate-spin"></div>
            <div className="absolute inset-0 flex items-center justify-center text-xl">🌐</div>
          </div>

          <div className="bg-[#f9f9f8] border border-[#e0ddd5] rounded-xl p-6 w-full max-w-md space-y-4">
            <div className="flex items-center justify-between">
              <div className="flex items-center space-x-3">
                {statusIcon(sourceStatus.gemini)}
                <span className="text-sm text-[#4a4a48]">Gemini + Google Search Grounding</span>
              </div>
              <span className="text-[10px] text-[#5c5c5a] font-mono">
                {sourceStatus.gemini === 'loading' ? '搜索中...' : sourceStatus.gemini === 'done' ? '已完成' : sourceStatus.gemini === 'error' ? '失败' : '等待'}
              </span>
            </div>
            <div className="flex items-center justify-between">
              <div className="flex items-center space-x-3">
                {statusIcon(sourceStatus.tavily)}
                <span className="text-sm text-[#4a4a48]">Tavily 深度搜索</span>
              </div>
              <span className="text-[10px] text-[#5c5c5a] font-mono">
                {sourceStatus.tavily === 'loading' ? '搜索中...' : sourceStatus.tavily === 'done' ? '已完成' : sourceStatus.tavily === 'error' ? '失败' : '等待'}
              </span>
            </div>
            <div className="border-t border-[#e0ddd5] pt-3 flex items-center justify-between">
              <div className="flex items-center space-x-3">
                {statusIcon(sourceStatus.merging)}
                <span className="text-sm text-[#4a4a48]">AI 智能合并分析</span>
              </div>
              <span className="text-[10px] text-[#5c5c5a] font-mono">
                {sourceStatus.merging === 'loading' ? '合并中...' : sourceStatus.merging === 'done' ? '已完成' : '等待搜索完成'}
              </span>
            </div>
          </div>
        </div>
      )}

      {results && (
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-8 animate-in slide-in-from-bottom-8 duration-700">

          {/* LEFT: Price Cards (2/3 width) */}
          <div className="lg:col-span-2 space-y-4">
            <div className="flex items-center justify-between mb-4">
              <h3 className="text-xl font-semibold text-[#191918]">全网实时比价结果</h3>
              <span className="text-xs text-[#5c5c5a]">找到 {results.prices.length} 条相关报价</span>
            </div>
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
              {results.prices.map((item, idx) => {
                const isGoogle = item.platform.includes('[Google]');
                const isTavily = item.platform.includes('[Tavily]');
                return (
                  <div key={idx} className="bg-[#f9f9f8] border border-[#e0ddd5] rounded-xl p-6 hover:border-[#d97757]/40 transition-all group">
                    <div className="flex justify-between items-start mb-4">
                      <div className="flex items-center space-x-2">
                        <span className="px-2 py-1 bg-[#d97757]/10 text-[#d97757] text-[10px] font-bold rounded uppercase tracking-wider">
                          {item.platform.replace(/\s*\[.*?\]\s*/, '')}
                        </span>
                        {isGoogle && (
                          <span className="px-1.5 py-0.5 bg-[#d97757]/10 text-[#d97757] text-[8px] font-bold rounded-full">G</span>
                        )}
                        {isTavily && (
                          <span className="px-1.5 py-0.5 bg-teal-500/10 text-teal-400 text-[8px] font-bold rounded-full">T</span>
                        )}
                      </div>
                      <p className="text-2xl font-bold text-[#191918] group-hover:text-[#d97757] transition-colors">¥{item.price.toLocaleString()}</p>
                    </div>
                    <h4 className="text-sm font-medium text-[#4a4a48] line-clamp-2 mb-4 h-10 leading-snug">
                      {item.title}
                    </h4>
                    <a
                      href={item.link}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="flex items-center justify-center w-full py-2 bg-[#f0eeeb] hover:bg-[#e0ddd5] text-[#4a4a48] text-xs font-medium rounded-lg transition-all border border-[#e0ddd5]"
                    >
                      查看商品详情 <i className="fas fa-external-link-alt ml-2 text-[10px]"></i>
                    </a>
                  </div>
                );
              })}
            </div>
          </div>

          {/* RIGHT: AI Analysis Report (1/3 width) */}
          <div className="lg:col-span-1 space-y-6">
            <div className="bg-[#f9f9f8] border border-[#e0ddd5] rounded-xl p-8" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.06)' }}>
              <div className="flex items-center space-x-3 mb-5">
                <i className="fas fa-robot text-[#d97757]"></i>
                <h3 className="text-lg font-semibold text-[#191918]">AI 综合分析报告</h3>
              </div>
              <div className="flex items-center space-x-2 mb-5">
                <span className="px-2 py-0.5 bg-[#d97757]/10 text-[#d97757] text-[9px] font-bold rounded-full">Google</span>
                <span className="text-[#d1cdc4] text-[10px]">+</span>
                <span className="px-2 py-0.5 bg-teal-500/10 text-teal-400 text-[9px] font-bold rounded-full">Tavily</span>
                <span className="text-[#d1cdc4] text-[10px]">→</span>
                <span className="px-2 py-0.5 bg-amber-500/10 text-amber-400 text-[9px] font-bold rounded-full">Gemini 合并</span>
              </div>

              {/* Summary Table */}
              {results.summaryTable && results.summaryTable.length > 0 && (
                <div className="mb-6">
                  <h4 className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest mb-3">
                    <i className="fas fa-table mr-1.5"></i>关键数据汇总
                  </h4>
                  {renderSummaryTable(results.summaryTable)}
                </div>
              )}

              {/* Text Analysis */}
              <div>
                <h4 className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest mb-3">
                  <i className="fas fa-lightbulb mr-1.5"></i>销售建议
                </h4>
                <div className="markdown-body text-sm text-[#4a4a48] leading-relaxed">
                  <ReactMarkdown remarkPlugins={[remarkGfm]}>
                    {results.analysis}
                  </ReactMarkdown>
                </div>
              </div>
            </div>

            {groundingLinks.length > 0 && (
              <div className="bg-[#f9f9f8]/40 border border-[#e0ddd5] rounded-xl p-8">
                <h4 className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest mb-4">参考数据源</h4>
                <div className="space-y-3">
                  {groundingLinks.map((link, idx) => (
                    <a
                      key={idx}
                      href={link.uri}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="block text-xs text-[#d97757] hover:text-[#c4694d] transition-colors truncate"
                    >
                      <i className="fas fa-link mr-2 opacity-50"></i> {link.title}
                    </a>
                  ))}
                </div>
              </div>
            )}
          </div>
        </div>
      )}

      {/* No Results Placeholder */}
      {!results && !isLoading && (
        <div className="py-20 text-center flex flex-col items-center">
          <div className="w-20 h-20 bg-[#f9f9f8] rounded-full flex items-center justify-center mb-6 text-3xl opacity-20 ring-1 ring-[#e0ddd5]">
            <i className="fas fa-search-dollar"></i>
          </div>
          <h3 className="text-[#5c5c5a] font-medium">输入关键词并开始市场调研</h3>
          <p className="text-[#7a7a78] text-xs mt-1">双引擎搜索 + AI 智能合并，覆盖 30+ 电商/批发/垂直平台</p>
        </div>
      )}
    </div>
  );
};

export default MarketSearchPage;
