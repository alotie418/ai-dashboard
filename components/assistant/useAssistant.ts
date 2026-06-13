// AI 助手会话 hook（R1：从 App.tsx 抽离聊天逻辑；语音功能已移除）
// 封装聊天对话状态 + 发送/上传发票管线 + 业务上下文缓存。
// 网络调用统一走 services/api 的 aiChat/aiContext（内部处理 Electron IPC vs Web fetch）。
// 系统提示词沿用 accountingLocale×uiLanguage 解耦：buildAIFinanceContext 注入制度上下文 +
// 语言指令，业务数据由 /api/ai/context 现查（60s 缓存）。行为与抽离前一致。

import { useEffect, useRef, useState } from 'react';
import { useTranslation } from 'react-i18next';
import {
  aiAgentChat, aiContext, type ToolTraceItem, type ConversationMeta,
  listConversations, createConversation, fetchConversationMessages,
  appendConversationMessage, deleteConversation, renameConversation,
} from '../../services/api';
import { aiErrorMessage } from '../../services/aiErrors';
import { analyzeInvoice } from '../../services/ocrService';
import { buildAIFinanceContext, formatMoney, getTaxLabel } from '../accountingHelpers';
import type { FinancialStatementData } from '../../types';

export interface ChatMessage {
  role: 'user' | 'model';
  text: string;
  toolTrace?: ToolTraceItem[];   // R2b-1：只读查账工具轨迹（仅 model 消息），渲染「已查询」
}

export interface AssistantDeps {
  accountingLocale: string;      // 会计制度（税种/币种/口径上下文）
  uiLanguage: string;            // 界面语言（回复语言）
  selectedYear: string;          // 业务上下文查询年度
  fallbackStatement: FinancialStatementData; // /api/ai/context 失败时的兜底摘要
}

export interface AssistantSession {
  messages: ChatMessage[];
  chatInput: string;
  setChatInput: (v: string) => void;
  isTyping: boolean;
  sendMessage: (predefined?: string) => Promise<void>;
  uploadInvoice: (file: File) => Promise<void>;
  activeTitle: string | null;         // R4a-1：当前会话标题（首条用户消息派生，供 ChatPanel 头部）
  newConversation: () => void;        // 新建对话（当前会话已持久化、留存历史）
  clearActive: () => Promise<void>;   // 清空当前对话（删除会话+消息）并开新空会话
  // R4a-2：独立页侧栏会话历史（浮窗不渲染侧栏）。
  conversations: ConversationMeta[];          // 会话列表（最近更新在前，响应式）
  activeConversationId: string | null;        // 当前活动会话 id（侧栏高亮）
  switchConversation: (id: string) => Promise<void>;        // 切换并载入该会话消息
  renameConversation: (id: string, title: string) => Promise<void>; // 重命名标题
  deleteConversation: (id: string) => Promise<void>;        // 删除会话（连同消息）
}

