// IPC handler 注册中心
// - api:request：业务路由分发（REST 风格）
// - providers:*：AI 服务商管理（list/save/remove/setDefault/test/hasAny）
// - app:*：应用级辅助（数据库导出/导入等）

const { dispatch } = require('./router');
const { IS_MAS } = require('../masBuild');
// MAS build: the AI/BYOK subsystem (electron/ai/**) is excluded from the package and
// never required. Guard the require so this file loads in a MAS bundle where ../ai is absent.
const aiCore = IS_MAS ? null : require('../ai');
const ecommerceCore = require('../ecommerce');
const { isDemoMode } = require('../db');
// §2A PR-1：把 SQLite/fs 写失败（磁盘满/IO/只读）归一化为稳定码，供备份·附件 catch 贴码。
// 仅用于 app:* 备份/附件路径；不触碰 api:request CRUD 保存路径（那是 PR-2 范围）。
const { diskErrorCode } = require('./_dbError');

function registerHandlers({ ipcMain, dialog }) {
  // ====== 业务统一路由 ======
  ipcMain.handle('api:request', async (_evt, req) => {
    try {
      return await dispatch(req || {});
    } catch (err) {
      // Electron IPC 不传 Error 自定义字段，故把【稳定 code】以 "AI_ERR:<code>" 前缀
      // 塞进 message，渲染端 services/aiErrors.ts 确定性提取后映射 i18n（aiError.*，随 uiLanguage）。
      // 不再外显本地化 friendly 中文——message 只保留英文调试信息（status / providerMessage）。
      const code = err?.code || 'unknown';
      const status = err?.status ? ` · HTTP ${err.status}` : '';
      const base = err?.providerMessage || err?.message || 'request failed';
      throw new Error(`AI_ERR:${code}${status} (${String(base).slice(0, 300)})`);
    }
  });

  // ====== AI Provider 管理 ======
  // MAS build: no external-AI / BYOK-API-key entry point ships — these channels are not
  // registered, so nothing in the Mac App Store binary can store/validate/use an API key.
  if (!IS_MAS) {
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
        // 回传【稳定 code】给 UI，由渲染端按 code 映射 i18n（aiError.*）；
        // 不再回传本地化 friendly 中文（providerMessage 为英文原文，仅供调试展示）。
        return {
          ok: false,
          code: err?.code || 'unknown',
          status: err?.status,
          providerMessage: err?.providerMessage,
          rawMessage: err?.message,
        };
      }
    });
  }

  // ====== 电商平台连接管理（MVP：仅连接设置 + 凭证 safeStorage 加密 + 测试连接）======
  // 明文凭证绝不回传渲染端；解密只在主进程 test 时发生。此处不做拉单/暂存/同步/写账本。
  ipcMain.handle('ecommerce:providers', async () => {
    return ecommerceCore.listProviders();
  });

  ipcMain.handle('ecommerce:list', async () => {
    return ecommerceCore.list();
  });

  ipcMain.handle('ecommerce:save', async (_evt, payload) => {
    return ecommerceCore.save(payload || {});
  });

  ipcMain.handle('ecommerce:setEnabled', async (_evt, payload) => {
    return ecommerceCore.setEnabled(payload || {});
  });

  ipcMain.handle('ecommerce:remove', async (_evt, payload) => {
    return ecommerceCore.remove(payload || {});
  });

  ipcMain.handle('ecommerce:test', async (_evt, payload) => {
    try {
      // Demo mode: answer OK in-process — never reach the network with a real provider.
      if (isDemoMode()) return { ok: true, storeInfo: { name: 'demo-store.local', domain: 'demo-store.local', currency: null } };
      // ecommerceCore.test already returns { ok, ... } (never throws for expected
      // auth/network failures); wrap only genuine exceptions (bad id / db).
      return await ecommerceCore.test(payload || {});
    } catch (err) {
      return { ok: false, code: err?.code || 'unknown', providerMessage: err?.message };
    }
  });

  // PR-EC3: pull orders → staging (NO ledger write). ecommerce:pull triggers a run;
  // ecommerce:staged / ecommerce:syncLog are read-only lists (never carry credentials).
  ipcMain.handle('ecommerce:pull', async (_evt, payload) => {
    try {
      const opts = { ...(payload || {}) };
      // Demo mode: pull the in-memory sample orders (no network, no credential decrypt).
      if (isDemoMode()) {
        opts.providers = require('../ecommerce/providers/demo').demoProviders();
        opts.creds = { demo: true };
      }
      const summary = await ecommerceCore.pull(opts.connectionId, opts);
      return { ok: true, ...summary };
    } catch (err) {
      return { ok: false, code: err?.code || 'unknown', message: err?.message };
    }
  });

  ipcMain.handle('ecommerce:staged', async (_evt, payload) => {
    return ecommerceCore.listStaged(payload || {});
  });

  ipcMain.handle('ecommerce:syncLog', async (_evt, payload) => {
    return ecommerceCore.listSyncLog(payload || {});
  });

  // PR-EC5a: commit selected staged orders → sales/sales_items (FIRST ledger write).
  // Two-pass all-or-nothing; per-order failures come back as machine codes in
  // result.errors (never a partial post). Genuine exceptions (bad connection id /
  // empty selection / db) surface as { ok:false }.
  ipcMain.handle('ecommerce:commit', async (_evt, payload) => {
    try {
      return { ok: true, ...ecommerceCore.commit(payload || {}) };
    } catch (err) {
      return { ok: false, code: err?.code || 'unknown', message: err?.message };
    }
  });

  // PR-EC5c: unlock a committed staged order whose posted sale was DELETED, so it can be
  // re-committed. Refuses (sale_still_exists) if the sale is still present. Updates ONLY the
  // staged row — no ledger / sync_log / cursor writes. Guard failures come back as { ok:false }.
  ipcMain.handle('ecommerce:unlockStaged', async (_evt, payload) => {
    try {
      return { ok: true, ...ecommerceCore.unlockStaged(payload || {}) };
    } catch (err) {
      return { ok: false, code: err?.code || 'unknown', message: err?.message };
    }
  });

  // Runtime info for the renderer — currently just the demo-mode flag (drives the demo banner).
  ipcMain.handle('app:runtimeInfo', async () => ({ demo: isDemoMode() }));

  // ====== 数据库备份 / 导出（文件夹 bundle：DB + 附件，§2A#3）======
  // 导出为一个文件夹（sololedger.db + attachments/docs/*），而非单 .db——否则换机导入后
  // tax_invoice_attachment_path 全部悬空。与 #152 启动自动备份同形，可互相恢复。
  ipcMain.handle('app:exportDb', async () => {
    const { getDbPath, getDataDir, getDb } = require('../db');
    const path = require('node:path');
    const { app } = require('electron');
    const { writeExportBundle } = require('./_backupBundle');
    const dbPath = getDbPath();
    // 加固：备份前先把 WAL 落盘到主库，否则最近已提交事务可能还在 -wal 里，单文件拷贝会丢。
    try { getDb().pragma('wal_checkpoint(TRUNCATE)'); } catch (e) { console.warn('[app:exportDb] checkpoint failed:', e?.message || e); }
    const result = await dialog.showSaveDialog({
      title: '导出账本数据（含附件）',
      // 默认落在「文稿」目录（持久、易找）。bundle 是文件夹，故默认名不带扩展名。
      defaultPath: path.join(app.getPath('documents'), `sololedger-backup-${new Date().toISOString().slice(0, 10)}`),
    });
    if (result.canceled || !result.filePath) return { ok: false };
    const res = writeExportBundle({ dbPath, userDataDir: getDataDir(), destDir: result.filePath });
    if (!res.ok) return { ok: false, error: diskErrorCode(res) || 'EXPORT_FAILED' };
    return { ok: true, path: res.path, attachments: res.attachments };
  });

  // ====== 数据库恢复 / 导入（文件夹 bundle 或旧单 .db，§2A#3）======
  // 安全顺序：选来源 → 解析(bundle/旧.db) → 校验(头/quick_check/关键表/版本) → 自动备份当前库
  //   → 关闭连接 → 原子替换 DB → 清旧 wal/shm → 合并附件(只增不删) → 引导重启。
  // DB 替换之前任何一步失败即中止；DB 替换成功后附件合并是 best-effort（只增不删、不回滚 DB）。
  ipcMain.handle('app:importDb', async () => {
    const fs = require('node:fs');
    const path = require('node:path');
    const { app } = require('electron');
    const { getDbPath, getDataDir, getDb, closeDb, SCHEMA_VERSION } = require('../db');
    const { resolveImportSource, mergeAttachments } = require('./_backupBundle');

    // 1. 选择 bundle 文件夹 或 旧单 .db 文件
    const sel = await dialog.showOpenDialog({
      title: '选择要恢复的账本备份（文件夹或 .db）',
      properties: ['openFile', 'openDirectory'],
      filters: [{ name: '账本备份 / SQLite 数据库', extensions: ['db'] }],
    });
    if (sel.canceled || !sel.filePaths || !sel.filePaths[0]) return { ok: false };
    const pickedPath = sel.filePaths[0];

    // 1b. 解析来源：文件夹 bundle（取内部 sololedger.db + attachments/docs）或旧单 .db
    const resolved = resolveImportSource(pickedPath);
    if (resolved.error) return { ok: false, error: resolved.error };
    const { dbSrc, attachSrc } = resolved;

    // 2. 校验 SQLite 文件头（前 16 字节应为 "SQLite format 3\0"）
    try {
      const fd = fs.openSync(dbSrc, 'r');
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
      probe = new Database(dbSrc, { readonly: true, fileMustExist: true });
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
    //    附件合并是「只增不删」，现有附件不会被破坏，故无需在此快照附件即构成完整回滚点。
    let autoBackupPath;
    try {
      try { getDb().pragma('wal_checkpoint(TRUNCATE)'); } catch { /* best effort */ }
      // demo-aware: derive from getDataDir() so a restore in demo mode snapshots the DEMO db into
      // userData/demo/backups (== userData/backups outside demo mode), never the real root.
      const backupsDir = path.join(getDataDir(), 'backups');
      if (!fs.existsSync(backupsDir)) fs.mkdirSync(backupsDir, { recursive: true });
      const stamp = new Date().toISOString().replace(/[:.]/g, '-');
      autoBackupPath = path.join(backupsDir, `sololedger-autobackup-before-restore-${stamp}.db`);
      fs.copyFileSync(dbPath, autoBackupPath);
    } catch (e) {
      return { ok: false, error: diskErrorCode(e) || 'AUTOBACKUP_FAILED' };
    }

    // 7. 关闭当前连接（checkpoint + close + null）
    try { closeDb(); } catch (e) { return { ok: false, error: diskErrorCode(e) || 'CLOSE_FAILED', autoBackupPath }; }

    // 8. 原子替换：先拷到同目录临时文件，再 rename 覆盖主库（同盘 rename 原子，防半成品）
    // 9. 删除旧的 -wal / -shm（属于旧库；留下会让 SQLite 用过期 WAL 覆盖新库 → 损坏）
    try {
      const tmpPath = dbPath + '.restore-tmp';
      fs.copyFileSync(dbSrc, tmpPath);
      fs.renameSync(tmpPath, dbPath);
      fs.rmSync(dbPath + '-wal', { force: true });
      fs.rmSync(dbPath + '-shm', { force: true });
    } catch (e) {
      return { ok: false, error: diskErrorCode(e) || 'REPLACE_FAILED', autoBackupPath };
    }

    // 10. 合并 bundle 附件进 userData/attachments/docs（只增不删；best-effort）。
    //     DB 已成功恢复，附件合并失败只记日志、不让整个恢复失败（缺失附件 UI 已优雅处理）。
    let attachmentsMerged = 0;
    if (attachSrc) {
      const m = mergeAttachments({ attachSrc, userDataDir: getDataDir() });
      attachmentsMerged = m.merged || 0;
      if (!m.ok) console.warn('[app:importDb] attachment merge failed:', m.error);
    }

    return { ok: true, restoredFrom: pickedPath, autoBackupPath, attachmentsMerged };
  });

  // ====== 结构化 CSV 导出（§2A：供会计师对接 / 迁出，per-table）======
  // 白名单表 → SELECT * → RFC4180+防注入 CSV → showSaveDialog → 写盘（带 UTF-8 BOM，Excel 识别中文）。
  ipcMain.handle('app:exportTableCsv', async (_evt, payload) => {
    const path = require('node:path');
    const fs = require('node:fs');
    const { app } = require('electron');
    const { getDb } = require('../db');
    const { tableToCsv } = require('./_csvExport');
    const table = payload && payload.table;
    let built;
    try {
      built = tableToCsv(getDb(), table);
    } catch (e) {
      return { ok: false, error: e?.message === 'INVALID_TABLE' ? 'INVALID_TABLE' : 'EXPORT_FAILED' };
    }
    const result = await dialog.showSaveDialog({
      title: '导出 CSV',
      defaultPath: path.join(app.getPath('documents'), `sololedger-${table}-${new Date().toISOString().slice(0, 10)}.csv`),
      filters: [{ name: 'CSV', extensions: ['csv'] }],
    });
    if (result.canceled || !result.filePath) return { ok: false };
    try {
      fs.writeFileSync(result.filePath, '\uFEFF' + built.csv, 'utf8'); // BOM：Excel 正确识别 UTF-8 中文
    } catch (e) {
      // §2A：磁盘满/IO/只读 → 可操作码（前端 errText 映射 systemError.*）；未命中保持 EXPORT_FAILED。
      return { ok: false, error: diskErrorCode(e) || 'EXPORT_FAILED' };
    }
    return { ok: true, path: result.filePath, rows: built.rows };
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

  // ====== 业务单据附件（Phase D：正式税务发票附件，仅记录外部开具的发票文件）======
  // 选择附件：复制一份进 userData/attachments/docs/（用户原文件永不移动/删除），
  // 只复制不落库——相对路径由前端经 PUT /api/documents/:id/tax-invoice 统一持久化
  // （单一写路径：作废锁/路径校验集中在 documents handler）。
  ipcMain.handle('app:pickDocAttachment', async (_evt, payload) => {
    const fs = require('node:fs');
    const path = require('node:path');
    const { getDocsAttachmentsRoot } = require('./attachments');
    const ALLOWED_EXTS = ['.pdf', '.jpg', '.jpeg', '.png'];
    const MAX_BYTES = 20 * 1024 * 1024; // 20 MB
    try {
      const sel = await dialog.showOpenDialog({
        title: '选择发票附件',
        properties: ['openFile'],
        filters: [{ name: 'PDF / 图片', extensions: ['pdf', 'jpg', 'jpeg', 'png'] }],
      });
      if (sel.canceled || !sel.filePaths || !sel.filePaths[0]) return { ok: false }; // 取消静默（#96 惯例）
      const srcPath = sel.filePaths[0];
      const ext = path.extname(srcPath).toLowerCase();
      if (!ALLOWED_EXTS.includes(ext)) return { ok: false, error: 'INVALID_FILE_TYPE' };
      const stat = fs.statSync(srcPath);
      if (!stat.isFile()) return { ok: false, error: 'INVALID_FILE_TYPE' };
      if (stat.size > MAX_BYTES) return { ok: false, error: 'FILE_TOO_LARGE' };

      const root = getDocsAttachmentsRoot();
      fs.mkdirSync(root, { recursive: true });
      // 唯一文件名：清洗后的单据 id + 时间戳 + 随机后缀。首字符强制字母数字
      // （与 attachments.js 的 REL_RE 白名单严格一致，生成的名字必能通过校验）；
      // 随机后缀防同毫秒重选碰撞。
      const rawId = String((payload && payload.docId) || 'doc')
        .replace(/[^A-Za-z0-9_-]/g, '').replace(/^[_-]+/, '').slice(0, 40);
      const docId = rawId || 'doc';
      const name = `${docId}-${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}${ext}`;
      fs.copyFileSync(srcPath, path.join(root, name));
      return { ok: true, relPath: `attachments/docs/${name}`, fileName: path.basename(srcPath) };
    } catch (e) {
      return { ok: false, error: diskErrorCode(e) || 'COPY_FAILED' };
    }
  });

  // 打开附件：白名单正则 + resolve 包含双校验后交给系统默认应用
  ipcMain.handle('app:openDocAttachment', async (_evt, payload) => {
    const fs = require('node:fs');
    const { shell } = require('electron');
    const { resolveAttachment } = require('./attachments');
    try {
      const abs = resolveAttachment(payload && payload.relPath);
      if (!abs) return { ok: false, error: 'INVALID_PATH' };
      if (!fs.existsSync(abs)) return { ok: false, error: 'ATTACHMENT_NOT_FOUND' };
      const err = await shell.openPath(abs);
      if (err) return { ok: false, error: 'OPEN_FAILED' };
      return { ok: true };
    } catch (e) {
      return { ok: false, error: 'OPEN_FAILED' };
    }
  });

  // 丢弃未保存的附件副本（选了又取消/重选时的清理）。
  // DB 引用守卫：被任何单据引用的文件拒绝删除（ATTACHMENT_IN_USE）——
  // 该渲染端可触达的删除通道在构造上无法删掉已保存的关联附件。
  ipcMain.handle('app:discardDocAttachment', async (_evt, payload) => {
    const { resolveAttachment, safeDeleteAttachment } = require('./attachments');
    const { getDb } = require('../db');
    try {
      const rel = payload && payload.relPath;
      const abs = resolveAttachment(rel);
      if (!abs) return { ok: false, error: 'INVALID_PATH' };
      const referenced = getDb()
        .prepare('SELECT 1 FROM business_documents WHERE tax_invoice_attachment_path = ? LIMIT 1')
        .get(rel);
      if (referenced) return { ok: false, error: 'ATTACHMENT_IN_USE' };
      safeDeleteAttachment(rel);
      return { ok: true };
    } catch (e) {
      return { ok: false, error: diskErrorCode(e) || 'DISCARD_FAILED' };
    }
  });

  console.log(`[handlers] registered (api:request + ${IS_MAS ? '' : 'providers:* + '}ecommerce:* + app:exportDb/importDb/relaunch/exportReportPdf + app:pickDocAttachment/openDocAttachment/discardDocAttachment)${IS_MAS ? ' — MAS build: AI/BYOK subsystem excluded' : ''}`);

  // 启动横幅（仅开发/调试）：打印当前主进程加载的 provider META，便于确认实际使用的 defaultModel。
  // 不再做 STALE 比对 / 「旧版 main 进程」告警——provider 默认值一致性由 check:providers 在 lint 期保证；
  // 运行时比对既无法真正检出旧版 main（loaded metas 与常量同源），又会对国产 provider 误报。
  // MAS build: no AI subsystem to introspect — skip entirely.
  if (!IS_MAS) {
    try {
      const { app } = require('electron');
      if (!app.isPackaged) {
        const list = aiCore.list();
        console.log('[providers] loaded:');
        for (const p of list) {
          const models = (p.availableModels || []).map(m =>
            typeof m === 'string' ? `${m}(${m})` : `${m.label}(${m.value})`
          ).join(', ');
          console.log(`  - ${p.provider.padEnd(10)} default=${String(p.defaultModel).padEnd(24)} available=[${models}]`);
        }
      }
    } catch (e) {
      console.warn('[providers] preflight list failed:', e?.message || e);
    }
  }
}

module.exports = { registerHandlers };
