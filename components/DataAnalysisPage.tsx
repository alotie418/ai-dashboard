
import React, { useState, useEffect, useCallback, useMemo } from 'react';
import {
  LineChart, Line, AreaChart, Area, XAxis, YAxis, CartesianGrid, Tooltip,
  ResponsiveContainer, BarChart, Bar, Legend, ComposedChart, Cell, ScatterChart, Scatter, ZAxis
} from 'recharts';
import { useTranslation } from 'react-i18next';
import { BusinessData } from '../types';
import { fetchSettings } from '../services/api';
import { parseAiErrorCode, aiErrorMessage } from '../services/aiErrors';
import { formatMoney, getCurrencySymbol, getInventoryUnitLabel, formatCompactMoney } from './accountingHelpers';
import { localizeMonthName } from './monthLabel';
// AI calls moved to server-side proxy

// Bug 1: forecast task state is owned by AppContent (survives sidebar navigation) and
// passed in here. The page reads/writes it via these props instead of local useState,
// so switching pages mid-run no longer drops the running state or the result.
export interface ForecastState {
  isAnalysing: boolean;
  setIsAnalysing: React.Dispatch<React.SetStateAction<boolean>>;
  salesForecast: string;
  setSalesForecast: React.Dispatch<React.SetStateAction<string>>;
  predictedData: any[];
  setPredictedData: React.Dispatch<React.SetStateAction<any[]>>;
  groundingSources: { title: string; uri: string }[];
  setGroundingSources: React.Dispatch<React.SetStateAction<{ title: string; uri: string }[]>>;
  isAnalysingRef: React.MutableRefObject<boolean>;
  aiQuotaCooldownRef: React.MutableRefObject<number>;
}

interface Props {
  data: BusinessData;
  selectedYear: string;
  selectedQuarter: string;
  selectedMonth: string;
  forecast: ForecastState;
}

type AnalysisDimension = 'financial' | 'volume' | 'efficiency';

