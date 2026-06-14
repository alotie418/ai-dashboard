// Electron main process — SoloLedger 独账
// 桌面壳入口：开发模式加载 vite dev server，生产模式加载本地 dist/index.html

const { app, BrowserWindow, ipcMain, dialog, shell } = require('electron');
const path = require('node:path');
const fs = require('node:fs');

const isDev = !app.isPackaged;
const BUILD_TARGET = process.env.BUILD_TARGET || (process.mas ? 'mas' : 'dmg');

let mainWindow = null;

// 外链 / 导航安全策略
// - 只允许 https 外链走系统浏览器（http / file / javascript: / 自定义协议一律忽略）
// - 应用内（dev: http://localhost:3000；prod: file://dist/index.html）以外的整页导航一律拦截
function openExternalIfAllowed(url) {
  try {
    if (new URL(url).protocol === 'https:') {
      shell.openExternal(url);
      return true;
    }
  } catch {
    // 非法 URL，忽略
  }
  return false;
}

function isInternalUrl(url) {
  return isDev
    ? url.startsWith('http://localhost:3000')
    : url.startsWith('file://');
}

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

  // 外链只允许 https 走系统浏览器，其余一律拒绝且不在窗口内打开
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    openExternalIfAllowed(url);
    return { action: 'deny' };
  });

  // 防护：阻止非预期的整页跳转（本应用是 SPA，正常不会触发 will-navigate）。
  // 非「应用内」目标一律拦截；若是 https 外链则转交系统浏览器。
  mainWindow.webContents.on('will-navigate', (event, url) => {
    if (!isInternalUrl(url)) {
      event.preventDefault();
      openExternalIfAllowed(url);
    }
  });
}

// 单实例锁：防止第二个实例连到同一个 SQLite 库（WAL 并发写 / 恢复时可能损坏数据）。
// 拿不到锁 = 已有实例在运行 → 退出本实例；已有实例收到 second-instance 后把窗口拉到前台。
const gotSingleInstanceLock = app.requestSingleInstanceLock();

if (!gotSingleInstanceLock) {
  app.quit();
} else {
  app.on('second-instance', () => {
    if (mainWindow) {
      if (mainWindow.isMinimized()) mainWindow.restore();
      mainWindow.focus();
    }
  });

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
}

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
