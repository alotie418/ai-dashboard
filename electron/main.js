// Electron main process — SoloLedger 独账
// 桌面壳入口：开发模式加载 vite dev server，生产模式加载本地 dist/index.html

const { app, BrowserWindow, ipcMain, dialog, shell } = require('electron');
const path = require('node:path');
const fs = require('node:fs');

const isDev = !app.isPackaged;
const BUILD_TARGET = process.env.BUILD_TARGET || (process.mas ? 'mas' : 'dmg');

let mainWindow = null;

function createMainWindow() {
  mainWindow = new BrowserWindow({
    width: 1440,
    height: 900,
    minWidth: 1100,
    minHeight: 700,
    titleBarStyle: 'hiddenInset',
    backgroundColor: '#ffffff',
    show: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false, // preload 里用 require('electron')，需要 sandbox=false
    },
  });

  mainWindow.once('ready-to-show', () => mainWindow.show());

  if (isDev) {
    mainWindow.loadURL('http://localhost:3000');
    mainWindow.webContents.openDevTools({ mode: 'detach' });
  } else {
    mainWindow.loadFile(path.join(__dirname, '..', 'dist', 'index.html'));
  }

  // 外链走系统浏览器，不在窗口内打开
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    if (url.startsWith('http')) shell.openExternal(url);
    return { action: 'deny' };
  });
}

app.whenReady().then(async () => {
  // 数据库 + IPC handler 注册（Phase 1.2/1.3 落地）
  try {
    const { initDatabase } = require('./db');
    initDatabase();
  } catch (e) {
    console.error('[db] init skipped or failed:', e?.message || e);
  }

  try {
    const { registerHandlers } = require('./handlers');
    registerHandlers({ ipcMain, dialog });
  } catch (e) {
    console.error('[handlers] registration failed:', e?.message || e);
  }

  createMainWindow();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createMainWindow();
  });
});

app.on('window-all-closed', () => {
  // macOS 习惯：关闭所有窗口不退出，留 Dock 图标
  if (process.platform !== 'darwin') app.quit();
});

// 暴露给 handler 模块用的元信息
module.exports = {
  isDev,
  BUILD_TARGET,
  getUserDataPath: () => app.getPath('userData'),
};