export function useAssistant(deps: AssistantDeps): AssistantSession {
  const { t } = useTranslation();
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [chatInput, setChatInput] = useState('');
  const [isTyping, setIsTyping] = useState(false);
  const contextCacheRef = useRef<{ text: string; ts: number } | null>(null);

  // R4a-1：会话持久化。convIdRef 同步保存当前活动会话 id（避免懒建竞态；ref 不触发渲染，
  // 头部标题改由 messages 派生）。所有持久化调用均 try/catch 降级——web 模式 /api/conversations
  // 404 / 任何失败时退回纯内存会话，绝不阻断聊天。
  const convIdRef = useRef<string | null>(null);
  // R4a-2：活动会话 id（响应式，供侧栏高亮）+ 会话列表（响应式）。convIdRef 始终与
  // activeConversationId 同步（ref 供 async 流同步读，state 供渲染）。
  const [activeConversationId, setActiveConversationIdState] = useState<string | null>(null);
  const [conversations, setConversations] = useState<ConversationMeta[]>([]);
  const setActiveConversationId = (id: string | null) => { convIdRef.current = id; setActiveConversationIdState(id); };

  const refreshConversations = async () => {
    try {
      const convs = await listConversations();
      if (Array.isArray(convs)) setConversations(convs);
    } catch { /* 降级：纯内存，列表留空 */ }
  };

  // 挂载时自动载入最近会话（重开 app 续上次对话）+ 拉取会话列表。仅跑一次。
  const loadedRef = useRef(false);
  useEffect(() => {
    if (loadedRef.current) return;
    loadedRef.current = true;
    (async () => {
      try {
        const convs = await listConversations();
        if (Array.isArray(convs) && convs.length) {
          setConversations(convs);
          const recent = convs[0];
          const msgs = await fetchConversationMessages(recent.id);
          setActiveConversationId(recent.id);
          setMessages(msgs as ChatMessage[]);
        }
      } catch { /* 非桌面/降级：保持空白纯内存会话 */ }
    })();
  }, []);

  // 懒建会话：无活动会话时新建并记录 id；失败（web/降级）返回 null，调用方走纯内存。
  const ensureConversation = async (): Promise<string | null> => {
    if (convIdRef.current) return convIdRef.current;
    try {
      const c = await createConversation({ accLocale: deps.accountingLocale, uiLanguage: deps.uiLanguage });
      setActiveConversationId(c.id);
      return c.id;
    } catch { return null; }
  };

  const persist = async (convId: string | null, msg: ChatMessage) => {
    if (!convId) return;
    try { await appendConversationMessage(convId, msg); } catch { /* 降级：纯内存 */ }
  };

  const sendMessage = async (predefinedMsg?: string) => {
    const text = predefinedMsg || chatInput;
    if (!text.trim() || isTyping) return;
    const newMsgs: ChatMessage[] = [...messages, { role: 'user', text }];
    setMessages(newMsgs);
    setChatInput('');
    setIsTyping(true);
    // 先持久化用户消息（懒建会话），即使后续 AI 失败也保留输入。
    const convId = await ensureConversation();
    await persist(convId, { role: 'user', text });
    void refreshConversations();  // 新会话 + 首条消息自动标题反映到侧栏
    try {
      // 多轮对话历史（Gemini 风格 parts；adapter 内部归一化）
      const chatHistory = newMsgs.map(m => ({ role: m.role, parts: [{ text: m.text }] }));

      // 业务上下文：服务端聚合，渲染端缓存 60s
      let contextText = '';
      try {
        const now = Date.now();
        if (contextCacheRef.current && now - contextCacheRef.current.ts < 60000) {
          contextText = contextCacheRef.current.text;
        } else {
          const ctxData = await aiContext(deps.selectedYear);
          contextText = ctxData.context || '';
          contextCacheRef.current = { text: contextText, ts: now };
        }
      } catch {
        // context 接口失败时退回基础摘要
        contextText = t('ai.contextFallback', {
          revenue: formatMoney(deps.fallbackStatement.salesRevenue, deps.accountingLocale),
          grossMargin: deps.fallbackStatement.grossMargin,
          netMargin: deps.fallbackStatement.netMargin,
        });
      }

      const systemInstruction = `${t('ai.chatSystemPrompt')}

${buildAIFinanceContext(deps.accountingLocale, deps.uiLanguage)}

${contextText}

${t('ai.boundaryDirective')}`;

      // R2b-1：改走只读查账 agent（主进程跑工具循环，API Key 不出主进程）；
      // 仍注入 60s 快照基线 context（简单问题不必触发工具），工具用于下钻取实数。
      const result = await aiAgentChat(chatHistory, systemInstruction);
      const content = result.text || t('chat.emptyReply');
      const modelMsg: ChatMessage = { role: 'model', text: content, toolTrace: result.toolTrace };
      setMessages([...newMsgs, modelMsg]);
      await persist(convId, modelMsg);
    } catch (err) {
      // R3c：按稳定 code 映射 i18n（随 uiLanguage），替代恒定的通用兜底文案。
      // 错误为瞬态（可重试），不落库——重开 app 时最后一条用户消息保留、可重发。
      setMessages([...newMsgs, { role: 'model', text: aiErrorMessage(err, t) }]);
    } finally {
      setIsTyping(false);
    }
  };

  const uploadInvoice = async (file: File) => {
    const userText = t('chat.uploadInvoiceMsg', { name: file.name });
    const newMsgs: ChatMessage[] = [...messages, { role: 'user', text: userText }];
    setMessages(newMsgs);
    setIsTyping(true);
    const convId = await ensureConversation();
    await persist(convId, { role: 'user', text: userText });
    void refreshConversations();
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
      const extracted = await analyzeInvoice(base64, file.type, deps.accountingLocale, deps.uiLanguage);
      if (!extracted.isInvoiceLike) {
        const notMsg: ChatMessage = { role: 'model', text: t('chat.notInvoice', { type: extracted.documentType || 'unknown' }) };
        setMessages([...newMsgs, notMsg]);
        await persist(convId, notMsg);
        return;
      }
      const extractVals = {
        date: extracted.date,
        partner: extracted.customer,
        quantity: extracted.quantity || '-',
        amount: formatMoney(extracted.price || 0, deps.accountingLocale),
        shipping: formatMoney(extracted.shipping || 0, deps.accountingLocale),
        invoiceNo: extracted.invoiceNo || '-',
      };
      // 非 CN 制度走通用「票据」结果（无 CN-VAT 进项/销项/发票号 措辞）；CN 用 i18n 模板。
      // taxConcept 返回纯字符串，用 $-safe 函数替换 token（金额串含 '$'）。
      let resultText: string;
      if (deps.accountingLocale !== 'CN') {
        resultText = getTaxLabel(deps.accountingLocale, deps.uiLanguage, 'chatExtractResult');
        for (const [k, v] of Object.entries(extractVals)) {
          resultText = resultText.replace(`{${k}}`, () => String(v));
        }
      } else {
        resultText = t('chat.invoiceExtractResult', extractVals);
      }
      const resultMsg: ChatMessage = { role: 'model', text: resultText };
      setMessages([...newMsgs, resultMsg]);
      await persist(convId, resultMsg);
    } catch {
      // 识别失败为瞬态，不落库（用户消息已保留）。
      setMessages([...newMsgs, { role: 'model', text: t('chat.invoiceRecognizeFailed') }]);
    } finally {
      setIsTyping(false);
    }
  };

  // 新建对话：当前会话已持久化、留存历史；清空当前视图、下次发消息懒建新会话。
  const newConversation = () => {
    setActiveConversationId(null);
    setMessages([]);
  };

  // 清空当前对话：删除当前会话（连同消息）并开新空会话。
  const clearActive = async () => {
    const id = convIdRef.current;
    setActiveConversationId(null);
    setMessages([]);
    if (id) {
      try { await deleteConversation(id); } catch { /* 降级：纯内存 */ }
      void refreshConversations();
    }
  };

  // R4a-2 侧栏：切换会话（载入其消息；发送中不切换防并发）。
  const switchConversation = async (id: string) => {
    if (id === convIdRef.current || isTyping) return;
    try {
      const msgs = await fetchConversationMessages(id);
      setActiveConversationId(id);
      setMessages(msgs as ChatMessage[]);
    } catch { /* 降级：忽略切换 */ }
  };

  // R4a-2 侧栏：就地重命名标题。
  const renameConversationById = async (id: string, title: string) => {
    try { await renameConversation(id, title); } catch { /* 降级：纯内存 */ }
    void refreshConversations();
  };

  // R4a-2 侧栏：删除会话（连同消息）；删的是当前会话则清空视图。
  const deleteConversationById = async (id: string) => {
    try { await deleteConversation(id); } catch { /* 降级：纯内存 */ }
    if (id === convIdRef.current) { setActiveConversationId(null); setMessages([]); }
    void refreshConversations();
  };

  // 头部标题：首条用户消息派生（截 40 字符），空会话为 null（ChatPanel 显示「新对话」）。
  const activeTitle = messages.find(m => m.role === 'user')?.text.slice(0, 40) || null;

  return {
    messages, chatInput, setChatInput, isTyping, sendMessage, uploadInvoice,
    activeTitle, newConversation, clearActive,
    conversations, activeConversationId, switchConversation,
    renameConversation: renameConversationById, deleteConversation: deleteConversationById,
  };
}
