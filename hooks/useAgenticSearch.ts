import { useState, useRef, useCallback } from 'react';
import {
  AgentPhase, AgenticSearchState, PlanResult, RankedResult, Evidence,
  SynthesisResult, CritiqueResult, PhaseLogEntry, SubQuery,
  BraveSearchResponse, GeminiSearchProxyResponse, DirectSearchResponse,
  InternationalSearchResponse, EcommerceSearchResponse,
} from '../types';
import {
  searchBrave, searchTavily, searchGemini, searchDirect, searchInternational, searchEcommerce,
  agentPlan, agentRank, agentExtract, agentSynthesize, agentCritique,
  savePriceHistory,
} from '../services/api';

const MAX_ITERATIONS = 3;
const MAX_EVIDENCE_POOL = 50;       // #6: cap evidence pool
const PHASE_TIMEOUT_MS = 90000;     // #7: 90s per-phase timeout

const initialState: AgenticSearchState = {
  original_query: '',
  question_type: '',
  multi_hop_required: false,
  sub_queries: [],
  search_results: [],
  evidence_pool: [],
  synthesis: null,
  confidence_score: 0,
  iteration_count: 0,
  max_iterations: MAX_ITERATIONS,
  critique_history: [],
  phase: 'idle',
  phase_log: [],
};

// ==================== Utility: Evidence dedup by text+source hash (#5) ====================

function deduplicateEvidence(evidence: Evidence[]): Evidence[] {
  const seen = new Map<string, Evidence>();
  for (const e of evidence) {
    const key = `${(e.text || '').slice(0, 100)}|${e.source_url || ''}`;
    const existing = seen.get(key);
    if (!existing || (e.confidence > existing.confidence)) {
      seen.set(key, e); // keep highest confidence
    }
  }
  return Array.from(seen.values());
}

// ==================== Utility: Per-phase timeout wrapper (#7) ====================

async function withPhaseTimeout<T>(
  promise: Promise<T>,
  signal: AbortSignal,
  phaseName: string,
  timeoutMs: number = PHASE_TIMEOUT_MS,
): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(new Error(`${phaseName} 阶段超时 (${Math.round(timeoutMs / 1000)}s)`));
    }, timeoutMs);

    const onAbort = () => {
      clearTimeout(timer);
      reject(new Error('cancelled'));
    };
    signal.addEventListener('abort', onAbort, { once: true });

    promise
      .then(result => { clearTimeout(timer); signal.removeEventListener('abort', onAbort); resolve(result); })
      .catch(err => { clearTimeout(timer); signal.removeEventListener('abort', onAbort); reject(err); });
  });
}

/** Flatten 6-source search results into a uniform array for ranking */
function flattenSearchResults(
  gemini: GeminiSearchProxyResponse | null,
  brave: { title: string; url: string; content: string }[],
  tavily: { title: string; url: string; content: string }[],
  direct: DirectSearchResponse | null,
  intl: InternationalSearchResponse | null,
  ecom: EcommerceSearchResponse | null,
): { title: string; url: string; content: string; source: string; published_date?: string }[] {
  const all: { title: string; url: string; content: string; source: string; published_date?: string }[] = [];

  // Gemini grounding links as results
  if (gemini) {
    for (const g of gemini.grounding || []) {
      all.push({ title: g.title, url: g.uri, content: gemini.text.slice(0, 500), source: 'gemini' });
    }
    // If no grounding links, add the text itself as one result
    if ((!gemini.grounding || gemini.grounding.length === 0) && gemini.text) {
      all.push({ title: 'Gemini综合分析', url: '', content: gemini.text.slice(0, 2000), source: 'gemini' });
    }
  }

  for (const r of brave) {
    all.push({ title: r.title, url: r.url, content: r.content, source: 'brave' });
  }
  for (const r of tavily) {
    all.push({ title: r.title, url: r.url, content: r.content, source: 'tavily' });
  }

  if (direct && direct.matched && direct.prices) {
    for (const p of direct.prices) {
      all.push({
        title: `${p.product} ${p.spec || ''} - ${p.source}`,
        url: direct.sources?.[0]?.url || '',
        content: `${p.product} 价格: ${p.price}${p.priceUnit} 地区: ${p.region || ''} 日期: ${p.date || ''}`,
        source: 'direct',
        published_date: p.date,
      });
    }
  }

  if (intl && intl.results) {
    for (const r of intl.results) {
      all.push({ title: r.title, url: r.url, content: r.description, source: 'international' });
    }
  }

  if (ecom && ecom.categories) {
    for (const cat of ecom.categories) {
      for (const r of cat.results || []) {
        all.push({ title: r.title, url: r.url, content: r.description, source: 'ecommerce' });
      }
    }
  }

  return all;
}

