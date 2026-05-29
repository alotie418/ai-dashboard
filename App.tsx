import React, { useState, useEffect, useCallback, useRef } from 'react';
import { useTranslation } from 'react-i18next';
import { MOCK_BUSINESS_DATA } from './constants';
import { fetchAIAnalysis } from './services/geminiService';
import { AIAnalysis, BusinessData } from './types';
import { fetchDashboardData, fetchSales, fetchPurchases, fetchSettings } from './services/api';
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
import AccountsPage from './components/AccountsPage';
import TransactionsPage from './components/TransactionsPage';
import USTaxToolsPage from './components/USTaxToolsPage';
import USDashboardCards from './components/USDashboardCards';
import { formatMoney, getTaxLabel, getDashboardSections, getCurrencySymbol, buildAIFinanceContext } from './components/accountingHelpers';
import AlertCenter from './components/AlertCenter';
import LoginPage from './components/LoginPage';
import OnboardingWizard from './components/OnboardingWizard';
import { GoogleGenAI, Modality, LiveServerMessage, Blob as GenAIBlob } from "@google/genai";
import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import { analyzeInvoice } from './services/ocrService';

type PageId = 'dashboard' | 'sales' | 'purchase' | 'analysis' | 'inventory' | 'finance' | 'accounts' | 'transactions' | 'ustax' | 'settings';

interface ChatMessage {
  role: 'user' | 'model';
  text: string;
}

const VOICE_OPTIONS = [
  { id: 'Aoede', nameKey: 'voice.aoede' },
  { id: 'Puck', nameKey: 'voice.puck' },
  { id: 'Charon', nameKey: 'voice.charon' },
  { id: 'Kore', nameKey: 'voice.kore' },
  { id: 'Fenrir', nameKey: 'voice.fenrir' },
];

// Recommended default voice per UI language (only used when user has not set one)
const DEFAULT_VOICE_BY_LANG: Record<string, string> = {
  'zh-CN': 'Aoede',
  'zh-TW': 'Aoede',
  en: 'Aoede',
  ja: 'Kore',
  ko: 'Kore',
  fr: 'Aoede',
};