const DataAnalysisPage: React.FC<Props> = ({ data, selectedYear, selectedQuarter, selectedMonth, forecast }) => {
  const { t, i18n } = useTranslation();
  // Forecast task state lives in AppContent (lifted) — read/write via props so it
  // survives this page unmounting on sidebar navigation. Destructured with the same
  // names the rest of this component already uses (no downstream changes needed).
  const {
    isAnalysing, setIsAnalysing,
    salesForecast, setSalesForecast,
    predictedData, setPredictedData,
    groundingSources, setGroundingSources,
    isAnalysingRef, aiQuotaCooldownRef,
  } = forecast;
  const [accLocale, setAccLocale] = useState<string>('CN');
  const [productUnit, setProductUnit] = useState<string>('ton');
  useEffect(() => {
    fetchSettings().then((s: any) => {
      if (s?.accounting_locale) setAccLocale(s.accounting_locale);
      if (s?.product_unit) setProductUnit(s.product_unit);
    }).catch(() => {});
  }, []);
  const uiLang = i18n.language;
  const unitLabel = getInventoryUnitLabel(productUnit, uiLang);
  const currSym = getCurrencySymbol(accLocale);

  const LOADING_MESSAGES = useMemo(() => [
    t('analysis.loading1'),
    t('analysis.loading2'),
    t('analysis.loading3'),
    t('analysis.loading4'),
    t('analysis.loading5'),
  ], [t]);
  const [activeTab, setActiveTab] = useState<'trends' | 'table' | 'forecast' | 'panorama'>('panorama');
  // salesForecast / predictedData / isAnalysing / groundingSources are lifted to
  // AppContent (see destructure above). loadingProgress/loadingMessage are the local
  // progress animation only — fine to reset on remount.
  const [loadingProgress, setLoadingProgress] = useState(0);
  const [loadingMessage, setLoadingMessage] = useState('');

  const stats = useMemo(() => {
    const perf = data.monthlyPerformance;
    if (!perf.length) return { yoy: null, mom: null, deflator: null, avgProfit: 0, avgRevenue: 0 };
    // 跳过 null（无基期）与非有限值——空集返回 null（前端显「—」，不显 0.0% 假均值）。
    const safeAvg = (arr: (number | null)[]): number | null => {
      const valid = arr.filter((v): v is number => v != null && Number.isFinite(v));
      return valid.length > 0 ? valid.reduce((a, b) => a + b, 0) / valid.length : null;
    };
    return {
      yoy: safeAvg(perf.map(p => p.yoy)),
      mom: safeAvg(perf.map(p => p.mom)),
      deflator: safeAvg(perf.map(p => p.deflator)),
      avgProfit: safeAvg(perf.map(p => p.profit)) ?? 0,
      avgRevenue: safeAvg(perf.map(p => p.revenue)) ?? 0
    };
  }, [data.monthlyPerformance]);

  const [dimension, setDimension] = useState<AnalysisDimension>('financial');

  useEffect(() => {
    if (!isAnalysing) return;
    let i = 0;
    setLoadingProgress(0);
    setLoadingMessage(LOADING_MESSAGES[0]);
    const timer = setInterval(() => {
      i++;
      if (i < LOADING_MESSAGES.length) {
        setLoadingMessage(LOADING_MESSAGES[i]);
        setLoadingProgress(Math.min(95, (i / LOADING_MESSAGES.length) * 100));
      } else {
        clearInterval(timer);
      }
    }, 2500);
    return () => clearInterval(timer);
  }, [isAnalysing]);

  // ========== LOCAL COMPUTE MODULES ==========

  // Box-Muller transform for normal distribution sampling
  const gaussianRandom = () => {
    let u = 0, v = 0;
    while (u === 0) u = Math.random();
    while (v === 0) v = Math.random();
    return Math.sqrt(-2.0 * Math.log(u)) * Math.cos(2.0 * Math.PI * v);
  };

  // ── LOCAL FORECAST MODELS ──
  // TODO [future-forecast]: Replace these 3 functions with a pluggable forecast engine.
  //   Candidates: real VAR / ARIMA / exponential smoothing / ML regression.
  //   Keep the same function signatures so the pipeline (STEP 1-3) doesn't change.
  //   Add backtesting + accuracy metrics when the engine is swapped.

  // ① Feature Vector Extraction
  const extractFeatures = (perf: typeof data.monthlyPerformance) => {
    const nonZero = perf.filter(p => p.revenue > 0);
    if (nonZero.length < 3) return null;

    const revenues = nonZero.map(p => p.revenue);
    const costs = nonZero.map(p => p.cost);
    const tons = nonZero.map(p => p.salesTons);
    const n = revenues.length;

    // Moving averages (3-month)
    const ma3 = revenues.length >= 3
      ? revenues.slice(-3).reduce((a, b) => a + b, 0) / 3
      : revenues.reduce((a, b) => a + b, 0) / n;

    // Trend slope via simple linear regression (revenue ~ time)
    const xMean = (n - 1) / 2;
    const yMean = revenues.reduce((a, b) => a + b, 0) / n;
    let num = 0, den = 0;
    for (let i = 0; i < n; i++) {
      num += (i - xMean) * (revenues[i] - yMean);
      den += (i - xMean) ** 2;
    }
    const trendSlope = den === 0 ? 0 : num / den;

    // Revenue per ton
    const totalTons = tons.reduce((a, b) => a + b, 0);
    const revenuePerTon = totalTons > 0 ? revenues.reduce((a, b) => a + b, 0) / totalTons : 0;

    // Cost-to-revenue ratio
    const totalRevenue = revenues.reduce((a, b) => a + b, 0);
    const totalCost = costs.reduce((a, b) => a + b, 0);
    const costRatio = totalRevenue > 0 ? totalCost / totalRevenue : 0;

    // Seasonal indices (each month's ratio to average)
    const avgRevenue = totalRevenue / n;
    const seasonalIndices = nonZero.map(p => ({
      month: p.name,
      index: avgRevenue > 0 ? +(p.revenue / avgRevenue).toFixed(3) : 1
    }));

    // Growth acceleration (2nd derivative of MoM) — skip null (no base period) MoM values.
    const moms = nonZero.map(p => p.mom).filter((v): v is number => v != null);
    const momDiffs = moms.slice(1).map((v, i) => v - moms[i]);
    const avgAcceleration = momDiffs.length > 0 ? momDiffs.reduce((a, b) => a + b, 0) / momDiffs.length : 0;

    return {
      ma3: Math.round(ma3),
      trendSlope: Math.round(trendSlope),
      revenuePerTon: Math.round(revenuePerTon),
      costRatio: +costRatio.toFixed(4),
      seasonalIndices,
      avgAcceleration: +avgAcceleration.toFixed(2),
      dataPoints: n
    };
  };

  // ② Trend Forecast: independent AR(1) per series [revenue, cost, salesTons]
  // TODO [future-forecast]: Replace with real multivariate model (VAR/VECM) that captures cross-series correlation.
  const varForecast = (perf: typeof data.monthlyPerformance) => {
    const nonZero = perf.filter(p => p.revenue > 0);
    if (nonZero.length < 4) return null;

    const series = nonZero.map(p => [p.revenue, p.cost, p.salesTons]);
    const k = 3;
    const arCoefs: { a: number; b: number }[] = [];

    for (let v = 0; v < k; v++) {
      const vals = series.map(s => s[v]);
      const y = vals.slice(1);
      const x = vals.slice(0, -1);
      const xMean = x.reduce((a, b) => a + b, 0) / x.length;
      const yMean = y.reduce((a, b) => a + b, 0) / y.length;
      let numerator = 0, denominator = 0;
      for (let i = 0; i < x.length; i++) {
        numerator += (x[i] - xMean) * (y[i] - yMean);
        denominator += (x[i] - xMean) ** 2;
      }
      const b = denominator === 0 ? 0 : numerator / denominator;
      const a = yMean - b * xMean;
      arCoefs.push({ a, b });
    }

    const forecasts: { revenue: number; cost: number; salesTons: number }[] = [];
    let lastVals = series[series.length - 1];
    for (let m = 0; m < 3; m++) {
      const nextVals = arCoefs.map((c, v) => Math.max(0, Math.round(c.a + c.b * lastVals[v])));
      forecasts.push({ revenue: nextVals[0], cost: nextVals[1], salesTons: nextVals[2] });
      lastVals = nextVals;
    }
    return forecasts;
  };

  // ③ Monte Carlo Simulation: P5/P95 confidence intervals
  // TODO [future-forecast]: Use model-specific residual distribution instead of historical CV.
  const monteCarloSimulation = (historicalRevenues: number[], pointEstimates: number[]) => {
    const nonZero = historicalRevenues.filter(r => r > 0);
    if (nonZero.length < 3) return null;

    const mean = nonZero.reduce((a, b) => a + b, 0) / nonZero.length;
    const variance = nonZero.reduce((a, b) => a + (b - mean) ** 2, 0) / (nonZero.length - 1);
    const cv = mean === 0 ? 0 : Math.sqrt(variance) / mean;
    const SIMULATIONS = 1000;

    return pointEstimates.map((predicted, month) => {
      const horizonFactor = Math.sqrt(1 + month);
      const simValues: number[] = [];
      for (let i = 0; i < SIMULATIONS; i++) {
        simValues.push(predicted * (1 + gaussianRandom() * cv * horizonFactor));
      }
      simValues.sort((a, b) => a - b);
      return {
        upper: Math.round(simValues[Math.floor(SIMULATIONS * 0.95)]),
        lower: Math.max(0, Math.round(simValues[Math.floor(SIMULATIONS * 0.05)]))
      };
    });
  };

  // ========== PREDICTION PIPELINE ==========

  // isAnalysingRef (concurrency guard) + aiQuotaCooldownRef (429 cooldown) are lifted to
  // AppContent too, so切页后再回来仍能防重复发起 / 维持冷却（见上方 forecast 解构）。
  const runAnalysis = useCallback(async () => {
    if (isAnalysingRef.current) return;
    // 冷却中：直接显示友好提示，不再发请求。
    if (Date.now() < aiQuotaCooldownRef.current) {
      setSalesForecast(t('aiInsights.quotaExceeded'));
      return;
    }
    isAnalysingRef.current = true;
    setIsAnalysing(true);
    setGroundingSources([]);

    try {
      const perf = data.monthlyPerformance;

      // STEP 1: Local feature extraction
      const features = extractFeatures(perf);

      // STEP 2: Trend forecast (AR(1) per series)
      const varPred = varForecast(perf);

      // STEP 3: Monte Carlo on trend predictions (if available)
      const historicalRevenues = perf.map(m => m.revenue);
      const mcOnVar = varPred
        ? monteCarloSimulation(historicalRevenues, varPred.map(v => v.revenue))
        : null;

      // STEP 4: Build comprehensive prompt with ALL local results
      const historySummary = perf.map(m => ({
        m: m.name, r: m.revenue, c: m.cost, p: m.profit, np: m.netProfit,
        pt: m.purchaseTons, st: m.salesTons, yoy: m.yoy, mom: m.mom, d: m.deflator
      }));
      const fs = data.financialStatement;
      const finSummary = {
        rev: fs.salesRevenue, cos: fs.costOfSales, gp: fs.grossProfit,
        gm: fs.grossMargin, np: fs.netProfit, nm: fs.netMargin,
        tax: fs.taxSurcharge, ship: fs.shippingFee, admin: fs.adminExpense, op: fs.operatingExpenses ?? 0
      };

      // Prompt prose is i18n-driven (follows uiLanguage); the JSON payloads below
      // are locale-neutral data and are injected verbatim. No industry hardcode.
      let prompt = `${t('analysis.forecastPromptIntro')}

${t('analysis.forecastPromptHistoryTitle')}
${JSON.stringify(historySummary)}
${t('analysis.forecastPromptHistoryLegend')}

${t('analysis.forecastPromptFinTitle')}
${JSON.stringify(finSummary)}`;

      if (features) {
        prompt += `

${t('analysis.forecastPromptFeaturesTitle')}
${JSON.stringify(features)}
${t('analysis.forecastPromptFeaturesLegend')}`;
      }

      if (varPred) {
        prompt += `

${t('analysis.forecastPromptVarTitle')}
${JSON.stringify(varPred)}
${t('analysis.forecastPromptVarLegend')}`;
      }

      if (mcOnVar) {
        prompt += `

${t('analysis.forecastPromptMcTitle')}
${JSON.stringify(mcOnVar)}
${t('analysis.forecastPromptMcLegend')}`;
      }

      prompt += `

${t('analysis.forecastPromptRequirements')}`;

      // STEP 6: AI synthesis (走 IPC 统一通道，桌面版不走 HTTP)
      const result: any = await (window as any).electronAPI.invoke('api:request', {
        method: 'POST',
        path: '/api/ai/data-analysis',
        body: {
          prompt,
          systemInstruction: `${t('ai.forecastSystemPrompt')}\n\n${t('ai.boundaryDirective')}`,
          responseSchema: {
            type: 'OBJECT',
            properties: {
              insights: { type: 'STRING' },
              predictions: {
                type: 'ARRAY',
                items: {
                  type: 'OBJECT',
                  properties: {
                    name: { type: 'STRING' },
                    revenue: { type: 'NUMBER' },
                    profit: { type: 'NUMBER' },
                    confidenceUpper: { type: 'NUMBER' },
                    confidenceLower: { type: 'NUMBER' }
                  }
                }
              }
            }
          }
        },
      });
      setSalesForecast(result.insights || t('analysis.forecastDefault'));

      // Extract Google Search grounding sources from server response
      if (result.groundingSources && result.groundingSources.length > 0) {
        setGroundingSources(result.groundingSources);
      }

      // STEP 7: Final Monte Carlo on AI's predictions for confidence intervals
      const lastMonth = perf[perf.length - 1];
      const aiPredictions = result.predictions || [];
      const mcOnAI = monteCarloSimulation(historicalRevenues, aiPredictions.map((p: any) => p.revenue));

      const forecasts = aiPredictions.map((p: any, i: number) => ({
        ...p,
        confidenceUpper: mcOnAI ? mcOnAI[i].upper : p.confidenceUpper,
        confidenceLower: mcOnAI ? mcOnAI[i].lower : p.confidenceLower,
        isForecast: true
      }));

      setPredictedData([
        { ...lastMonth, confidenceUpper: lastMonth.revenue, confidenceLower: lastMonth.revenue, isForecast: false },
        ...forecasts
      ]);
    } catch (err: any) {
      // 区分「额度/限流(quota)」与一般错误：quota 进入 5 分钟冷却 + 友好提示，
      // 避免连点或任何残留路径反复刷 429 刷屏控制台。
      // R3c：错误分类改用稳定 code（parseAiErrorCode），其余按 code 映射 i18n（随 uiLanguage）。
      const code = parseAiErrorCode(err);
      if (code === 'quota') {
        aiQuotaCooldownRef.current = Date.now() + 5 * 60 * 1000;
        setSalesForecast(t('aiInsights.quotaExceeded'));
        console.warn('[AI] data-analysis quota/429 — paused 5 min, no auto-retry');
      } else {
        console.error(err);
        setSalesForecast(aiErrorMessage(err, t));
      }
    } finally {
      isAnalysingRef.current = false;
      setIsAnalysing(false);
      setLoadingProgress(100);
    }
  }, [data.monthlyPerformance, data.financialStatement, t, i18n.language]);

  // AI 经营预测不再在挂载 / 切页 / 热更新时自动调用 —— 改为用户点击横幅按钮
  // (onClick={runAnalysis}) 时才触发，避免对默认 provider 反复请求刷 Gemini 429。
  const formatCurrency = (v: number) => formatCompactMoney(v, accLocale, uiLang, 1);
  // Defensive: a forecast point may carry an undefined/null numeric field (e.g. the AI
  // response omits profit/revenue/confidence), which previously crashed the page with
  // `undefined.toLocaleString()`. Fall back to '0' for any non-finite value; format is
  // unchanged for real numbers.
  const formatNum = (v: number | null | undefined) => {
    const n = Number(v);
    return Number.isFinite(n) ? n.toLocaleString() : '0';
  };

  return (
    <div className="space-y-8 animate-in fade-in duration-700 pb-20">
      {/* AI Header Banner */}
      <div className="bg-gradient-to-br from-white via-white to-[#f9f9f8] border border-[#e0ddd5] rounded-xl p-10 relative overflow-hidden" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.06)' }}>
        <div className="absolute top-0 right-0 w-1/3 h-full bg-primary/5 blur-[120px] pointer-events-none"></div>
        <div className="relative z-10 flex flex-col md:flex-row md:items-center justify-between gap-10">
          <div className="flex-1">
            <div className="flex items-center space-x-3 mb-6">
              <div className="flex space-x-1">
                <span className="h-1.5 w-1.5 rounded-full bg-primary"></span>
                <span className="h-1.5 w-1.5 rounded-full bg-primary/60"></span>
                <span className="h-1.5 w-1.5 rounded-full bg-primary/30"></span>
              </div>
              <h3 className="text-primary text-xs font-bold uppercase">{t('analysis.aiDashboard')}</h3>
            </div>
            {isAnalysing ? (
              <div className="space-y-6">
                <div className="flex items-center space-x-6">
                  <div className="w-14 h-14 bg-primary/10 rounded-xl flex items-center justify-center border border-primary/20 shadow-inner">
                    <span className="text-3xl animate-bounce">🧠</span>
                  </div>
                  <div>
                    <p className="text-[#191918] font-bold text-xl">{loadingMessage}</p>
                    <p className="text-primary/60 text-[10px] font-mono mt-1">{t('analysis.realtimeProcessing')} | {t('analysis.progress')}: {Math.floor(loadingProgress)}%</p>
                  </div>
                </div>
                <div className="w-full bg-[#f9f9f8] h-1.5 rounded-full overflow-hidden">
                  <div className="bg-gradient-to-r from-primary to-primary-light h-full transition-all duration-300 ease-out" style={{ width: `${loadingProgress}%`, boxShadow: '0 0 15px rgba(39,76,146,0.5)' }}></div>
                </div>
              </div>
            ) : (
              <div className="group">
                <p className="text-[#191918] text-2xl font-light leading-snug max-w-2xl" style={{ whiteSpace: 'pre-wrap' }}>
                  {salesForecast || t('analysis.forecastIdle')}
                </p>
                <div className="mt-8 flex items-center space-x-6">
                  <button onClick={runAnalysis} className="px-6 py-2.5 bg-primary/10 hover:bg-primary/20 border border-primary/30 rounded-full text-[10px] text-primary font-bold uppercase tracking-widest flex items-center transition-all active:scale-95">
                    <i className="fas fa-sync-alt mr-2"></i> {salesForecast ? t('analysis.rerun') : t('analysis.runForecast')}
                  </button>
                </div>
                {/* PR-E1: AI forecast is a management estimate, not professional advice. */}
                <p className="mt-4 text-[10px] text-[#5c5c5a] leading-snug max-w-2xl">{t('disclaimer.ai')}</p>
              </div>
            )}
          </div>
          <div className="hidden lg:grid grid-cols-3 gap-8 border-l border-[#e0ddd5] pl-12 shrink-0">
            <StatsIndicator label={t('analysis.avgYoy')} value={stats.yoy == null ? '—' : `${stats.yoy.toFixed(1)}%`} trend={stats.yoy == null ? 'neutral' : stats.yoy >= 0 ? 'up' : 'down'} />
            <StatsIndicator label={t('analysis.avgMom')} value={stats.mom == null ? '—' : `${stats.mom.toFixed(1)}%`} trend={stats.mom == null ? 'neutral' : stats.mom >= 0 ? 'up' : 'down'} />
            <StatsIndicator label={t('analysis.deflator')} value={stats.deflator == null ? '—' : stats.deflator.toFixed(1)} trend="neutral" color="text-amber-500" />
          </div>
        </div>
      </div>

      {/* Navigation Tabs */}
      <div className="flex flex-col md:flex-row md:items-center justify-between gap-6 bg-white/60 p-3 rounded-xl border border-[#e0ddd5]/70 backdrop-blur-md">
        <div className="flex p-1 bg-[#f9f9f8]/80 rounded-xl w-fit">
          <TabButton active={activeTab === 'panorama'} onClick={() => setActiveTab('panorama')} label={t('analysis.panorama')} icon="fa-globe-asia" />
          <TabButton active={activeTab === 'trends'} onClick={() => setActiveTab('trends')} label={t('analysis.trends')} icon="fa-chart-area" />
          <TabButton active={activeTab === 'forecast'} onClick={() => setActiveTab('forecast')} label={t('analysis.forecast')} icon="fa-bolt-lightning" />
          <TabButton active={activeTab === 'table'} onClick={() => setActiveTab('table')} label={t('analysis.table')} icon="fa-table" />
        </div>

        {activeTab === 'trends' && (
          <div className="flex items-center space-x-2 px-6">
            <span className="text-[10px] text-[#5c5c5a] font-bold uppercase tracking-widest mr-2">{t('analysis.dimSwitch')}:</span>
            <div className="flex bg-[#f9f9f8] rounded-xl p-1">
              <DimButton active={dimension === 'financial'} onClick={() => setDimension('financial')} label={t('analysis.dimAmount')} />
              <DimButton active={dimension === 'volume'} onClick={() => setDimension('volume')} label={t('analysis.dimVolume')} />
              <DimButton active={dimension === 'efficiency'} onClick={() => setDimension('efficiency')} label={t('analysis.dimEfficiency')} />
            </div>
          </div>
        )}
      </div>

      {/* Content Rendering */}
      {activeTab === 'panorama' && (
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-8 animate-in fade-in duration-1000">
          {/* Revenue vs Cost Stacked Area */}
          <PanoramaCard title={t('analysis.revenueStructure')} subtitle={t('analysis.subtitleRevenueCost')}>
            <ResponsiveContainer width="100%" height={260}>
              <AreaChart data={data.monthlyPerformance}>
                <defs>
                  <linearGradient id="p_rev" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="5%" stopColor="#274C92" stopOpacity={0.3} />
                    <stop offset="95%" stopColor="#274C92" stopOpacity={0} />
                  </linearGradient>
                </defs>
                <CartesianGrid strokeDasharray="3 3" stroke="#e0ddd5" vertical={false} />
                <XAxis dataKey="name" hide />
                <YAxis hide domain={['auto', 'auto']} />
                <Tooltip contentStyle={{ backgroundColor: '#ffffff', border: '1px solid #e0ddd5', borderRadius: '12px' }} labelFormatter={(label) => localizeMonthName(label, t)} />
                <Area type="monotone" dataKey="revenue" stroke="#274C92" fill="url(#p_rev)" strokeWidth={2} />
                <Area type="monotone" dataKey="cost" stroke="#ef4444" fill="transparent" strokeWidth={1} strokeDasharray="3 3" />
              </AreaChart>
            </ResponsiveContainer>
          </PanoramaCard>

          {/* Monthly Growth Compare */}
          <PanoramaCard title={t('analysis.growthTrend')} subtitle={t('analysis.subtitleYoyMom')}>
            {data.monthlyPerformance.some(p => p.mom != null || p.yoy != null) ? (
              <ResponsiveContainer width="100%" height={260}>
                <ComposedChart data={data.monthlyPerformance}>
                  <XAxis dataKey="name" hide />
                  <YAxis hide />
                  <Tooltip contentStyle={{ backgroundColor: '#ffffff', border: '1px solid #e0ddd5', borderRadius: '12px' }} labelFormatter={(label) => localizeMonthName(label, t)} />
                  <Bar dataKey="mom" name={t('analysis.chartMom')} fill="#274C92" radius={[4, 4, 0, 0]} barSize={8} />
                  <Line type="monotone" dataKey="yoy" name={t('analysis.chartYoy')} stroke="#10b981" strokeWidth={2} dot={{ r: 2 }} connectNulls={false} />
                </ComposedChart>
              </ResponsiveContainer>
            ) : (
              /* 全期 mom/yoy 均无基期 → 不画假趋势，显式空态 */
              <div className="h-[260px] flex items-center justify-center text-center px-4">
                <p className="text-xs text-[#5c5c5a] italic">{t('analysis.insufficientHistory')}</p>
              </div>
            )}
          </PanoramaCard>

          {/* Unit Profit Contribution */}
          <PanoramaCard title={t('analysis.logistics')} subtitle={t('analysis.subtitleLogistics')}>
            <ResponsiveContainer width="100%" height={260}>
              <BarChart data={data.monthlyPerformance}>
                <XAxis dataKey="name" hide />
                <YAxis hide />
                <Tooltip contentStyle={{ backgroundColor: '#ffffff', border: '1px solid #e0ddd5', borderRadius: '12px' }} labelFormatter={(label) => localizeMonthName(label, t)} />
                <Bar dataKey="purchaseTons" name={t('analysis.chartPurchase')} fill="#5B7FC4" opacity={0.6} radius={[2, 2, 0, 0]} />
                <Bar dataKey="salesTons" name={t('analysis.chartSales')} fill="#10b981" radius={[2, 2, 0, 0]} />
              </BarChart>
            </ResponsiveContainer>
          </PanoramaCard>

          {/* Profitability Index Scatter */}
          <PanoramaCard title={t('analysis.efficiency')} subtitle={t('analysis.subtitleEfficiency')}>
            <ResponsiveContainer width="100%" height={260}>
              <ScatterChart margin={{ top: 20, right: 20, bottom: 20, left: 20 }}>
                <XAxis type="number" dataKey="revenue" name={t('analysis.chartRevenue')} hide />
                <YAxis type="number" dataKey="profit" name={t('analysis.chartProfit')} hide />
                <ZAxis type="number" dataKey="deflator" range={[50, 400]} name={t('analysis.deflator')} />
                <Tooltip cursor={{ strokeDasharray: '3 3' }} contentStyle={{ backgroundColor: '#ffffff', border: '1px solid #e0ddd5', borderRadius: '12px' }} />
                <Scatter name={t('analysis.chartMonthlyData')} data={data.monthlyPerformance.filter(p => p.deflator != null)} fill="#274C92">
                  {data.monthlyPerformance.filter(p => p.deflator != null).map((entry, index) => (
                    <Cell key={`cell-${index}`} fill={entry.profit > stats.avgProfit ? '#10b981' : '#274C92'} />
                  ))}
                </Scatter>
              </ScatterChart>
            </ResponsiveContainer>
          </PanoramaCard>

          {/* Large Row: Comprehensive Summary Table Overlay or Chart */}
          <div className="lg:col-span-4 bg-white/80 border border-[#e0ddd5] rounded-xl p-10 overflow-hidden relative" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.06)' }}>
            <div className="absolute -top-24 -right-24 w-64 h-64 bg-primary/5 blur-[80px] rounded-full pointer-events-none"></div>
            <div className="flex flex-col md:flex-row justify-between items-start md:items-center mb-10 gap-4">
              <div>
                <h4 className="text-xl font-bold text-[#191918] tracking-tight">{t('analysis.matrixTitle')}</h4>
                <p className="text-[#5c5c5a] text-xs mt-1">{t('analysis.matrixSubtitle')}</p>
              </div>
              <div className="flex space-x-2">
                <span className="px-3 py-1 bg-emerald-500/10 text-emerald-600 text-[10px] font-bold rounded-full border border-emerald-500/20">{t('analysis.matrixBadgeSteady')}</span>
                <span className="px-3 py-1 bg-primary/10 text-primary text-[10px] font-bold rounded-full border border-primary/20">{t('analysis.matrixBadgeBalance')}</span>
              </div>
            </div>

            <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-5 gap-6">
              {data.monthlyPerformance.map((item, idx) => (
                <div key={idx} className="bg-[#f9f9f8]/60 border border-[#e0ddd5]/70 p-4 rounded-xl hover:border-primary/40 transition-all hover:bg-[#f9f9f8]/80 group">
                  <p className="text-[#5c5c5a] text-[11px] font-bold uppercase mb-2 whitespace-nowrap group-hover:text-primary transition-colors">{localizeMonthName(item.name, t)}</p>
                  <p className="text-[#191918] text-lg font-bold">{formatMoney(item.revenue, accLocale, uiLang)}</p>
                  <div className="mt-3 space-y-1">
                    <div className="flex justify-between items-center gap-2 text-[11px] whitespace-nowrap">
                      <span className="text-[#5c5c5a]">{t('analysis.chartProfit')}</span>
                      <span className="text-emerald-600 font-bold">{formatMoney(item.profit, accLocale, uiLang)}</span>
                    </div>
                    <div className="flex justify-between items-center gap-2 text-[11px] whitespace-nowrap">
                      <span className="text-[#5c5c5a]">{t('analysis.chartTons')}</span>
                      {/* Quantity only — no hardcoded商品单位 (units belong to product/SKU settings, not analytics) */}
                      <span className="text-[#4a4a48] font-bold">{item.salesTons}</span>
                    </div>
                  </div>
                </div>
              ))}
              <div className="bg-primary border border-primary p-4 rounded-xl flex flex-col justify-center items-center cursor-pointer hover:scale-105 transition-transform" style={{ boxShadow: '0 4px 16px rgba(39,76,146,0.15)' }}>
                <p className="text-white/80 text-[10px] font-bold uppercase mb-1">{t('analysis.chartAvgRevenue')}</p>
                <p className="text-white text-xl font-bold">{formatMoney(stats.avgRevenue, accLocale, uiLang)}</p>
              </div>
            </div>
          </div>
        </div>
      )}

      {activeTab === 'trends' && (
        <div className="grid grid-cols-1 lg:grid-cols-4 gap-8">
          <div className="lg:col-span-3 bg-white/80 border border-[#e0ddd5] rounded-xl p-10 min-h-[500px]" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.06)' }}>
            <div className="flex items-center justify-between mb-12">
              <div>
                <h3 className="text-2xl font-bold text-[#191918]">
                  {dimension === 'financial' && t('analysis.trendFinancial')}
                  {dimension === 'volume' && t('analysis.trendVolume')}
                  {dimension === 'efficiency' && t('analysis.trendEfficiency')}
                </h3>
                <p className="text-[#5c5c5a] text-sm mt-1 italic">{t('analysis.trendSubtitle')}</p>
              </div>
            </div>
            <div className="h-[400px]">
              <ResponsiveContainer width="100%" height="100%">
                <ComposedChart data={data.monthlyPerformance}>
                  <CartesianGrid strokeDasharray="3 3" stroke="#e0ddd5" vertical={false} />
                  <XAxis dataKey="name" stroke="#6b6b69" fontSize={11} tickLine={false} axisLine={false} dy={10} tickFormatter={(v) => localizeMonthName(v, t)} />
                  <YAxis yAxisId="left" stroke="#6b6b69" fontSize={11} tickLine={false} axisLine={false} tickFormatter={(v) => dimension === 'volume' ? `${v} ${unitLabel}` : formatCurrency(v)} />
                  <Tooltip
                    contentStyle={{ backgroundColor: '#ffffff', border: '1px solid #e0ddd5', borderRadius: '16px', boxShadow: '0 25px 50px -12px rgba(0,0,0,0.15)' }}
                    cursor={{ stroke: '#274C92', strokeWidth: 1 }}
                    labelFormatter={(label) => localizeMonthName(label, t)}
                  />
                  <Legend verticalAlign="top" align="right" wrapperStyle={{ paddingBottom: '30px' }} />
                  {dimension === 'financial' && (
                    <>
                      <Area yAxisId="left" type="monotone" dataKey="revenue" name={t('analysis.chartRevenueLabel')} stroke="#274C92" fill="url(#colorRev)" strokeWidth={3} />
                      <Line yAxisId="left" type="monotone" dataKey="profit" name={t('analysis.chartProfitLabel')} stroke="#10b981" strokeWidth={3} dot={{ r: 4, fill: '#10b981' }} />
                      <defs>
                        <linearGradient id="colorRev" x1="0" y1="0" x2="0" y2="1">
                          <stop offset="5%" stopColor="#274C92" stopOpacity={0.2} />
                          <stop offset="95%" stopColor="#274C92" stopOpacity={0} />
                        </linearGradient>
                      </defs>
                    </>
                  )}
                  {dimension === 'volume' && (
                    <>
                      <Bar yAxisId="left" dataKey="purchaseTons" name={t('analysis.chartPurchaseTons')} fill="#5B7FC4" radius={[6, 6, 0, 0]} barSize={20} />
                      <Bar yAxisId="left" dataKey="salesTons" name={t('analysis.chartSalesTons')} fill="#274C92" radius={[6, 6, 0, 0]} barSize={20} />
                    </>
                  )}
                  {dimension === 'efficiency' && (
                    <>
                      <YAxis yAxisId="right" orientation="right" stroke="#f59e0b" fontSize={11} tickLine={false} axisLine={false} domain={['auto', 'auto']} />
                      <Line yAxisId="right" type="step" dataKey="deflator" name={t('analysis.deflator')} stroke="#f59e0b" strokeWidth={2} dot={{ r: 3 }} connectNulls={false} />
                      <Area yAxisId="left" type="monotone" dataKey="profit" name={t('analysis.chartUnitProfit')} fill="#10b981" fillOpacity={0.1} stroke="#10b981" />
                    </>
                  )}
                </ComposedChart>
              </ResponsiveContainer>
            </div>
          </div>

          <div className="space-y-6">
            <SummaryMiniCard title={t('analysis.peakMonth')} value={data.monthlyPerformance.length > 0 ? localizeMonthName([...data.monthlyPerformance].sort((a, b) => b.revenue - a.revenue)[0].name, t) : '—'} sub={t('analysis.peakMonthSub')} icon="fa-crown" color="text-amber-600" />
            <SummaryMiniCard title={t('analysis.fastest')} value={data.monthlyPerformance.some(p => p.mom != null) ? localizeMonthName([...data.monthlyPerformance].sort((a, b) => (b.mom ?? -Infinity) - (a.mom ?? -Infinity))[0].name, t) : '—'} sub={t('analysis.fastestSub')} icon="fa-bolt" color="text-primary" />
            <div className="bg-white/80 border border-[#e0ddd5] rounded-xl p-8" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.06)' }}>
              <h4 className="text-[#5c5c5a] text-[10px] uppercase font-bold tracking-[0.2em] mb-6">{t('analysis.anomalyTitle')}</h4>
              <div className="space-y-5">
                {(() => {
                  const perf = data.monthlyPerformance;
                  if (!perf.length) return <p className="text-[10px] text-[#5c5c5a] italic">{t('analysis.anomalyNoData')}</p>;
                  // 营收/吨位偏离度：各月单吨营收的变异系数
                  const unitRevenues = perf.filter(p => p.salesTons > 0).map(p => p.revenue / p.salesTons);
                  const meanUR = unitRevenues.length > 0 ? unitRevenues.reduce((a, b) => a + b, 0) / unitRevenues.length : 0;
                  const stdUR = unitRevenues.length > 1 ? Math.sqrt(unitRevenues.reduce((a, b) => a + (b - meanUR) ** 2, 0) / (unitRevenues.length - 1)) : 0;
                  const cvUR = meanUR === 0 ? 0 : (stdUR / meanUR * 100);
                  const cvLabel = cvUR < 5 ? t('analysis.severityLow') : cvUR < 15 ? t('analysis.severityMid') : t('analysis.severityHigh');
                  const cvColor = cvUR < 5 ? 'text-emerald-600' : cvUR < 15 ? 'text-amber-500' : 'text-rose-500';
                  // 价格指数关联度：deflator 与 profit 的皮尔逊相关系数（仅取有价格指数的月份，成对对齐）
                  const withDef = perf.filter(p => p.deflator != null);
                  const profits = withDef.map(p => p.profit);
                  const deflators = withDef.map(p => p.deflator as number);
                  const n = deflators.length;
                  const meanP = n ? profits.reduce((a, b) => a + b, 0) / n : 0;
                  const meanD = n ? deflators.reduce((a, b) => a + b, 0) / n : 0;
                  const cov = profits.reduce((a, b, i) => a + (b - meanP) * (deflators[i] - meanD), 0);
                  const stdP = Math.sqrt(profits.reduce((a, b) => a + (b - meanP) ** 2, 0));
                  const stdD = Math.sqrt(deflators.reduce((a, b) => a + (b - meanD) ** 2, 0));
                  const corr = (n < 2 || stdP === 0 || stdD === 0) ? 0 : (cov / (stdP * stdD)) * 100;
                  const absCorr = Math.abs(corr);
                  const corrSign = corr >= 0 ? '+' : '−';
                  const corrLabel = absCorr > 70 ? t('analysis.corrStrong') : absCorr > 40 ? t('analysis.corrModerate') : t('analysis.corrWeak');
                  const corrColor = absCorr > 70 ? 'text-primary' : absCorr > 40 ? 'text-amber-500' : 'text-emerald-600';
                  return (
                    <>
                      <div className="flex justify-between items-center text-xs">
                        <span className="text-[#4a4a48]">{t('analysis.anomalyRevTon')}</span>
                        <span className={`${cvColor} font-mono font-bold`}>{cvUR.toFixed(1)}% {cvLabel}</span>
                      </div>
                      <div className="flex justify-between items-center text-xs">
                        <span className="text-[#4a4a48]">{t('analysis.anomalyPriceCorr')}</span>
                        <span className={`${corrColor} font-mono font-bold`}>{corrSign}{absCorr.toFixed(1)}% {corrLabel}</span>
                      </div>
                      <div className="pt-4 border-t border-[#e0ddd5]">
                        <p className="text-[10px] text-[#5c5c5a] leading-relaxed italic">
                          {cvUR < 5 ? t('analysis.anomalyLow') : cvUR < 15 ? t('analysis.anomalyMid') : t('analysis.anomalyHigh')}
                        </p>
                      </div>
                    </>
                  );
                })()}
              </div>
            </div>
          </div>
        </div>
      )}

      {/* Rest of the Tabs (Forecast, Table) */}
      {activeTab === 'forecast' && (
        <div className="bg-white/80 border border-[#e0ddd5] rounded-xl p-10" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.06)' }}>
          <div className="flex items-center justify-between mb-12">
            <div>
              <h3 className="text-2xl font-bold text-[#191918] flex items-center">
                {t('analysis.forecastTitle')}
                <span className="ml-4 px-3 py-1 bg-primary/10 text-primary text-[10px] rounded-full border border-primary/20 font-bold uppercase tracking-wider">{t('analysis.forecastBadge')}</span>
              </h3>
              <p className="text-[#5c5c5a] text-sm mt-1 italic">{t('analysis.forecastSubtitle')}</p>
            </div>
          </div>

          {isAnalysing ? (
            <div className="h-[450px] flex flex-col items-center justify-center space-y-10">
              <div className="relative">
                <div className="w-24 h-24 rounded-full bg-primary/10 border border-primary/30 flex items-center justify-center animate-pulse">
                  <span className="text-4xl">🔮</span>
                </div>
                <div className="absolute inset-0 border-2 border-dashed border-primary/40 rounded-full animate-[spin_10s_linear_infinite]"></div>
              </div>
              <div className="text-center space-y-3">
                <p className="text-[#191918] text-xl font-medium tracking-tight">{loadingMessage}</p>
                <p className="text-[#5c5c5a] text-sm">{t('analysis.forecastLoading')}</p>
              </div>
            </div>
          ) : (
            <div className="h-[450px]">
              <ResponsiveContainer width="100%" height="100%">
                <ComposedChart data={predictedData}>
                  <defs>
                    <linearGradient id="colorForecast" x1="0" y1="0" x2="0" y2="1">
                      <stop offset="5%" stopColor="#274C92" stopOpacity={0.3} />
                      <stop offset="95%" stopColor="#274C92" stopOpacity={0} />
                    </linearGradient>
                  </defs>
                  <CartesianGrid strokeDasharray="3 3" stroke="#e0ddd5" vertical={false} />
                  <XAxis dataKey="name" stroke="#6b6b69" fontSize={11} tickLine={false} axisLine={false} tickFormatter={(v) => localizeMonthName(v, t)} />
                  <YAxis stroke="#6b6b69" fontSize={11} tickLine={false} axisLine={false} tickFormatter={(v) => formatCurrency(v)} />
                  <Tooltip
                    content={({ active, payload, label }) => {
                      if (active && payload && payload.length) {
                        const d = payload[0].payload;
                        return (
                          <div className="bg-white border border-[#e0ddd5] p-6 rounded-xl backdrop-blur-xl ring-1 ring-[#e0ddd5]" style={{ boxShadow: '0 25px 50px -12px rgba(0,0,0,0.15)' }}>
                            <p className="text-[#5c5c5a] text-[10px] font-bold uppercase mb-3 tracking-[0.2em]">{localizeMonthName(label, t)} {d.isForecast ? t('analysis.forecastValue') : t('analysis.forecastActual')}</p>
                            <div className="space-y-3">
                              <p className="text-[#191918] text-2xl font-bold">{currSym}{formatNum(d.revenue)}</p>
                              {d.isForecast && (
                                <p className="text-primary text-xs font-medium border-t border-[#e0ddd5] pt-2">
                                  {t('analysis.forecastConfidence')}: {currSym}{formatNum(d.confidenceLower)} - {currSym}{formatNum(d.confidenceUpper)}
                                </p>
                              )}
                              <p className="text-emerald-600 text-sm flex items-center">
                                <i className="fas fa-chart-line mr-2"></i> {t('analysis.forecastEstProfit')}: {currSym}{formatNum(d.profit)}
                              </p>
                            </div>
                          </div>
                        );
                      }
                      return null;
                    }}
                  />
                  <Area type="monotone" dataKey="confidenceUpper" stroke="none" fill="#274C92" fillOpacity={0.12} name={t('analysis.forecastUpperBound')} />
                  <Area type="monotone" dataKey="confidenceLower" stroke="none" fill="#274C92" fillOpacity={0.12} name={t('analysis.forecastLowerBound')} />
                  <Area
                    type="monotone"
                    dataKey="revenue"
                    name={t('analysis.chartRevenueLabel')}
                    stroke="#274C92"
                    strokeWidth={4}
                    fill="url(#colorForecast)"
                  />
                  <Line type="monotone" dataKey="profit" name={t('analysis.chartProfitLabel')} stroke="#10b981" strokeWidth={2} dot={{ r: 3 }} strokeDasharray="4 4" />
                </ComposedChart>
              </ResponsiveContainer>
            </div>
          )}

          {/* Grounding Sources */}
          {groundingSources.length > 0 && (
            <div className="mt-6 bg-white/60 border border-[#e0ddd5] rounded-xl p-6" style={{ boxShadow: '0 2px 12px rgba(0,0,0,0.03)' }}>
              <h4 className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest mb-4 flex items-center">
                <i className="fas fa-globe mr-2 text-primary"></i>
                {t('analysis.forecastSources')}
              </h4>
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
                {groundingSources.map((src, idx) => (
                  <a
                    key={idx}
                    href={src.uri}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="flex items-center text-xs text-[#4a4a48] hover:text-primary transition-colors truncate p-2 rounded-lg hover:bg-[#f9f9f8]"
                  >
                    <i className="fas fa-link mr-2 text-primary/40 flex-shrink-0"></i>
                    <span className="truncate">{src.title}</span>
                  </a>
                ))}
              </div>
            </div>
          )}
        </div>
      )}

      {activeTab === 'table' && (
        <div className="bg-white/80 border border-[#e0ddd5] rounded-xl overflow-hidden" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.06)' }}>
          <div className="p-10 border-b border-[#e0ddd5] bg-[#f9f9f8]/50 flex justify-between items-center">
            <div>
              <h3 className="text-2xl font-bold text-[#191918] tracking-tight">{t('analysis.tableTitle')}</h3>
              <p className="text-[#5c5c5a] text-sm mt-1">{t('analysis.tableSubtitle')}</p>
            </div>
            <button
              onClick={() => {
                const rows = data.monthlyPerformance;
                const csvHeader = [t('analysis.tableMonth'),t('analysis.tableHeaderPurchase'),t('analysis.tableHeaderSales'),t('analysis.tableHeaderRevenue'),t('analysis.tableHeaderCost'),t('analysis.tableHeaderGross'),t('analysis.tableHeaderNet'),t('analysis.tableHeaderYoy'),t('analysis.tableHeaderMom'),t('analysis.tableHeaderPrice')].join(',');
                let csv = '﻿' + csvHeader + '\n';
                rows.forEach(r => {
                  csv += `${r.name},${r.purchaseTons},${r.salesTons},${r.revenue},${r.cost},${r.profit},${r.netProfit},${r.yoy ?? ''},${r.mom ?? ''},${r.deflator ?? ''}\n`;
                });
                const blob = new Blob([csv], { type: 'text/csv;charset=utf-8;' });
                const url = URL.createObjectURL(blob);
                const a = document.createElement('a');
                a.href = url; a.download = t('analysis.tableExportFilename'); a.click();
                setTimeout(() => URL.revokeObjectURL(url), 1000);
              }}
              className="px-6 py-2.5 bg-[#f9f9f8] text-[#4a4a48] rounded-xl text-xs font-bold border border-[#e0ddd5] hover:text-[#191918] hover:bg-[#f0eeeb] transition-all flex items-center"
            >
              <i className="fas fa-file-csv mr-2"></i> {t('analysis.tableExport')}
            </button>
          </div>
          <div className="overflow-x-auto">
            <table className="w-full text-left border-collapse min-w-[1400px]">
              <thead>
                <tr className="bg-[#f9f9f8]/70 text-[#333330] text-[10px] uppercase font-bold tracking-widest">
                  <th className="px-10 py-6 border-r border-[#e0ddd5]/70 sticky left-0 bg-white">{t('analysis.tableMonth')}</th>
                  <th className="px-10 py-6 text-center border-r border-[#e0ddd5]/70">{t('analysis.tableHeaderPurchase')}</th>
                  <th className="px-10 py-6 text-center border-r border-[#e0ddd5]/70">{t('analysis.tableHeaderSales')}</th>
                  <th className="px-10 py-6 text-right border-r border-[#e0ddd5]/70">{t('analysis.tableHeaderRevenue')}</th>
                  <th className="px-10 py-6 text-right border-r border-[#e0ddd5]/70">{t('analysis.tableHeaderNet')}</th>
                  <th className="px-10 py-6 text-center border-r border-[#e0ddd5]/70">{t('analysis.tableHeaderYoy')}</th>
                  <th className="px-10 py-6 text-center border-r border-[#e0ddd5]/70">{t('analysis.tableHeaderMom')}</th>
                  <th className="px-10 py-6 text-center bg-amber-500/5">{t('analysis.tableHeaderPrice')}</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-[#e0ddd5]">
                {data.monthlyPerformance.map((row, idx) => (
                  <tr key={idx} className="hover:bg-primary/5 transition-colors group">
                    <td className="px-10 py-6 text-sm font-bold text-[#333330] border-r border-[#e0ddd5]/70 sticky left-0 bg-white/90 group-hover:bg-[#f0eeeb] transition-colors">{localizeMonthName(row.name, t)}</td>
                    <td className="px-10 py-6 text-sm text-center font-mono text-[#4a4a48] border-r border-[#e0ddd5]/70">{row.purchaseTons}</td>
                    <td className="px-10 py-6 text-sm text-center font-mono text-[#4a4a48] border-r border-[#e0ddd5]/70">{row.salesTons}</td>
                    <td className="px-10 py-6 text-sm text-right font-bold text-[#191918] border-r border-[#e0ddd5]/70">{row.revenue.toLocaleString()}</td>
                    <td className="px-10 py-6 text-sm text-right font-bold text-emerald-600 border-r border-[#e0ddd5]/70">{row.netProfit.toLocaleString()}</td>
                    <td className="px-10 py-6 text-center border-r border-[#e0ddd5]/70">
                      {row.yoy == null ? (
                        <span className="text-[10px] text-[#5c5c5a]">—</span>
                      ) : (
                        <span className={`px-2.5 py-1 rounded-lg text-[10px] font-bold ${row.yoy >= 0 ? 'bg-emerald-500/10 text-emerald-600' : 'bg-rose-500/10 text-rose-500'}`}>
                          {row.yoy > 0 ? '+' : ''}{row.yoy.toFixed(1)}%
                        </span>
                      )}
                    </td>
                    <td className="px-10 py-6 text-center border-r border-[#e0ddd5]/70">
                      {row.mom == null ? (
                        <span className="text-[10px] text-[#5c5c5a]">—</span>
                      ) : (
                        <span className={`px-2.5 py-1 rounded-lg text-[10px] font-bold ${row.mom >= 0 ? 'bg-primary/10 text-primary' : 'bg-rose-500/10 text-rose-500'}`}>
                          {row.mom > 0 ? '+' : ''}{row.mom.toFixed(1)}%
                        </span>
                      )}
                    </td>
                    <td className="px-10 py-6 text-sm text-center font-bold text-amber-500 bg-amber-500/5">{row.deflator == null ? <span className="text-[#5c5c5a]">—</span> : row.deflator}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}

    </div>
  );
};

const PanoramaCard: React.FC<{ title: string, subtitle: string, children: React.ReactNode }> = ({ title, subtitle, children }) => (
  <div className="bg-white/80 border border-[#e0ddd5] rounded-xl p-8 flex flex-col hover:border-primary/30 transition-all group" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.06)' }}>
    <div className="mb-6">
      <h4 className="text-[#191918] font-bold text-lg tracking-tight group-hover:text-primary transition-colors">{title}</h4>
      <p className="text-[10px] text-[#5c5c5a] uppercase font-bold tracking-[0.2em] mt-1">{subtitle}</p>
    </div>
    <div className="flex-1 min-h-[260px] flex items-center justify-center">
      {children}
    </div>
  </div>
);

const TabButton: React.FC<{ active: boolean, onClick: () => void, label: string, icon: string }> = ({ active, onClick, label, icon }) => (
  <button
    onClick={onClick}
    className={`flex items-center space-x-3 px-6 py-3 rounded-xl text-sm font-bold transition-all duration-300
      ${active ? 'bg-primary text-white' : 'text-[#4a4a48] hover:text-[#333330]'}
    `}
    style={active ? { boxShadow: '0 4px 16px rgba(39,76,146,0.15)' } : {}}
  >
    <i className={`fas ${icon} text-sm ${active ? 'scale-110' : ''}`}></i>
    <span>{label}</span>
  </button>
);

const DimButton: React.FC<{ active: boolean, onClick: () => void, label: string }> = ({ active, onClick, label }) => (
  <button
    onClick={onClick}
    className={`px-5 py-2 rounded-lg text-[10px] font-bold uppercase tracking-widest transition-all
      ${active ? 'bg-[#f0eeeb] text-primary shadow-inner' : 'text-[#5c5c5a] hover:text-[#4a4a48]'}
    `}
  >
    {label}
  </button>
);

const StatsIndicator: React.FC<{ label: string, value: string, trend: 'up' | 'down' | 'neutral', color?: string }> = ({ label, value, trend, color }) => (
  <div className="text-center">
    <p className="text-[#5c5c5a] text-[10px] uppercase font-bold mb-2 tracking-[0.2em]">{label}</p>
    <div className="flex items-center justify-center space-x-2">
      <p className={`text-2xl font-bold tracking-tight ${color || (trend === 'up' ? 'text-emerald-600' : trend === 'down' ? 'text-rose-500' : 'text-[#191918]')}`}>{value}</p>
      {trend !== 'neutral' && <i className={`fas fa-caret-${trend} text-xs ${trend === 'up' ? 'text-emerald-500' : 'text-rose-500'}`}></i>}
    </div>
  </div>
);

const SummaryMiniCard: React.FC<{ title: string, value: string, sub: string, icon: string, color: string }> = ({ title, value, sub, icon, color }) => (
  <div className="bg-white/80 border border-[#e0ddd5] rounded-xl p-8 flex items-start space-x-6 hover:border-[#d1cdc4] transition-all" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.06)' }}>
    <div className={`w-14 h-14 rounded-xl bg-[#f0eeeb]/50 flex items-center justify-center ${color} shadow-inner`}>
      <i className={`fas ${icon} text-2xl`}></i>
    </div>
    <div>
      <p className="text-[#5c5c5a] text-[10px] uppercase font-bold tracking-[0.2em] mb-2">{title}</p>
      <p className="text-[#191918] text-2xl font-bold tracking-tight">{value}</p>
      <p className="text-[#5c5c5a] text-xs mt-1 italic">{sub}</p>
    </div>
  </div>
);

export default DataAnalysisPage;
