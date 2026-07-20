// Electron main process — SoloLedger 独账
// 桌面壳入口：开发模式加载 vite dev server，生产模式加载本地 dist/index.html

const { app, BrowserWindow, Menu, ipcMain, dialog, shell } = require('electron');
const path = require('node:path');
const fs = require('node:fs');
const { pathToFileURL } = require('node:url');

const isDev = !app.isPackaged;
// QA 门控（CSP file:// 验收）：SOLOLEDGER_LOAD_DIST=1 时，未打包运行也加载构建产物
// dist/index.html（file://，生产注入的 meta CSP 生效）——用于不打包就真机验证 CSP。
// 双门控：仅 !app.isPackaged 时生效，打包版永远走正常 loadFile 分支、不受此开关影响。
const loadDistForQa = isDev && process.env.SOLOLEDGER_LOAD_DIST === '1';
// QA 模式的「应用内」资源前缀：只认 dist/ 目录下的 file:// URL，不放行任意 file://。
const distDirFileUrl = pathToFileURL(path.join(__dirname, '..', 'dist')).href + '/';
// Demo mode is decided in one place (electron/db/index.js): SOLOLEDGER_DEMO=1 AND non-packaged.
const { isDemoMode } = require('./db');

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
  // QA 模式：仅 dist/ 目录内的 file:// 资源算「应用内」（不粗放地认所有 file://）。
  if (loadDistForQa) return url.startsWith(distDirFileUrl);
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
    title: isDemoMode() ? 'SoloLedger [DEMO]' : 'SoloLedger',
    titleBarStyle: 'hiddenInset',
    backgroundColor: '#ffffff',
    show: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      // preload 仅用 contextBridge / ipcRenderer / process.platform —— 均为 sandbox
      // preload 可用能力（allowlisted 渲染端模块 + polyfilled process），无需完整 Node
      // 模块，故可开启沙箱。渲染层本身已 Node-free（全走 electronAPI.invoke IPC）。
      sandbox: true,
    },
  });

  mainWindow.once('ready-to-show', () => mainWindow.show());

  // 关闭主窗口后清空引用，让 showMainWindow / activate 能可靠地重新创建（macOS 习惯：
  // 关窗不退出）。配合应用菜单的「打开主窗口」项与 Dock 点击，保证窗口关闭后总能重开。
  mainWindow.on('closed', () => { mainWindow = null; });

  if (loadDistForQa) {
    // CSP QA：加载构建产物（file:// + meta CSP 生效）；开 DevTools 便于观察 securitypolicyviolation
    mainWindow.loadFile(path.join(__dirname, '..', 'dist', 'index.html'));
    mainWindow.webContents.openDevTools({ mode: 'detach' });
  } else if (isDev) {
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

// 打开/聚焦主窗口：已有窗口则恢复并聚焦，否则新建——始终只保留一个主窗口（防重复创建）。
// 供应用菜单「打开主窗口」项、Dock 图标点击（activate）、以及第二实例唤起统一调用。
function showMainWindow() {
  if (mainWindow && !mainWindow.isDestroyed()) {
    if (mainWindow.isMinimized()) mainWindow.restore();
    mainWindow.show();
    mainWindow.focus();
  } else {
    createMainWindow();
  }
}

// 应用菜单（macOS）。默认 Electron 菜单没有「重新打开已关闭主窗口」的入口，导致关窗后
// 只能靠 Dock；App Review Guideline 4 要求提供菜单项重开窗口。这里用标准角色（自动本地化：
// 关于/隐藏/退出/复制粘贴/最小化等）重建标准菜单，并在「窗口」菜单加一个显式的
// 「打开主窗口」项（⌘0 → showMainWindow）。角色项保证复制/粘贴/撤销等标准行为不丢失。
function buildAppMenu() {
  const isMac = process.platform === 'darwin';
  const openMainWindowItem = {
    label: 'SoloLedger',
    accelerator: 'CmdOrCtrl+0',
    click: () => showMainWindow(),
  };
  const template = [
    ...(isMac ? [{ role: 'appMenu' }] : []),
    { role: 'fileMenu' },
    { role: 'editMenu' },
    { role: 'viewMenu' },
    {
      label: 'Window',
      submenu: [
        { role: 'minimize' },
        { role: 'zoom' },
        openMainWindowItem,
        ...(isMac
          ? [{ type: 'separator' }, { role: 'front' }, { type: 'separator' }, { role: 'close' }]
          : [{ role: 'close' }]),
      ],
    },
  ];
  return Menu.buildFromTemplate(template);
}

// 单实例锁：防止第二个实例连到同一个 SQLite 库（WAL 并发写 / 恢复时可能损坏数据）。
// 拿不到锁 = 已有实例在运行 → 退出本实例；已有实例收到 second-instance 后把窗口拉到前台。
const gotSingleInstanceLock = app.requestSingleInstanceLock();

if (!gotSingleInstanceLock) {
  app.quit();
} else {
  app.on('second-instance', () => {
    showMainWindow();
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

    // Demo mode: seed the isolated demo DB with sample e-commerce data on first launch.
    // Idempotent (no-op if already seeded) and gated to demo mode; never runs for a real DB.
    if (isDemoMode()) {
      try {
        const { seedDemoIfEmpty } = require('./ecommerce/demoSeed');
        const res = await seedDemoIfEmpty();
        console.log('[demo] seed:', res?.seeded ? `seeded ${res.staged} sample orders` : `skipped (${res?.reason})`);
      } catch (e) {
        console.error('[demo] seed failed:', e?.message || e);
      }
    }

    // 应用菜单：提供「窗口 → 打开主窗口」(⌘0) 入口，关窗后可从菜单重开（Guideline 4）。
    Menu.setApplicationMenu(buildAppMenu());

    createMainWindow();

    // Dock 图标点击（或从菜单激活）时，没有窗口就重建、有则聚焦——始终单窗口。
    app.on('activate', () => {
      showMainWindow();
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
  getUserDataPath: () => app.getPath('userData'),
};
