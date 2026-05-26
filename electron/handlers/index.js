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
    const { getDbPath } = require('../db');
    const dbPath = getDbPath();
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

  console.log('[handlers] registered (api:request + providers:* + app:exportDb)');

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
