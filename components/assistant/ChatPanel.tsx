// AI 助手聊天面板（R1：从 App.tsx 抽离；语音相关的播放按钮/实时语音 orb 已移除）。
// 纯展示 + 输入，消费 useAssistantSession()。浮窗（AssistantWidget）与后续独立页面（R2）
// 复用同一面板。消息区/快捷按钮/文件上传/输入框行为与抽离前一致。
import React, { useEffect, useRef } from 'react';
import { useTranslation } from 'react-i18next';
import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import { useAssistantSession } from './AssistantProvider';
import { SendIcon } from './icons';

const QUICK_FUNCTIONS = [
  { labelKey: 'chat.uploadInvoice', icon: 'fa-camera', promptKey: 'chat.quickPromptUploadInvoice' },
  { labelKey: 'chat.financeQuery', icon: 'fa-file-invoice-dollar', promptKey: 'chat.quickPromptFinanceQuery' },
  { labelKey: 'chat.trendAnalysis', icon: 'fa-chart-area', promptKey: 'chat.quickPromptTrend' },
  { labelKey: 'chat.marketAnalysis', icon: 'fa-globe-asia', promptKey: 'chat.quickPromptMarket' },
  { labelKey: 'chat.inventoryQuery', icon: 'fa-boxes', promptKey: 'chat.quickPromptInventory' },
];

const ChatPanel: React.FC = () => {
  const { t } = useTranslation();
  const { messages, chatInput, setChatInput, isTyping, sendMessage, uploadInvoice } = useAssistantSession();
  const chatEndRef = useRef<HTMLDivElement>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (chatEndRef.current) chatEndRef.current.scrollIntoView({ behavior: 'smooth' });
  }, [messages, isTyping]);

  const onFileChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (file) uploadInvoice(file);
    if (fileInputRef.current) fileInputRef.current.value = '';
  };

  return (
    <>
      <div className="flex-1 p-6 space-y-6 overflow-y-auto custom-scrollbar bg-[#fafaf9]">
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
            </div>
          </div>
        ))}
        {isTyping && <div className="text-[#7a7a78] text-[10px] font-bold uppercase tracking-widest animate-pulse flex items-center space-x-2"><div className="w-1 h-1 bg-[#a0a09c] rounded-full"></div><span>{t('chat.thinking')}</span></div>}
        <div ref={chatEndRef} />
      </div>

      <div className="px-5 py-3 bg-[#f9f9f8] border-t border-[#e0ddd5] flex space-x-2 overflow-x-auto shrink-0 no-scrollbar items-center">
        <input type="file" ref={fileInputRef} onChange={onFileChange} className="hidden" accept="image/*,application/pdf" />
        {QUICK_FUNCTIONS.map((fn) => (
          <button key={fn.labelKey} onClick={() => fn.labelKey === 'chat.uploadInvoice' ? fileInputRef.current?.click() : sendMessage(t(fn.promptKey))} className="whitespace-nowrap flex items-center space-x-2 px-4 py-2 bg-white border border-[#e0ddd5] rounded-full text-[10px] font-bold text-[#4a4a48] hover:text-[#d97757] hover:border-[#d97757]/40 transition-all active:scale-95">
            <i className={`fas ${fn.icon} text-[10px]`}></i><span>{t(fn.labelKey)}</span>
          </button>
        ))}
      </div>

      <div className="p-5 bg-[#f9f9f8] border-t border-[#e0ddd5] shrink-0">
        <form onSubmit={(e) => { e.preventDefault(); sendMessage(); }} className="flex items-center space-x-3">
          <input
            type="text"
            value={chatInput}
            onChange={(e) => setChatInput(e.target.value)}
            placeholder={t('chat.placeholder')}
            className="flex-1 bg-white border border-[#e0ddd5] rounded-xl px-5 py-3.5 text-xs outline-none focus:border-[#d97757] text-[#191918] placeholder:text-[#7a7a78] transition-all"
          />
          <button type="submit" disabled={!chatInput.trim() || isTyping} className="w-12 h-12 bg-[#d97757] rounded-xl text-white hover:bg-[#c4694d] disabled:opacity-30 transition-all flex items-center justify-center shrink-0 active:scale-90" style={{ boxShadow: '0 4px 24px rgba(217,119,87,0.2)' }}>
            <SendIcon />
          </button>
        </form>
      </div>
    </>
  );
};

export default ChatPanel;
