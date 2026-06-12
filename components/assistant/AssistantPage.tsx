// 独立 AI 助手页面（R2a）。复用浮窗同款 ChatPanel，与右下角轻量浮窗共享同一个
// AssistantProvider 会话——页面与浮窗看到的是同一组消息。纯 UI：不新增工具调用 /
// 不查账 / 不碰后端 / 不暴露 API Key；语音功能保持移除。
import React from 'react';
import { useTranslation } from 'react-i18next';
import ChatPanel from './ChatPanel';
import ConversationSidebar from './ConversationSidebar';

// 页面填满内容区：主区高度 = 100vh − header(h-16=4rem) − 内容内边距 p-8(上下共 4rem)
// = 100vh − 8rem，与首页 AIInsights 的 calc 高度同范式，避免外层双滚动条；min-h-0 让
// ChatPanel 内部消息区的 flex-1 滚动正常生效（浮窗用固定 height 提供同样的约束上下文）。
const AssistantPage: React.FC = () => {
  const { t } = useTranslation();
  return (
    <div className="h-[calc(100vh-8rem)] flex flex-col min-h-0">
      {/* R4a-2：两栏 —— 左侧会话历史栏（页面专属，浮窗不渲染）+ 右侧 页头 + ChatPanel */}
      <div
        className="flex-1 min-h-0 flex flex-row bg-white border border-[#e0ddd5] rounded-2xl overflow-hidden"
        style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.06)' }}
      >
        <ConversationSidebar />
        <div className="flex-1 min-w-0 flex flex-col">
          {/* 页头：复用浮窗同款标题/状态文案（chat.title / chat.status），不新增 i18n 键 */}
          <div className="p-5 bg-primary flex items-center space-x-3 shrink-0">
            <div className="w-8 h-8 bg-white/20 rounded-lg flex items-center justify-center text-white">
              <i className="fas fa-comments text-sm"></i>
            </div>
            <div>
              <h3 className="text-sm font-semibold text-white tracking-tight">{t('chat.title')}</h3>
              <p className="text-[10px] text-white/60">{t('chat.status')}</p>
            </div>
          </div>
          <ChatPanel />
        </div>
      </div>
    </div>
  );
};

export default AssistantPage;
