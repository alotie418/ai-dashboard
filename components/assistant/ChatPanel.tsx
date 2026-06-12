// AI 助手聊天面板（R1：从 App.tsx 抽离；语音相关的播放按钮/实时语音 orb 已移除）。
// 纯展示 + 输入，消费 useAssistantSession()。浮窗（AssistantWidget）与后续独立页面（R2）
// 复用同一面板。消息区/快捷按钮/文件上传/输入框行为与抽离前一致。
import React, { useEffect, useRef, useState } from 'react';
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
  const { messages, chatInput, setChatInput, isTyping, sendMessage, uploadInvoice, activeTitle, newConversation, clearActive } = useAssistantSession();
  const chatEndRef = useRef<HTMLDivElement>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const [confirmClear, setConfirmClear] = useState(false);

  useEffect(() => {
    if (chatEndRef.current) chatEndRef.current.scrollIntoView({ behavior: 'smooth' });
  }, [messages, isTyping]);

  // 会话切换 / 发送新消息后重置「确认清空」二次确认态。
  useEffect(() => { setConfirmClear(false); }, [messages.length]);

  const onFileChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (file) uploadInvoice(file);
    if (fileInputRef.current) fileInputRef.current.value = '';
  };

  return (
    <>
      {/* R4a-1：会话工具条 —— 当前标题 + 新建对话 + 清空（二次确认）。widget 与独立页共用。 */}
      <div className="px-4 py-2 bg-white border-b border-[#e0ddd5] flex items-center justify-between shrink-0">
        <span className="text-[11px] font-semibold text-[#4a4a48] truncate mr-2" title={activeTitle || t('chat.untitledConversation')}>
          {activeTitle || t('chat.untitledConversation')}
        </span>
        <div className="flex items-center space-x-1.5 shrink-0">
          <button
            onClick={() => { newConversation(); setConfirmClear(false); }}
            className="flex items-center px-2.5 py-1 rounded-full text-[10px] font-bold text-[#4a4a48] border border-[#e0ddd5] hover:text-primary hover:border-primary/40 transition-all active:scale-95"
          >
            <i className="fas fa-plus mr-1 text-[9px]"></i>{t('chat.newConversation')}
          </button>
          {confirmClear ? (
            <button
              onClick={() => { clearActive(); setConfirmClear(false); }}
              className="px-2.5 py-1 rounded-full text-[10px] font-bold text-white bg-rose-500 hover:bg-rose-600 transition-all active:scale-95"
            >
              {t('chat.clearConfirm')}
            </button>
          ) : (
            <button
              onClick={() => setConfirmClear(true)}
              disabled={messages.length === 0}
              className="px-2.5 py-1 rounded-full text-[10px] font-bold text-[#4a4a48] border border-[#e0ddd5] hover:text-rose-500 hover:border-rose-300 disabled:opacity-30 transition-all active:scale-95"
            >
              {t('chat.clearChat')}
            </button>
          )}
        </div>
      </div>

      <div className="flex-1 p-6 space-y-6 overflow-y-auto custom-scrollbar bg-[#fafaf9]">
        {messages.length === 0 && (
          <div className="bg-white p-6 rounded-xl text-[#4a4a48] text-sm leading-relaxed border border-[#e0ddd5]">
            <p className="font-semibold text-primary mb-2 flex items-center"><i className="fas fa-hand-sparkles mr-2"></i> {t('chat.welcome')}</p>
            <p className="text-[#6b6b69]">{t('chat.welcomeDesc')}</p>
          </div>
        )}
        {messages.map((m, i) => (
          <div key={i} className={`flex ${m.role === 'user' ? 'justify-end' : 'justify-start'}`}>
            <div className={`relative group max-w-[88%] p-4 rounded-xl text-sm leading-relaxed ${m.role === 'user' ? 'bg-primary text-white rounded-tr-sm' : 'bg-white text-[#4a4a48] border border-[#e0ddd5] rounded-tl-sm'}`}>
              {m.role === 'user' ? m.text : (
                <div className="markdown-body">
                  <ReactMarkdown remarkPlugins={[remarkGfm]}>{m.text}</ReactMarkdown>
                </div>
              )}
              {/* R2b-1：只读查账工具轨迹「已查询：…」。未知工具名兜底显示原始名，绝不裸 key。 */}
              {m.role !== 'user' && m.toolTrace && m.toolTrace.length > 0 && (
                <div className="mt-2 pt-2 border-t border-[#e0ddd5] flex items-center flex-wrap gap-x-1 text-[10px] text-[#7a7a78]">
                  <i className="fas fa-search mr-1 text-primary"></i>
                  <span className="font-semibold">{t('chat.toolTraceTitle')}：</span>
                  <span>{m.toolTrace.map((tt) => t(`chat.toolLabel.${tt.name}`, { defaultValue: tt.name })).join(' · ')}</span>
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
          <button key={fn.labelKey} onClick={() => fn.labelKey === 'chat.uploadInvoice' ? fileInputRef.current?.click() : sendMessage(t(fn.promptKey))} className="whitespace-nowrap flex items-center space-x-2 px-4 py-2 bg-white border border-[#e0ddd5] rounded-full text-[10px] font-bold text-[#4a4a48] hover:text-primary hover:border-primary/40 transition-all active:scale-95">
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
            className="flex-1 bg-white border border-[#e0ddd5] rounded-xl px-5 py-3.5 text-xs outline-none focus:border-primary text-[#191918] placeholder:text-[#7a7a78] transition-all"
          />
          <button type="submit" disabled={!chatInput.trim() || isTyping} className="w-12 h-12 bg-primary rounded-xl text-white hover:bg-primary-hover disabled:opacity-30 transition-all flex items-center justify-center shrink-0 active:scale-90" style={{ boxShadow: '0 4px 24px rgba(39,76,146,0.2)' }}>
            <SendIcon />
          </button>
        </form>
      </div>
    </>
  );
};

export default ChatPanel;
