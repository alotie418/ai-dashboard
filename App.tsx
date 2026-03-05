import React, { useState, useEffect, useCallback, useRef } from 'react';
import { MOCK_BUSINESS_DATA } from './constants';
import { fetchAIAnalysis } from './services/geminiService';
import { AIAnalysis, BusinessData } from './types';
import { fetchDashboardData } from './services/api';
import MetricCard from './components/MetricCard';
import AIInsights from './components/AIInsights';
import FinancialStatementTable from './components/FinancialStatementTable';
import ProfitMarginIndicators from './components/ProfitMarginIndicators';
import VATStatistics from './components/VATStatistics';
import TaxInclusiveSummary from './components/TaxInclusiveSummary';
import SalesAndOutputPage from './components/SalesAndOutputPage';
import PurchaseAndInputPage from './components/PurchaseAndInputPage';
import DataAnalysisPage from './components/DataAnalysisPage';
import InventoryPage from './components/InventoryPage';
import FinancePage from './components/FinancePage';
import SettingsPage from './components/SettingsPage';
import MarketSearchPage from './components/MarketSearchPage';
import AccountsPage from './components/AccountsPage';
import AlertCenter from './components/AlertCenter';
import { MarketDataProvider, useMarketData } from './contexts/MarketDataContext';
// SnowflakeEffect removed
import { GoogleGenAI, Modality, LiveServerMessage, Blob as GenAIBlob } from "@google/genai";
import { getApiKey } from './services/apiKey';
import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import { analyzeInvoice } from './services/ocrService';

type PageId = 'dashboard' | 'sales' | 'purchase' | 'analysis' | 'inventory' | 'finance' | 'market' | 'accounts' | 'settings';

interface ChatMessage {
  role: 'user' | 'model';
  text: string;
}

const VOICE_OPTIONS = [
  { id: 'Aoede', name: 'Aoede (温柔女声)' },
  { id: 'Puck', name: 'Puck (活泼男声)' },
  { id: 'Charon', name: 'Charon (深沉男声)' },
  { id: 'Kore', name: 'Kore (清新女声)' },
  { id: 'Fenrir', name: 'Fenrir (激情男声)' },
];

const QUICK_FUNCTIONS = [
  { label: '上传发票', icon: 'fa-camera', prompt: '我想上传一张发票进行记账' },
  { label: '财报查询', icon: 'fa-file-invoice-dollar', prompt: '帮我查询最新的财务报表摘要' },
  { label: '历史趋势', icon: 'fa-chart-area', prompt: '分析一下过去几个月的业务历史趋势' },
  { label: '市场分析', icon: 'fa-globe-asia', prompt: '搜索中国软水盐/工业盐最新市场价格和行情，简要分析：请回答：\n1. 当前市场价格区间\n2. 主要产区和供应商\n3. 近期价格趋势\n4. 对企业的建议（包括成本评估、库存管理、销售策略）' },
  { label: '库存查询', icon: 'fa-boxes', prompt: '查询当前库存余量和风险' },
];

const YEARS = ['2026', '2025', '2024'];
const QUARTERS = ['全年', 'Q1', 'Q2', 'Q3', 'Q4'];
const MONTHS = ['全部', '01月', '02月', '03月', '04月', '05月', '06月', '07月', '08月', '09月', '10月', '11月', '12月'];
const DATA_VERSION = 'cleared-2026-02-11';
const FILTER_SUPPORTED_PAGES: PageId[] = ['dashboard', 'sales', 'purchase', 'analysis', 'inventory', 'finance'];

// --- Custom Icons ---
const LiveIcon = () => (
  <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
    <path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3Z" />
    <path d="M19 10v2a7 7 0 0 1-14 0v-2" />
    <line x1="12" x2="12" y1="19" y2="22" />
  </svg>
);

const WaveformIcon = () => (
  <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
    <path d="M3 12h1M6 12h1M9 12h1M12 12h1M15 12h1M18 12h1M21 12h1M6 12v-4m0 4v4M12 12v-7m0 7v7M18 12v-3m0 3v3" />
  </svg>
);

const SendIcon = () => (
  <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
    <line x1="22" y1="2" x2="11" y2="13" />
    <polygon points="22 2 15 22 11 13 2 9 22 2" />
  </svg>
);

const CloseIcon = () => (
  <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
    <line x1="18" y1="6" x2="6" y2="18" />
    <line x1="6" y1="6" x2="18" y2="18" />
  </svg>
);

// --- Audio Helpers ---
function encode(bytes: Uint8Array) {
  let binary = '';
  const len = bytes.byteLength;
  for (let i = 0; i < len; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary);
}

function decode(base64: string) {
  const binaryString = atob(base64);
  const len = binaryString.length;
  const bytes = new Uint8Array(len);
  for (let i = 0; i < len; i++) {
    bytes[i] = binaryString.charCodeAt(i);
  }
  return bytes;
}

async function decodeAudioData(
  data: Uint8Array,
  ctx: AudioContext,
  sampleRate: number,
  numChannels: number,
): Promise<AudioBuffer> {
  const dataInt16 = new Int16Array(data.buffer, data.byteOffset, data.byteLength / 2);
  const frameCount = dataInt16.length / numChannels;
  const buffer = ctx.createBuffer(numChannels, frameCount, sampleRate);
  for (let channel = 0; channel < numChannels; channel++) {
    const channelData = buffer.getChannelData(channel);
    for (let i = 0; i < frameCount; i++) {
      channelData[i] = dataInt16[i * numChannels + channel] / 32768.0;
    }
  }
  return buffer;
}

