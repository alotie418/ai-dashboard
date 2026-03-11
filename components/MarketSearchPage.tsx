import React, { useState, useEffect, useMemo, useCallback, Component, ErrorInfo, ReactNode } from 'react';
import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import rehypeSanitize from 'rehype-sanitize';
import { fetchPriceHistory } from '../services/api';
import { PlatformCategory, MarketSummaryRow, PriceHistoryPoint, AgentPhase, PhaseLogEntry } from '../types';
import { useMarketData } from '../contexts/MarketDataContext';
import { useAgenticSearch } from '../hooks/useAgenticSearch';
import { AreaChart, Area, Line, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer } from 'recharts';

/** ErrorBoundary: prevents markdown/chart rendering crashes from breaking the entire page */
class AnalysisErrorBoundary extends Component<{ children: ReactNode }, { hasError: boolean; error: string }> {
  constructor(props: { children: ReactNode }) {
    super(props);
    this.state = { hasError: false, error: '' };
  }
  static getDerivedStateFromError(error: Error) {
    return { hasError: true, error: error.message };
  }
  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error('AnalysisErrorBoundary caught:', error, info);
  }
  render() {
    if (this.state.hasError) {
      return (
        <div className="bg-red-50 border border-red-200 rounded-xl p-6 text-center">
          <i className="fas fa-exclamation-triangle text-red-400 text-2xl mb-3"></i>
          <p className="text-sm text-red-700 font-medium">分析内容渲染失败</p>
          <p className="text-xs text-red-500 mt-1">{this.state.error}</p>
          <button
            onClick={() => this.setState({ hasError: false, error: '' })}
            className="mt-3 px-4 py-1.5 bg-red-100 hover:bg-red-200 text-red-700 text-xs rounded-lg transition-colors"
          >
            重试渲染
          </button>
        </div>
      );
    }
    return this.props.children;
  }
}

const CATEGORY_TABS: { key: 'all' | PlatformCategory; label: string; icon: string }[] = [
  { key: 'all', label: '全部', icon: 'fa-layer-group' },
  { key: 'B2C', label: 'B2C零售', icon: 'fa-shopping-bag' },
  { key: 'B2B', label: 'B2B批发', icon: 'fa-industry' },
  { key: 'industry', label: '行业数据', icon: 'fa-chart-bar' },
  { key: 'international', label: '跨境平台', icon: 'fa-globe' },
];

const PHASE_CONFIG: Record<AgentPhase, { icon: string; label: string; color: string }> = {
  idle: { icon: 'fa-circle', label: '等待', color: 'text-gray-400' },
  planning: { icon: 'fa-brain', label: '规划器', color: 'text-violet-500' },
  searching: { icon: 'fa-search', label: '六源搜索', color: 'text-blue-500' },
  ranking: { icon: 'fa-sort-amount-down', label: '检索排序', color: 'text-cyan-500' },
  extracting: { icon: 'fa-flask', label: '证据提取', color: 'text-amber-500' },
  synthesizing: { icon: 'fa-lightbulb', label: '综合分析', color: 'text-emerald-500' },
  critiquing: { icon: 'fa-gavel', label: '评审', color: 'text-red-500' },
  iterating: { icon: 'fa-redo', label: '迭代搜索', color: 'text-purple-500' },
  complete: { icon: 'fa-check-circle', label: '完成', color: 'text-emerald-500' },
  error: { icon: 'fa-exclamation-triangle', label: '错误', color: 'text-red-500' },
};

/**
 * Clean up Gemini grounding URLs and fix markdown formatting in analysis text.
 * - Strips long vertexaisearch.cloud.google.com/grounding-api-redirect/... URLs
 * - Ensures ### headings are on their own line for proper markdown rendering
 * - Cleans up messy (来源: <url>) patterns
 */
