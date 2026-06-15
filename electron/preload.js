// Electron preload — 通过 contextBridge 暴露 window.electronAPI
// 渲染进程只能通过 invoke(channel, payload) 与主进程通信，channel 必须在白名单内

const { contextBridge, ipcRenderer } = require('electron');

// channel 命名约定: `${resource}:${action}`
// 例如: sales:list / sales:create / ai:analyze / agent:plan
// 渲染进程不需要知道具体 channel 列表，由 services/api.ts 内的 apiFetch 翻译 REST path 到 channel

contextBridge.exposeInMainWorld('electronAPI', {
  invoke: (channel, payload) => ipcRenderer.invoke(channel, payload),
  // 平台信息（渲染层可用于条件渲染）
  platform: process.platform,
  isElectron: true,
});
