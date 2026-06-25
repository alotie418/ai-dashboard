// AI 助手浮窗（R1：从 App.tsx 抽离的右下角浮窗壳）。
// 负责 浮窗开关 / 拖拽调整大小 / 标题栏，内部渲染共享的 ChatPanel。
// 语音控件（实时通话按钮、语音选择）已随语音功能移除；浮窗的开关与拉伸行为不变。
import React, { useRef, useState } from 'react';
import { useTranslation } from 'react-i18next';
import ChatPanel from './ChatPanel';
import { CloseIcon } from './icons';

const DEFAULT_CHAT_SIZE = { width: 620, height: 680 };

const AssistantWidget: React.FC = () => {
  const { t } = useTranslation();
  const [showChat, setShowChat] = useState(false);
  const [chatSize, setChatSize] = useState(DEFAULT_CHAT_SIZE);
  const chatBoxRef = useRef<HTMLDivElement>(null);
  const isResizing = useRef(false);
  const startResizeData = useRef({ mouseX: 0, mouseY: 0, startW: 0, startH: 0 });

  const resetChatSize = () => setChatSize(DEFAULT_CHAT_SIZE);

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
    const onUp = () => {
      isResizing.current = false;
      document.removeEventListener('mousemove', onMove);
      document.removeEventListener('mouseup', onUp);
      if (box) setChatSize({ width: box.offsetWidth, height: box.offsetHeight });
    };
    document.addEventListener('mousemove', onMove);
    document.addEventListener('mouseup', onUp);
  };

  return (
    <div className="fixed bottom-8 right-8 z-[10000] flex flex-row-reverse items-end space-x-4 space-x-reverse">
      <button
        onClick={() => setShowChat(!showChat)}
        aria-label={t('chat.title')}
        className={`w-14 h-14 rounded-full flex items-center justify-center transition-all duration-300 ${showChat ? 'bg-[#f0eeeb] border border-[#d1cdc4] text-primary rotate-90 scale-110' : 'bg-primary text-white hover:scale-110'}`}
        style={{ boxShadow: showChat ? 'none' : '0 4px 24px rgba(39,76,146,0.3)' }}
      >
        {showChat ? <CloseIcon /> : <div className="text-2xl">AI</div>}
      </button>

      {showChat && (
        <div
          ref={chatBoxRef}
          style={{ width: `${chatSize.width}px`, height: `${chatSize.height}px`, boxShadow: '0 8px 32px rgba(0,0,0,0.12)' }}
          className="glass-modal rounded-2xl overflow-hidden flex flex-col animate-in slide-in-from-right-8 duration-500 relative max-w-[calc(100vw-4rem)] max-h-[calc(100vh-4rem)]"
        >
          <div onMouseDown={handleMouseDown} className="absolute top-0 left-0 w-8 h-8 cursor-nw-resize z-50 flex items-end justify-end pr-1 pb-1 group" title={t('chat.resize')}>
            <svg width="10" height="10" viewBox="0 0 10 10" className="text-[#d1cdc4] group-hover:text-primary transition-colors"><path d="M0 10L10 0M0 6L6 0M0 2L2 0" stroke="currentColor" strokeWidth="1.5" /></svg>
          </div>

          {/* 标题栏（双击复位大小）。语音控件已移除。 */}
          <div onDoubleClick={resetChatSize} className="p-5 bg-primary flex justify-between items-center shrink-0 cursor-pointer select-none">
            <div className="flex items-center space-x-3">
              <div className="w-8 h-8 bg-accent/90 rounded-lg flex items-center justify-center text-[#16264D]"><i className="fas fa-robot text-sm"></i></div>
              <div>
                <h3 className="text-sm font-semibold text-white tracking-tight">{t('chat.title')}</h3>
                <p className="text-[10px] text-white/60">{t('chat.status')}</p>
              </div>
            </div>
          </div>

          <ChatPanel />
        </div>
      )}
    </div>
  );
};

export default AssistantWidget;
