import React, { useState, useRef, useEffect, useMemo, useCallback } from 'react';
import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import { searchBrave, searchTavily, searchGemini, searchDirect, searchInternational, searchEcommerce, mergeSearch, savePriceHistory, fetchPriceHistory } from '../services/api';
import { MarketSearchResponse, MarketSummaryRow, BraveSearchResponse, GeminiSearchProxyResponse, DirectSearchResponse, InternationalSearchResponse, EcommerceSearchResponse, PlatformCategory, PriceHistoryPoint } from '../types';
import { useMarketData } from '../contexts/MarketDataContext';
import { AreaChart, Area, Line, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer } from 'recharts';

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
  direct: 'idle' | 'loading' | 'done' | 'error';
  international: 'idle' | 'loading' | 'done' | 'error';
  ecommerce: 'idle' | 'loading' | 'done' | 'error';
  merging: 'idle' | 'loading' | 'done' | 'error';
}

const CATEGORY_TABS: { key: 'all' | PlatformCategory; label: string; icon: string }[] = [
  { key: 'all', label: '全部', icon: 'fa-layer-group' },
  { key: 'B2C', label: 'B2C零售', icon: 'fa-shopping-bag' },
  { key: 'B2B', label: 'B2B批发', icon: 'fa-industry' },
  { key: 'industry', label: '行业数据', icon: 'fa-chart-bar' },
  { key: 'international', label: '跨境平台', icon: 'fa-globe' },
];

