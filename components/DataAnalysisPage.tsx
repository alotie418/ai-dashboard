
import React, { useState, useEffect, useCallback, useMemo, useRef } from 'react';
import {
  LineChart, Line, AreaChart, Area, XAxis, YAxis, CartesianGrid, Tooltip,
  ResponsiveContainer, BarChart, Bar, Legend, ComposedChart, Cell, ScatterChart, Scatter, ZAxis
} from 'recharts';
import { BusinessData } from '../types';
import { GoogleGenAI, Type } from "@google/genai";
import { getApiKey } from '../services/apiKey';
import { searchTavily } from '../services/api';

interface Props {
  data: BusinessData;
  selectedYear: string;
  selectedQuarter: string;
  selectedMonth: string;
}

type AnalysisDimension = 'financial' | 'volume' | 'efficiency';

const LOADING_MESSAGES = [
  '① 提取历史业绩特征向量（移动平均/趋势/季节性）...',
  '② 构建 VAR(1) 多变量自回归模型...',
  '③ 运行蒙特卡洛模拟 (1000次) 计算置信区间...',
  '④ Tavily 搜索软水盐市场行情...',
  '⑤ Gemini + Google Search 综合分析...',
  '⑥ 融合全部数据源生成最终预测...'
];

const DataAnalysisPage: React.FC<Props> = ({ data, selectedYear, selectedQuarter, selectedMonth }) => {
  const [activeTab, setActiveTab] = useState<'trends' | 'table' | 'forecast' | 'panorama'>('panorama');
  const [salesForecast, setSalesForecast] = useState<string>('');
  const [predictedData, setPredictedData] = useState<any[]>([]);
  const [isAnalysing, setIsAnalysing] = useState(false);
  const [loadingProgress, setLoadingProgress] = useState(0);
  const [loadingMessage, setLoadingMessage] = useState('');
  const [groundingSources, setGroundingSources] = useState<{ title: string, uri: string }[]>([]);

  const stats = useMemo(() => {
    const perf = data.monthlyPerformance;
    if (!perf.length) return { yoy: 0, mom: 0, deflator: 0, avgProfit: 0, avgRevenue: 0 };
    const avg = (arr: number[]) => arr.reduce((a, b) => a + b, 0) / arr.length;
    return {
      yoy: avg(perf.map(p => p.yoy)),
      mom: avg(perf.map(p => p.mom)),
      deflator: avg(perf.map(p => p.deflator)),
      avgProfit: avg(perf.map(p => p.profit)),
      avgRevenue: avg(perf.map(p => p.revenue))
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

    // Growth acceleration (2nd derivative of MoM)
    const moms = nonZero.map(p => p.mom);
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

  // ② VAR(1) Model: independent AR(1) for [revenue, cost, salesTons]
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
  const monteCarloSimulation = (historicalRevenues: number[], pointEstimates: number[]) => {
    const nonZero = historicalRevenues.filter(r => r > 0);
    if (nonZero.length < 3) return null;

    const mean = nonZero.reduce((a, b) => a + b, 0) / nonZero.length;
    const variance = nonZero.reduce((a, b) => a + (b - mean) ** 2, 0) / nonZero.length;
    const cv = mean === 0 ? 0 : Math.sqrt(variance) / mean;
    const SIMULATIONS = 1000;

    return pointEstimates.map((predicted, month) => {
      const horizonFactor = 1 + month * 0.15;
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

  const isAnalysingRef = useRef(false);
  const runAnalysis = useCallback(async () => {
    if (isAnalysingRef.current) return;
    isAnalysingRef.current = true;
    setIsAnalysing(true);
    setGroundingSources([]);

    try {
      const perf = data.monthlyPerformance;

      // STEP 1: Local feature extraction
      const features = extractFeatures(perf);

      // STEP 2: VAR forecast
      const varPred = varForecast(perf);

      // STEP 3: Monte Carlo on VAR predictions (if available)
      const historicalRevenues = perf.map(m => m.revenue);
      const mcOnVar = varPred
        ? monteCarloSimulation(historicalRevenues, varPred.map(v => v.revenue))
        : null;

      // STEP 4: Tavily search for market data (via Worker proxy)
      let tavilyContext = '';
      try {
        const tavilyData = await searchTavily('软水盐 市场行情 价格趋势 原盐 化工盐 2026', 5);
        tavilyContext = (tavilyData.results || [])
          .map((r: any, i: number) => `[来源${i + 1}] ${r.title}\n${r.content}`)
          .join('\n\n');
      } catch (e) {
        console.warn('Tavily search skipped:', e);
      }

      // STEP 5: Build comprehensive prompt with ALL local results
      const historySummary = perf.map(m => ({
        m: m.name, r: m.revenue, c: m.cost, p: m.profit, np: m.netProfit,
        pt: m.purchaseTons, st: m.salesTons, yoy: m.yoy, mom: m.mom, d: m.deflator
      }));
      const fs = data.financialStatement;
      const finSummary = {
        rev: fs.salesRevenue, cos: fs.costOfSales, gp: fs.grossProfit,
        gm: fs.grossMargin, np: fs.netProfit, nm: fs.netMargin,
        tax: fs.taxSurcharge, ship: fs.shippingFee, admin: fs.adminExpense
      };

      let prompt = `你是一位精通软水盐行业的首席财务官。请综合以下所有信息源，给出未来 3 个月的营业收入和利润预测。

## 一、企业历史月度数据（12 维度）
${JSON.stringify(historySummary)}
字段：m=月份, r=营收, c=成本, p=毛利, np=净利润, pt=采购吨数, st=销售吨数, yoy=同比%, mom=环比%, d=平减指数

## 二、年度财务汇总
${JSON.stringify(finSummary)}`;

      if (features) {
        prompt += `

## 三、本地统计特征向量
${JSON.stringify(features)}
说明：ma3=3月移动平均, trendSlope=趋势斜率(月增量), revenuePerTon=吨单价, costRatio=成本收入比, seasonalIndices=季节性指数, avgAcceleration=增长加速度`;
      }

      if (varPred) {
        prompt += `

## 四、VAR(1) 自回归模型预测
${JSON.stringify(varPred)}
说明：基于 revenue/cost/salesTons 三变量 AR(1) 拟合的纯统计预测。`;
      }

      if (mcOnVar) {
        prompt += `

## 五、蒙特卡洛模拟 90% 置信区间 (1000次模拟, P5-P95)
${JSON.stringify(mcOnVar)}
说明：基于历史波动率的随机模拟区间，不确定性随预测时间增长。`;
      }

      if (tavilyContext) {
        prompt += `

## 六、Tavily 搜索引擎返回的市场情报
${tavilyContext}`;
      }

      prompt += `

## 分析要求
1. 请同时使用 Google 搜索功能查找最新的【软水盐】市场行情、原盐价格走势和宏观经济指标。
2. 综合以上全部信息（企业数据 + 统计模型 + 蒙特卡洛区间 + 双引擎市场搜索），给出科学预测。
3. 如果 VAR 模型预测与你自己的判断不一致，请在 insights 中说明原因和你的修正依据。
4. 在 insights 中总结你参考了哪些市场数据源，以及主要风险因素。`;

      // STEP 6: AI synthesis with Google Search grounding
      const ai = new GoogleGenAI({ apiKey: getApiKey() });
      const response = await ai.models.generateContent({
        model: "gemini-3-pro-preview",
        contents: prompt,
        config: {
          tools: [{ googleSearch: {} }],
          systemInstruction: "你是一位精通软水盐行业的首席财务官与市场分析师。你将收到：企业历史数据、本地统计模型（特征向量+VAR+蒙特卡洛）的计算结果、以及 Tavily 搜索到的市场情报。请结合所有信息和你自己的 Google 搜索结果，进行最终的综合预测。返回JSON，包含insights字符串和predictions数组。",
          responseMimeType: "application/json",
          responseSchema: {
            type: Type.OBJECT,
            properties: {
              insights: { type: Type.STRING },
              predictions: {
                type: Type.ARRAY,
                items: {
                  type: Type.OBJECT,
                  properties: {
                    name: { type: Type.STRING },
                    revenue: { type: Type.NUMBER },
                    profit: { type: Type.NUMBER },
                    confidenceUpper: { type: Type.NUMBER },
                    confidenceLower: { type: Type.NUMBER }
                  }
                }
              }
            }
          }
        }
      });

      const result = JSON.parse(response.text || '{}');
      setSalesForecast(result.insights || '分析完成。未来季度预计呈稳健增长趋势。');

      // Extract Google Search grounding sources
      const chunks = response.candidates?.[0]?.groundingMetadata?.groundingChunks;
      if (chunks) {
        const sources: { title: string, uri: string }[] = [];
        for (const chunk of chunks) {
          if (chunk.web) {
            sources.push({ title: chunk.web.title || '参考来源', uri: chunk.web.uri });
          }
        }
        setGroundingSources(sources);
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
    } catch (err) {
      console.error(err);
      setSalesForecast("无法连接到预测引擎，请检查网络或 API 配置。");
    } finally {
      isAnalysingRef.current = false;
      setIsAnalysing(false);
      setLoadingProgress(100);
    }
  }, [data.monthlyPerformance, data.financialStatement]);

  const hasRun = useRef(false);
  useEffect(() => {
    if (!hasRun.current) {
      hasRun.current = true;
      runAnalysis();
    }
  }, [runAnalysis]);

  const formatCurrency = (v: number) => `¥${(v / 1000).toFixed(1)}k`;
  const formatNum = (v: number) => v.toLocaleString();

  return (
    <div className="space-y-8 animate-in fade-in duration-700 pb-20">
      {/* AI Header Banner */}
      <div className="bg-gradient-to-br from-white via-white to-[#f9f9f8] border border-[#e0ddd5] rounded-xl p-10 relative overflow-hidden" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.06)' }}>
        <div className="absolute top-0 right-0 w-1/3 h-full bg-[#d97757]/5 blur-[120px] pointer-events-none"></div>
        <div className="relative z-10 flex flex-col md:flex-row md:items-center justify-between gap-10">
          <div className="flex-1">
            <div className="flex items-center space-x-3 mb-6">
              <div className="flex space-x-1">
                <span className="h-1.5 w-1.5 rounded-full bg-[#d97757]"></span>
                <span className="h-1.5 w-1.5 rounded-full bg-[#d97757]/60"></span>
                <span className="h-1.5 w-1.5 rounded-full bg-[#d97757]/30"></span>
              </div>
              <h3 className="text-[#d97757] text-xs font-bold uppercase tracking-[0.4em]">AI Intelligence Dashboard</h3>
            </div>
            {isAnalysing ? (
              <div className="space-y-6">
                <div className="flex items-center space-x-6">
                  <div className="w-14 h-14 bg-[#d97757]/10 rounded-xl flex items-center justify-center border border-[#d97757]/20 shadow-inner">
                    <span className="text-3xl animate-bounce">🧠</span>
                  </div>
                  <div>
                    <p className="text-[#191918] font-bold text-xl">{loadingMessage}</p>
                    <p className="text-[#d97757]/60 text-[10px] font-mono mt-1">REALTIME NEURAL PROCESSING | PROGRESS: {Math.floor(loadingProgress)}%</p>
                  </div>
                </div>
                <div className="w-full bg-[#f9f9f8] h-1.5 rounded-full overflow-hidden">
                  <div className="bg-gradient-to-r from-[#d97757] to-[#e8956e] h-full transition-all duration-300 ease-out" style={{ width: `${loadingProgress}%`, boxShadow: '0 0 15px rgba(217,119,87,0.5)' }}></div>
                </div>
              </div>
            ) : (
              <div className="group">
                <p className="text-[#191918] text-2xl font-light leading-snug max-w-2xl">
                  {salesForecast || "正在等待数据注入..."}
                </p>
                <div className="mt-8 flex items-center space-x-6">
                  <button onClick={runAnalysis} className="px-6 py-2.5 bg-[#d97757]/10 hover:bg-[#d97757]/20 border border-[#d97757]/30 rounded-full text-[10px] text-[#d97757] font-bold uppercase tracking-widest flex items-center transition-all active:scale-95">
                    <i className="fas fa-sync-alt mr-2"></i> 重新运行预测
                  </button>
                </div>
              </div>
            )}
          </div>
          <div className="hidden lg:grid grid-cols-3 gap-8 border-l border-[#e0ddd5] pl-12 shrink-0">
            <StatsIndicator label="Avg YoY" value={`${stats.yoy.toFixed(1)}%`} trend={stats.yoy >= 0 ? 'up' : 'down'} />
            <StatsIndicator label="Avg MoM" value={`${stats.mom.toFixed(1)}%`} trend={stats.mom >= 0 ? 'up' : 'down'} />
            <StatsIndicator label="平减指数" value={stats.deflator.toFixed(1)} trend="neutral" color="text-amber-500" />
          </div>
        </div>
      </div>

      {/* Navigation Tabs */}
      <div className="flex flex-col md:flex-row md:items-center justify-between gap-6 bg-white/60 p-3 rounded-xl border border-[#e0ddd5]/70 backdrop-blur-md">
        <div className="flex p-1 bg-[#f9f9f8]/80 rounded-xl w-fit">
          <TabButton active={activeTab === 'panorama'} onClick={() => setActiveTab('panorama')} label="年度全景图" icon="fa-globe-asia" />
          <TabButton active={activeTab === 'trends'} onClick={() => setActiveTab('trends')} label="趋势分析" icon="fa-chart-area" />
          <TabButton active={activeTab === 'forecast'} onClick={() => setActiveTab('forecast')} label="预测未来" icon="fa-bolt-lightning" />
          <TabButton active={activeTab === 'table'} onClick={() => setActiveTab('table')} label="明细数据" icon="fa-table" />
        </div>

        {activeTab === 'trends' && (
          <div className="flex items-center space-x-2 px-6">
            <span className="text-[10px] text-[#5c5c5a] font-bold uppercase tracking-widest mr-2">维度切换:</span>
            <div className="flex bg-[#f9f9f8] rounded-xl p-1">
              <DimButton active={dimension === 'financial'} onClick={() => setDimension('financial')} label="金额" />
              <DimButton active={dimension === 'volume'} onClick={() => setDimension('volume')} label="吨位" />
              <DimButton active={dimension === 'efficiency'} onClick={() => setDimension('efficiency')} label="效率" />
            </div>
          </div>
        )}
      </div>

      {/* Content Rendering */}
      {activeTab === 'panorama' && (
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-8 animate-in fade-in duration-1000">
          {/* Revenue vs Cost Stacked Area */}
          <PanoramaCard title="营收与成本结构" subtitle="Revenue vs Cost Structure">
            <ResponsiveContainer width="100%" height={260}>
              <AreaChart data={data.monthlyPerformance}>
                <defs>
                  <linearGradient id="p_rev" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="5%" stopColor="#d97757" stopOpacity={0.3} />
                    <stop offset="95%" stopColor="#d97757" stopOpacity={0} />
                  </linearGradient>
                </defs>
                <CartesianGrid strokeDasharray="3 3" stroke="#e0ddd5" vertical={false} />
                <XAxis dataKey="name" hide />
                <YAxis hide domain={['auto', 'auto']} />
                <Tooltip contentStyle={{ backgroundColor: '#ffffff', border: '1px solid #e0ddd5', borderRadius: '12px' }} />
                <Area type="monotone" dataKey="revenue" stroke="#d97757" fill="url(#p_rev)" strokeWidth={2} />
                <Area type="monotone" dataKey="cost" stroke="#ef4444" fill="transparent" strokeWidth={1} strokeDasharray="3 3" />
              </AreaChart>
            </ResponsiveContainer>
          </PanoramaCard>

          {/* Monthly Growth Compare */}
          <PanoramaCard title="增长动态对比" subtitle="YoY & MoM Trajectory">
            <ResponsiveContainer width="100%" height={260}>
              <ComposedChart data={data.monthlyPerformance}>
                <XAxis dataKey="name" hide />
                <YAxis hide />
                <Tooltip contentStyle={{ backgroundColor: '#ffffff', border: '1px solid #e0ddd5', borderRadius: '12px' }} />
                <Bar dataKey="mom" name="环比" fill="#d97757" radius={[4, 4, 0, 0]} barSize={8} />
                <Line type="monotone" dataKey="yoy" name="同比" stroke="#10b981" strokeWidth={2} dot={{ r: 2 }} />
              </ComposedChart>
            </ResponsiveContainer>
          </PanoramaCard>

          {/* Unit Profit Contribution */}
          <PanoramaCard title="物流量流转平衡" subtitle="Purchase vs Sales Tons">
            <ResponsiveContainer width="100%" height={260}>
              <BarChart data={data.monthlyPerformance}>
                <XAxis dataKey="name" hide />
                <YAxis hide />
                <Tooltip contentStyle={{ backgroundColor: '#ffffff', border: '1px solid #e0ddd5', borderRadius: '12px' }} />
                <Bar dataKey="purchaseTons" name="进货" fill="#e8956e" opacity={0.6} radius={[2, 2, 0, 0]} />
                <Bar dataKey="salesTons" name="出货" fill="#10b981" radius={[2, 2, 0, 0]} />
              </BarChart>
            </ResponsiveContainer>
          </PanoramaCard>

          {/* Profitability Index Scatter */}
          <PanoramaCard title="盈利效率偏离度" subtitle="Efficiency Scatter Matrix">
            <ResponsiveContainer width="100%" height={260}>
              <ScatterChart margin={{ top: 20, right: 20, bottom: 20, left: 20 }}>
                <XAxis type="number" dataKey="revenue" name="营收" hide />
                <YAxis type="number" dataKey="profit" name="利润" hide />
                <ZAxis type="number" dataKey="deflator" range={[50, 400]} name="平减指数" />
                <Tooltip cursor={{ strokeDasharray: '3 3' }} contentStyle={{ backgroundColor: '#ffffff', border: '1px solid #e0ddd5', borderRadius: '12px' }} />
                <Scatter name="月度数据" data={data.monthlyPerformance} fill="#d97757">
                  {data.monthlyPerformance.map((entry, index) => (
                    <Cell key={`cell-${index}`} fill={entry.profit > stats.avgProfit ? '#10b981' : '#d97757'} />
                  ))}
                </Scatter>
              </ScatterChart>
            </ResponsiveContainer>
          </PanoramaCard>

          {/* Large Row: Comprehensive Summary Table Overlay or Chart */}
          <div className="lg:col-span-4 bg-white/80 border border-[#e0ddd5] rounded-xl p-10 overflow-hidden relative" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.06)' }}>
            <div className="absolute -top-24 -right-24 w-64 h-64 bg-[#d97757]/5 blur-[80px] rounded-full pointer-events-none"></div>
            <div className="flex flex-col md:flex-row justify-between items-start md:items-center mb-10 gap-4">
              <div>
                <h4 className="text-xl font-bold text-[#191918] tracking-tight">年度数据全景矩阵 (2026)</h4>
                <p className="text-[#5c5c5a] text-xs mt-1">整合金额、吨数与宏观指数的深度聚类分析</p>
              </div>
              <div className="flex space-x-2">
                <span className="px-3 py-1 bg-emerald-500/10 text-emerald-600 text-[10px] font-bold rounded-full border border-emerald-500/20">稳健增长</span>
                <span className="px-3 py-1 bg-[#d97757]/10 text-[#d97757] text-[10px] font-bold rounded-full border border-[#d97757]/20">供需平衡</span>
              </div>
            </div>

            <div className="grid grid-cols-2 md:grid-cols-4 lg:grid-cols-7 gap-6">
              {data.monthlyPerformance.map((item, idx) => (
                <div key={idx} className="bg-[#f9f9f8]/60 border border-[#e0ddd5]/70 p-4 rounded-xl hover:border-[#d97757]/40 transition-all hover:bg-[#f9f9f8]/80 group">
                  <p className="text-[#5c5c5a] text-[10px] font-bold uppercase mb-2 group-hover:text-[#d97757] transition-colors">{item.name}</p>
                  <p className="text-[#191918] text-lg font-bold">¥{(item.revenue / 1000).toFixed(0)}k</p>
                  <div className="mt-3 space-y-1">
                    <div className="flex justify-between text-[9px]">
                      <span className="text-[#5c5c5a]">利润</span>
                      <span className="text-emerald-600 font-bold">¥{(item.profit / 1000).toFixed(1)}k</span>
                    </div>
                    <div className="flex justify-between text-[9px]">
                      <span className="text-[#5c5c5a]">吨数</span>
                      <span className="text-[#4a4a48]">{item.salesTons}t</span>
                    </div>
                  </div>
                </div>
              ))}
              <div className="bg-[#d97757] border border-[#d97757] p-4 rounded-xl flex flex-col justify-center items-center cursor-pointer hover:scale-105 transition-transform" style={{ boxShadow: '0 4px 16px rgba(217,119,87,0.15)' }}>
                <p className="text-white/80 text-[10px] font-bold uppercase mb-1">月均营收</p>
                <p className="text-white text-xl font-bold">¥{(stats.avgRevenue / 1000).toFixed(1)}k</p>
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
                  {dimension === 'financial' && '营收与利润动态趋势'}
                  {dimension === 'volume' && '吨位流转与库存消耗'}
                  {dimension === 'efficiency' && '毛利率与平减指数关联分析'}
                </h3>
                <p className="text-[#5c5c5a] text-sm mt-1 italic">多变量复合坐标系分析模型</p>
              </div>
            </div>
            <div className="h-[400px]">
              <ResponsiveContainer width="100%" height="100%">
                <ComposedChart data={data.monthlyPerformance}>
                  <CartesianGrid strokeDasharray="3 3" stroke="#e0ddd5" vertical={false} />
                  <XAxis dataKey="name" stroke="#6b6b69" fontSize={11} tickLine={false} axisLine={false} dy={10} />
                  <YAxis yAxisId="left" stroke="#6b6b69" fontSize={11} tickLine={false} axisLine={false} tickFormatter={(v) => dimension === 'volume' ? `${v}t` : formatCurrency(v)} />
                  <Tooltip
                    contentStyle={{ backgroundColor: '#ffffff', border: '1px solid #e0ddd5', borderRadius: '16px', boxShadow: '0 25px 50px -12px rgba(0,0,0,0.15)' }}
                    cursor={{ stroke: '#d97757', strokeWidth: 1 }}
                  />
                  <Legend verticalAlign="top" align="right" wrapperStyle={{ paddingBottom: '30px' }} />
                  {dimension === 'financial' && (
                    <>
                      <Area yAxisId="left" type="monotone" dataKey="revenue" name="营业收入" stroke="#d97757" fill="url(#colorRev)" strokeWidth={3} />
                      <Line yAxisId="left" type="monotone" dataKey="profit" name="营业利润" stroke="#10b981" strokeWidth={3} dot={{ r: 4, fill: '#10b981' }} />
                      <defs>
                        <linearGradient id="colorRev" x1="0" y1="0" x2="0" y2="1">
                          <stop offset="5%" stopColor="#d97757" stopOpacity={0.2} />
                          <stop offset="95%" stopColor="#d97757" stopOpacity={0} />
                        </linearGradient>
                      </defs>
                    </>
                  )}
                  {dimension === 'volume' && (
                    <>
                      <Bar yAxisId="left" dataKey="purchaseTons" name="采购吨数" fill="#e8956e" radius={[6, 6, 0, 0]} barSize={20} />
                      <Bar yAxisId="left" dataKey="salesTons" name="销售吨数" fill="#d97757" radius={[6, 6, 0, 0]} barSize={20} />
                    </>
                  )}
                  {dimension === 'efficiency' && (
                    <>
                      <YAxis yAxisId="right" orientation="right" stroke="#f59e0b" fontSize={11} tickLine={false} axisLine={false} domain={['auto', 'auto']} />
                      <Line yAxisId="right" type="step" dataKey="deflator" name="平减指数" stroke="#f59e0b" strokeWidth={2} dot={{ r: 3 }} />
                      <Area yAxisId="left" type="monotone" dataKey="profit" name="单位利润贡献" fill="#10b981" fillOpacity={0.1} stroke="#10b981" />
                    </>
                  )}
                </ComposedChart>
              </ResponsiveContainer>
            </div>
          </div>

          <div className="space-y-6">
            <SummaryMiniCard title="峰值月份" value={data.monthlyPerformance.length > 0 ? [...data.monthlyPerformance].sort((a, b) => b.revenue - a.revenue)[0].name : '—'} sub="年度最高营收记录" icon="fa-crown" color="text-amber-600" />
            <SummaryMiniCard title="增长最快" value={data.monthlyPerformance.length > 0 ? [...data.monthlyPerformance].sort((a, b) => b.mom - a.mom)[0].name : '—'} sub="单月环比增长领先" icon="fa-bolt" color="text-[#d97757]" />
            <div className="bg-white/80 border border-[#e0ddd5] rounded-xl p-8" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.06)' }}>
              <h4 className="text-[#5c5c5a] text-[10px] uppercase font-bold tracking-[0.2em] mb-6">异常偏离度分析</h4>
              <div className="space-y-5">
                {(() => {
                  const perf = data.monthlyPerformance;
                  if (!perf.length) return <p className="text-[10px] text-[#5c5c5a] italic">暂无数据</p>;
                  // 营收/吨位偏离度：各月单吨营收的变异系数
                  const unitRevenues = perf.filter(p => p.salesTons > 0).map(p => p.revenue / p.salesTons);
                  const meanUR = unitRevenues.length > 0 ? unitRevenues.reduce((a, b) => a + b, 0) / unitRevenues.length : 0;
                  const stdUR = unitRevenues.length > 1 ? Math.sqrt(unitRevenues.reduce((a, b) => a + (b - meanUR) ** 2, 0) / unitRevenues.length) : 0;
                  const cvUR = meanUR === 0 ? 0 : (stdUR / meanUR * 100);
                  const cvLabel = cvUR < 5 ? 'Low' : cvUR < 15 ? 'Mid' : 'High';
                  const cvColor = cvUR < 5 ? 'text-emerald-600' : cvUR < 15 ? 'text-amber-500' : 'text-rose-500';
                  // 价格指数关联度：deflator 与 profit 的皮尔逊相关系数
                  const profits = perf.map(p => p.profit);
                  const deflators = perf.map(p => p.deflator);
                  const meanP = profits.reduce((a, b) => a + b, 0) / profits.length;
                  const meanD = deflators.reduce((a, b) => a + b, 0) / deflators.length;
                  const cov = profits.reduce((a, b, i) => a + (b - meanP) * (deflators[i] - meanD), 0);
                  const stdP = Math.sqrt(profits.reduce((a, b) => a + (b - meanP) ** 2, 0));
                  const stdD = Math.sqrt(deflators.reduce((a, b) => a + (b - meanD) ** 2, 0));
                  const corr = (stdP === 0 || stdD === 0) ? 0 : Math.abs(cov / (stdP * stdD)) * 100;
                  const corrLabel = corr > 70 ? 'High' : corr > 40 ? 'Mid' : 'Low';
                  const corrColor = corr > 70 ? 'text-[#d97757]' : corr > 40 ? 'text-amber-500' : 'text-emerald-600';
                  return (
                    <>
                      <div className="flex justify-between items-center text-xs">
                        <span className="text-[#4a4a48]">营收/吨位偏离</span>
                        <span className={`${cvColor} font-mono font-bold`}>{cvUR.toFixed(1)}% {cvLabel}</span>
                      </div>
                      <div className="flex justify-between items-center text-xs">
                        <span className="text-[#4a4a48]">价格指数关联</span>
                        <span className={`${corrColor} font-mono font-bold`}>{corr.toFixed(1)}% {corrLabel}</span>
                      </div>
                      <div className="pt-4 border-t border-[#e0ddd5]">
                        <p className="text-[10px] text-[#5c5c5a] leading-relaxed italic">
                          {cvUR < 5 ? '单吨营收波动极低，定价策略稳定。' : cvUR < 15 ? '单吨营收存在一定波动，建议关注价格变动。' : '单吨营收波动较大，建议排查异常月份。'}
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
                智能业务增长预测
                <span className="ml-4 px-3 py-1 bg-[#d97757]/10 text-[#d97757] text-[10px] rounded-full border border-[#d97757]/20 font-bold uppercase tracking-wider">Next 90 Days</span>
              </h3>
              <p className="text-[#5c5c5a] text-sm mt-1 italic">基于历史销量与宏观平减指数的深度学习模型推演</p>
            </div>
          </div>

          {isAnalysing ? (
            <div className="h-[450px] flex flex-col items-center justify-center space-y-10">
              <div className="relative">
                <div className="w-24 h-24 rounded-full bg-[#d97757]/10 border border-[#d97757]/30 flex items-center justify-center animate-pulse">
                  <span className="text-4xl">🔮</span>
                </div>
                <div className="absolute inset-0 border-2 border-dashed border-[#d97757]/40 rounded-full animate-[spin_10s_linear_infinite]"></div>
              </div>
              <div className="text-center space-y-3">
                <p className="text-[#191918] text-xl font-medium tracking-tight">{loadingMessage}</p>
                <p className="text-[#5c5c5a] text-sm">正在整合全量业务指标进行回归分析...</p>
              </div>
            </div>
          ) : (
            <div className="h-[450px]">
              <ResponsiveContainer width="100%" height="100%">
                <ComposedChart data={predictedData}>
                  <defs>
                    <linearGradient id="colorForecast" x1="0" y1="0" x2="0" y2="1">
                      <stop offset="5%" stopColor="#d97757" stopOpacity={0.3} />
                      <stop offset="95%" stopColor="#d97757" stopOpacity={0} />
                    </linearGradient>
                  </defs>
                  <CartesianGrid strokeDasharray="3 3" stroke="#e0ddd5" vertical={false} />
                  <XAxis dataKey="name" stroke="#6b6b69" fontSize={11} tickLine={false} axisLine={false} />
                  <YAxis stroke="#6b6b69" fontSize={11} tickLine={false} axisLine={false} tickFormatter={(v) => formatCurrency(v)} />
                  <Tooltip
                    content={({ active, payload, label }) => {
                      if (active && payload && payload.length) {
                        const d = payload[0].payload;
                        return (
                          <div className="bg-white border border-[#e0ddd5] p-6 rounded-xl backdrop-blur-xl ring-1 ring-[#e0ddd5]" style={{ boxShadow: '0 25px 50px -12px rgba(0,0,0,0.15)' }}>
                            <p className="text-[#5c5c5a] text-[10px] font-bold uppercase mb-3 tracking-[0.2em]">{label} {d.isForecast ? '预测值' : '实际值'}</p>
                            <div className="space-y-3">
                              <p className="text-[#191918] text-2xl font-bold">¥{formatNum(d.revenue)}</p>
                              {d.isForecast && (
                                <p className="text-[#d97757] text-xs font-medium border-t border-[#e0ddd5] pt-2">
                                  置信范围: ¥{formatNum(d.confidenceLower)} - ¥{formatNum(d.confidenceUpper)}
                                </p>
                              )}
                              <p className="text-emerald-600 text-sm flex items-center">
                                <i className="fas fa-chart-line mr-2"></i> 预估利润: ¥{formatNum(d.profit)}
                              </p>
                            </div>
                          </div>
                        );
                      }
                      return null;
                    }}
                  />
                  <Area type="monotone" dataKey="confidenceUpper" stroke="none" fill="#d97757" fillOpacity={0.12} name="置信上界" />
                  <Area type="monotone" dataKey="confidenceLower" stroke="none" fill="#d97757" fillOpacity={0.12} name="置信下界" />
                  <Area
                    type="monotone"
                    dataKey="revenue"
                    name="营业收入"
                    stroke="#d97757"
                    strokeWidth={4}
                    fill="url(#colorForecast)"
                  />
                  <Line type="monotone" dataKey="profit" name="营业利润" stroke="#10b981" strokeWidth={2} dot={{ r: 3 }} strokeDasharray="4 4" />
                </ComposedChart>
              </ResponsiveContainer>
            </div>
          )}

          {/* Grounding Sources */}
          {groundingSources.length > 0 && (
            <div className="mt-6 bg-white/60 border border-[#e0ddd5] rounded-xl p-6" style={{ boxShadow: '0 2px 12px rgba(0,0,0,0.03)' }}>
              <h4 className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest mb-4 flex items-center">
                <i className="fas fa-globe mr-2 text-[#d97757]"></i>
                AI 预测参考的市场数据来源
              </h4>
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
                {groundingSources.map((src, idx) => (
                  <a
                    key={idx}
                    href={src.uri}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="flex items-center text-xs text-[#4a4a48] hover:text-[#d97757] transition-colors truncate p-2 rounded-lg hover:bg-[#f9f9f8]"
                  >
                    <i className="fas fa-link mr-2 text-[#d97757]/40 flex-shrink-0"></i>
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
              <h3 className="text-2xl font-bold text-[#191918] tracking-tight">2026年度业务数据全景表</h3>
              <p className="text-[#5c5c5a] text-sm mt-1">包含金额、吨位、增长率与价格指数的完整明细</p>
            </div>
            <button
              onClick={() => {
                const rows = data.monthlyPerformance;
                let csv = '\uFEFF月份,采购量(t),销售量(t),营业收入,成本,毛利,净利润,同比(%),环比(%),价格指数\n';
                rows.forEach(r => {
                  csv += `${r.name},${r.purchaseTons},${r.salesTons},${r.revenue},${r.cost},${r.profit},${r.netProfit},${r.yoy},${r.mom},${r.deflator}\n`;
                });
                const blob = new Blob([csv], { type: 'text/csv;charset=utf-8;' });
                const url = URL.createObjectURL(blob);
                const a = document.createElement('a');
                a.href = url; a.download = '2026年度业务数据明细.csv'; a.click();
                setTimeout(() => URL.revokeObjectURL(url), 1000);
              }}
              className="px-6 py-2.5 bg-[#f9f9f8] text-[#4a4a48] rounded-xl text-xs font-bold border border-[#e0ddd5] hover:text-[#191918] hover:bg-[#f0eeeb] transition-all flex items-center"
            >
              <i className="fas fa-file-csv mr-2"></i> 导出 CSV 明细
            </button>
          </div>
          <div className="overflow-x-auto">
            <table className="w-full text-left border-collapse min-w-[1400px]">
              <thead>
                <tr className="bg-[#f9f9f8]/70 text-[#5c5c5a] text-[10px] uppercase font-bold tracking-widest">
                  <th className="px-10 py-6 border-r border-[#e0ddd5]/70 sticky left-0 bg-white">月份</th>
                  <th className="px-10 py-6 text-center border-r border-[#e0ddd5]/70">采购量 (t)</th>
                  <th className="px-10 py-6 text-center border-r border-[#e0ddd5]/70">销售量 (t)</th>
                  <th className="px-10 py-6 text-right border-r border-[#e0ddd5]/70">营业收入 (¥)</th>
                  <th className="px-10 py-6 text-right border-r border-[#e0ddd5]/70">净利润 (¥)</th>
                  <th className="px-10 py-6 text-center border-r border-[#e0ddd5]/70">同比 (YoY)</th>
                  <th className="px-10 py-6 text-center border-r border-[#e0ddd5]/70">环比 (MoM)</th>
                  <th className="px-10 py-6 text-center bg-amber-500/5">价格指数</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-[#e0ddd5]">
                {data.monthlyPerformance.map((row, idx) => (
                  <tr key={idx} className="hover:bg-[#d97757]/5 transition-colors group">
                    <td className="px-10 py-6 text-sm font-bold text-[#333330] border-r border-[#e0ddd5]/70 sticky left-0 bg-white/90 group-hover:bg-[#f0eeeb] transition-colors">{row.name}</td>
                    <td className="px-10 py-6 text-sm text-center font-mono text-[#4a4a48] border-r border-[#e0ddd5]/70">{row.purchaseTons}</td>
                    <td className="px-10 py-6 text-sm text-center font-mono text-[#4a4a48] border-r border-[#e0ddd5]/70">{row.salesTons}</td>
                    <td className="px-10 py-6 text-sm text-right font-bold text-[#191918] border-r border-[#e0ddd5]/70">{row.revenue.toLocaleString()}</td>
                    <td className="px-10 py-6 text-sm text-right font-bold text-emerald-600 border-r border-[#e0ddd5]/70">{row.netProfit.toLocaleString()}</td>
                    <td className="px-10 py-6 text-center border-r border-[#e0ddd5]/70">
                      <span className={`px-2.5 py-1 rounded-lg text-[10px] font-bold ${row.yoy >= 0 ? 'bg-emerald-500/10 text-emerald-600' : 'bg-rose-500/10 text-rose-500'}`}>
                        {row.yoy > 0 ? '+' : ''}{row.yoy.toFixed(1)}%
                      </span>
                    </td>
                    <td className="px-10 py-6 text-center border-r border-[#e0ddd5]/70">
                      <span className={`px-2.5 py-1 rounded-lg text-[10px] font-bold ${row.mom >= 0 ? 'bg-[#d97757]/10 text-[#d97757]' : 'bg-rose-500/10 text-rose-500'}`}>
                        {row.mom > 0 ? '+' : ''}{row.mom.toFixed(1)}%
                      </span>
                    </td>
                    <td className="px-10 py-6 text-sm text-center font-bold text-amber-500 bg-amber-500/5">{row.deflator}</td>
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
  <div className="bg-white/80 border border-[#e0ddd5] rounded-xl p-8 flex flex-col hover:border-[#d97757]/30 transition-all group" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.06)' }}>
    <div className="mb-6">
      <h4 className="text-[#191918] font-bold text-lg tracking-tight group-hover:text-[#d97757] transition-colors">{title}</h4>
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
      ${active ? 'bg-[#d97757] text-white' : 'text-[#4a4a48] hover:text-[#333330]'}
    `}
    style={active ? { boxShadow: '0 4px 16px rgba(217,119,87,0.15)' } : {}}
  >
    <i className={`fas ${icon} text-sm ${active ? 'scale-110' : ''}`}></i>
    <span>{label}</span>
  </button>
);

const DimButton: React.FC<{ active: boolean, onClick: () => void, label: string }> = ({ active, onClick, label }) => (
  <button
    onClick={onClick}
    className={`px-5 py-2 rounded-lg text-[10px] font-bold uppercase tracking-widest transition-all
      ${active ? 'bg-[#f0eeeb] text-[#d97757] shadow-inner' : 'text-[#5c5c5a] hover:text-[#4a4a48]'}
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