const QUICK_FUNCTIONS = [
  { labelKey: 'chat.uploadInvoice', icon: 'fa-camera', promptKey: 'chat.quickPromptUploadInvoice' },
  { labelKey: 'chat.financeQuery', icon: 'fa-file-invoice-dollar', promptKey: 'chat.quickPromptFinanceQuery' },
  { labelKey: 'chat.trendAnalysis', icon: 'fa-chart-area', promptKey: 'chat.quickPromptTrend' },
  { labelKey: 'chat.marketAnalysis', icon: 'fa-globe-asia', promptKey: 'chat.quickPromptMarket' },
  { labelKey: 'chat.inventoryQuery', icon: 'fa-boxes', promptKey: 'chat.quickPromptInventory' },
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

const AppContent: React.FC = () => {
  const { t, i18n } = useTranslation();
  const [data, setData] = useState<BusinessData>(MOCK_BUSINESS_DATA);
  const [analysis, setAnalysis] = useState<AIAnalysis | null>(null);
  const [loadingAI, setLoadingAI] = useState(false);
  const [aiError, setAiError] = useState<string | null>(null);
  const [sidebarOpen, setSidebarOpen] = useState(true);
  const [currentPage, setCurrentPage] = useState<PageId>('dashboard');
  const [showChat, setShowChat] = useState(false);

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

      // Enrich financialStatement with computed expense fields
      const fs = dashboard.financialStatement;
      let shippingFee = fs.shippingFee;
      let taxSurcharge = fs.taxSurcharge;

      // If Worker didn't compute shippingFee, derive from sales records
      if (shippingFee === 0) {
        try {
          const salesRecords = await fetchSales();
          shippingFee = Math.round(salesRecords.reduce((sum, s) => sum + (s.shipping || 0), 0) * 100) / 100;
        } catch { /* fallback to 0 */ }
      }

      // 税金及附加 = 应纳增值税 × 12%
      if (taxSurcharge === 0 && dashboard.vatStatistics) {
        const vatPayable = Math.max(0, dashboard.vatStatistics.cumulativeOutput - dashboard.vatStatistics.cumulativeInput);
        taxSurcharge = Math.round(vatPayable * 0.12 * 100) / 100;
      }

      // 管理费用：从设置中读取
      let adminExpense = fs.adminExpense;
      if (adminExpense === 0) {
        try {
          const settings = await fetchSettings();
          adminExpense = parseFloat(String((settings as any).admin_expense_annual)) || 0;
        } catch { /* fallback to 0 */ }
      }

      const revenue = fs.salesRevenue;
      const cost = fs.costOfSales;
      const grossProfit = Math.round((revenue - cost) * 100) / 100;

      // 所得税 = max(0, 利润总额) × 25%
      const profitBeforeTax = grossProfit - taxSurcharge - shippingFee - adminExpense;
      const incomeTax = Math.round(Math.max(0, profitBeforeTax) * 0.25 * 100) / 100;

      const netProfit = Math.round((profitBeforeTax - incomeTax) * 100) / 100;
      const grossMargin = revenue === 0 ? 0 : +(grossProfit / revenue * 100).toFixed(2);
      const netMargin = revenue === 0 ? 0 : +(netProfit / revenue * 100).toFixed(2);

      const enrichedFS = {
        ...fs,
        shippingFee,
        taxSurcharge,
        adminExpense,
        incomeTax,
        grossProfit,
        netProfit,
        grossMargin,
        netMargin,
      };

      // accountingLocale from dashboard response (or fallback to CN)
      const accLocale = dashboard.locale || 'CN';
      const sym = getCurrencySymbol(accLocale);

      const next: BusinessData = {
        ...dataRef.current,
        locale: accLocale, // pass through for dashboard rendering
        metrics: [
          {
            label: t('dashboard.inventory'),
            value: m.inventoryTons > 0 ? `${m.inventoryTons}${t('units.tonSuffix')}` : '—',
            subValue: m.inventoryTons > 0 ? `${t('dashboard.purchasesLabel')}${m.purchaseTotalTons}${t('units.tonSuffix')} - ${t('dashboard.salesLabel')}${m.salesTotalTons}${t('units.tonSuffix')}` : '—',
            icon: 'fa-boxes',
            color: 'bg-blue-500',
          },
          {
            label: `${t('header.yearLabel', { year: selectedYear })} ${t('dashboard.purchasesLabel')}`,
            value: m.purchaseTotalAmount > 0 ? formatMoney(m.purchaseTotalAmount, accLocale) : '—',
            subValue: m.purchaseTotalTons > 0 ? `${m.purchaseTotalTons}${t('units.tonSuffix')}` : '—',
            icon: 'fa-truck-loading',
            color: 'bg-purple-500',
          },
          {
            label: `${t('header.yearLabel', { year: selectedYear })} ${t('dashboard.salesLabel')}`,
            value: m.salesTotalAmount > 0 ? formatMoney(m.salesTotalAmount, accLocale) : '—',
            subValue: m.salesTotalTons > 0 ? `${m.salesTotalTons}${t('units.tonSuffix')}` : '—',
            icon: 'fa-chart-line',
            color: 'bg-green-500',
          },
          {
            label: t('dashboard.avgCost'),
            value: m.avgCostPerTon > 0 ? `${sym}${m.avgCostPerTon.toLocaleString()}${t('units.perTon')}` : '—',
            subValue: m.purchaseTotalTons > 0 ? `${m.purchaseTotalTons}${t('units.tonSuffix')} ${t('dashboard.purchasesLabel')}` : '—',
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
        financialStatement: enrichedFS,
        vatStatistics: dashboard.vatStatistics,
        taxInclusiveSummary: dashboard.taxInclusiveSummary,
      };
      dataRef.current = next;
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
  const [selectedVoice, setSelectedVoice] = useState<string>(() => {
    const stored = typeof window !== 'undefined' ? localStorage.getItem('selectedVoice') : null;
    return stored || DEFAULT_VOICE_BY_LANG[i18n.language] || 'Aoede';
  });
  const [playingIndex, setPlayingIndex] = useState<number | null>(null);
  // Stable accounting locale for the AI assistant — sourced from settings,
  // independent from dashboard data.locale
  const [assistantAccLocale, setAssistantAccLocale] = useState<string>('CN');
  useEffect(() => {
    fetchSettings().then((s: any) => {
      if (s?.accounting_locale) setAssistantAccLocale(s.accounting_locale);
    }).catch(() => {});
  }, []);
  // Persist voice when user picks one
  const handleVoiceChange = (v: string) => {
    setSelectedVoice(v);
    try { localStorage.setItem('selectedVoice', v); } catch {}
  };

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
  const contextCacheRef = useRef<{ text: string; ts: number } | null>(null);

  const resetChatSize = () => setChatSize(DEFAULT_CHAT_SIZE);

  const performAnalysis = useCallback(async () => {
    setLoadingAI(true);
    setAiError(null);
    try {
      const freshData = await loadDashboardData();
      // Inject both accountingLocale (tax/currency/regime context) and
      // uiLanguage (response language) into the system prompt, so the AI
      // briefing follows the same separation rules as the chat assistant.
      const localeForAI = (freshData as any)?.locale || assistantAccLocale || 'CN';
      const systemPrompt = `${t('ai.analyzeSystemPrompt')}\n\n${buildAIFinanceContext(localeForAI, i18n.language)}`;
      const result = await fetchAIAnalysis(freshData || dataRef.current, undefined, t('ai.languageHint'), systemPrompt);
      setAnalysis(result);
    } catch (err) {
      console.error("AI Analysis Failed", err);
      setAiError(t('aiInsights.error'));
    } finally {
      setLoadingAI(false);
    }
  }, [loadDashboardData, assistantAccLocale, i18n.language]);

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

  useEffect(() => {
    return () => { stopLiveSession(); };
  }, [stopLiveSession]);

  // Live voice session — still uses frontend SDK (WebSocket, plan for server token in v2)
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
      // Live audio still needs direct SDK (WebSocket). API key fetched from server for this use case.
      let key: string;
      if (isElectronEnv) {
        const r = await (window as any).electronAPI.invoke('api:request', { method: 'GET', path: '/api/ai/live-key' });
        key = r.key;
      } else {
        const keyRes = await fetch('/api/ai/live-key', { credentials: 'same-origin' });
        const keyData = await keyRes.json();
        key = keyData.key;
      }
      const ai = new GoogleGenAI({ apiKey: key });
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
          systemInstruction: `${t('ai.liveSystemPrompt')}\n\n${buildAIFinanceContext(assistantAccLocale, i18n.language)}`,
        },
      });
      resolvedSession = await sessionPromise;
      liveSessionRef.current = resolvedSession;
    } catch (e) { console.error(e); setIsLiveMode(false); setLiveStatus('idle'); }
  }, [selectedVoice, stopLiveSession]);

  // TTS via server proxy
  const handlePlayVoice = async (text: string, index: number) => {
    if (playingIndex !== null) return;
    setPlayingIndex(index);
    try {
      let audioData: string | null;
      if (isElectronEnv) {
        const r = await (window as any).electronAPI.invoke('api:request', {
          method: 'POST', path: '/api/ai/tts', body: { text, voiceName: selectedVoice },
        });
        audioData = r.data;
      } else {
        const res = await fetch('/api/ai/tts', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          credentials: 'same-origin',
          body: JSON.stringify({ text, voiceName: selectedVoice }),
        });
        const ttsResult = await res.json();
        audioData = ttsResult.data;
      }
      if (audioData) {
        if (!ttsAudioCtxRef.current) ttsAudioCtxRef.current = new AudioContext({ sampleRate: 24000 });
        const ctx = ttsAudioCtxRef.current;
        const buf = await decodeAudioData(decode(audioData), ctx, 24000, 1);
        const source = ctx.createBufferSource();
        source.buffer = buf;
        source.connect(ctx.destination);
        source.onended = () => setPlayingIndex(null);
        source.start();
      } else setPlayingIndex(null);
    } catch (e) { setPlayingIndex(null); }
  };

  // Chat via server proxy
  const handleSendMessage = async (predefinedMsg?: string) => {
    const text = predefinedMsg || chatInput;
    if (!text.trim() || isTyping || isLiveMode) return;
    const newMsgs: ChatMessage[] = [...messages, { role: 'user', text }];
    setMessages(newMsgs);
    setChatInput('');
    setIsTyping(true);
    try {
      // Build conversation history for multi-turn context
      const chatHistory = newMsgs.map(m => ({
        role: m.role,
        parts: [{ text: m.text }]
      }));

      // Fetch full business context from server (cached 60s)
      let contextText = '';
      try {
        const now = Date.now();
        if (contextCacheRef.current && now - contextCacheRef.current.ts < 60000) {
          contextText = contextCacheRef.current.text;
        } else {
          let ctxData: any;
          if (isElectronEnv) {
            ctxData = await (window as any).electronAPI.invoke('api:request', {
              method: 'POST', path: '/api/ai/context', body: { year: selectedYear },
            });
          } else {
            const ctxRes = await fetch('/api/ai/context', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              credentials: 'same-origin',
              body: JSON.stringify({ year: selectedYear }),
            });
            ctxData = await ctxRes.json();
          }
          contextText = ctxData.context || '';
          contextCacheRef.current = { text: contextText, ts: now };
        }
      } catch {
        // Fallback to basic summary if context endpoint fails
        const fs = data.financialStatement;
        contextText = t('ai.contextFallback', {
          revenue: formatMoney(fs.salesRevenue, assistantAccLocale),
          grossMargin: fs.grossMargin,
          netMargin: fs.netMargin,
        });
      }

      const systemInstruction = `${t('ai.chatSystemPrompt')}

${buildAIFinanceContext(assistantAccLocale, i18n.language)}

${contextText}`;

      let result: any;
      if (isElectronEnv) {
        result = await (window as any).electronAPI.invoke('api:request', {
          method: 'POST', path: '/api/ai/chat', body: { messages: chatHistory, systemInstruction },
        });
      } else {
        const res = await fetch('/api/ai/chat', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          credentials: 'same-origin',
          body: JSON.stringify({ messages: chatHistory, systemInstruction }),
        });
        result = await res.json();
      }
      const content = result.text || t('chat.emptyReply');
      setMessages([...newMsgs, { role: 'model', text: content }]);
    } catch (e) {
      setMessages([...newMsgs, { role: 'model', text: t('chat.requestError') }]);
    } finally {
      setIsTyping(false);
    }
  };

  const handleChatFileUpload = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;
    const newMsgs: ChatMessage[] = [...messages, { role: 'user', text: t('chat.uploadInvoiceMsg', { name: file.name }) }];
    setMessages(newMsgs);
    setIsTyping(true);
    try {
      const reader = new FileReader();
      const base64Promise = new Promise<string>((resolve, reject) => {
        const timeout = setTimeout(() => reject(new Error(t('chat.fileReadTimeout'))), 30000);
        reader.onload = () => {
          clearTimeout(timeout);
          const result = reader.result as string;
          const parts = result.split(',');
          if (parts.length < 2) { reject(new Error(t('chat.fileFormatUnsupported'))); return; }
          resolve(parts[1]);
        };
        reader.onerror = () => { clearTimeout(timeout); reject(new Error(t('chat.fileReadFailed'))); };
      });
      reader.readAsDataURL(file);
      const base64 = await base64Promise;
      const extracted = await analyzeInvoice(base64, file.type, assistantAccLocale, i18n.language);
      if (!extracted.isInvoiceLike) {
        setMessages([...newMsgs, { role: 'model', text: t('chat.notInvoice', { type: extracted.documentType || 'unknown' }) }]);
        return;
      }
      const resultText = t('chat.invoiceExtractResult', {
        date: extracted.date,
        partner: extracted.customer,
        quantity: extracted.quantity || '-',
        amount: formatMoney(extracted.price || 0, assistantAccLocale),
        shipping: formatMoney(extracted.shipping || 0, assistantAccLocale),
        invoiceNo: extracted.invoiceNo || '-',
      });
      setMessages([...newMsgs, { role: 'model', text: resultText }]);
    } catch (err) {
      setMessages([...newMsgs, { role: 'model', text: t('chat.invoiceRecognizeFailed') }]);
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
      box.style.width = `${newW}px`;
      box.style.height = `${newH}px`;
    };
    const onUp = (me: MouseEvent) => {
      isResizing.current = false;
      document.removeEventListener('mousemove', onMove);
      document.removeEventListener('mouseup', onUp);
      if (box) {
        setChatSize({ width: box.offsetWidth, height: box.offsetHeight });
      }
    };
    document.addEventListener('mousemove', onMove);
    document.addEventListener('mouseup', onUp);
  };

  const renderPage = () => {
    switch (currentPage) {
      case 'dashboard': {
        const accLocale = (data as any).locale || 'CN';
        const uiLang = i18n.language;
        const sections = getDashboardSections(accLocale);
        // sections determine which cards to show — driven by accountingLocale
        // labels on those cards are in uiLanguage via getTaxLabel()
        return (
          <div className="grid grid-cols-1 xl:grid-cols-4 gap-8">
            <div className="xl:col-span-3 space-y-8">
              <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-6">
                {data.metrics.map((m, i) => <MetricCard key={i} metric={m} />)}
              </div>
              <div className="grid grid-cols-1 lg:grid-cols-2 gap-8 items-stretch [grid-auto-rows:1fr]">
                {/* US: Schedule C + Deductions + SE Tax + Margins */}
                {sections.includes('schedule_c_summary') ? (
                  <USDashboardCards
                    report={(data as any).report}
                    mileageSummary={(data as any).mileageSummary}
                    homeOffice={(data as any).homeOffice}
                    accountingLocale={accLocale}
                    uiLanguage={uiLang}
                  />
                ) : (
                  <>
                    {/* P&L + Profit Margins — all non-US locales, locale-aware */}
                    {sections.includes('profit_loss') && <FinancialStatementTable data={data.financialStatement} accountingLocale={accLocale} />}
                    {sections.includes('profit_margins') && <ProfitMarginIndicators data={data.financialStatement} accountingLocale={accLocale} />}
                    {/* Tax summary — locale-aware labels + currency */}
                    {(sections.includes('vat_summary') || sections.includes('consumption_tax_summary') || sections.includes('business_tax_summary')) && (
                      <VATStatistics data={data.vatStatistics} accountingLocale={accLocale} />
                    )}
                    {sections.includes('tax_inclusive_summary') && <TaxInclusiveSummary data={data.taxInclusiveSummary} accountingLocale={accLocale} />}
                  </>
                )}
              </div>
            </div>
            <div className="xl:col-span-1 h-full min-h-[600px] xl:sticky xl:top-0 xl:h-[calc(100vh-120px)]">
              <AIInsights analysis={analysis} loading={loadingAI} error={aiError} onRefresh={performAnalysis} />
            </div>
          </div>
        );
      }
      case 'sales': return <SalesAndOutputPage data={data} selectedYear={selectedYear} selectedQuarter={selectedQuarter} selectedMonth={selectedMonth} />;
      case 'purchase': return <PurchaseAndInputPage data={data} selectedYear={selectedYear} selectedQuarter={selectedQuarter} selectedMonth={selectedMonth} />;
      case 'analysis': return <DataAnalysisPage data={data} selectedYear={selectedYear} selectedQuarter={selectedQuarter} selectedMonth={selectedMonth} />;
      case 'inventory': return <InventoryPage data={data} selectedYear={selectedYear} selectedQuarter={selectedQuarter} selectedMonth={selectedMonth} />;
      case 'finance': return <FinancePage data={data} selectedYear={selectedYear} selectedQuarter={selectedQuarter} selectedMonth={selectedMonth} />;
      case 'accounts': return <AccountsPage />;
      case 'transactions': return <TransactionsPage />;
      case 'ustax': return <USTaxToolsPage />;
      case 'settings': return <SettingsPage />;
      default: return null;
    }
  };

  return (
    <div className="flex h-screen overflow-hidden bg-white text-[#191918] font-sans relative">
      {/* Sidebar */}
      <aside className={`${sidebarOpen ? 'w-64' : 'w-20'} bg-[#f9f9f8] border-r border-[#e0ddd5] transition-all duration-300 flex flex-col hidden md:flex z-20`}>
        {/* macOS 红绿灯避让区 + 可拖动 + 可双击最大化（仅 Electron 桌面版生效）*/}
        {isElectronEnv && (
          <div
            className="h-7 shrink-0"
            style={{ WebkitAppRegion: 'drag' } as React.CSSProperties}
          />
        )}
        <div
          className={`p-6 flex items-center mb-8 shrink-0 ${isElectronEnv ? 'pt-2' : ''}`}
          style={isElectronEnv ? ({ WebkitAppRegion: 'drag' } as React.CSSProperties) : undefined}
        >
          <div className="w-8 h-8 bg-[#d97757] rounded-lg flex items-center justify-center mr-3 flex-shrink-0 shadow-lg" style={{ boxShadow: '0 4px 24px rgba(217,119,87,0.2)' }}>
            <i className="fas fa-layer-group text-white text-sm"></i>
          </div>
          {sidebarOpen && <span className="font-bold text-xl tracking-tight text-[#191918]">SoloLedger<span className="text-[#6b6b69] text-sm font-normal ml-1.5">{t('app.subtitle').split('·')[0]?.trim()}</span></span>}
        </div>
        <nav className="flex-1 px-4 space-y-1 overflow-y-auto custom-scrollbar">
          <NavItem icon="fa-th-large" label={t('nav.dashboard')} active={currentPage === 'dashboard'} expanded={sidebarOpen} onClick={() => setCurrentPage('dashboard')} />
          <NavItem icon="fa-file-import" label={assistantAccLocale === 'US' ? getTaxLabel(assistantAccLocale, i18n.language, 'navPurchase') : t('nav.purchase')} active={currentPage === 'purchase'} expanded={sidebarOpen} onClick={() => setCurrentPage('purchase')} />
          <NavItem icon="fa-file-export" label={assistantAccLocale === 'US' ? getTaxLabel(assistantAccLocale, i18n.language, 'navSales') : t('nav.sales')} active={currentPage === 'sales'} expanded={sidebarOpen} onClick={() => setCurrentPage('sales')} />
          <NavItem icon="fa-search-dollar" label={t('nav.inventory')} active={currentPage === 'inventory'} expanded={sidebarOpen} onClick={() => setCurrentPage('inventory')} />
          <NavItem icon="fa-chart-pie" label={t('nav.analysis')} active={currentPage === 'analysis'} expanded={sidebarOpen} onClick={() => setCurrentPage('analysis')} />
          <NavItem icon="fa-handshake" label={t('nav.accounts')} active={currentPage === 'accounts'} expanded={sidebarOpen} onClick={() => setCurrentPage('accounts')} />
          <NavItem icon="fa-wallet" label={t('nav.finance')} active={currentPage === 'finance'} expanded={sidebarOpen} onClick={() => setCurrentPage('finance')} />
          <NavItem icon="fa-exchange-alt" label={t('nav.transactions')} active={currentPage === 'transactions'} expanded={sidebarOpen} onClick={() => setCurrentPage('transactions')} />
          {assistantAccLocale === 'US' && (
            <NavItem icon="fa-flag-usa" label={t('nav.usTax')} active={currentPage === 'ustax'} expanded={sidebarOpen} onClick={() => setCurrentPage('ustax')} />
          )}
          <NavItem icon="fa-cog" label={t('nav.settings')} active={currentPage === 'settings'} expanded={sidebarOpen} onClick={() => setCurrentPage('settings')} />
        </nav>
        <div className="p-4 mt-auto border-t border-[#e0ddd5] space-y-2">
          <button onClick={() => setSidebarOpen(!sidebarOpen)} className="w-full flex items-center justify-center p-2 rounded-lg bg-[#f0eeeb] hover:bg-[#e0ddd5] transition-colors text-[#6b6b69]">
            <i className={`fas ${sidebarOpen ? 'fa-angle-double-left' : 'fa-angle-double-right'}`}></i>
          </button>
          {!isElectronEnv && (
            <button
              onClick={async () => {
                await fetch('/auth/logout', { method: 'POST', credentials: 'same-origin' });
                window.location.reload();
              }}
              className="w-full flex items-center justify-center p-2 rounded-lg hover:bg-red-50 transition-colors text-[#6b6b69] hover:text-red-600"
              title="退出登录"
            >
              <i className="fas fa-sign-out-alt"></i>
              {sidebarOpen && <span className="ml-2 text-sm">退出登录</span>}
            </button>
          )}
        </div>
      </aside>

      {/* Main */}
      <main className="flex-1 flex flex-col overflow-hidden relative z-10">
        {(
          <header
            className="h-16 bg-[#f9f9f8] border-b border-[#e0ddd5] flex items-center justify-between px-8 z-10 shrink-0"
            style={isElectronEnv ? ({ WebkitAppRegion: 'drag' } as React.CSSProperties) : undefined}
          >
            <div
              className="flex items-center space-x-6"
              style={isElectronEnv ? ({ WebkitAppRegion: 'no-drag' } as React.CSSProperties) : undefined}
            >
              <h2 className="text-xl font-semibold text-[#191918]">
                {t(`headerTitle.${currentPage}`)}
              </h2>
              <div className="hidden lg:flex items-center space-x-4 pl-4 border-l border-[#e0ddd5]">
                <div className="flex items-center space-x-2 bg-white rounded-lg p-1 border border-[#e0ddd5]">
                  <select value={selectedYear} onChange={(e) => setSelectedYear(e.target.value)} className="bg-transparent text-xs font-medium text-[#6b6b69] outline-none px-2 py-1.5 cursor-pointer hover:text-[#d97757]">
                    {YEARS.map(y => <option key={y} value={y} className="bg-white">{t('header.yearLabel', { year: y })}</option>)}
                  </select>
                  {FILTER_SUPPORTED_PAGES.includes(currentPage) && (
                    <>
                      <div className="w-px h-3 bg-[#e0ddd5]"></div>
                      <select value={selectedQuarter} onChange={(e) => { setSelectedQuarter(e.target.value); if (e.target.value !== '全年') setSelectedMonth('全部'); }} className="bg-transparent text-xs font-medium text-[#6b6b69] outline-none px-2 py-1.5 cursor-pointer hover:text-[#d97757]">
                        {QUARTERS.map(q => <option key={q} value={q} className="bg-white">{q === '全年' ? t('header.allYear') : t('header.quarterLabel', { n: q.replace('Q', '') })}</option>)}
                      </select>
                    </>
                  )}
                  <div className="w-px h-3 bg-[#e0ddd5]"></div>
                  <select value={selectedMonth} onChange={(e) => { setSelectedMonth(e.target.value); if (e.target.value !== '全部') setSelectedQuarter('全年'); }} className="bg-transparent text-xs font-medium text-[#6b6b69] outline-none px-2 py-1.5 cursor-pointer hover:text-[#d97757]">
                    {MONTHS.map((m, i) => <option key={m} value={m} className="bg-white">{i === 0 ? t('header.monthAll') : t(`header.month${m.replace('月', '').padStart(2, '0')}`)}</option>)}
                  </select>
                </div>
                <button onClick={performAnalysis} className="p-2 text-[#d97757] hover:text-[#c4694d] transition-colors" title="立即刷新数据">
                  <i className={`fas fa-sync-alt ${loadingAI ? 'animate-spin' : ''}`}></i>
                </button>
              </div>
            </div>
            <div
              className="flex items-center space-x-4"
              style={isElectronEnv ? ({ WebkitAppRegion: 'no-drag' } as React.CSSProperties) : undefined}
            >
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
          {showChat ? <CloseIcon /> : <div className="text-2xl">AI</div>}
        </button>

        {showChat && (
          <div
            ref={chatBoxRef}
            style={{ width: `${chatSize.width}px`, height: `${chatSize.height}px`, boxShadow: '0 8px 32px rgba(0,0,0,0.12)' }}
            className="bg-white border border-[#e0ddd5] rounded-2xl overflow-hidden flex flex-col animate-in slide-in-from-right-8 duration-500 relative"
          >
            <div onMouseDown={handleMouseDown} className="absolute top-0 left-0 w-8 h-8 cursor-nw-resize z-50 flex items-end justify-end pr-1 pb-1 group" title={t('chat.resize')}>
              <svg width="10" height="10" viewBox="0 0 10 10" className="text-[#d1cdc4] group-hover:text-[#d97757] transition-colors"><path d="M0 10L10 0M0 6L6 0M0 2L2 0" stroke="currentColor" strokeWidth="1.5" /></svg>
            </div>

            {/* AI Assistant Header */}
            <div onDoubleClick={resetChatSize} className="p-5 bg-[#d97757] flex justify-between items-center shrink-0 cursor-pointer select-none">
              <div className="flex items-center space-x-3">
                <div className="w-8 h-8 bg-white/20 rounded-lg flex items-center justify-center text-white"><i className="fas fa-robot text-sm"></i></div>
                <div>
                  <h3 className="text-sm font-semibold text-white tracking-tight">{t('chat.title')}</h3>
                  <p className="text-[10px] text-white/60">{t('chat.status')}</p>
                </div>
              </div>
              <div className="flex items-center space-x-3">
                <button
                  onClick={() => isLiveMode ? stopLiveSession() : startLiveSession()}
                  className={`flex items-center space-x-2 px-4 py-1.5 rounded-full text-[10px] font-bold uppercase transition-all duration-300 border ${isLiveMode ? 'bg-red-600 border-red-400 text-white' : 'bg-white/10 border-white/20 text-white hover:bg-white/20'}`}
                >
                  {isLiveMode ? <WaveformIcon /> : <LiveIcon />}
                  <span>{isLiveMode ? t('chat.liveStop') : t('chat.liveStart')}</span>
                </button>
                <select
                  value={selectedVoice}
                  onChange={(e) => handleVoiceChange(e.target.value)}
                  className="text-[10px] text-white/80 bg-white/10 px-3 py-1.5 rounded-full border border-white/10 outline-none cursor-pointer appearance-none"
                >
                  {VOICE_OPTIONS.map(v => (
                    <option key={v.id} value={v.id} className="bg-[#333] text-white">{t((v as any).nameKey || 'voice.aoede')}</option>
                  ))}
                </select>
              </div>
            </div>

            <div className="flex-1 p-6 space-y-6 overflow-y-auto custom-scrollbar bg-[#fafaf9]">
              {isLiveMode ? (
                <div className="flex flex-col items-center justify-center h-full space-y-10 text-center animate-in fade-in duration-500">
                  <div className="relative">
                    <div className={`w-36 h-36 rounded-full border-4 flex items-center justify-center transition-all duration-700 ${liveStatus === 'speaking' ? 'border-emerald-500 scale-110 shadow-[0_0_40px_rgba(16,185,129,0.3)]' : liveStatus === 'listening' ? 'border-[#d97757] scale-105 shadow-[0_0_40px_rgba(217,119,87,0.3)]' : 'border-[#e0ddd5] scale-95 opacity-50'}`}>
                      <div className="text-6xl animate-bounce">AI</div>
                    </div>
                  </div>
                  <div className="space-y-3">
                    <h4 className="text-[#191918] font-semibold text-xl tracking-tight">{liveStatus === 'connecting' ? t('chat.liveConnecting') : liveStatus === 'listening' ? t('chat.liveListening') : t('chat.liveResponding')}</h4>
                    <p className="text-[#6b6b69] text-sm leading-relaxed px-12">{t('chat.liveHint')}</p>
                  </div>
                </div>
              ) : (
                <>
                  {messages.length === 0 && (
                    <div className="bg-white p-6 rounded-xl text-[#4a4a48] text-sm leading-relaxed border border-[#e0ddd5]">
                      <p className="font-semibold text-[#d97757] mb-2 flex items-center"><i className="fas fa-hand-sparkles mr-2"></i> {t('chat.welcome')}</p>
                      <p className="text-[#6b6b69]">{t('chat.welcomeDesc')}</p>
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
                        <button onClick={() => handlePlayVoice(m.text, i)} className={`absolute ${m.role === 'user' ? '-left-10' : '-right-10'} top-1/2 -translate-y-1/2 p-2 rounded-full transition-all ${playingIndex === i ? 'text-[#d97757] scale-125' : 'text-[#7a7a78] hover:text-[#d97757] opacity-0 group-hover:opacity-100'}`} title={t('chat.playVoice')}><i className={`fas ${playingIndex === i ? 'fa-spinner fa-spin' : 'fa-volume-up'}`}></i></button>
                      </div>
                    </div>
                  ))}
                  {isTyping && <div className="text-[#7a7a78] text-[10px] font-bold uppercase tracking-widest animate-pulse flex items-center space-x-2"><div className="w-1 h-1 bg-[#a0a09c] rounded-full"></div><span>{t('chat.thinking')}</span></div>}
                  <div ref={chatEndRef} />
                </>
              )}
            </div>

            {!isLiveMode && (
              <div className="px-5 py-3 bg-[#f9f9f8] border-t border-[#e0ddd5] flex space-x-2 overflow-x-auto shrink-0 no-scrollbar items-center">
                <input type="file" ref={chatFileInputRef} onChange={handleChatFileUpload} className="hidden" accept="image/*,application/pdf" />
                {QUICK_FUNCTIONS.map((fn) => (
                  <button key={fn.labelKey} onClick={() => fn.labelKey === 'chat.uploadInvoice' ? chatFileInputRef.current?.click() : handleSendMessage(t(fn.promptKey))} className="whitespace-nowrap flex items-center space-x-2 px-4 py-2 bg-white border border-[#e0ddd5] rounded-full text-[10px] font-bold text-[#4a4a48] hover:text-[#d97757] hover:border-[#d97757]/40 transition-all active:scale-95">
                    <i className={`fas ${fn.icon} text-[10px]`}></i><span>{t(fn.labelKey)}</span>
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
                  placeholder={isLiveMode ? t('chat.livePlaceholder') : t('chat.placeholder')}
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

// Auth wrapper — 桌面版默认无需登录，Web 版保持后端 session 校验
const isElectronEnv = typeof window !== 'undefined' && !!(window as any).electronAPI?.isElectron;

const AuthWrapper: React.FC = () => {
  const [authState, setAuthState] = useState<'checking' | 'authenticated' | 'unauthenticated'>(
    isElectronEnv ? 'authenticated' : 'checking'
  );
  // 桌面版需要 BYOK：启动时检测是否已配置 API Key，未配置时显示 Onboarding
  const [onboardingState, setOnboardingState] = useState<'checking' | 'needed' | 'done'>(
    isElectronEnv ? 'checking' : 'done'
  );

  useEffect(() => {
    if (isElectronEnv) {
      const electronAPI = (window as any).electronAPI;
      electronAPI.invoke('providers:hasAny')
        .then((has: boolean) => setOnboardingState(has ? 'done' : 'needed'))
        .catch(() => setOnboardingState('needed'));
      return; // 桌面版跳过远程 session 校验
    }
    fetch('/auth/check', { credentials: 'same-origin' })
      .then(r => r.json())
      .then(data => setAuthState(data.authenticated ? 'authenticated' : 'unauthenticated'))
      .catch(() => setAuthState('unauthenticated'));
  }, []);

  if (authState === 'checking') {
    return (
      <div className="min-h-screen flex items-center justify-center bg-[#f9f9f8]">
        <div className="flex items-center space-x-3 text-[#6b6b69]">
          <i className="fas fa-spinner fa-spin text-[#d97757]"></i>
          <span className="text-sm">加载中...</span>
        </div>
      </div>
    );
  }

  if (authState === 'unauthenticated') {
    return <LoginPage onLogin={() => setAuthState('authenticated')} />;
  }

  if (onboardingState === 'checking') {
    return (
      <div className="min-h-screen flex items-center justify-center bg-[#f9f9f8]">
        <div className="flex items-center space-x-3 text-[#6b6b69]">
          <i className="fas fa-spinner fa-spin text-[#d97757]"></i>
          <span className="text-sm">加载中...</span>
        </div>
      </div>
    );
  }

  if (onboardingState === 'needed') {
    return <OnboardingWizard onComplete={() => setOnboardingState('done')} />;
  }

  return <AppContent />;
};

const NavItem: React.FC<{ icon: string; label: string; active?: boolean; expanded?: boolean; onClick?: () => void; }> = ({ icon, label, active = false, expanded = true, onClick }) => (
  <div onClick={onClick} className={`flex items-center p-3 rounded-lg transition-all duration-200 cursor-pointer group ${active ? 'bg-[#d97757] text-white' : 'text-[#4a4a48] hover:bg-[#f0eeeb] hover:text-[#191918]'}`} style={active ? { boxShadow: '0 4px 24px rgba(217,119,87,0.15)' } : {}}>
    <i className={`fas ${icon} text-base ${expanded ? 'mr-4' : 'mx-auto'} w-5 text-center group-hover:scale-110 transition-transform`}></i>
    {expanded && <span className="text-sm font-medium">{label}</span>}
  </div>
);

export default AuthWrapper;
