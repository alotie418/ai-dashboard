import React, { useState, useRef, useEffect } from 'react';
import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import { searchBrave, searchTavily, searchGemini, mergeSearch } from '../services/api';
import { MarketSearchResponse, MarketSummaryRow, BraveSearchResponse, GeminiSearchProxyResponse } from '../types';

interface SearchResult {
  title: string;
  url: string;
  content: string;
  source: 'brave' | 'tavily';
}

interface SearchSourceStatus {
  gemini: 'idle' | 'loading' | 'done' | 'error';
  brave: 'idle' | 'loading' | 'done' | 'error';
  tavily: 'idle' | 'loading' | 'done' | 'error';
  merging: 'idle' | 'loading' | 'done' | 'error';
}

const MarketSearchPage: React.FC = () => {
  const [query, setQuery] = useState('');
  const [isLoading, setIsLoading] = useState(false);
  const [results, setResults] = useState<MarketSearchResponse | null>(null);
  const [groundingLinks, setGroundingLinks] = useState<{ title: string, uri: string }[]>([]);
  const [sourceStatus, setSourceStatus] = useState<SearchSourceStatus>({
    gemini: 'idle', brave: 'idle', tavily: 'idle', merging: 'idle'
  });

  // AbortController for cancelling in-flight searches
  const abortControllerRef = useRef<AbortController | null>(null);

  // Clean up on unmount
  useEffect(() => {
    return () => {
      abortControllerRef.current?.abort();
    };
  }, []);

  const searchWithGeminiProxy = async (searchQuery: string, signal: AbortSignal): Promise<GeminiSearchProxyResponse> => {
    return searchGemini(searchQuery, signal);
  };

  const searchWithBraveProxy = async (searchQuery: string, signal: AbortSignal): Promise<SearchResult[]> => {
    const data: BraveSearchResponse = await searchBrave(
      `${searchQuery} 最新价格 批发价 零售价 成交价 市场行情 2026`,
      15,
      signal
    );
    const webResults = data.web?.results || [];
    return webResults.map(r => ({
      title: r.title,
      url: r.url,
      content: r.description,
      source: 'brave' as const,
    }));
  };

  const searchWithTavilyProxy = async (searchQuery: string, signal: AbortSignal): Promise<SearchResult[]> => {
    const data = await searchTavily(
      `${searchQuery} 最新价格 批发价 零售价 成交价 市场行情 2026`,
      15,
      signal
    );
    const results = data.results || [];
    return results.map((r: any) => ({
      title: r.title,
      url: r.url,
      content: r.content,
      source: 'tavily' as const,
    }));
  };

  const handleSearch = async (e?: React.FormEvent) => {
    if (e) e.preventDefault();
    if (!query.trim() || isLoading) return;

    // Abort previous search if any
    abortControllerRef.current?.abort();
    const controller = new AbortController();
    abortControllerRef.current = controller;
    const signal = controller.signal;

    // Overall timeout: 60 seconds
    const timeoutId = setTimeout(() => controller.abort(), 60000);

    setIsLoading(true);
    setResults(null);
    setGroundingLinks([]);
    setSourceStatus({ gemini: 'loading', brave: 'loading', tavily: 'loading', merging: 'idle' });

    try {
      const [geminiResult, braveResult, tavilyResult] = await Promise.allSettled([
        searchWithGeminiProxy(query, signal).then(r => {
          setSourceStatus(prev => ({ ...prev, gemini: 'done' }));
          return r;
        }),
        searchWithBraveProxy(query, signal).then(r => {
          setSourceStatus(prev => ({ ...prev, brave: 'done' }));
          return r;
        }),
        searchWithTavilyProxy(query, signal).then(r => {
          setSourceStatus(prev => ({ ...prev, tavily: 'done' }));
          return r;
        }),
      ]);

      // Check if aborted
      if (signal.aborted) return;

      if (geminiResult.status === 'rejected') {
        console.error("Gemini search failed:", geminiResult.reason);
        setSourceStatus(prev => ({ ...prev, gemini: 'error' }));
      }
      if (braveResult.status === 'rejected') {
        console.error("Brave search failed:", braveResult.reason);
        setSourceStatus(prev => ({ ...prev, brave: 'error' }));
      }
      if (tavilyResult.status === 'rejected') {
        console.error("Tavily search failed:", tavilyResult.reason);
        setSourceStatus(prev => ({ ...prev, tavily: 'error' }));
      }

      const geminiRaw = geminiResult.status === 'fulfilled' ? geminiResult.value.text : '';
      const geminiGrounding = geminiResult.status === 'fulfilled' ? geminiResult.value.grounding : [];
      const braveData = braveResult.status === 'fulfilled' ? braveResult.value : [];
      const tavilyData = tavilyResult.status === 'fulfilled' ? tavilyResult.value : [];

      setGroundingLinks(geminiGrounding);

      if (geminiResult.status === 'rejected' && braveResult.status === 'rejected' && tavilyResult.status === 'rejected') {
        throw new Error('三个搜索引擎均失败，请检查网络或 API 配置。');
      }

      if (signal.aborted) return;

      setSourceStatus(prev => ({ ...prev, merging: 'loading' }));
      const merged = await mergeSearch({
        geminiRaw,
        braveResults: braveData.map(r => ({ title: r.title, url: r.url, content: r.content })),
        tavilyResults: tavilyData.map(r => ({ title: r.title, url: r.url, content: r.content })),
      }, signal);

      if (signal.aborted) return;

      setSourceStatus(prev => ({ ...prev, merging: 'done' }));
      setResults(merged);
    } catch (error) {
      if (signal.aborted) return; // Silently ignore abort errors
      console.error("Market Search Failed:", error);
      alert(`搜索失败：${error instanceof Error ? error.message : '未知错误'} `);
    } finally {
      clearTimeout(timeoutId);
      if (!signal.aborted) {
        setIsLoading(false);
      }
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
          <p className="text-[#5c5c5a] mt-2 text-sm">三引擎驱动：Gemini 3.1 Pro + Google Search Grounding & Brave Search & Tavily，覆盖 30+ 平台</p>

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
              <span className="w-1.5 h-1.5 bg-blue-500 rounded-full mr-2"></span> Brave Search
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
                {statusIcon(sourceStatus.brave)}
                <span className="text-sm text-[#4a4a48]">Brave 深度搜索</span>
              </div>
              <span className="text-[10px] text-[#5c5c5a] font-mono">
                {sourceStatus.brave === 'loading' ? '搜索中...' : sourceStatus.brave === 'done' ? '已完成' : sourceStatus.brave === 'error' ? '失败' : '等待'}
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
                const isBrave = item.platform.includes('[Brave]');
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
                        {isBrave && (
                          <span className="px-1.5 py-0.5 bg-blue-500/10 text-blue-500 text-[8px] font-bold rounded-full">B</span>
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
                <span className="px-2 py-0.5 bg-blue-500/10 text-blue-500 text-[9px] font-bold rounded-full">Brave</span>
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
          <p className="text-[#7a7a78] text-xs mt-1">三引擎搜索 + AI 智能合并，覆盖 30+ 电商/批发/垂直平台</p>
        </div>
      )}
    </div>
  );
};

export default MarketSearchPage;
