// IPC handler 注册中心
// - api:request：业务路由分发（REST 风格）
// - providers:*：AI 服务商管理（list/save/remove/setDefault/test/hasAny）
// - app:*：应用级辅助（数据库导出/导入等）

const { dispatch } = require('./router');
const aiCore = require('../ai');

function registerHandlers({ ipcMain, dialog }) {
  // ====== 业务统一路由 ======
  ipcMain.handle('api:request', async (_evt, req) => {
    try {
      return await dispatch(req || {});
    } catch (err) {
      // 把归一化的错误字段拼到 message 里，IPC throw 至少能保留 message
      // 前端 catch 后可以基于关键字判断（NO_PROVIDER / model_not_found / HTTP 401 等）
      const status = err?.status ? ` · HTTP ${err.status}` : '';
      const code = err?.code ? ` [${err.code}]` : '';
      const friendly = err?.friendly ? ` — ${err.friendly}` : '';
      const base = err?.message || 'IPC dispatch failed';
      throw new Error(`${base}${status}${code}${friendly}`);
    }
  });

  // ====== AI Provider 管理 ======
  ipcMain.handle('providers:list', async () => {
    return aiCore.list();
  });

  ipcMain.handle('providers:hasAny', async () => {
    return aiCore.hasAny();
  });

  ipcMain.handle('providers:save', async (_evt, payload) => {
    return aiCore.save(payload || {});
  });

  ipcMain.handle('providers:remove', async (_evt, payload) => {
    return aiCore.remove(payload || {});
  });

  ipcMain.handle('providers:setDefault', async (_evt, payload) => {
    return aiCore.setDefault(payload || {});
  });

  ipcMain.handle('providers:test', async (_evt, payload) => {
    try {
      const result = await aiCore.test(payload || {});
      return { ok: true, ...result };
    } catch (err) {
      // 把 provider adapter / _error.js 归一化后的错误字段全部回传给 UI
      return {
        ok: false,
        error: err?.friendly || err?.message || '连接失败',
        status: err?.status,
        code: err?.code,
        providerMessage: err?.providerMessage,
        rawMessage: err?.message,
      };
    }
  });

  // ====== 数据库备份 / 导出 ======
  ipcMain.handle('app:exportDb', async () => {
    const { getDbPath, getDb } = require('../db');
    const dbPath = getDbPath();
    // 加固：备份前先把 WAL 落盘到主库，否则最近已提交事务可能还在 -wal 里，
    // 单文件拷贝会丢这部分数据。TRUNCATE 后 wal 清空，单 .db 即完整快照。
    try { getDb().pragma('wal_checkpoint(TRUNCATE)'); } catch (e) { console.warn('[app:exportDb] checkpoint failed:', e?.message || e); }
    const result = await dialog.showSaveDialog({
      title: '导出账本数据',
      defaultPath: `sololedger-backup-${new Date().toISOString().slice(0, 10)}.db`,
      filters: [{ name: 'SQLite 数据库', extensions: ['db'] }],
    });
    if (result.canceled || !result.filePath) return { ok: false };
    const fs = require('node:fs');
    fs.copyFileSync(dbPath, result.filePath);
    return { ok: true, path: result.filePath };
  });

  // ====== 数据库恢复 / 导入 ======
  // 安全顺序：选文件 → 校验(头/quick_check/关键表/版本) → 自动备份当前库 →
  //   关闭连接 → 原子替换 → 清旧 wal/shm → 让前端引导重启。任何一步失败即中止并回传 error。
  ipcMain.handle('app:importDb', async () => {
    const fs = require('node:fs');
    const path = require('node:path');
    const { app } = require('electron');
    const { getDbPath, getDb, closeDb, SCHEMA_VERSION } = require('../db');

    // 1. 选择 .db 文件
    const sel = await dialog.showOpenDialog({
      title: '选择要恢复的账本备份',
      properties: ['openFile'],
      filters: [{ name: 'SQLite 数据库', extensions: ['db'] }],
    });
    if (sel.canceled || !sel.filePaths || !sel.filePaths[0]) return { ok: false };
    const srcPath = sel.filePaths[0];

    // 2. 校验 SQLite 文件头（前 16 字节应为 "SQLite format 3\0"）
    try {
      const fd = fs.openSync(srcPath, 'r');
      const header = Buffer.alloc(16);
      fs.readSync(fd, header, 0, 16, 0);
      fs.closeSync(fd);
      if (header.toString('utf8', 0, 15) !== 'SQLite format 3') return { ok: false, error: 'INVALID_FILE' };
    } catch (e) {
      return { ok: false, error: 'INVALID_FILE' };
    }

    // 3-5. 只读打开校验：quick_check + 关键表存在 + user_version 不高于当前支持版本
    let probe = null;
    try {
      const Database = require('better-sqlite3');
      probe = new Database(srcPath, { readonly: true, fileMustExist: true });
      const qc = probe.pragma('quick_check', { simple: true });
      if (qc !== 'ok') { probe.close(); return { ok: false, error: 'INTEGRITY_FAILED' }; }
      const tables = probe
        .prepare("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('products','transactions')")
        .all().map(r => r.name);
      if (!tables.includes('products') || !tables.includes('transactions')) { probe.close(); return { ok: false, error: 'INVALID_FILE' }; }
      const uv = probe.pragma('user_version', { simple: true });
      probe.close();
      probe = null;
      if (uv > SCHEMA_VERSION) return { ok: false, error: 'NEWER_VERSION' };
    } catch (e) {
      try { if (probe) probe.close(); } catch { /* ignore */ }
      return { ok: false, error: 'INVALID_FILE' };
    }

    const dbPath = getDbPath();

    // 6. 恢复前自动备份当前库（安全网）。失败则中止恢复，绝不在没有备份的情况下覆盖。
    let autoBackupPath;
    try {
      try { getDb().pragma('wal_checkpoint(TRUNCATE)'); } catch { /* best effort */ }
      const backupsDir = path.join(app.getPath('userData'), 'backups');
      if (!fs.existsSync(backupsDir)) fs.mkdirSync(backupsDir, { recursive: true });
      const stamp = new Date().toISOString().replace(/[:.]/g, '-');
      autoBackupPath = path.join(backupsDir, `sololedger-autobackup-before-restore-${stamp}.db`);
      fs.copyFileSync(dbPath, autoBackupPath);
    } catch (e) {
      return { ok: false, error: 'AUTOBACKUP_FAILED' };
    }

    // 7. 关闭当前连接（checkpoint + close + null）
    try { closeDb(); } catch (e) { return { ok: false, error: 'CLOSE_FAILED', autoBackupPath }; }

    // 8. 原子替换：先拷到同目录临时文件，再 rename 覆盖主库（同盘 rename 原子，防半成品）
    // 9. 删除旧的 -wal / -shm（属于旧库；留下会让 SQLite 用过期 WAL 覆盖新库 → 损坏）
    try {
      const tmpPath = dbPath + '.restore-tmp';
      fs.copyFileSync(srcPath, tmpPath);
      fs.renameSync(tmpPath, dbPath);
      fs.rmSync(dbPath + '-wal', { force: true });
      fs.rmSync(dbPath + '-shm', { force: true });
    } catch (e) {
      return { ok: false, error: 'REPLACE_FAILED', autoBackupPath };
    }

    return { ok: true, restoredFrom: srcPath, autoBackupPath };
  });

  // ====== 重启应用（恢复完成后引导用户立即重启，拿到干净的新库状态）======
  ipcMain.handle('app:relaunch', async () => {
    const { app } = require('electron');
    // 开发模式（concurrently 同时起 vite + electron）下 relaunch()+exit() 会把整组
    // 子进程一起 SIGTERM 掉，vite dev server 也被杀 → 白屏。仅生产打包版执行真正重启；
    // 开发模式回传 devMode，由 UI 提示用户手动关闭并重跑 npm run electron:dev。
    if (!app.isPackaged) return { ok: true, devMode: true };
    app.relaunch();
    app.exit(0);
    return { ok: true };
  });

  // ====== 财务报表 PDF 导出（离屏 BrowserWindow + webContents.printToPDF）======
  // 前端传入「自包含打印 HTML」（内联 CSS、无 Tailwind/FontAwesome、用户文本已转义）；
  // 主进程用隐藏窗口渲染该 HTML → printToPDF → showSaveDialog → 写盘。不嵌字体
  // （Chromium 原生渲染 6 语言 CJK）；javascript:false 禁脚本执行，纯静态渲染。
  ipcMain.handle('app:exportReportPdf', async (_evt, payload) => {
    const { html, defaultFileName } = payload || {};
    if (!html || typeof html !== 'string') return { ok: false, error: 'NO_HTML' };
    const { app, BrowserWindow } = require('electron');
    const fs = require('node:fs');
    const path = require('node:path');
    let win = null;
    let tmpHtmlPath = null;
    try {
      // 写临时 HTML 再 loadFile（避免 data: URL 长度上限）
      tmpHtmlPath = path.join(app.getPath('temp'), `sololedger-report-${Date.now()}.html`);
      fs.writeFileSync(tmpHtmlPath, html, 'utf8');
      win = new BrowserWindow({
        show: false,
        webPreferences: { sandbox: true, contextIsolation: true, nodeIntegration: false, javascript: false },
      });
      await win.loadFile(tmpHtmlPath);
      const pdf = await win.webContents.printToPDF({ printBackground: true, pageSize: 'A4', margins: { marginType: 'default' } });
      const result = await dialog.showSaveDialog({
        title: '导出 PDF 报表',
        defaultPath: defaultFileName || `SoloLedger-report-${new Date().toISOString().slice(0, 10)}.pdf`,
        filters: [{ name: 'PDF', extensions: ['pdf'] }],
      });
      if (result.canceled || !result.filePath) return { ok: false };
      fs.writeFileSync(result.filePath, pdf);
      return { ok: true, path: result.filePath };
    } catch (e) {
      return { ok: false, error: e?.message || 'EXPORT_FAILED' };
    } finally {
      try { if (win && !win.isDestroyed()) win.destroy(); } catch { /* ignore */ }
      try { if (tmpHtmlPath && fs.existsSync(tmpHtmlPath)) fs.rmSync(tmpHtmlPath, { force: true }); } catch { /* ignore */ }
    }
  });

  console.log('[handlers] registered (api:request + providers:* + app:exportDb/importDb/relaunch/exportReportPdf)');

  // 启动横幅：打印当前主进程加载的 provider META
  // 调试时看到的 defaultModel 才是真正被使用的版本——前端再"新鲜"也得跟它对得上
  try {
    const aiCore = require('../ai');
    const list = aiCore.list();
    const EXPECTED_DEFAULTS = {
      anthropic: 'claude-sonnet-4-6',
      openai: 'gpt-5.5',
      gemini: 'gemini-3.5-flash',
    };
    console.log('[providers] loaded:');
    let stale = false;
    for (const p of list) {
      const models = (p.availableModels || []).map(m =>
        typeof m === 'string' ? `${m}(${m})` : `${m.label}(${m.value})`
      ).join(', ');
      const ok = EXPECTED_DEFAULTS[p.provider] === p.defaultModel;
      const tag = ok ? '✓' : '⚠ STALE';
      if (!ok) stale = true;
      console.log(`  - ${tag} ${p.provider.padEnd(10)} default=${String(p.defaultModel).padEnd(24)} available=[${models}]`);
    }
    if (stale) {
      console.warn('⚠ 检测到主进程加载的 default model 与预期不符 — 你可能在跑旧版 main 进程！请彻底重启：Ctrl+C 后再 npm run electron:dev');
    }
  } catch (e) {
    console.warn('[providers] preflight list failed:', e?.message || e);
  }
}

module.exports = { registerHandlers };
