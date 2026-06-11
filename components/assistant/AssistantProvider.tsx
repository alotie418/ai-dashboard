// AI 助手会话 Provider（R1）。把单一会话状态提升到 context，供浮窗（本期）与
// 后续独立页面（R2）共享同一会话——浮窗与页面看到的是同一组消息。
import React, { createContext, useContext } from 'react';
import { useAssistant, type AssistantSession, type AssistantDeps } from './useAssistant';

const AssistantContext = createContext<AssistantSession | null>(null);

export const AssistantProvider: React.FC<AssistantDeps & { children: React.ReactNode }> = ({ children, ...deps }) => {
  const session = useAssistant(deps);
  return <AssistantContext.Provider value={session}>{children}</AssistantContext.Provider>;
};

export function useAssistantSession(): AssistantSession {
  const ctx = useContext(AssistantContext);
  if (!ctx) throw new Error('useAssistantSession must be used within an AssistantProvider');
  return ctx;
}