export interface SearchSourceCounts {
  gemini: number;
  brave: number;
  tavily: number;
  direct: number;
  international: number;
  ecommerce: number;
  uniqueUrls: number;  // #9: unique URL count across all sources
}

export interface UseAgenticSearchReturn {
  state: AgenticSearchState;
  isSearching: boolean;
  error: string | null;
  sourceCounts: SearchSourceCounts;
  startSearch: (query: string) => Promise<void>;
  cancelSearch: () => void;
}

export function useAgenticSearch(): UseAgenticSearchReturn {
  const [state, setState] = useState<AgenticSearchState>(initialState);
  const [isSearching, setIsSearching] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [sourceCounts, setSourceCounts] = useState<SearchSourceCounts>({
    gemini: 0, brave: 0, tavily: 0, direct: 0, international: 0, ecommerce: 0, uniqueUrls: 0,
  });
  const abortRef = useRef<AbortController | null>(null);

  const setPhase = useCallback((phase: AgentPhase) => {
    setState(prev => ({ ...prev, phase }));
  }, []);

  const addLog = useCallback((entry: PhaseLogEntry) => {
    setState(prev => ({ ...prev, phase_log: [...prev.phase_log, entry] }));
  }, []);

  const cancelSearch = useCallback(() => {
    abortRef.current?.abort();
    setIsSearching(false);
    setPhase('idle');
  }, [setPhase]);

  /** Run 6-source parallel search for a list of queries */
  const runParallelSearch = useCallback(async (
    queries: string[],
    signal: AbortSignal,
  ): Promise<{ flat: { title: string; url: string; content: string; source: string; published_date?: string }[]; counts: Omit<SearchSourceCounts, 'uniqueUrls'> }> => {
    // Use first query for main search, additional queries enhance coverage
    const primaryQuery = queries[0];
    const allQueries = queries.slice(0, 4); // limit to 4 sub-queries for parallel search

    const searchPromises = allQueries.flatMap((q) => [
      searchGemini(q, signal).catch(() => null),
      searchBrave(q, 10, signal).catch(() => null),
      searchTavily(q, 10, signal).catch(() => null),
    ]);

    // Direct, international, ecommerce only on primary query
    searchPromises.push(
      searchDirect(primaryQuery, signal).catch(() => null) as any,
      searchInternational(primaryQuery, signal).catch(() => null) as any,
      searchEcommerce(primaryQuery, signal).catch(() => null) as any,
    );

    const results = await Promise.allSettled(searchPromises);
    if (signal.aborted) throw new Error('cancelled');

    const perQueryCount = 3; // gemini, brave, tavily per query
    const totalQueryResults = allQueries.length * perQueryCount;

    // Aggregate results
    let allFlattened: { title: string; url: string; content: string; source: string; published_date?: string }[] = [];
    const counts: Omit<SearchSourceCounts, 'uniqueUrls'> = { gemini: 0, brave: 0, tavily: 0, direct: 0, international: 0, ecommerce: 0 };

    for (let qi = 0; qi < allQueries.length; qi++) {
      const base = qi * perQueryCount;

      // Gemini
      const gemRes = results[base];
      const gem: GeminiSearchProxyResponse | null = gemRes?.status === 'fulfilled' ? gemRes.value as any : null;

      // Brave
      const brRes = results[base + 1];
      const brRaw: BraveSearchResponse | null = brRes?.status === 'fulfilled' ? brRes.value as any : null;
      const brave = (brRaw?.web?.results || []).map(r => ({ title: r.title, url: r.url, content: r.description }));

      // Tavily
      const tvRes = results[base + 2];
      const tvRaw: any = tvRes?.status === 'fulfilled' ? tvRes.value : null;
      const tavily = (tvRaw?.results || []).map((r: any) => ({ title: r.title, url: r.url, content: r.content }));

      const flat = flattenSearchResults(gem, brave, tavily, null, null, null);
      allFlattened.push(...flat);

      counts.gemini += gem?.grounding?.length || (gem?.text ? 1 : 0);
      counts.brave += brave.length;
      counts.tavily += tavily.length;
    }

    // Direct, International, Ecommerce from primary query
    const directRes = results[totalQueryResults];
    const directData: DirectSearchResponse | null = directRes?.status === 'fulfilled' ? directRes.value as any : null;
    const intlRes = results[totalQueryResults + 1];
    const intlData: InternationalSearchResponse | null = intlRes?.status === 'fulfilled' ? intlRes.value as any : null;
    const ecomRes = results[totalQueryResults + 2];
    const ecomData: EcommerceSearchResponse | null = ecomRes?.status === 'fulfilled' ? ecomRes.value as any : null;

    const specialFlat = flattenSearchResults(null, [], [], directData, intlData, ecomData);
    allFlattened.push(...specialFlat);

    counts.direct = directData?.matched ? (directData.prices?.length || 0) : 0;
    counts.international = intlData?.results?.length || 0;
    counts.ecommerce = ecomData?.categories?.reduce((sum, c) => sum + (c.results?.length || 0), 0) || 0;

    return { flat: allFlattened, counts };
  }, []);

  const startSearch = useCallback(async (query: string) => {
    // Abort previous
    abortRef.current?.abort();
    const controller = new AbortController();
    abortRef.current = controller;
    const signal = controller.signal;

    setIsSearching(true);
    setError(null);
    setSourceCounts({ gemini: 0, brave: 0, tavily: 0, direct: 0, international: 0, ecommerce: 0, uniqueUrls: 0 });
    setState({ ...initialState, original_query: query, phase: 'planning' });

    // #9: Track unique URLs across all iterations
    const globalUrlSet = new Set<string>();
    // #2: Track all queries used across iterations to detect loops
    const usedQueries = new Set<string>();

    try {
      // ==================== Phase 1: PLAN ====================
      const planStart = Date.now();
      setPhase('planning');

      const plan: PlanResult = await withPhaseTimeout(agentPlan(query, signal), signal, '规划', 30000);
      if (signal.aborted) return;

      setState(prev => ({
        ...prev,
        question_type: plan.question_type,
        multi_hop_required: plan.multi_hop_required,
        sub_queries: plan.sub_queries,
      }));
      addLog({
        phase: 'planning',
        duration_ms: Date.now() - planStart,
        summary: `类型: ${plan.question_type} | 子查询: ${plan.sub_queries.length} 条 | Multi-hop: ${plan.multi_hop_required ? '是' : '否'}`,
        iteration: 0,
      });

      // ==================== Iterative Loop ====================
      let iteration = 0;
      let allSearchResults: RankedResult[] = [];
      let allEvidence: Evidence[] = [];
      let currentSynthesis: SynthesisResult | null = null;
      let critiqueHistory: CritiqueResult[] = [];
      let currentQueries = plan.sub_queries.map(sq => sq.query);
      // Mark initial queries as used
      currentQueries.forEach(q => usedQueries.add(q));

      while (iteration < MAX_ITERATIONS) {
        iteration++;
        if (signal.aborted) return;

        // ==================== Phase 2: SEARCH ====================
        const searchStart = Date.now();
        setPhase('searching');
        setState(prev => ({ ...prev, iteration_count: iteration }));

        const { flat: rawResults, counts } = await withPhaseTimeout(
          runParallelSearch(currentQueries, signal), signal, '搜索',
        );
        if (signal.aborted) return;

        // #9: Accumulate source counts and track unique URLs
        rawResults.forEach(r => { if (r.url) globalUrlSet.add(r.url); });
        setSourceCounts(prev => ({
          gemini: prev.gemini + counts.gemini,
          brave: prev.brave + counts.brave,
          tavily: prev.tavily + counts.tavily,
          direct: prev.direct + counts.direct,
          international: prev.international + counts.international,
          ecommerce: prev.ecommerce + counts.ecommerce,
          uniqueUrls: globalUrlSet.size,
        }));

        addLog({
          phase: 'searching',
          duration_ms: Date.now() - searchStart,
          summary: `${rawResults.length} 条原始结果 | ${globalUrlSet.size} 独立来源`,
          iteration,
        });

        // ==================== Phase 3: RANK ====================
        const rankStart = Date.now();
        setPhase('ranking');

        const rankResult = await withPhaseTimeout(
          agentRank(query, rawResults, signal), signal, '排序', 30000,
        );
        if (signal.aborted) return;

        // Merge with existing results (dedup across iterations)
        const existingUrls = new Set(allSearchResults.map(r => r.url));
        const newRanked = rankResult.ranked.filter(r => !existingUrls.has(r.url));
        allSearchResults = [...allSearchResults, ...newRanked];

        setState(prev => ({ ...prev, search_results: allSearchResults }));
        addLog({
          phase: 'ranking',
          duration_ms: Date.now() - rankStart,
          summary: `${rankResult.dedup_stats.before}条 → 去重后 ${rankResult.dedup_stats.after}条 | 本轮新增 ${newRanked.length}条`,
          iteration,
        });

        // ==================== Phase 4: EXTRACT ====================
        const extractStart = Date.now();
        setPhase('extracting');

        // Only extract from top-ranked results; cap at 15 to keep prompt small for fast extraction
        const candidates = iteration === 1 ? allSearchResults : newRanked;
        const toExtract = candidates.slice(0, 15);
        const extractResult = await withPhaseTimeout(
          agentExtract(query, toExtract, signal), signal, '证据提取',
        );
        if (signal.aborted) return;

        // Merge evidence (dedup by claim_id prefix per iteration)
        const newEvidence = extractResult.evidence.map(e => ({
          ...e,
          claim_id: `r${iteration}_${e.claim_id}`,
        }));

        // #5: Deduplicate evidence by text+source across all iterations
        const mergedEvidence = deduplicateEvidence([...allEvidence, ...newEvidence]);

        // #6: Cap evidence pool — keep top N by confidence
        if (mergedEvidence.length > MAX_EVIDENCE_POOL) {
          mergedEvidence.sort((a, b) => (b.confidence || 0) - (a.confidence || 0));
          allEvidence = mergedEvidence.slice(0, MAX_EVIDENCE_POOL);
        } else {
          allEvidence = mergedEvidence;
        }

        setState(prev => ({ ...prev, evidence_pool: allEvidence }));
        addLog({
          phase: 'extracting',
          duration_ms: Date.now() - extractStart,
          summary: `提取 ${newEvidence.length} 条 | 去重后累计 ${allEvidence.length} 条${allEvidence.length >= MAX_EVIDENCE_POOL ? ' (已达上限)' : ''}`,
          iteration,
        });

        // ==================== Phase 5: SYNTHESIZE ====================
        const synthStart = Date.now();
        setPhase('synthesizing');

        // Synthesize with large evidence pools (50 items) may need primary+fallback = up to 180s
        currentSynthesis = await withPhaseTimeout(
          agentSynthesize(query, plan.question_type, allEvidence, iteration, signal), signal, '综合分析', 180000,
        );
        if (signal.aborted) return;

        setState(prev => ({
          ...prev,
          synthesis: currentSynthesis,
          confidence_score: currentSynthesis!.confidence_score,
        }));
        addLog({
          phase: 'synthesizing',
          duration_ms: Date.now() - synthStart,
          summary: `共识 ${currentSynthesis.consensus?.length || 0} 条 | 矛盾 ${currentSynthesis.contradictions?.length || 0} 条 | 信心 ${Math.round((currentSynthesis.confidence_score || 0) * 100)}%`,
          iteration,
        });

        // ==================== Phase 6: CRITIQUE ====================
        if (iteration < MAX_ITERATIONS) {
          const critiqueStart = Date.now();
          setPhase('critiquing');

          const critique = await withPhaseTimeout(
            agentCritique(
              query, plan.question_type, currentSynthesis, allEvidence,
              iteration, MAX_ITERATIONS, signal,
            ), signal, '评审', 60000,
          );
          if (signal.aborted) return;

          critiqueHistory.push(critique);
          setState(prev => ({
            ...prev,
            critique_history: critiqueHistory,
            confidence_score: critique.confidence_score,
          }));

          addLog({
            phase: 'critiquing',
            duration_ms: Date.now() - critiqueStart,
            summary: critique.needs_more_search
              ? `不通过 (${Math.round(critique.confidence_score * 100)}%) | 缺失: ${critique.missing_aspects.join(', ')} | +${critique.new_queries.length}条新查询`
              : `通过 ✅ (${Math.round(critique.confidence_score * 100)}%)`,
            iteration,
          });

          if (!critique.needs_more_search || critique.new_queries.length === 0) {
            break; // Satisfied or no more queries to add
          }

          // #2: Deduplicate new queries against all previously used queries
          const genuinelyNew = critique.new_queries.filter(q => !usedQueries.has(q));
          if (genuinelyNew.length === 0) {
            // All suggested queries already used → break to prevent infinite loop
            addLog({
              phase: 'critiquing',
              duration_ms: 0,
              summary: `⚠️ 评审建议的查询均已执行过，跳出循环`,
              iteration,
            });
            break;
          }

          // Prepare next iteration
          genuinelyNew.forEach(q => usedQueries.add(q));
          currentQueries = genuinelyNew;
          setPhase('iterating');
        } else {
          // Final iteration — force complete
          break;
        }
      }

      // ==================== COMPLETE ====================
      setPhase('complete');
      setState(prev => ({
        ...prev,
        phase: 'complete',
        synthesis: currentSynthesis,
        confidence_score: currentSynthesis?.confidence_score || prev.confidence_score,
      }));

      // Save price history (fire-and-forget)
      if (currentSynthesis?.prices && currentSynthesis.prices.length > 0) {
        savePriceHistory(query, currentSynthesis.prices.map(p => ({
          price: p.price,
          priceUnit: p.priceUnit || '元',
          platform: p.platform,
        }))).catch(e => console.warn('Price history save failed:', e));
      }

    } catch (err: any) {
      if (signal.aborted || err?.message === 'cancelled') {
        console.warn('Agentic search cancelled');
        return;
      }
      console.error('Agentic search error:', err);
      setError(err?.message || '搜索失败');
      setPhase('error');
    } finally {
      if (!signal.aborted) {
        setIsSearching(false);
      }
    }
  }, [setPhase, addLog, runParallelSearch]);

  return { state, isSearching, error, sourceCounts, startSearch, cancelSearch };
}