function cleanAnalysisText(text: string): string {
  if (!text) return text;

  let cleaned = text;

  // 1. Remove inline Gemini grounding-api-redirect URLs entirely
  //    Pattern: (来源: https://vertexaisearch.cloud.google.com/grounding-api-redirect/...) or similar
  cleaned = cleaned.replace(
    /\(来源[:：]\s*https?:\/\/vertexaisearch\.cloud\.google\.com\/grounding-api-redirect\/[^\s)]*\s*\)/gi,
    ''
  );

  // 2. Remove standalone grounding URLs (not wrapped in parentheses)
  cleaned = cleaned.replace(
    /来源[:：]\s*https?:\/\/vertexaisearch\.cloud\.google\.com\/grounding-api-redirect\/[^\s)}\]]*\s*/gi,
    ''
  );

  // 3. Remove any remaining bare grounding-api-redirect URLs
  cleaned = cleaned.replace(
    /https?:\/\/vertexaisearch\.cloud\.google\.com\/grounding-api-redirect\/[^\s)}\]<]*/gi,
    ''
  );

  // 4. Clean up empty parentheses or brackets left behind: (来源: ) → remove
  cleaned = cleaned.replace(/\(来源[:：]?\s*\)/g, '');

  // 5. Convert remaining (来源: URL) patterns to proper markdown links
  //    This prevents auto-linker from bleeding URLs into surrounding text
  cleaned = cleaned.replace(
    /\(来源[:：]\s*(https?:\/\/[^\s)]+)\s*\)/g,
    '([来源]($1))'
  );

  // 6. Convert standalone 来源: URL patterns (not in parentheses) to markdown links
  cleaned = cleaned.replace(
    /来源[:：]\s*(https?:\/\/[^\s)}\]<,，。]+)/g,
    '[来源]($1)'
  );

  // 7. Ensure markdown headings (##, ###, ####) are on their own line
  //    If a heading marker appears inline (not at start of line), add a newline before it
  cleaned = cleaned.replace(/([^\n])(#{2,4}\s)/g, '$1\n\n$2');

  // 8. Clean up multiple consecutive blank lines
  cleaned = cleaned.replace(/\n{3,}/g, '\n\n');

  return cleaned.trim();
}

const MarketSearchPage: React.FC = () => {
  const [query, setQuery] = useState('');
  const [activeCategory, setActiveCategory] = useState<'all' | PlatformCategory>('all');
  const { setMarketData } = useMarketData();

  // Price trend state
  const [trendData, setTrendData] = useState<PriceHistoryPoint[]>([]);
  const [trendDays, setTrendDays] = useState<7 | 30 | 90>(30);
  const [trendLoading, setTrendLoading] = useState(false);

  // Timeline collapsed state
  const [timelineExpanded, setTimelineExpanded] = useState(true);
  const [tableExpanded, setTableExpanded] = useState(false);

  // Agentic search hook
  const { state, isSearching, error, sourceCounts, startSearch, cancelSearch } = useAgenticSearch();

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

  // Reload trend when days change
  useEffect(() => {
    if (state.synthesis && query.trim()) {
      loadTrend(query.trim(), trendDays);
    }
  }, [trendDays]); // eslint-disable-line react-hooks/exhaustive-deps

  // Set market data context when synthesis completes
  useEffect(() => {
    if (state.phase === 'complete' && state.synthesis) {
      setMarketData(state.original_query, state.synthesis);
      loadTrend(state.original_query, trendDays);
    }
  }, [state.phase]); // eslint-disable-line react-hooks/exhaustive-deps

  const handleSearch = async (e?: React.FormEvent) => {
    if (e) e.preventDefault();
    if (!query.trim() || isSearching) return;
    setActiveCategory('all');
    await startSearch(query.trim());
  };

  // Filtered prices
  const filteredPrices = useMemo(() => {
    if (!state.synthesis?.prices) return [];
    if (activeCategory === 'all') return state.synthesis.prices;
    return state.synthesis.prices.filter(p => p.platformCategory === activeCategory);
  }, [state.synthesis, activeCategory]);

  const categoryCounts = useMemo(() => {
    const counts: Record<string, number> = { all: 0, B2C: 0, B2B: 0, industry: 0, international: 0 };
    if (!state.synthesis?.prices) return counts;
    counts.all = state.synthesis.prices.length;
    for (const p of state.synthesis.prices) {
      if (p.platformCategory && counts[p.platformCategory] !== undefined) {
        counts[p.platformCategory]++;
      }
    }
    return counts;
  }, [state.synthesis]);

  // Group logs by iteration
  const logsByIteration = useMemo(() => {
    const grouped: Record<number, PhaseLogEntry[]> = {};
    for (const log of state.phase_log) {
      const it = log.iteration;
      if (!grouped[it]) grouped[it] = [];
      grouped[it].push(log);
    }
    return grouped;
  }, [state.phase_log]);

  const confidencePercent = Math.round(state.confidence_score * 100);

  const renderValue = (value: string) => {
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

  /** Pick the top N stat-card-worthy rows from summaryTable */
  const extractStatCards = (table: MarketSummaryRow[]) => {
    const priceKeywords = ['最低', '最高', '均价', '区间', '价格'];
    const top = table.filter(r => priceKeywords.some(k => r.label.includes(k))).slice(0, 4);
    if (top.length < 2) return table.slice(0, 4);
    return top;
  };

  return (
    <div className="max-w-7xl mx-auto space-y-8 animate-in fade-in duration-500">
      {/* Hero Search Section */}
      <div className="bg-[#f9f9f8] border border-[#e0ddd5] rounded-xl p-12 relative overflow-hidden text-center" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.06)' }}>
        <div className="absolute -top-24 -left-24 w-64 h-64 bg-[#d97757]/5 blur-[100px] rounded-full"></div>
        <div className="relative z-10">
          <h2 className="text-3xl font-semibold text-[#191918] mb-2 tracking-tight">
            <i className="fas fa-brain text-[#d97757] mr-3"></i>
            AI 深度市场研究
          </h2>
          <p className="text-[#5c5c5a] mt-2 text-sm">
            Agentic RAG · 智能规划 → 多源搜索 → 证据提取 → 综合分析 → 自迭代评审
          </p>

          <form onSubmit={handleSearch} className="max-w-2xl mx-auto relative group mt-6">
            <input
              type="text"
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder="输入产品名称，如：碳酸钙、不锈钢 304 卷板、iPhone 16 Pro..."
              className="w-full bg-white border border-[#e0ddd5] rounded-xl py-5 pl-8 pr-36 text-[#191918] placeholder:text-[#7a7a78] outline-none focus:border-[#d97757] transition-all group-hover:border-[#d1cdc4]"
            />
            <div className="absolute right-3 top-1/2 -translate-y-1/2 flex items-center space-x-2">
              {isSearching && (
                <button
                  type="button"
                  onClick={cancelSearch}
                  className="px-4 py-3 bg-red-500 hover:bg-red-600 text-white font-semibold rounded-lg transition-all text-sm"
                >
                  <i className="fas fa-stop mr-1.5"></i>停止
                </button>
              )}
              <button
                type="submit"
                disabled={isSearching || !query.trim()}
                className="px-8 py-3 bg-[#d97757] hover:bg-[#c4694d] disabled:opacity-50 disabled:bg-[#f0eeeb] text-white font-semibold rounded-lg transition-all active:scale-95"
              >
                {isSearching ? <i className="fas fa-spinner animate-spin"></i> : '深度研究'}
              </button>
            </div>
          </form>

          <div className="mt-5 flex justify-center items-center space-x-4 flex-wrap gap-y-2">
            {[
              { color: 'bg-[#d97757]', label: 'Gemini Grounding' },
              { color: 'bg-blue-500', label: 'Brave Search' },
              { color: 'bg-teal-500', label: 'Tavily Search' },
              { color: 'bg-violet-500', label: '行业直连' },
              { color: 'bg-emerald-500', label: '国际平台' },
              { color: 'bg-pink-500', label: '电商平台' },
            ].map(s => (
              <div key={s.label} className="flex items-center text-[10px] text-[#5c5c5a] font-bold uppercase tracking-widest">
                <span className={`w-1.5 h-1.5 ${s.color} rounded-full mr-1.5`}></span>{s.label}
              </div>
            ))}
          </div>
        </div>
      </div>

      {/* Agentic Timeline Panel */}
      {(isSearching || state.phase_log.length > 0) && (
        <div className="bg-[#f9f9f8] border border-[#e0ddd5] rounded-xl overflow-hidden" style={{ boxShadow: '0 2px 12px rgba(0,0,0,0.04)' }}>
          {/* Header */}
          <div
            className="px-6 py-4 flex items-center justify-between cursor-pointer hover:bg-[#f0eeeb] transition-colors"
            onClick={() => setTimelineExpanded(!timelineExpanded)}
          >
            <div className="flex items-center space-x-3">
              <i className={`fas fa-robot text-[#d97757]`}></i>
              <span className="font-semibold text-[#191918] text-sm">
                Agentic 深度研究
                {state.iteration_count > 0 && ` · 第 ${state.iteration_count}/${state.max_iterations} 轮`}
              </span>
              {state.confidence_score > 0 && (
                <span className={`text-xs font-bold px-2 py-0.5 rounded-full ${
                  confidencePercent >= 80 ? 'bg-emerald-100 text-emerald-700' :
                  confidencePercent >= 60 ? 'bg-amber-100 text-amber-700' :
                  'bg-red-100 text-red-700'
                }`}>
                  信心 {confidencePercent}%
                </span>
              )}
              {isSearching && (
                <span className="flex items-center space-x-1.5 text-xs text-[#d97757]">
                  <i className="fas fa-spinner animate-spin text-[10px]"></i>
                  <span>{PHASE_CONFIG[state.phase]?.label || '处理中'}...</span>
                </span>
              )}
            </div>
            <div className="flex items-center space-x-3">
              {/* Source Counts Summary */}
              {(sourceCounts.gemini + sourceCounts.brave + sourceCounts.tavily + sourceCounts.direct + sourceCounts.international + sourceCounts.ecommerce) > 0 && (
                <span className="text-[10px] text-[#7a7a78] font-mono">
                  {sourceCounts.uniqueUrls || '—'} 独立来源 / {sourceCounts.gemini + sourceCounts.brave + sourceCounts.tavily + sourceCounts.direct + sourceCounts.international + sourceCounts.ecommerce} 条原始数据
                </span>
              )}
              <i className={`fas fa-chevron-${timelineExpanded ? 'up' : 'down'} text-[#7a7a78] text-xs`}></i>
            </div>
          </div>

          {/* Confidence Progress Bar */}
          {state.confidence_score > 0 && (
            <div className="px-6 pb-2">
              <div className="w-full h-1.5 bg-[#e0ddd5] rounded-full overflow-hidden">
                <div
                  className={`h-full rounded-full transition-all duration-1000 ${
                    confidencePercent >= 80 ? 'bg-emerald-500' :
                    confidencePercent >= 60 ? 'bg-amber-500' :
                    'bg-red-500'
                  }`}
                  style={{ width: `${confidencePercent}%` }}
                ></div>
              </div>
            </div>
          )}

          {/* Timeline Steps */}
          {timelineExpanded && (
            <div className="px-6 pb-5 space-y-1">
              {Object.entries(logsByIteration).map(([iterStr, logs]) => {
                const iter = Number(iterStr);
                return (
                  <div key={iter}>
                    {iter > 0 && (
                      <div className="flex items-center space-x-2 mt-3 mb-1">
                        <span className="text-[10px] font-bold text-[#7a7a78] uppercase tracking-widest">
                          第 {iter} 轮
                        </span>
                        <div className="flex-1 h-px bg-[#e0ddd5]"></div>
                      </div>
                    )}
                    {logs.map((log, idx) => {
                      const config = PHASE_CONFIG[log.phase] || PHASE_CONFIG.idle;
                      const isCurrentPhase = isSearching && idx === logs.length - 1 && iter === state.iteration_count;
                      return (
                        <div key={`${iter}-${idx}`} className="flex items-start space-x-3 py-1.5">
                          <div className="mt-0.5">
                            {isCurrentPhase && state.phase === log.phase ? (
                              <i className={`fas fa-spinner animate-spin ${config.color} text-xs`}></i>
                            ) : log.phase === 'critiquing' && log.summary.includes('不通过') ? (
                              <i className="fas fa-exclamation-circle text-amber-500 text-xs"></i>
                            ) : (
                              <i className={`fas fa-check-circle text-emerald-400 text-xs`}></i>
                            )}
                          </div>
                          <div className="flex-1 min-w-0">
                            <div className="flex items-center space-x-2">
                              <span className={`text-xs font-semibold ${config.color}`}>{config.label}</span>
                              <span className="text-[10px] text-[#7a7a78] font-mono">{(log.duration_ms / 1000).toFixed(1)}s</span>
                            </div>
                            <p className="text-[11px] text-[#5c5c5a] mt-0.5 truncate">{log.summary}</p>
                          </div>
                        </div>
                      );
                    })}
                  </div>
                );
              })}

              {/* Current active phase (not yet logged) */}
              {isSearching && state.phase !== 'idle' && !state.phase_log.some(l => l.phase === state.phase && l.iteration === state.iteration_count) && (
                <div className="flex items-start space-x-3 py-1.5">
                  <div className="mt-0.5">
                    <i className={`fas fa-spinner animate-spin ${PHASE_CONFIG[state.phase]?.color || 'text-gray-400'} text-xs`}></i>
                  </div>
                  <div>
                    <span className={`text-xs font-semibold ${PHASE_CONFIG[state.phase]?.color}`}>
                      {PHASE_CONFIG[state.phase]?.label}
                    </span>
                    <span className="text-[10px] text-[#7a7a78] ml-2">处理中...</span>
                  </div>
                </div>
              )}
            </div>
          )}
        </div>
      )}

      {/* Error */}
      {error && (
        <div className="bg-red-50 border border-red-200 rounded-xl p-6 text-center">
          <i className="fas fa-exclamation-triangle text-red-500 text-xl mb-2"></i>
          <p className="text-red-700 text-sm">{error}</p>
        </div>
      )}

      {/* Results Section */}
      {state.synthesis && (
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-8 animate-in slide-in-from-bottom-8 duration-700">

          {/* LEFT: Price Cards (2/3 width) */}
          <div className="lg:col-span-2 space-y-4">
            <div className="flex items-center justify-between mb-2">
              <h3 className="text-xl font-semibold text-[#191918]">全网实时比价结果</h3>
              <span className="text-xs text-[#5c5c5a]">
                {activeCategory === 'all'
                  ? `找到 ${state.synthesis.prices?.length || 0} 条相关报价`
                  : `筛选 ${filteredPrices.length} / ${state.synthesis.prices?.length || 0} 条`}
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

            {/* Price Cards Grid */}
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
              {filteredPrices.map((item, idx) => (
                <div key={idx} className="bg-[#f9f9f8] border border-[#e0ddd5] rounded-xl p-6 hover:border-[#d97757]/40 transition-all group">
                  <div className="flex justify-between items-start mb-4">
                    <div className="flex items-center space-x-2">
                      <span className="px-2 py-1 bg-[#d97757]/10 text-[#d97757] text-[10px] font-bold rounded uppercase tracking-wider">
                        {item.platform.replace(/\s*\[.*?\]\s*/, '')}
                      </span>
                      {item.platformCategory && (
                        <span className={`px-1.5 py-0.5 text-[8px] font-bold rounded-full ${
                          item.platformCategory === 'B2C' ? 'bg-pink-100 text-pink-600' :
                          item.platformCategory === 'B2B' ? 'bg-blue-100 text-blue-600' :
                          item.platformCategory === 'industry' ? 'bg-violet-100 text-violet-600' :
                          'bg-emerald-100 text-emerald-600'
                        }`}>
                          {item.platformCategory === 'B2C' ? '零售' :
                           item.platformCategory === 'B2B' ? '批发' :
                           item.platformCategory === 'industry' ? '行业' : '国际'}
                        </span>
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
              ))}
            </div>

            {filteredPrices.length === 0 && (
              <div className="text-center py-12 text-[#7a7a78]">
                <i className="fas fa-inbox text-2xl opacity-20 mb-3"></i>
                <p className="text-sm">该分类暂无报价数据</p>
              </div>
            )}
          </div>

          {/* RIGHT: AI Analysis Report (1/3 width) */}
          <div className="lg:col-span-1 space-y-5">
            {/* Confidence Score Card */}
            <div className="bg-gradient-to-br from-[#f9f9f8] to-[#f0eeeb] border border-[#e0ddd5] rounded-xl p-5" style={{ boxShadow: '0 2px 12px rgba(0,0,0,0.04)' }}>
              <div className="flex items-center justify-between mb-3">
                <span className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">
                  <i className="fas fa-shield-alt mr-1.5"></i>研究信心评分
                </span>
                <span className={`text-2xl font-bold ${
                  confidencePercent >= 80 ? 'text-emerald-600' :
                  confidencePercent >= 60 ? 'text-amber-600' :
                  'text-red-600'
                }`}>
                  {confidencePercent}%
                </span>
              </div>
              <div className="w-full h-2 bg-[#e0ddd5] rounded-full overflow-hidden">
                <div
                  className={`h-full rounded-full transition-all duration-1000 ${
                    confidencePercent >= 80 ? 'bg-emerald-500' :
                    confidencePercent >= 60 ? 'bg-amber-500' :
                    'bg-red-500'
                  }`}
                  style={{ width: `${confidencePercent}%` }}
                ></div>
              </div>
              <div className="flex items-center justify-between mt-2 text-[10px] text-[#7a7a78]">
                <span>{state.iteration_count} 轮迭代</span>
                <span>{state.evidence_pool.length} 条证据</span>
                <span>{state.search_results.length} 条搜索结果</span>
              </div>
            </div>

            {/* Consensus & Contradictions */}
            {(state.synthesis.consensus?.length > 0 || state.synthesis.contradictions?.length > 0) && (
              <div className="space-y-3">
                {state.synthesis.consensus?.length > 0 && (
                  <div className="bg-emerald-50/80 border border-emerald-200/60 rounded-xl p-4">
                    <h4 className="text-[10px] font-bold text-emerald-700 uppercase tracking-widest mb-2 flex items-center">
                      <span className="w-0.5 h-3 bg-emerald-500 rounded-full mr-2"></span>
                      <i className="fas fa-check-double mr-1.5"></i>多源共识
                    </h4>
                    <ul className="space-y-1.5">
                      {state.synthesis.consensus.map((c, i) => (
                        <li key={i} className="text-xs text-emerald-800 leading-relaxed flex items-start">
                          <i className="fas fa-circle text-[4px] text-emerald-400 mt-1.5 mr-2 flex-shrink-0"></i>
                          <span className="markdown-inline">
                            <ReactMarkdown remarkPlugins={[remarkGfm]} rehypePlugins={[rehypeSanitize]}>
                              {cleanAnalysisText(c)}
                            </ReactMarkdown>
                          </span>
                        </li>
                      ))}
                    </ul>
                  </div>
                )}

                {state.synthesis.contradictions?.length > 0 && (
                  <div className="bg-amber-50/80 border border-amber-200/60 rounded-xl p-4">
                    <h4 className="text-[10px] font-bold text-amber-700 uppercase tracking-widest mb-2 flex items-center">
                      <span className="w-0.5 h-3 bg-amber-500 rounded-full mr-2"></span>
                      <i className="fas fa-exclamation-triangle mr-1.5"></i>矛盾发现
                    </h4>
                    <ul className="space-y-1.5">
                      {state.synthesis.contradictions.map((c, i) => (
                        <li key={i} className="text-xs text-amber-800 leading-relaxed flex items-start">
                          <i className="fas fa-circle text-[4px] text-amber-400 mt-1.5 mr-2 flex-shrink-0"></i>
                          <span className="markdown-inline">
                            <ReactMarkdown remarkPlugins={[remarkGfm]} rehypePlugins={[rehypeSanitize]}>
                              {cleanAnalysisText(c)}
                            </ReactMarkdown>
                          </span>
                        </li>
                      ))}
                    </ul>
                  </div>
                )}
              </div>
            )}

            {/* Main Analysis Report — Unified Panel */}
            <div className="bg-white border border-[#e0ddd5] rounded-xl overflow-hidden" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.05)' }}>
              {/* Panel Header */}
              <div className="px-6 py-4 bg-gradient-to-r from-[#f9f9f8] to-white border-b border-[#e0ddd5]">
                <div className="flex items-center space-x-2.5">
                  <div className="w-8 h-8 bg-[#d97757]/10 rounded-lg flex items-center justify-center">
                    <i className="fas fa-robot text-[#d97757] text-sm"></i>
                  </div>
                  <h3 className="text-base font-bold text-[#191918] tracking-tight">AI 综合分析报告</h3>
                </div>
              </div>

              <div className="p-6 space-y-6">
                {/* Stat Cards — Top price indicators */}
                {state.synthesis.summaryTable && state.synthesis.summaryTable.length > 0 && (() => {
                  const cards = extractStatCards(state.synthesis.summaryTable);
                  const remaining = state.synthesis.summaryTable.filter(r => !cards.includes(r));
                  return (
                    <>
                      <div className="grid grid-cols-2 gap-3">
                        {cards.map((row, idx) => {
                          const valuePart = row.value.match(/^(.+?)(\s*\(.+\)\s*)?$/); 
                          return (
                            <div
                              key={idx}
                              className="bg-gradient-to-br from-[#f9f9f8] to-[#f5f4f1] border border-[#e8e5de] rounded-xl p-4 hover:border-[#d97757]/30 transition-all group"
                            >
                              <p className="text-[10px] font-bold text-[#7a7a78] uppercase tracking-wider mb-1.5 group-hover:text-[#d97757] transition-colors">
                                {row.label}
                              </p>
                              <p className="text-sm font-bold text-[#191918] leading-snug">
                                {valuePart?.[1] || row.value}
                              </p>
                              {valuePart?.[2] && (
                                <p className="text-[10px] text-[#9a9a98] mt-0.5 leading-tight">
                                  {valuePart[2].trim()}
                                </p>
                              )}
                            </div>
                          );
                        })}
                      </div>

                      {/* Accordion — Remaining detail rows */}
                      {remaining.length > 0 && (
                        <div className="border border-[#e8e5de] rounded-xl overflow-hidden">
                          <button
                            onClick={() => setTableExpanded(!tableExpanded)}
                            className="w-full flex items-center justify-between px-4 py-3 bg-[#fafaf9] hover:bg-[#f5f4f1] transition-colors text-left"
                          >
                            <span className="text-[11px] font-bold text-[#5c5c5a] uppercase tracking-wider flex items-center">
                              <span className="w-0.5 h-3.5 bg-[#d97757] rounded-full mr-2.5"></span>
                              <i className="fas fa-table mr-1.5 text-[#d97757]/60"></i>
                              完整数据明细
                              <span className="ml-2 px-1.5 py-0.5 bg-[#e8e5de] text-[#7a7a78] rounded text-[9px] font-mono">{remaining.length}</span>
                            </span>
                            <i className={`fas fa-chevron-${tableExpanded ? 'up' : 'down'} text-[10px] text-[#9a9a98] transition-transform`}></i>
                          </button>
                          {tableExpanded && (
                            <div className="border-t border-[#e8e5de]">
                              <table className="w-full text-xs table-fixed">
                                <tbody>
                                  {remaining.map((row, idx) => (
                                    <tr key={idx} className={`${idx % 2 === 0 ? 'bg-white' : 'bg-[#fafaf9]'} hover:bg-[#f5f4f1] transition-colors`}>
                                      <td className="px-4 py-2.5 text-[#5c5c5a] font-medium w-[40%] leading-snug">{row.label}</td>
                                      <td className="px-4 py-2.5 text-[#191918] leading-snug">{renderValue(row.value)}</td>
                                    </tr>
                                  ))}
                                </tbody>
                              </table>
                            </div>
                          )}
                        </div>
                      )}
                    </>
                  );
                })()}

                {/* Divider */}
                <div className="h-px bg-gradient-to-r from-transparent via-[#e0ddd5] to-transparent"></div>

                {/* Text Analysis — with side decoration */}
                <div>
                  <h4 className="text-[11px] font-bold text-[#5c5c5a] uppercase tracking-wider mb-4 flex items-center">
                    <span className="w-0.5 h-3.5 bg-[#d97757] rounded-full mr-2.5"></span>
                    <i className="fas fa-lightbulb mr-1.5 text-[#d97757]/60"></i>深度分析
                  </h4>
                  <AnalysisErrorBoundary>
                    <div className="markdown-body text-[13px] text-[#4a4a48] leading-[1.85] [&_h3]:text-sm [&_h3]:font-bold [&_h3]:text-[#191918] [&_h3]:mt-5 [&_h3]:mb-2 [&_h3]:flex [&_h3]:items-center [&_h3]:border-l-2 [&_h3]:border-[#d97757]/40 [&_h3]:pl-3 [&_h4]:text-[13px] [&_h4]:font-bold [&_h4]:text-[#4a4a48] [&_h4]:mt-4 [&_h4]:mb-1.5 [&_h4]:border-l-2 [&_h4]:border-[#e0ddd5] [&_h4]:pl-3 [&_p]:mb-3 [&_ul]:space-y-1 [&_ul]:mb-3 [&_li]:leading-relaxed [&_strong]:text-[#191918] [&_a]:text-[#d97757] [&_a]:underline [&_a]:underline-offset-2">
                      <ReactMarkdown remarkPlugins={[remarkGfm]} rehypePlugins={[rehypeSanitize]}>
                        {cleanAnalysisText(state.synthesis.analysis)}
                      </ReactMarkdown>
                    </div>
                  </AnalysisErrorBoundary>
                </div>
              </div>
            </div>
          </div>
        </div>
      )}

      {/* Price Trend Chart */}
      {state.synthesis && (
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
                    domain={[(d: number) => Math.floor(d) - 10, (d: number) => Math.ceil(d) + 10]}
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
      {!state.synthesis && !isSearching && !error && (
        <div className="py-20 text-center flex flex-col items-center">
          <div className="w-20 h-20 bg-[#f9f9f8] rounded-full flex items-center justify-center mb-6 text-3xl opacity-20 ring-1 ring-[#e0ddd5]">
            <i className="fas fa-brain"></i>
          </div>
          <h3 className="text-[#5c5c5a] font-medium">输入关键词并开始 AI 深度市场研究</h3>
          <p className="text-[#7a7a78] text-xs mt-2 max-w-md">
            智能规划搜索策略 → 六源并行搜索 → 去重排序 → 结构化证据提取 → AI 综合分析 → 自迭代评审（最多 3 轮）
          </p>
        </div>
      )}
    </div>
  );
};

export default MarketSearchPage;