const MarketSearchPage: React.FC = () => {
  const [query, setQuery] = useState('');
  const [isLoading, setIsLoading] = useState(false);
  const [results, setResults] = useState<MarketSearchResponse | null>(null);
  const [groundingLinks, setGroundingLinks] = useState<{ title: string, uri: string }[]>([]);
  const [activeCategory, setActiveCategory] = useState<'all' | PlatformCategory>('all');
  const [sourceStatus, setSourceStatus] = useState<SearchSourceStatus>({
    gemini: 'idle', brave: 'idle', tavily: 'idle', direct: 'idle', international: 'idle', ecommerce: 'idle', merging: 'idle'
  });
  const { setMarketData } = useMarketData();

  // Price trend state
  const [trendData, setTrendData] = useState<PriceHistoryPoint[]>([]);
  const [trendDays, setTrendDays] = useState<7 | 30 | 90>(30);
  const [trendLoading, setTrendLoading] = useState(false);

  // AbortController for cancelling in-flight searches
  const abortControllerRef = useRef<AbortController | null>(null);

  // Clean up on unmount
  useEffect(() => {
    return () => {
      abortControllerRef.current?.abort();
    };
  }, []);

  const loadTrend = useCallback(async (searchQuery: string, days: 7 | 30 | 90) => {
    setTrendLoading(true);
    try {
      const res = await fetchPriceHistory(searchQuery, days);
      setTrendData(res.history || []);
    } catch (e) {
      console.error('Failed to load price trend:', e);
      setTrendData([]);
    } finally {
      setTrendLoading(false);
    }
  }, []);

  // Reload trend when days change (only if results exist)
  useEffect(() => {
    if (results && query.trim()) {
      loadTrend(query.trim(), trendDays);
    }
  }, [trendDays]); // eslint-disable-line react-hooks/exhaustive-deps

  const searchWithGeminiProxy = async (searchQuery: string, signal: AbortSignal): Promise<GeminiSearchProxyResponse> => {
    return searchGemini(searchQuery, signal);
  };

  const searchWithBraveProxy = async (searchQuery: string, signal: AbortSignal): Promise<SearchResult[]> => {
    const data: BraveSearchResponse = await searchBrave(
      searchQuery,
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
      searchQuery,
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

    setIsLoading(true);
    setResults(null);
    setGroundingLinks([]);
    setActiveCategory('all');
    setSourceStatus({ gemini: 'loading', brave: 'loading', tavily: 'loading', direct: 'loading', international: 'loading', ecommerce: 'loading', merging: 'idle' });

    try {
      // --- Phase 1: Parallel search with 60s timeout (5 sources) ---
      const searchPhase = Promise.allSettled([
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
        searchDirect(query, signal).then(r => {
          setSourceStatus(prev => ({ ...prev, direct: r.matched ? 'done' : 'idle' }));
          return r;
        }),
        searchInternational(query, signal).then(r => {
          setSourceStatus(prev => ({ ...prev, international: r.results.length > 0 ? 'done' : 'idle' }));
          return r;
        }),
        searchEcommerce(query, signal).then(r => {
          setSourceStatus(prev => ({ ...prev, ecommerce: r.categories.length > 0 ? 'done' : 'idle' }));
          return r;
        }),
      ]);

      const searchTimeoutPromise = new Promise<never>((_, reject) =>
        setTimeout(() => reject(new Error('搜索阶段超时（60秒），请重试')), 60000)
      );

      const [geminiResult, braveResult, tavilyResult, directResult, internationalResult, ecommerceResult] = await Promise.race([
        searchPhase,
        searchTimeoutPromise,
      ]) as [PromiseSettledResult<GeminiSearchProxyResponse>, PromiseSettledResult<SearchResult[]>, PromiseSettledResult<SearchResult[]>, PromiseSettledResult<DirectSearchResponse>, PromiseSettledResult<InternationalSearchResponse>, PromiseSettledResult<EcommerceSearchResponse>];

      // Check if user cancelled
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
      if (directResult.status === 'rejected') {
        console.error("Direct scrape failed:", directResult.reason);
        setSourceStatus(prev => ({ ...prev, direct: 'error' }));
      }
      if (internationalResult.status === 'rejected') {
        console.error("International search failed:", internationalResult.reason);
        setSourceStatus(prev => ({ ...prev, international: 'error' }));
      }
      if (ecommerceResult.status === 'rejected') {
        console.error("E-commerce search failed:", ecommerceResult.reason);
        setSourceStatus(prev => ({ ...prev, ecommerce: 'error' }));
      }

      const geminiRaw = geminiResult.status === 'fulfilled' ? geminiResult.value.text : '';
      const geminiGrounding = geminiResult.status === 'fulfilled' ? geminiResult.value.grounding : [];
      const braveData = braveResult.status === 'fulfilled' ? braveResult.value : [];
      const tavilyData = tavilyResult.status === 'fulfilled' ? tavilyResult.value : [];
      const directData = directResult.status === 'fulfilled' && directResult.value.matched ? directResult.value.prices : [];
      const internationalData = internationalResult.status === 'fulfilled' ? internationalResult.value.results : [];
      const ecommerceData = ecommerceResult.status === 'fulfilled' ? ecommerceResult.value.categories : [];

      setGroundingLinks(geminiGrounding);

      if (geminiResult.status === 'rejected' && braveResult.status === 'rejected' && tavilyResult.status === 'rejected') {
        // Direct scrape or international results alone may not be enough for full analysis
        if (directData.length === 0 && internationalData.length === 0) {
          throw new Error('所有数据源均失败，请检查网络或 API 配置。');
        }
      }

      if (signal.aborted) return;

      // --- Phase 2: Merge analysis with independent 90s timeout ---
      setSourceStatus(prev => ({ ...prev, merging: 'loading' }));
      const mergeController = new AbortController();
      const mergeTimeoutId = setTimeout(() => mergeController.abort(), 90000);

      // If user cancels the main search, also abort the merge
      const onMainAbort = () => mergeController.abort();
      signal.addEventListener('abort', onMainAbort);

      try {
        const merged = await mergeSearch({
          geminiRaw,
          braveResults: braveData.map(r => ({ title: r.title, url: r.url, content: r.content })),
          tavilyResults: tavilyData.map(r => ({ title: r.title, url: r.url, content: r.content })),
          directResults: directData.length > 0 ? directData : undefined,
          internationalResults: internationalData.length > 0 ? internationalData.map(r => ({ title: r.title, url: r.url, description: r.description })) : undefined,
          ecommerceResults: ecommerceData.length > 0 ? ecommerceData : undefined,
        }, mergeController.signal);

        clearTimeout(mergeTimeoutId);
        signal.removeEventListener('abort', onMainAbort);

        if (signal.aborted) return;

        setSourceStatus(prev => ({ ...prev, merging: 'done' }));
        setResults(merged);
        setMarketData(query, merged);

        // Save price history for trend tracking (fire-and-forget)
        if (merged.prices && merged.prices.length > 0) {
          savePriceHistory(query, merged.prices.map(p => ({
            price: p.price,
            priceUnit: p.priceUnit || '元',
            platform: p.platform,
          }))).catch(e => console.warn('Price history save failed:', e));
          // Load trend data
          loadTrend(query, trendDays);
        }
      } catch (mergeErr) {
        clearTimeout(mergeTimeoutId);
        signal.removeEventListener('abort', onMainAbort);

        if (!signal.aborted) {
          console.error('Merge analysis failed:', mergeErr);
          setSourceStatus(prev => ({ ...prev, merging: 'error' }));
          // Don't throw — search results already fetched, show partial state
        }
      }
    } catch (error) {
      if (signal.aborted) {
        console.warn('搜索被用户取消');
      } else {
        console.error("Market Search Failed:", error);
        alert(`搜索失败：${error instanceof Error ? error.message : '未知错误'}`);
      }
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

  const renderValue = (value: string) => {
    // "0.67 元/kg (生意社, 山东济南)" → 数字部分加粗 + 括号注释变灰变小
    const match = value.match(/^(.+?)(\s*\(.+\)\s*)$/);
    if (match) {
      return (
        <>
          <span className="font-semibold">{match[1]}</span>
          <span className="text-[#7a7a78] font-normal text-[11px]">{match[2]}</span>
        </>
      );
    }
    return <span className="font-semibold">{value}</span>;
  };

  const renderSummaryTable = (table: MarketSummaryRow[]) => (
    <div className="overflow-hidden rounded-lg border border-[#e0ddd5]">
      <table className="w-full text-sm table-fixed">
        <thead>
          <tr className="bg-[#f0eeeb]">
            <th className="text-left px-3 py-2 text-[9px] font-bold text-[#4a4a48] uppercase tracking-widest w-[38%]">指标</th>
            <th className="text-left px-3 py-2 text-[9px] font-bold text-[#4a4a48] uppercase tracking-widest w-[62%]">数据</th>
          </tr>
        </thead>
        <tbody>
          {table.map((row, idx) => (
            <tr key={idx} className={idx % 2 === 0 ? 'bg-white' : 'bg-[#f9f9f8]'}>
              <td className="px-3 py-2 text-[#4a4a48] font-medium text-xs leading-snug">{row.label}</td>
              <td className="px-3 py-2 text-[#191918] text-xs leading-snug">{renderValue(row.value)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );

  const filteredPrices = useMemo(() => {
    if (!results?.prices) return [];
    if (activeCategory === 'all') return results.prices;
    return results.prices.filter(p => p.platformCategory === activeCategory);
  }, [results, activeCategory]);

  const categoryCounts = useMemo(() => {
    const counts: Record<string, number> = { all: 0, B2C: 0, B2B: 0, industry: 0, international: 0 };
    if (!results?.prices) return counts;
    counts.all = results.prices.length;
    for (const p of results.prices) {
      if (p.platformCategory && counts[p.platformCategory] !== undefined) {
        counts[p.platformCategory]++;
      }
    }
    return counts;
  }, [results]);

  return (
    <div className="max-w-7xl mx-auto space-y-8 animate-in fade-in duration-500">
      {/* Hero Search Section */}
      <div className="bg-[#f9f9f8] border border-[#e0ddd5] rounded-xl p-12 relative overflow-hidden text-center" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.06)' }}>
        <div className="absolute -top-24 -left-24 w-64 h-64 bg-[#d97757]/5 blur-[100px] rounded-full"></div>
        <div className="relative z-10">
          <h2 className="text-3xl font-semibold text-[#191918] mb-2 tracking-tight">市场聚合价格搜索</h2>
          <p className="text-[#5c5c5a] mt-2 text-sm">六源驱动：Gemini 3.1 Pro + Google Grounding & Brave & Tavily + 行业直连 + 国际平台 + 电商定向</p>

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
              <span className="w-1.5 h-1.5 bg-violet-500 rounded-full mr-2"></span> 行业直连
            </div>
            <div className="flex items-center text-[10px] text-[#5c5c5a] font-bold uppercase tracking-widest">
              <span className="w-1.5 h-1.5 bg-emerald-500 rounded-full mr-2"></span> 国际平台
            </div>
            <div className="flex items-center text-[10px] text-[#5c5c5a] font-bold uppercase tracking-widest">
              <span className="w-1.5 h-1.5 bg-pink-500 rounded-full mr-2"></span> 电商平台
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
            <div className="flex items-center justify-between">
              <div className="flex items-center space-x-3">
                {statusIcon(sourceStatus.direct)}
                <span className="text-sm text-[#4a4a48]">行业权威网站直连</span>
              </div>
              <span className="text-[10px] text-[#5c5c5a] font-mono">
                {sourceStatus.direct === 'loading' ? '抓取中...' : sourceStatus.direct === 'done' ? '已匹配' : sourceStatus.direct === 'error' ? '失败' : '无匹配品种'}
              </span>
            </div>
            <div className="flex items-center justify-between">
              <div className="flex items-center space-x-3">
                {statusIcon(sourceStatus.international)}
                <span className="text-sm text-[#4a4a48]">国际平台搜索</span>
              </div>
              <span className="text-[10px] text-[#5c5c5a] font-mono">
                {sourceStatus.international === 'loading' ? '翻译+搜索中...' : sourceStatus.international === 'done' ? '已完成' : sourceStatus.international === 'error' ? '失败' : '等待'}
              </span>
            </div>
            <div className="flex items-center justify-between">
              <div className="flex items-center space-x-3">
                {statusIcon(sourceStatus.ecommerce)}
                <span className="text-sm text-[#4a4a48]">电商平台定向搜索</span>
              </div>
              <span className="text-[10px] text-[#5c5c5a] font-mono">
                {sourceStatus.ecommerce === 'loading' ? '搜索中...' : sourceStatus.ecommerce === 'done' ? '已完成' : sourceStatus.ecommerce === 'error' ? '失败' : '等待'}
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
            <div className="flex items-center justify-between mb-2">
              <h3 className="text-xl font-semibold text-[#191918]">全网实时比价结果</h3>
              <span className="text-xs text-[#5c5c5a]">
                {activeCategory === 'all'
                  ? `找到 ${results.prices.length} 条相关报价`
                  : `筛选 ${filteredPrices.length} / ${results.prices.length} 条`}
              </span>
            </div>

            {/* Category Filter Tabs */}
            <div className="flex items-center space-x-2 mb-4 overflow-x-auto no-scrollbar pb-1">
              {CATEGORY_TABS.map(tab => (
                <button
                  key={tab.key}
                  onClick={() => setActiveCategory(tab.key)}
                  className={`flex items-center space-x-1.5 px-4 py-2 rounded-lg text-xs font-medium transition-all whitespace-nowrap ${
                    activeCategory === tab.key
                      ? 'bg-[#d97757] text-white shadow-sm'
                      : 'bg-[#f0eeeb] text-[#4a4a48] hover:bg-[#e0ddd5]'
                  }`}
                >
                  <i className={`fas ${tab.icon} text-[10px]`}></i>
                  <span>{tab.label}</span>
                  <span className={`px-1.5 py-0.5 rounded-full text-[9px] font-bold ${
                    activeCategory === tab.key
                      ? 'bg-white/20 text-white'
                      : 'bg-[#e0ddd5] text-[#5c5c5a]'
                  }`}>
                    {categoryCounts[tab.key] || 0}
                  </span>
                </button>
              ))}
            </div>

            <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
              {filteredPrices.map((item, idx) => {
                const isGoogle = item.platform.includes('[Google]');
                const isBrave = item.platform.includes('[Brave]');
                const isTavily = item.platform.includes('[Tavily]');
                const isDirect = item.platform.includes('[直连]');
                const isInternational = item.platform.includes('[国际]');
                const isEcommerce = item.platform.includes('[电商]');
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
                        {isDirect && (
                          <span className="px-1.5 py-0.5 bg-violet-500/10 text-violet-500 text-[8px] font-bold rounded-full">直</span>
                        )}
                        {isInternational && (
                          <span className="px-1.5 py-0.5 bg-emerald-500/10 text-emerald-500 text-[8px] font-bold rounded-full">国际</span>
                        )}
                        {isEcommerce && (
                          <span className="px-1.5 py-0.5 bg-pink-500/10 text-pink-500 text-[8px] font-bold rounded-full">电商</span>
                        )}
                      </div>
                      <p className="text-2xl font-bold text-[#191918] group-hover:text-[#d97757] transition-colors">
                        ¥{item.price.toLocaleString()}
                        {item.priceUnit && item.priceUnit !== '元' && (
                          <span className="text-sm font-normal text-[#7a7a78] ml-1">/{item.priceUnit.replace(/^元\/?/, '')}</span>
                        )}
                      </p>
                    </div>
                    <h4 className="text-sm font-medium text-[#4a4a48] line-clamp-2 mb-4 h-10 leading-snug">
                      {item.title}
                    </h4>
                    {item.link ? (
                      <a
                        href={item.link}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="flex items-center justify-center w-full py-2 bg-[#f0eeeb] hover:bg-[#e0ddd5] text-[#4a4a48] text-xs font-medium rounded-lg transition-all border border-[#e0ddd5]"
                      >
                        查看商品详情 <i className="fas fa-external-link-alt ml-2 text-[10px]"></i>
                      </a>
                    ) : (
                      <span className="flex items-center justify-center w-full py-2 bg-gray-100 text-gray-400 text-xs rounded-lg cursor-not-allowed">
                        暂无链接
                      </span>
                    )}
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
              <div className="flex items-center flex-wrap gap-1.5 mb-5">
                <span className="px-2 py-0.5 bg-[#d97757]/10 text-[#d97757] text-[9px] font-bold rounded-full">Google</span>
                <span className="text-[#d1cdc4] text-[10px]">+</span>
                <span className="px-2 py-0.5 bg-blue-500/10 text-blue-500 text-[9px] font-bold rounded-full">Brave</span>
                <span className="text-[#d1cdc4] text-[10px]">+</span>
                <span className="px-2 py-0.5 bg-teal-500/10 text-teal-400 text-[9px] font-bold rounded-full">Tavily</span>
                <span className="text-[#d1cdc4] text-[10px]">+</span>
                <span className="px-2 py-0.5 bg-violet-500/10 text-violet-500 text-[9px] font-bold rounded-full">直连</span>
                <span className="text-[#d1cdc4] text-[10px]">+</span>
                <span className="px-2 py-0.5 bg-emerald-500/10 text-emerald-500 text-[9px] font-bold rounded-full">国际</span>
                <span className="text-[#d1cdc4] text-[10px]">+</span>
                <span className="px-2 py-0.5 bg-pink-500/10 text-pink-500 text-[9px] font-bold rounded-full">电商</span>
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

      {/* Price Trend Chart */}
      {results && (
        <div className="bg-[#f9f9f8] border border-[#e0ddd5] rounded-xl p-8 animate-in fade-in duration-500" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.06)' }}>
          <div className="flex items-center justify-between mb-6">
            <div className="flex items-center space-x-3">
              <i className="fas fa-chart-line text-[#d97757]"></i>
              <h3 className="text-lg font-semibold text-[#191918]">价格趋势追踪</h3>
              <span className="text-xs text-[#7a7a78]">搜索越多，趋势越准确</span>
            </div>
            <div className="flex items-center space-x-2">
              {([7, 30, 90] as const).map(d => (
                <button
                  key={d}
                  onClick={() => setTrendDays(d)}
                  className={`px-3 py-1.5 rounded-lg text-xs font-medium transition-all ${trendDays === d ? 'bg-[#d97757] text-white' : 'bg-[#f0eeeb] text-[#4a4a48] hover:bg-[#e0ddd5]'}`}
                >
                  {d}天
                </button>
              ))}
            </div>
          </div>

          {trendLoading ? (
            <div className="flex items-center justify-center py-16">
              <i className="fas fa-spinner animate-spin text-[#d97757] text-lg mr-3"></i>
              <span className="text-sm text-[#7a7a78]">加载趋势数据...</span>
            </div>
          ) : trendData.length === 0 ? (
            <div className="flex flex-col items-center justify-center py-16 text-[#7a7a78]">
              <i className="fas fa-chart-area text-3xl opacity-20 mb-3"></i>
              <p className="text-sm">暂无历史价格数据</p>
              <p className="text-xs mt-1">每次搜索会自动保存价格快照，积累后将显示趋势图</p>
            </div>
          ) : (
            <div>
              {/* Summary Cards */}
              {trendData.length >= 2 && (() => {
                const latest = trendData[trendData.length - 1];
                const earliest = trendData[0];
                const avgChange = latest.avg_price && earliest.avg_price && earliest.avg_price > 0
                  ? ((latest.avg_price - earliest.avg_price) / earliest.avg_price * 100)
                  : 0;
                return (
                  <div className="grid grid-cols-4 gap-4 mb-6">
                    <div className="bg-white rounded-lg p-4 border border-[#e0ddd5]">
                      <p className="text-[10px] font-bold text-[#7a7a78] uppercase tracking-widest mb-1">当前均价</p>
                      <p className="text-xl font-bold text-[#191918]">¥{latest.avg_price?.toLocaleString()}</p>
                    </div>
                    <div className="bg-white rounded-lg p-4 border border-[#e0ddd5]">
                      <p className="text-[10px] font-bold text-[#7a7a78] uppercase tracking-widest mb-1">期间最低</p>
                      <p className="text-xl font-bold text-emerald-600">¥{Math.min(...trendData.map(d => d.min_price)).toLocaleString()}</p>
                    </div>
                    <div className="bg-white rounded-lg p-4 border border-[#e0ddd5]">
                      <p className="text-[10px] font-bold text-[#7a7a78] uppercase tracking-widest mb-1">期间最高</p>
                      <p className="text-xl font-bold text-red-500">¥{Math.max(...trendData.map(d => d.max_price)).toLocaleString()}</p>
                    </div>
                    <div className="bg-white rounded-lg p-4 border border-[#e0ddd5]">
                      <p className="text-[10px] font-bold text-[#7a7a78] uppercase tracking-widest mb-1">涨跌幅</p>
                      <p className={`text-xl font-bold ${avgChange >= 0 ? 'text-red-500' : 'text-emerald-600'}`}>
                        {avgChange >= 0 ? '+' : ''}{avgChange.toFixed(1)}%
                      </p>
                    </div>
                  </div>
                );
              })()}

              <ResponsiveContainer width="100%" height={300}>
                <AreaChart data={trendData} margin={{ top: 10, right: 30, left: 0, bottom: 0 }}>
                  <defs>
                    <linearGradient id="priceRange" x1="0" y1="0" x2="0" y2="1">
                      <stop offset="5%" stopColor="#d97757" stopOpacity={0.15} />
                      <stop offset="95%" stopColor="#d97757" stopOpacity={0.02} />
                    </linearGradient>
                  </defs>
                  <CartesianGrid strokeDasharray="3 3" stroke="#e0ddd5" />
                  <XAxis
                    dataKey="search_date"
                    tick={{ fontSize: 11, fill: '#7a7a78' }}
                    tickFormatter={(v: string) => v.slice(5)}
                  />
                  <YAxis
                    tick={{ fontSize: 11, fill: '#7a7a78' }}
                    tickFormatter={(v: number) => `¥${v.toLocaleString()}`}
                    domain={['dataMin - 10', 'dataMax + 10']}
                  />
                  <Tooltip
                    contentStyle={{ background: '#fff', border: '1px solid #e0ddd5', borderRadius: '8px', fontSize: '12px' }}
                    formatter={(value: number, name: string) => [
                      `¥${value.toLocaleString()}`,
                      name === 'max_price' ? '最高价' : name === 'min_price' ? '最低价' : '均价'
                    ]}
                    labelFormatter={(label: string) => `日期: ${label}`}
                  />
                  <Area type="monotone" dataKey="max_price" stroke="transparent" fill="url(#priceRange)" fillOpacity={1} />
                  <Area type="monotone" dataKey="min_price" stroke="transparent" fill="#fff" fillOpacity={1} />
                  <Line type="monotone" dataKey="avg_price" stroke="#d97757" strokeWidth={2} dot={{ fill: '#d97757', r: 4 }} activeDot={{ r: 6 }} />
                  <Line type="monotone" dataKey="max_price" stroke="#ef4444" strokeWidth={1} strokeDasharray="4 4" dot={false} />
                  <Line type="monotone" dataKey="min_price" stroke="#10b981" strokeWidth={1} strokeDasharray="4 4" dot={false} />
                </AreaChart>
              </ResponsiveContainer>
              <div className="flex items-center justify-center space-x-6 mt-4 text-[10px] text-[#7a7a78]">
                <div className="flex items-center space-x-1.5"><span className="w-3 h-0.5 bg-[#d97757] rounded"></span><span>均价</span></div>
                <div className="flex items-center space-x-1.5"><span className="w-3 h-0.5 bg-red-400 rounded" style={{ borderTop: '1px dashed #ef4444' }}></span><span>最高价</span></div>
                <div className="flex items-center space-x-1.5"><span className="w-3 h-0.5 bg-emerald-400 rounded" style={{ borderTop: '1px dashed #10b981' }}></span><span>最低价</span></div>
                <div className="flex items-center space-x-1.5"><span className="w-3 h-3 bg-[#d97757]/10 rounded"></span><span>价格区间</span></div>
              </div>
            </div>
          )}
        </div>
      )}

      {/* No Results Placeholder */}
      {!results && !isLoading && (
        <div className="py-20 text-center flex flex-col items-center">
          <div className="w-20 h-20 bg-[#f9f9f8] rounded-full flex items-center justify-center mb-6 text-3xl opacity-20 ring-1 ring-[#e0ddd5]">
            <i className="fas fa-search-dollar"></i>
          </div>
          <h3 className="text-[#5c5c5a] font-medium">输入关键词并开始市场调研</h3>
          <p className="text-[#7a7a78] text-xs mt-1">六源搜索 + AI 智能合并，覆盖国内外 30+ 电商/批发/垂直平台</p>
        </div>
      )}
    </div>
  );
};

export default MarketSearchPage;
