// AI 助手会话 hook（R1：从 App.tsx 抽离聊天逻辑；语音功能已移除）
// 封装聊天对话状态 + 发送/上传发票管线 + 业务上下文缓存。
// 网络调用统一走 services/api 的 aiChat/aiContext（内部处理 Electron IPC vs Web fetch）。
// 系统提示词沿用 accountingLocale×uiLanguage 解耦：buildAIFinanceContext 注入制度上下文 +
// 语言指令，业务数据由 /api/ai/context 现查（60s 缓存）。行为与抽离前一致。

import { useRef, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { aiChat, aiContext } from '../../services/api';
import { analyzeInvoice } from '../../services/ocrService';
import { buildAIFinanceContext, formatMoney, getTaxLabel } from '../accountingHelpers';
import type { FinancialStatementData } from '../../types';

export interface ChatMessage {
  role: 'user' | 'model';
  text: string;
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
}

export function useAssistant(deps: AssistantDeps): AssistantSession {
  const { t } = useTranslation();
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [chatInput, setChatInput] = useState('');
  const [isTyping, setIsTyping] = useState(false);
  const contextCacheRef = useRef<{ text: string; ts: number } | null>(null);

  const sendMessage = async (predefinedMsg?: string) => {
    const text = predefinedMsg || chatInput;
    if (!text.trim() || isTyping) return;
    const newMsgs: ChatMessage[] = [...messages, { role: 'user', text }];
    setMessages(newMsgs);
    setChatInput('');
    setIsTyping(true);
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

${contextText}`;

      const result = await aiChat(chatHistory, systemInstruction);
      const content = result.text || t('chat.emptyReply');
      setMessages([...newMsgs, { role: 'model', text: content }]);
    } catch {
      setMessages([...newMsgs, { role: 'model', text: t('chat.requestError') }]);
    } finally {
      setIsTyping(false);
    }
  };

  const uploadInvoice = async (file: File) => {
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
      const extracted = await analyzeInvoice(base64, file.type, deps.accountingLocale, deps.uiLanguage);
      if (!extracted.isInvoiceLike) {
        setMessages([...newMsgs, { role: 'model', text: t('chat.notInvoice', { type: extracted.documentType || 'unknown' }) }]);
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
      setMessages([...newMsgs, { role: 'model', text: resultText }]);
    } catch {
      setMessages([...newMsgs, { role: 'model', text: t('chat.invoiceRecognizeFailed') }]);
    } finally {
      setIsTyping(false);
    }
  };

  return { messages, chatInput, setChatInput, isTyping, sendMessage, uploadInvoice };
}
