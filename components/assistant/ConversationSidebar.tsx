// AI 助手会话历史侧栏（R4a-2，仅独立页 AssistantPage 渲染；浮窗保持紧凑无侧栏）。
// 消费共享的 useAssistantSession：列表 / 切换 / 就地重命名 / 删除 / 新建。重命名与删除
// 均为 inline 二次确认（无原生阻塞弹窗），与 ChatPanel 清空按钮同模式。
import React, { useState } from 'react';
import { useTranslation } from 'react-i18next';
import { useAssistantSession } from './AssistantProvider';

const ConversationSidebar: React.FC = () => {
  const { t } = useTranslation();
  const {
    conversations, activeConversationId,
    switchConversation, renameConversation, deleteConversation, newConversation,
  } = useAssistantSession();
  const [renamingId, setRenamingId] = useState<string | null>(null);
  const [renameValue, setRenameValue] = useState('');
  const [confirmDeleteId, setConfirmDeleteId] = useState<string | null>(null);

  const startRename = (id: string, current: string) => {
    setRenamingId(id);
    setRenameValue(current);
    setConfirmDeleteId(null);
  };
  const submitRename = (id: string) => {
    const v = renameValue.trim();
    if (v) renameConversation(id, v);
    setRenamingId(null);
  };

  return (
    <div className="w-64 shrink-0 bg-[#f9f9f8] border-r border-[#e0ddd5] flex flex-col">
      <div className="p-3 shrink-0">
        <button
          onClick={() => { newConversation(); setRenamingId(null); setConfirmDeleteId(null); }}
          className="w-full flex items-center justify-center px-3 py-2 rounded-lg text-xs font-bold text-white bg-primary hover:bg-primary-hover transition-all active:scale-95"
        >
          <i className="fas fa-plus mr-2 text-[10px]"></i>{t('chat.newConversation')}
        </button>
      </div>
      <div className="px-3 pb-2 text-[10px] font-bold uppercase tracking-widest text-[#5c5c5a] shrink-0">
        {t('chat.historyTitle')}
      </div>
      <div className="flex-1 overflow-y-auto custom-scrollbar px-2 pb-3 space-y-1">
        {conversations.length === 0 && (
          <p className="px-2 py-3 text-[11px] text-[#5c5c5a] italic">{t('chat.noHistory')}</p>
        )}
        {conversations.map((c) => {
          const active = c.id === activeConversationId;
          const title = (c.title && c.title.trim()) || t('chat.untitledConversation');

          if (renamingId === c.id) {
            return (
              <div key={c.id} className="px-2 py-1.5 rounded-lg bg-white border border-primary/40">
                <input
                  autoFocus
                  value={renameValue}
                  onChange={(e) => setRenameValue(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter') submitRename(c.id);
                    if (e.key === 'Escape') setRenamingId(null);
                  }}
                  onBlur={() => submitRename(c.id)}
                  placeholder={t('chat.renamePlaceholder')}
                  className="w-full bg-transparent text-xs text-[#191918] outline-none"
                />
              </div>
            );
          }

          const armed = confirmDeleteId === c.id;
          return (
            <div
              key={c.id}
              className={`group relative px-2 py-1.5 rounded-lg cursor-pointer transition-all ${active ? 'bg-white border border-primary/40' : 'hover:bg-white/70 border border-transparent'}`}
            >
              <button onClick={() => switchConversation(c.id)} className="w-full text-left pr-12">
                <div className={`text-xs font-medium truncate ${active ? 'text-primary' : 'text-[#4a4a48]'}`} title={title}>{title}</div>
                {c.updated_at && <div className="text-[9px] text-[#a0a09c] mt-0.5">{c.updated_at.slice(0, 10)}</div>}
              </button>
              <div className={`absolute right-1.5 top-1/2 -translate-y-1/2 flex items-center space-x-1 transition-opacity ${armed ? 'opacity-100' : 'opacity-0 group-hover:opacity-100'}`}>
                {armed ? (
                  <button
                    onClick={(e) => { e.stopPropagation(); deleteConversation(c.id); setConfirmDeleteId(null); }}
                    className="text-[9px] font-bold text-white bg-rose-500 hover:bg-rose-600 px-1.5 py-0.5 rounded"
                  >
                    {t('chat.deleteConfirm')}
                  </button>
                ) : (
                  <>
                    <button
                      onClick={(e) => { e.stopPropagation(); startRename(c.id, c.title || ''); }}
                      title={t('chat.renameConversation')}
                      className="text-[#5c5c5a] hover:text-primary text-[10px] w-5 h-5 flex items-center justify-center"
                    >
                      <i className="fas fa-pen"></i>
                    </button>
                    <button
                      onClick={(e) => { e.stopPropagation(); setConfirmDeleteId(c.id); }}
                      title={t('chat.deleteConversation')}
                      className="text-[#5c5c5a] hover:text-rose-500 text-[10px] w-5 h-5 flex items-center justify-center"
                    >
                      <i className="fas fa-trash"></i>
                    </button>
                  </>
                )}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
};

export default ConversationSidebar;