function createBlob(data: Float32Array): GenAIBlob {
  const l = data.length;
  const int16 = new Int16Array(l);
  for (let i = 0; i < l; i++) {
    int16[i] = Math.max(-32768, Math.min(32767, Math.round(data[i] * 32768)));
  }
  return {
    data: encode(new Uint8Array(int16.buffer)),
    mimeType: 'audio/pcm;rate=16000',
  };
}

interface TavilyResult {
  title: string;
  url: string;
  content: string;
  score: number;
}

const searchTavily = async (query: string): Promise<string> => {
  const apiKey = import.meta.env.VITE_TAVILY_API_KEY;
  if (!apiKey) return '';
  try {
    const response = await fetch('https://api.tavily.com/search', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        api_key: apiKey,
        query: query,
        search_depth: 'basic',
        max_results: 5,
        include_answer: false,
      }),
    });
    if (!response.ok) return '';
    const data = await response.json();
    if (!data.results) return '';
    return (data.results as TavilyResult[]).map((r, i) =>
      `[Tavily Source ${i + 1}] ${r.title}\nURL: ${r.url}\nSummary: ${r.content}`
    ).join('\n\n');
  } catch (e) { console.error(e); return ''; }
};

const AppContent: React.FC = () => {
  const [data, setData] = useState<BusinessData>(MOCK_BUSINESS_DATA);
  const [analysis, setAnalysis] = useState<AIAnalysis | null>(null);
  const [loadingAI, setLoadingAI] = useState(false);
  const [aiError, setAiError] = useState<string | null>(null);
  const [sidebarOpen, setSidebarOpen] = useState(true);
  const [currentPage, setCurrentPage] = useState<PageId>('dashboard');
  const [showChat, setShowChat] = useState(false);
  const { latestQuery: marketQuery, latestResults: marketResults, searchTimestamp: marketTimestamp } = useMarketData();

  const [selectedYear, setSelectedYear] = useState('2026');
  const [selectedQuarter, setSelectedQuarter] = useState('全年');
  const [selectedMonth, setSelectedMonth] = useState('全部');

  // Ref to always hold latest data for AI analysis (avoids stale closure / infinite loop)
  const dataRef = useRef<BusinessData>(MOCK_BUSINESS_DATA);

  // Load real dashboard data from API (returns data directly to avoid ref race condition)
  const loadDashboardData = useCallback(async (): Promise<BusinessData | null> => {
    try {
      const dashboard = await fetchDashboardData(selectedYear);
      const m = dashboard.metrics;
      const next: BusinessData = {
        ...dataRef.current,
        metrics: [
          {
            label: '库存余量 (实时)',
            value: m.inventoryTons > 0 ? `${m.inventoryTons}吨` : '—',
            subValue: m.inventoryTons > 0 ? `采购${m.purchaseTotalTons}吨 - 销售${m.salesTotalTons}吨` : '—',
            icon: 'fa-boxes',
            color: 'bg-blue-500',
          },
          {
            label: `${selectedYear}年度 采购`,
            value: m.purchaseTotalAmount > 0 ? `¥${m.purchaseTotalAmount.toLocaleString()}` : '—',
            subValue: m.purchaseTotalTons > 0 ? `${m.purchaseTotalTons}吨` : '—',
            icon: 'fa-truck-loading',
            color: 'bg-purple-500',
          },
          {
            label: `${selectedYear}年度 销售`,
            value: m.salesTotalAmount > 0 ? `¥${m.salesTotalAmount.toLocaleString()}` : '—',
            subValue: m.salesTotalTons > 0 ? `${m.salesTotalTons}吨` : '—',
            icon: 'fa-chart-line',
            color: 'bg-green-500',
          },
          {
            label: '平均成本',
            value: m.avgCostPerTon > 0 ? `¥${m.avgCostPerTon.toLocaleString()}/吨` : '—',
            subValue: m.purchaseTotalTons > 0 ? `基于${m.purchaseTotalTons}吨采购` : '—',
            icon: 'fa-tags',
            color: 'bg-orange-500',
          },
        ],
        rawMetrics: {
          inventoryTons: m.inventoryTons,
          purchaseTotalTons: m.purchaseTotalTons,
          salesTotalTons: m.salesTotalTons,
        },
        monthlyPerformance: dashboard.monthlyPerformance,
        financialStatement: dashboard.financialStatement,
        vatStatistics: dashboard.vatStatistics,
        taxInclusiveSummary: dashboard.taxInclusiveSummary,
      };
      dataRef.current = next;  // Sync update ref BEFORE setData
      setData(next);
      return next;
    } catch (err) {
      console.error('Failed to load dashboard data:', err);
      return null;
    }
  }, [selectedYear]);

  useEffect(() => {
    loadDashboardData();
  }, [loadDashboardData]);

  const [chatInput, setChatInput] = useState('');
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [isTyping, setIsTyping] = useState(false);
  const [selectedVoice, setSelectedVoice] = useState(VOICE_OPTIONS[0].id);
  const [playingIndex, setPlayingIndex] = useState<number | null>(null);

  const [isLiveMode, setIsLiveMode] = useState(false);
  const [liveStatus, setLiveStatus] = useState<'idle' | 'connecting' | 'listening' | 'speaking'>('idle');
  const liveSessionRef = useRef<any>(null);
  const liveStreamRef = useRef<MediaStream | null>(null);
  const nextStartTimeRef = useRef(0);
  const liveAudioSourcesRef = useRef<Set<AudioBufferSourceNode>>(new Set());
  const inputAudioCtxRef = useRef<AudioContext | null>(null);
  const outputAudioCtxRef = useRef<AudioContext | null>(null);

  const chatEndRef = useRef<HTMLDivElement>(null);
  const ttsAudioCtxRef = useRef<AudioContext | null>(null);
  const chatFileInputRef = useRef<HTMLInputElement>(null);
  const chatBoxRef = useRef<HTMLDivElement>(null);

  const DEFAULT_CHAT_SIZE = { width: 620, height: 680 };
  const [chatSize, setChatSize] = useState(DEFAULT_CHAT_SIZE);
  const isResizing = useRef(false);
  const startResizeData = useRef({ mouseX: 0, mouseY: 0, startW: 0, startH: 0 });

  const resetChatSize = () => setChatSize(DEFAULT_CHAT_SIZE);

  const performAnalysis = useCallback(async () => {
    setLoadingAI(true);
    setAiError(null);
    try {
      // Refresh dashboard data first; use returned value to avoid stale ref
      const freshData = await loadDashboardData();
      // Build market summary if available
      let marketSummary: string | undefined;
      if (marketResults && marketQuery) {
        const summaryRows = marketResults.summaryTable?.map(r => `${r.label}: ${r.value}`).join('\n') || '';
        const priceRange = marketResults.prices.length > 0
          ? `价格范围: ¥${Math.min(...marketResults.prices.map(p => p.price)).toLocaleString()} - ¥${Math.max(...marketResults.prices.map(p => p.price)).toLocaleString()}，共${marketResults.prices.length}条报价`
          : '';
        marketSummary = `搜索词: "${marketQuery}"\n${summaryRows}\n${priceRange}`;
      }
      const result = await fetchAIAnalysis(freshData || dataRef.current, marketSummary);
      setAnalysis(result);
    } catch (err) {
      console.error("AI Analysis Failed", err);
      setAiError("AI 分析失败，请检查网络连接或 API 配置后重试。");
    } finally {
      setLoadingAI(false);
    }
  }, [loadDashboardData, marketResults, marketQuery]);

  useEffect(() => {
    performAnalysis();
  }, [performAnalysis]);

  useEffect(() => {
    if (chatEndRef.current) {
      chatEndRef.current.scrollIntoView({ behavior: 'smooth' });
    }
  }, [messages, liveStatus]);

  const stopLiveSession = useCallback(() => {
    if (liveSessionRef.current) {
      liveSessionRef.current.close();
      liveSessionRef.current = null;
    }
    if (liveStreamRef.current) {
      liveStreamRef.current.getTracks().forEach(t => t.stop());
      liveStreamRef.current = null;
    }
    for (const source of liveAudioSourcesRef.current.values()) {
      source.stop();
    }
    liveAudioSourcesRef.current.clear();
    setIsLiveMode(false);
    setLiveStatus('idle');
  }, []);

  // Cleanup live session on unmount
  useEffect(() => {
    return () => { stopLiveSession(); };
  }, [stopLiveSession]);

  const startLiveSession = useCallback(async () => {
    setIsLiveMode(true);
    setLiveStatus('connecting');
    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: {
          sampleRate: 16000,
          echoCancellation: true,
          noiseSuppression: true,
          autoGainControl: true,
          channelCount: 1,
          googEchoCancellation: true,
          googAutoGainControl: true,
          googNoiseSuppression: true,
          googHighpassFilter: true,
          latency: 0,
        } as any
      });
      liveStreamRef.current = stream;
      const ai = new GoogleGenAI({ apiKey: getApiKey() });
      if (!inputAudioCtxRef.current) inputAudioCtxRef.current = new AudioContext({ sampleRate: 16000 });
      if (!outputAudioCtxRef.current) outputAudioCtxRef.current = new AudioContext({ sampleRate: 24000 });

      let resolvedSession: any = null;
      const sessionPromise = ai.live.connect({
        model: 'gemini-2.5-flash-native-audio-preview-12-2025',
        callbacks: {
          onopen: () => {
            setLiveStatus('listening');
            const source = inputAudioCtxRef.current!.createMediaStreamSource(stream);
            const scriptProcessor = inputAudioCtxRef.current!.createScriptProcessor(4096, 1, 1);
            scriptProcessor.onaudioprocess = (e) => {
              if (!resolvedSession) return;
              const inputData = e.inputBuffer.getChannelData(0);
              try {
                resolvedSession.sendRealtimeInput({ media: createBlob(inputData) });
              } catch (_) { /* session closed */ }
            };
            source.connect(scriptProcessor);
            scriptProcessor.connect(inputAudioCtxRef.current!.destination);
          },
          onmessage: async (message: LiveServerMessage) => {
            const parts = message.serverContent?.modelTurn?.parts;
            if (parts) {
              for (const part of parts) {
                if (part.inlineData?.data) {
                  const base64Audio = part.inlineData.data;
                  if (base64Audio) {
                    setLiveStatus('speaking');
                    const ctx = outputAudioCtxRef.current!;
                    nextStartTimeRef.current = Math.max(nextStartTimeRef.current, ctx.currentTime);
                    const audioBuffer = await decodeAudioData(decode(base64Audio), ctx, 24000, 1);
                    const source = ctx.createBufferSource();
                    source.buffer = audioBuffer;
                    source.connect(ctx.destination);
                    source.onended = () => {
                      liveAudioSourcesRef.current.delete(source);
                      if (liveAudioSourcesRef.current.size === 0) setLiveStatus('listening');
                    };
                    source.start(nextStartTimeRef.current);
                    nextStartTimeRef.current += audioBuffer.duration;
                    liveAudioSourcesRef.current.add(source);
                  }
                }

              }
            }
            if (message.serverContent?.interrupted) {
              for (const s of liveAudioSourcesRef.current.values()) { s.stop(); }
              liveAudioSourcesRef.current.clear();
              nextStartTimeRef.current = 0;
              setLiveStatus('listening');
            }
            if (message.serverContent?.turnComplete) setLiveStatus('listening');
          },
          onerror: (e) => { console.error(e); stopLiveSession(); },
          onclose: () => setLiveStatus('idle'),
        },
        config: {
          tools: [{ googleSearch: {} }],
          responseModalities: [Modality.AUDIO],
          speechConfig: { voiceConfig: { prebuiltVoiceConfig: { voiceName: selectedVoice } } },
          systemInstruction: '你是一位精通业务看板数据的 AI 助手。对于语音交互，请保持回答**简练直接**。当用户询问商品价格或行情时：1. 优先使用 Google Search 查询最新价格。2. **直接报出价格数字**和关键趋势，不要通过长篇大论的铺垫。3. 如果有多个来源，简要概括范围（例如“目前市场价在 50 到 60 元之间”）。请像一位专业的交易员一样高效沟通。',
        },
      });
      resolvedSession = await sessionPromise;
      liveSessionRef.current = resolvedSession;
    } catch (e) { console.error(e); setIsLiveMode(false); setLiveStatus('idle'); }
  }, [selectedVoice, stopLiveSession]);

  const handlePlayVoice = async (text: string, index: number) => {
    if (playingIndex !== null) return;
    setPlayingIndex(index);
    try {
      const ai = new GoogleGenAI({ apiKey: getApiKey() });
      const response = await ai.models.generateContent({
        model: "gemini-2.5-flash-preview-tts",
        contents: [{ parts: [{ text }] }],
        config: {
          responseModalities: [Modality.AUDIO],
          speechConfig: { voiceConfig: { prebuiltVoiceConfig: { voiceName: selectedVoice } } },
        },
      });
      const data = response.candidates?.[0]?.content?.parts?.[0]?.inlineData?.data;
      if (data) {
        if (!ttsAudioCtxRef.current) ttsAudioCtxRef.current = new AudioContext({ sampleRate: 24000 });
        const ctx = ttsAudioCtxRef.current;
        const buf = await decodeAudioData(decode(data), ctx, 24000, 1);
        const source = ctx.createBufferSource();
        source.buffer = buf;
        source.connect(ctx.destination);
        source.onended = () => setPlayingIndex(null);
        source.start();
      } else setPlayingIndex(null);
    } catch (e) { setPlayingIndex(null); }
  };

  const handleSendMessage = async (predefinedMsg?: string) => {
    const text = predefinedMsg || chatInput;
    if (!text.trim() || isTyping || isLiveMode) return;
    const newMsgs: ChatMessage[] = [...messages, { role: 'user', text }];
    setMessages(newMsgs);
    setChatInput('');
    setIsTyping(true);
    try {
      const ai = new GoogleGenAI({ apiKey: getApiKey() });

      // Trigger Tavily for market/news/price related queries
      let tavilyContext = '';
      if (/价格|行情|新闻|搜索|多少钱|趋势|分析|找|查/.test(text)) {
        tavilyContext = await searchTavily(text);
      }

      // Build conversation history for multi-turn context
      const chatHistory = newMsgs.map(m => ({
        role: m.role,
        parts: [{ text: m.text }]
      }));

      // Inject Tavily context into the last user message for the model configuration
      if (tavilyContext) {
        const lastMsg = chatHistory[chatHistory.length - 1];
        lastMsg.parts[0].text += `\n\n[System Note: Additional External Search Context from Tavily]\n${tavilyContext}\n\nPlease use this context combined with Google Search to answer.`;
      }

      // Compact context summary instead of full JSON dump
      const perf = data.monthlyPerformance;
      const fs = data.financialStatement;
      const contextSummary = `企业概况：年营收¥${fs.salesRevenue.toLocaleString()}，毛利率${fs.grossMargin}%，净利率${fs.netMargin}%。` +
        `近3月营收：${perf.slice(-3).map(p => `${p.name}:¥${p.revenue.toLocaleString()}`).join('，')}。` +
        `近3月销量：${perf.slice(-3).map(p => `${p.name}:${p.salesTons}t`).join('，')}。` +
        `增值税统计：进项${data.vatStatistics.cumulativeInput.toLocaleString()}，销项${data.vatStatistics.cumulativeOutput.toLocaleString()}。`;

      // Inject market search context if available
      let marketChatContext = '';
      if (marketResults && marketQuery) {
        const prices = marketResults.prices;
        const minPrice = prices.length > 0 ? Math.min(...prices.map(p => p.price)) : 0;
        const maxPrice = prices.length > 0 ? Math.max(...prices.map(p => p.price)) : 0;
        const avgPrice = prices.length > 0 ? Math.round(prices.reduce((s, p) => s + p.price, 0) / prices.length) : 0;
        const summaryLines = marketResults.summaryTable?.slice(0, 6).map(r => `${r.label}: ${r.value}`).join('；') || '';
        marketChatContext = `\n\n【最新市场搜索结果】搜索词："${marketQuery}"，共${prices.length}条报价。` +
          `最低价¥${minPrice.toLocaleString()}，最高价¥${maxPrice.toLocaleString()}，均价¥${avgPrice.toLocaleString()}。` +
          (summaryLines ? `\n关键指标：${summaryLines}` : '') +
          `\n请在回答中自然引用上述市场数据。`;
      }

      const response = await ai.models.generateContent({
        model: "gemini-3.1-flash-lite-preview",
        contents: chatHistory,
        config: {
          tools: [{ googleSearch: {} }],
          systemInstruction: `你是一位专业的业务数据助手。以下是企业实时经营数据摘要：\n${contextSummary}${marketChatContext}\n你的职责：\n1. 基于上述数据简明扼要地回答用户关于企业内部经营的问题。\n2. 对于外部市场、竞品分析或一般性知识问题，你拥有 **Google Search Grounding** (原生联网) 和 **Tavily Context** (已注入的外部搜索结果) 双重信息源。\n3. 如果有市场搜索数据，请在回答中自然引用市场价格和趋势信息。\n4. 请综合利用这些信息，给出最准确、实时的回答。\n\n【排版要求】\n- 禁止使用三个星号 (***) 进行加粗斜体，这会导致显示异常。\n- 仅使用两个星号 (**) 进行加粗。\n- 使用清晰的列表和段落。`
        }
      });

      // Extract text from response (handle grounding metadata if needed, but for chat simple text is fine)
      const content = response.candidates?.[0]?.content?.parts?.[0]?.text || response.text || "未能获取有效回复。";
      setMessages([...newMsgs, { role: 'model', text: content }]);
    } catch (e) {
      setMessages([...newMsgs, { role: 'model', text: "请求发生错误，请稍后重试。" }]);
    } finally {
      setIsTyping(false);
    }
  };

  const handleChatFileUpload = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;
    const newMsgs: ChatMessage[] = [...messages, { role: 'user', text: `📎 上传发票: ${file.name}` }];
    setMessages(newMsgs);
    setIsTyping(true);
    try {
      const reader = new FileReader();
      const base64Promise = new Promise<string>((resolve, reject) => {
        const timeout = setTimeout(() => reject(new Error('文件读取超时')), 30000);
        reader.onload = () => {
          clearTimeout(timeout);
          const result = reader.result as string;
          const parts = result.split(',');
          if (parts.length < 2) { reject(new Error('文件格式不支持')); return; }
          resolve(parts[1]);
        };
        reader.onerror = () => { clearTimeout(timeout); reject(new Error('文件读取失败')); };
      });
      reader.readAsDataURL(file);
      const base64 = await base64Promise;
      const extracted = await analyzeInvoice(base64, file.type);
      const resultText = `✅ 发票识别成功！\n\n📅 日期: ${extracted.date}\n👤 客户/供应商: ${extracted.customer}\n📦 数量: ${extracted.quantity}\n💰 金额: ¥${extracted.price.toLocaleString()}\n🚚 运费: ¥${extracted.shipping.toLocaleString()}\n🔢 发票号: ${extracted.invoiceNo}\n\n以上信息已从发票中提取。如需记账，请手动前往「采购与进项」或「销售与销项」页面录入。`;
      setMessages([...newMsgs, { role: 'model', text: resultText }]);
    } catch (err) {
      setMessages([...newMsgs, { role: 'model', text: '❌ 发票识别失败，请确保上传清晰的发票图片后重试。' }]);
    } finally {
      setIsTyping(false);
      if (chatFileInputRef.current) chatFileInputRef.current.value = '';
    }
  };

  const handleMouseDown = (e: React.MouseEvent) => {
    e.preventDefault();
    isResizing.current = true;
    const box = chatBoxRef.current;
    startResizeData.current = { mouseX: e.clientX, mouseY: e.clientY, startW: chatSize.width, startH: chatSize.height };
    const onMove = (me: MouseEvent) => {
      if (!isResizing.current || !box) return;
      const dx = startResizeData.current.mouseX - me.clientX;
      const dy = startResizeData.current.mouseY - me.clientY;
      const newW = Math.max(340, startResizeData.current.startW + dx);
      const newH = Math.max(450, startResizeData.current.startH + dy);
      // Direct DOM update — no React re-render, instant feedback
      box.style.width = `${newW}px`;
      box.style.height = `${newH}px`;
    };
    const onUp = (me: MouseEvent) => {
      isResizing.current = false;
      document.removeEventListener('mousemove', onMove);
      document.removeEventListener('mouseup', onUp);
      // Sync final size to React state once
      if (box) {
        setChatSize({ width: box.offsetWidth, height: box.offsetHeight });
      }
    };
    document.addEventListener('mousemove', onMove);
    document.addEventListener('mouseup', onUp);
  };

  const renderPage = () => {
    switch (currentPage) {
      case 'dashboard': return (
        <div className="grid grid-cols-1 xl:grid-cols-4 gap-8">
          <div className="xl:col-span-3 space-y-8">
            <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-6">
              {data.metrics.map((m, i) => <MetricCard key={i} metric={m} />)}
            </div>
            <div className="grid grid-cols-1 lg:grid-cols-2 gap-8 items-stretch [grid-auto-rows:1fr]">
              <FinancialStatementTable data={data.financialStatement} />
              <ProfitMarginIndicators data={data.financialStatement} />
              <VATStatistics data={data.vatStatistics} />
              <TaxInclusiveSummary data={data.taxInclusiveSummary} />
            </div>
          </div>
          <div className="xl:col-span-1 h-full min-h-[600px] xl:sticky xl:top-0 xl:h-[calc(100vh-120px)]">
            <AIInsights analysis={analysis} loading={loadingAI} error={aiError} onRefresh={performAnalysis} />
          </div>
        </div>
      );
      case 'sales': return <SalesAndOutputPage data={data} selectedYear={selectedYear} selectedQuarter={selectedQuarter} selectedMonth={selectedMonth} />;
      case 'purchase': return <PurchaseAndInputPage data={data} selectedYear={selectedYear} selectedQuarter={selectedQuarter} selectedMonth={selectedMonth} />;
      case 'analysis': return <DataAnalysisPage data={data} selectedYear={selectedYear} selectedQuarter={selectedQuarter} selectedMonth={selectedMonth} />;
      case 'inventory': return <InventoryPage data={data} selectedYear={selectedYear} selectedQuarter={selectedQuarter} selectedMonth={selectedMonth} />;
      case 'finance': return <FinancePage data={data} selectedYear={selectedYear} selectedQuarter={selectedQuarter} selectedMonth={selectedMonth} />;
      case 'market': return <MarketSearchPage />;
      case 'accounts': return <AccountsPage />;
      case 'settings': return <SettingsPage />;
      default: return null;
    }
  };

  return (
    <div className="flex h-screen overflow-hidden bg-white text-[#191918] font-sans relative">
      {/* SnowflakeEffect removed */}

      {/* Sidebar */}
      <aside className={`${sidebarOpen ? 'w-64' : 'w-20'} bg-[#f9f9f8] border-r border-[#e0ddd5] transition-all duration-300 flex flex-col hidden md:flex z-20`}>
        <div className="p-6 flex items-center mb-8 shrink-0">
          <div className="w-8 h-8 bg-[#d97757] rounded-lg flex items-center justify-center mr-3 flex-shrink-0 shadow-lg" style={{ boxShadow: '0 4px 24px rgba(217,119,87,0.2)' }}>
            <i className="fas fa-layer-group text-white text-sm"></i>
          </div>
          {sidebarOpen && <span className="font-bold text-xl tracking-tight text-[#191918]">AI看板</span>}
        </div>
        <nav className="flex-1 px-4 space-y-1 overflow-y-auto custom-scrollbar">
          <NavItem icon="fa-th-large" label="经营看板" active={currentPage === 'dashboard'} expanded={sidebarOpen} onClick={() => setCurrentPage('dashboard')} />
          <NavItem icon="fa-file-import" label="采购与进项" active={currentPage === 'purchase'} expanded={sidebarOpen} onClick={() => setCurrentPage('purchase')} />
          <NavItem icon="fa-file-export" label="销售与销项" active={currentPage === 'sales'} expanded={sidebarOpen} onClick={() => setCurrentPage('sales')} />
          <NavItem icon="fa-search-dollar" label="发票查询" active={currentPage === 'inventory'} expanded={sidebarOpen} onClick={() => setCurrentPage('inventory')} />
          <NavItem icon="fa-chart-pie" label="数据分析" active={currentPage === 'analysis'} expanded={sidebarOpen} onClick={() => setCurrentPage('analysis')} />
          <NavItem icon="fa-shopping-cart" label="市场聚合搜索" active={currentPage === 'market'} expanded={sidebarOpen} onClick={() => setCurrentPage('market')} />
          <NavItem icon="fa-handshake" label="应收应付" active={currentPage === 'accounts'} expanded={sidebarOpen} onClick={() => setCurrentPage('accounts')} />
          <NavItem icon="fa-wallet" label="财务报表" active={currentPage === 'finance'} expanded={sidebarOpen} onClick={() => setCurrentPage('finance')} />
          <NavItem icon="fa-cog" label="系统设置" active={currentPage === 'settings'} expanded={sidebarOpen} onClick={() => setCurrentPage('settings')} />
        </nav>
        <div className="p-4 mt-auto border-t border-[#e0ddd5]">
          <button onClick={() => setSidebarOpen(!sidebarOpen)} className="w-full flex items-center justify-center p-2 rounded-lg bg-[#f0eeeb] hover:bg-[#e0ddd5] transition-colors text-[#6b6b69]">
            <i className={`fas ${sidebarOpen ? 'fa-angle-double-left' : 'fa-angle-double-right'}`}></i>
          </button>
        </div>
      </aside>

      {/* Main */}
      <main className="flex-1 flex flex-col overflow-hidden relative z-10">
        {currentPage !== 'market' && (
          <header className="h-16 bg-[#f9f9f8] border-b border-[#e0ddd5] flex items-center justify-between px-8 z-10 shrink-0">
            <div className="flex items-center space-x-6">
              <h2 className="text-xl font-semibold text-[#191918]">
                {{ dashboard: '经营数据概览', sales: '销售与销项', purchase: '采购与进项', analysis: '数据分析中心', inventory: '发票查询', finance: '财务报表', market: '市场聚合搜索', accounts: '应收应付', settings: '系统设置' }[currentPage]}
              </h2>
              <div className="hidden lg:flex items-center space-x-4 pl-4 border-l border-[#e0ddd5]">
                <div className="flex items-center space-x-2 bg-white rounded-lg p-1 border border-[#e0ddd5]">
                  <select value={selectedYear} onChange={(e) => setSelectedYear(e.target.value)} className="bg-transparent text-xs font-medium text-[#6b6b69] outline-none px-2 py-1.5 cursor-pointer hover:text-[#d97757]">
                    {YEARS.map(y => <option key={y} value={y} className="bg-white">{y} 年度</option>)}
                  </select>
                  {FILTER_SUPPORTED_PAGES.includes(currentPage) && (
                    <>
                      <div className="w-px h-3 bg-[#e0ddd5]"></div>
                      <select value={selectedQuarter} onChange={(e) => { setSelectedQuarter(e.target.value); if (e.target.value !== '全年') setSelectedMonth('全部'); }} className="bg-transparent text-xs font-medium text-[#6b6b69] outline-none px-2 py-1.5 cursor-pointer hover:text-[#d97757]">
                        {QUARTERS.map(q => <option key={q} value={q} className="bg-white">{q === '全年' ? '全年' : `第${q.replace('Q', '')}季度`}</option>)}
                      </select>
                    </>
                  )}
                  <div className="w-px h-3 bg-[#e0ddd5]"></div>
                  <select value={selectedMonth} onChange={(e) => { setSelectedMonth(e.target.value); if (e.target.value !== '全部') setSelectedQuarter('全年'); }} className="bg-transparent text-xs font-medium text-[#6b6b69] outline-none px-2 py-1.5 cursor-pointer hover:text-[#d97757]">
                    {MONTHS.map(m => <option key={m} value={m} className="bg-white">{m}</option>)}
                  </select>
                </div>
                <button onClick={performAnalysis} className="p-2 text-[#d97757] hover:text-[#c4694d] transition-colors" title="立即刷新数据">
                  <i className={`fas fa-sync-alt ${loadingAI ? 'animate-spin' : ''}`}></i>
                </button>
              </div>
            </div>
            <div className="flex items-center space-x-4">
              <AlertCenter />
            </div>
          </header>
        )}
        <div className="flex-1 overflow-y-auto p-8 custom-scrollbar">
          {renderPage()}
        </div>
      </main>

      {/* AI Assistant */}
      <div className="fixed bottom-8 right-8 z-[10000] flex flex-row-reverse items-end space-x-4 space-x-reverse">
        <button
          onClick={() => setShowChat(!showChat)}
          className={`w-14 h-14 rounded-full flex items-center justify-center transition-all duration-300 ${showChat ? 'bg-[#f0eeeb] border border-[#d1cdc4] text-[#d97757] rotate-90 scale-110' : 'bg-[#d97757] text-white hover:scale-110'}`}
          style={{ boxShadow: showChat ? 'none' : '0 4px 24px rgba(217,119,87,0.3)' }}
        >
          {showChat ? <CloseIcon /> : <div className="text-2xl">🤖</div>}
        </button>

        {showChat && (
          <div
            ref={chatBoxRef}
            style={{ width: `${chatSize.width}px`, height: `${chatSize.height}px`, boxShadow: '0 8px 32px rgba(0,0,0,0.12)' }}
            className="bg-white border border-[#e0ddd5] rounded-2xl overflow-hidden flex flex-col animate-in slide-in-from-right-8 duration-500 relative"
          >
            <div onMouseDown={handleMouseDown} className="absolute top-0 left-0 w-8 h-8 cursor-nw-resize z-50 flex items-end justify-end pr-1 pb-1 group" title="拖拽调整大小">
              <svg width="10" height="10" viewBox="0 0 10 10" className="text-[#d1cdc4] group-hover:text-[#d97757] transition-colors"><path d="M0 10L10 0M0 6L6 0M0 2L2 0" stroke="currentColor" strokeWidth="1.5" /></svg>
            </div>

            {/* AI Assistant Header */}
            <div onDoubleClick={resetChatSize} className="p-5 bg-[#d97757] flex justify-between items-center shrink-0 cursor-pointer select-none">
              <div className="flex items-center space-x-3">
                <div className="w-8 h-8 bg-white/20 rounded-lg flex items-center justify-center text-white"><i className="fas fa-robot text-sm"></i></div>
                <div>
                  <h3 className="text-sm font-semibold text-white tracking-tight">AI 助手</h3>
                  <p className="text-[10px] text-white/60">数据实时同步中</p>
                </div>
              </div>
              <div className="flex items-center space-x-3">
                <button
                  onClick={() => isLiveMode ? stopLiveSession() : startLiveSession()}
                  className={`flex items-center space-x-2 px-4 py-1.5 rounded-full text-[10px] font-bold uppercase transition-all duration-300 border ${isLiveMode ? 'bg-red-600 border-red-400 text-white' : 'bg-white/10 border-white/20 text-white hover:bg-white/20'}`}
                >
                  {isLiveMode ? <WaveformIcon /> : <LiveIcon />}
                  <span>{isLiveMode ? '退出语音' : '实时通话'}</span>
                </button>
                <select
                  value={selectedVoice}
                  onChange={(e) => setSelectedVoice(e.target.value)}
                  className="text-[10px] text-white/80 bg-white/10 px-3 py-1.5 rounded-full border border-white/10 outline-none cursor-pointer appearance-none"
                >
                  {VOICE_OPTIONS.map(v => (
                    <option key={v.id} value={v.id} className="bg-[#333] text-white">{v.name}</option>
                  ))}
                </select>
              </div>
            </div>

            <div className="flex-1 p-6 space-y-6 overflow-y-auto custom-scrollbar bg-[#fafaf9]">
              {isLiveMode ? (
                <div className="flex flex-col items-center justify-center h-full space-y-10 text-center animate-in fade-in duration-500">
                  <div className="relative">
                    <div className={`w-36 h-36 rounded-full border-4 flex items-center justify-center transition-all duration-700 ${liveStatus === 'speaking' ? 'border-emerald-500 scale-110 shadow-[0_0_40px_rgba(16,185,129,0.3)]' : liveStatus === 'listening' ? 'border-[#d97757] scale-105 shadow-[0_0_40px_rgba(217,119,87,0.3)]' : 'border-[#e0ddd5] scale-95 opacity-50'}`}>
                      <div className="text-6xl animate-bounce">🤖</div>
                    </div>
                  </div>
                  <div className="space-y-3">
                    <h4 className="text-[#191918] font-semibold text-xl tracking-tight">{liveStatus === 'connecting' ? '正在连接...' : liveStatus === 'listening' ? '请讲，我在听' : 'AI 正在响应'}</h4>
                    <p className="text-[#6b6b69] text-sm leading-relaxed px-12">您可以询问任何有关经营、财务或市场的数据问题。</p>
                  </div>
                </div>
              ) : (
                <>
                  {messages.length === 0 && (
                    <div className="bg-white p-6 rounded-xl text-[#4a4a48] text-sm leading-relaxed border border-[#e0ddd5]">
                      <p className="font-semibold text-[#d97757] mb-2 flex items-center"><i className="fas fa-hand-sparkles mr-2"></i> 您好，我是 AI 助手</p>
                      <p className="text-[#6b6b69]">我可以为您提供实时的经营分析和建议。您可以直接提问，或点击下方的功能快捷键。</p>
                    </div>
                  )}
                  {messages.map((m, i) => (
                    <div key={i} className={`flex ${m.role === 'user' ? 'justify-end' : 'justify-start'}`}>
                      <div className={`relative group max-w-[88%] p-4 rounded-xl text-sm leading-relaxed ${m.role === 'user' ? 'bg-[#d97757] text-white rounded-tr-sm' : 'bg-white text-[#4a4a48] border border-[#e0ddd5] rounded-tl-sm'}`}>
                        {m.role === 'user' ? m.text : (
                          <div className="markdown-body">
                            <ReactMarkdown remarkPlugins={[remarkGfm]}>{m.text}</ReactMarkdown>
                          </div>
                        )}
                        <button onClick={() => handlePlayVoice(m.text, i)} className={`absolute ${m.role === 'user' ? '-left-10' : '-right-10'} top-1/2 -translate-y-1/2 p-2 rounded-full transition-all ${playingIndex === i ? 'text-[#d97757] scale-125' : 'text-[#7a7a78] hover:text-[#d97757] opacity-0 group-hover:opacity-100'}`} title="播放语音"><i className={`fas ${playingIndex === i ? 'fa-spinner fa-spin' : 'fa-volume-up'}`}></i></button>
                      </div>
                    </div>
                  ))}
                  {isTyping && <div className="text-[#7a7a78] text-[10px] font-bold uppercase tracking-widest animate-pulse flex items-center space-x-2"><div className="w-1 h-1 bg-[#a0a09c] rounded-full"></div><span>AI 正在分析中...</span></div>}
                  <div ref={chatEndRef} />
                </>
              )}
            </div>

            {!isLiveMode && (
              <div className="px-5 py-3 bg-[#f9f9f8] border-t border-[#e0ddd5] flex space-x-2 overflow-x-auto shrink-0 no-scrollbar items-center">
                <input type="file" ref={chatFileInputRef} onChange={handleChatFileUpload} className="hidden" accept="image/*,application/pdf" />
                {QUICK_FUNCTIONS.map((fn) => (
                  <button key={fn.label} onClick={() => fn.label === '上传发票' ? chatFileInputRef.current?.click() : handleSendMessage(fn.prompt)} className="whitespace-nowrap flex items-center space-x-2 px-4 py-2 bg-white border border-[#e0ddd5] rounded-full text-[10px] font-bold text-[#4a4a48] hover:text-[#d97757] hover:border-[#d97757]/40 transition-all active:scale-95">
                    <i className={`fas ${fn.icon} text-[10px]`}></i><span>{fn.label}</span>
                  </button>
                ))}
              </div>
            )}

            <div className="p-5 bg-[#f9f9f8] border-t border-[#e0ddd5] shrink-0">
              <form onSubmit={(e) => { e.preventDefault(); handleSendMessage(); }} className="flex items-center space-x-3">
                <input
                  type="text"
                  value={chatInput}
                  onChange={(e) => setChatInput(e.target.value)}
                  placeholder={isLiveMode ? "实时语音模式..." : "请输入您的问题..."}
                  disabled={isLiveMode}
                  className="flex-1 bg-white border border-[#e0ddd5] rounded-xl px-5 py-3.5 text-xs outline-none focus:border-[#d97757] text-[#191918] disabled:opacity-30 placeholder:text-[#7a7a78] transition-all"
                />
                <button type="submit" disabled={!chatInput.trim() || isTyping || isLiveMode} className="w-12 h-12 bg-[#d97757] rounded-xl text-white hover:bg-[#c4694d] disabled:opacity-30 transition-all flex items-center justify-center shrink-0 active:scale-90" style={{ boxShadow: '0 4px 24px rgba(217,119,87,0.2)' }}>
                  <SendIcon />
                </button>
              </form>
            </div>
          </div>
        )}
      </div>

      <style>{`
        .no-scrollbar::-webkit-scrollbar { display: none; }
        .no-scrollbar { -ms-overflow-style: none; scrollbar-width: none; }
      `}</style>
    </div>
  );
};

const App: React.FC = () => (
  <MarketDataProvider>
    <AppContent />
  </MarketDataProvider>
);

const NavItem: React.FC<{ icon: string; label: string; active?: boolean; expanded?: boolean; onClick?: () => void; }> = ({ icon, label, active = false, expanded = true, onClick }) => (
  <div onClick={onClick} className={`flex items-center p-3 rounded-lg transition-all duration-200 cursor-pointer group ${active ? 'bg-[#d97757] text-white' : 'text-[#4a4a48] hover:bg-[#f0eeeb] hover:text-[#191918]'}`} style={active ? { boxShadow: '0 4px 24px rgba(217,119,87,0.15)' } : {}}>
    <i className={`fas ${icon} text-base ${expanded ? 'mr-4' : 'mx-auto'} w-5 text-center group-hover:scale-110 transition-transform`}></i>
    {expanded && <span className="text-sm font-medium">{label}</span>}
  </div>
);

export default App;
