// AI Provider 统一接口
// - 管理面：list / save / remove / setDefault / test
// - 业务面：analyze / ocr / chat / tts
//
// API Key 全程加密：safeStorage encrypt → base64 → ai_providers.api_key_encrypted
// 渲染端永远拿不到明文，主进程从 DB 解密后注入到 provider adapter

const { getDb } = require('../db');

const anthropic = require('./providers/anthropic');
const openai = require('./providers/openai');
const gemini = require('./providers/gemini');
const deepseek = require('./providers/deepseek');
const qwen = require('./providers/qwen');
const kimi = require('./providers/kimi');
const glm = require('./providers/glm');
const doubao = require('./providers/doubao');

const PROVIDERS = {
  anthropic,
  openai,
  gemini,
  deepseek,
  qwen,
  kimi,
  glm,
  doubao,
};

const VALID_IDS = Object.keys(PROVIDERS);

// 旧模型 ID → 新模型 ID 映射
// 只在自动迁移用，不会出现在 UI availableModels 里
const MODEL_MIGRATION_MAP = {
  // Gemini
  'gemini-2.0-flash': 'gemini-3.5-flash',
  'gemini-1.5-flash': 'gemini-3.5-flash',
  'gemini-1.5-pro': 'gemini-3.5-flash',
  // Anthropic
  'claude-3-5-sonnet-latest': 'claude-sonnet-4-6',
  'claude-sonnet-4-5': 'claude-sonnet-4-6',
  'claude-opus-4-5': 'claude-opus-4-7',
  'claude-haiku-4-5': 'claude-sonnet-4-6',
  // OpenAI
  'gpt-4o': 'gpt-5.5',
  'gpt-4o-mini': 'gpt-5.5',
  'gpt-4.1': 'gpt-5.5',
  'gpt-4.1-mini': 'gpt-5.5',
};

function migrateOldModels(db) {
  for (const [oldId, newId] of Object.entries(MODEL_MIGRATION_MAP)) {
    const info = db.prepare('UPDATE ai_providers SET model = ?, updated_at = datetime(\'now\') WHERE model = ?').run(newId, oldId);
    if (info.changes > 0) {
      console.log(`[ai] migrated model "${oldId}" → "${newId}" (${info.changes} row)`);
    }
  }
}

// 自愈：每次访问前确保表存在（用户从旧版升级时 v2 migration 若未跑也能兜底）
function ensureTable() {
  const db = getDb();
  if (!db) throw new Error('数据库未初始化');
  db.exec(`
    CREATE TABLE IF NOT EXISTS ai_providers (
      provider TEXT PRIMARY KEY,
      api_key_encrypted TEXT NOT NULL,
      model TEXT,
      enabled INTEGER DEFAULT 1,
      is_default INTEGER DEFAULT 0,
      created_at TEXT DEFAULT (datetime('now')),
      updated_at TEXT DEFAULT (datetime('now'))
    );
  `);
  // 顺手做一次旧 key 平滑迁移（仅当存在 legacy 且 ai_providers 还没有 gemini 行）
  const legacy = db.prepare("SELECT value FROM settings WHERE key = 'gemini_key_encrypted'").get();
  if (legacy?.value) {
    const has = db.prepare("SELECT 1 FROM ai_providers WHERE provider = 'gemini'").get();
    if (!has) {
      db.prepare(`
        INSERT INTO ai_providers (provider, api_key_encrypted, model, enabled, is_default, updated_at)
        VALUES ('gemini', ?, 'gemini-3.5-flash', 1, 1, datetime('now'))
      `).run(legacy.value);
      db.prepare("DELETE FROM settings WHERE key = 'gemini_key_encrypted'").run();
    }
  }

  // 迁移本地存的旧 model ID 到新 ID（不可逆，但旧模型本就不能用）
  migrateOldModels(db);
}

function getSafeStorage() {
  return require('electron').safeStorage;
}

function encryptKey(plain) {
  const ss = getSafeStorage();
  if (!ss.isEncryptionAvailable()) throw new Error('safeStorage 不可用，无法加密 API Key');
  return ss.encryptString(plain).toString('base64');
}

function decryptKey(encrypted) {
  const ss = getSafeStorage();
  if (!ss.isEncryptionAvailable()) throw new Error('safeStorage 不可用，无法解密 API Key');
  return ss.decryptString(Buffer.from(encrypted, 'base64'));
}

// ============================================================
// 管理面
// ============================================================

function list() {
  ensureTable();
  const db = getDb();
  const rows = db.prepare('SELECT provider, model, enabled, is_default FROM ai_providers').all();
  const byId = Object.fromEntries(rows.map(r => [r.provider, r]));

  // 返回所有支持的 provider（即使未配置），方便前端展示完整列表
  return VALID_IDS.map(id => {
    const adapter = PROVIDERS[id];
    const meta = adapter.meta;
    const row = byId[id];
    const currentModel = row?.model || meta.defaultModel;
    // 判断当前 model 是否在白名单里（用户可能输入了自定义 ID）
    const matched = meta.availableModels.find(m => m.value === currentModel);
    const modelLabel = matched ? matched.label : `${currentModel}（自定义）`;
    return {
      provider: id,
      name: meta.name,
      hasKey: !!row,
      model: currentModel,
      modelLabel,
      modelIsKnown: !!matched,
      availableModels: meta.availableModels,
      defaultModel: meta.defaultModel,
      enabled: row ? !!row.enabled : false,
      isDefault: row ? !!row.is_default : false,
      supportsOCR: meta.capabilities.ocr,
      supportsWebGrounding: meta.capabilities.webGrounding,
    };
  });
}

function hasAny() {
  ensureTable();
  const db = getDb();
  const row = db.prepare('SELECT COUNT(*) as c FROM ai_providers WHERE enabled = 1').get();
  return row.c > 0;
}

function save({ provider, apiKey, model, enabled = true, setAsDefault = false }) {
  if (!VALID_IDS.includes(provider)) throw new Error(`Unknown provider: ${provider}`);

  ensureTable();
  const db = getDb();
  const meta = PROVIDERS[provider].meta;
  const finalModel = model || meta.defaultModel;

  // apiKey 留空表示"沿用现有 Key 只更新 model / 默认设置"
  // 这样用户在设置页换模型不必重新粘贴 Key
  let encrypted;
  if (apiKey && typeof apiKey === 'string' && apiKey.trim()) {
    encrypted = encryptKey(apiKey.trim());
  } else {
    const existing = db.prepare('SELECT api_key_encrypted FROM ai_providers WHERE provider = ?').get(provider);
    if (!existing) {
      throw new Error('该 Provider 尚未配置 API Key，请先输入 Key 再保存');
    }
    encrypted = existing.api_key_encrypted;
  }

  // 若是首个 provider，自动设为默认
  const existingCount = db.prepare('SELECT COUNT(*) as c FROM ai_providers').get().c;
  const shouldBeDefault = setAsDefault || existingCount === 0;

  const tx = db.transaction(() => {
    if (shouldBeDefault) {
      db.prepare('UPDATE ai_providers SET is_default = 0').run();
    }
    db.prepare(`
      INSERT INTO ai_providers (provider, api_key_encrypted, model, enabled, is_default, updated_at)
      VALUES (?, ?, ?, ?, ?, datetime('now'))
      ON CONFLICT(provider) DO UPDATE SET
        api_key_encrypted = excluded.api_key_encrypted,
        model = excluded.model,
        enabled = excluded.enabled,
        is_default = CASE WHEN ? THEN 1 ELSE is_default END,
        updated_at = datetime('now')
    `).run(provider, encrypted, finalModel, enabled ? 1 : 0, shouldBeDefault ? 1 : 0, shouldBeDefault ? 1 : 0);
  });
  tx();

  return { success: true };
}

function remove({ provider }) {
  if (!VALID_IDS.includes(provider)) throw new Error(`Unknown provider: ${provider}`);
  ensureTable();
  const db = getDb();
  const wasDefault = db.prepare('SELECT is_default FROM ai_providers WHERE provider = ?').get(provider)?.is_default;
  db.prepare('DELETE FROM ai_providers WHERE provider = ?').run(provider);
  // 若删的是默认 provider，把剩下第一个启用的设为默认
  if (wasDefault) {
    const next = db.prepare('SELECT provider FROM ai_providers WHERE enabled = 1 ORDER BY updated_at DESC LIMIT 1').get();
    if (next) {
      db.prepare('UPDATE ai_providers SET is_default = 1 WHERE provider = ?').run(next.provider);
    }
  }
  return { success: true };
}

function setDefault({ provider }) {
  if (!VALID_IDS.includes(provider)) throw new Error(`Unknown provider: ${provider}`);
  ensureTable();
  const db = getDb();
  const row = db.prepare('SELECT 1 FROM ai_providers WHERE provider = ?').get(provider);
  if (!row) throw new Error('该 Provider 尚未配置 API Key');
  const tx = db.transaction(() => {
    db.prepare('UPDATE ai_providers SET is_default = 0').run();
    db.prepare('UPDATE ai_providers SET is_default = 1 WHERE provider = ?').run(provider);
  });
  tx();
  return { success: true };
}

async function test({ provider, apiKey, model }) {
  if (!VALID_IDS.includes(provider)) throw new Error(`Unknown provider: ${provider}`);
  const adapter = PROVIDERS[provider];
  // apiKey 留空 = 已配置的 provider 想用本地已保存的 Key 测试连接（不必重新粘贴 Key）。
  // 解密只发生在主进程并直接注入 adapter，明文 Key 绝不回传渲染端（与 getDefaultRecord 同源）。
  let key = (apiKey && typeof apiKey === 'string') ? apiKey.trim() : '';
  if (!key) {
    ensureTable();
    const existing = getDb().prepare('SELECT api_key_encrypted FROM ai_providers WHERE provider = ?').get(provider);
    if (!existing) throw new Error('apiKey is required for test');
    key = decryptKey(existing.api_key_encrypted);
  }
  return await adapter.test(key, model);
}

// ============================================================
// 业务面 — 自动取默认 provider，找不到则提示
// ============================================================

function getDefaultRecord() {
  ensureTable();
  const db = getDb();
  let row = db.prepare(
    'SELECT provider, api_key_encrypted, model FROM ai_providers WHERE is_default = 1 AND enabled = 1'
  ).get();
  // 兜底：如果没有 default 但存在 enabled 的，取最新
  if (!row) {
    row = db.prepare(
      'SELECT provider, api_key_encrypted, model FROM ai_providers WHERE enabled = 1 ORDER BY updated_at DESC LIMIT 1'
    ).get();
  }
  if (!row) {
    const err = new Error('No AI provider configured [noProvider]');
    err.code = 'noProvider';
    throw err;
  }
  return {
    provider: row.provider,
    apiKey: decryptKey(row.api_key_encrypted),
    model: row.model,
  };
}

// OCR provider selection (PR-3b): OCR follows whichever CONFIGURED provider supports it (using that
// provider's own key) — the default provider first if it is OCR-capable, else a priority fallback.
// No separate OCR key. Text features keep using getDefaultRecord() unchanged, so the text default
// provider is never affected. Returns the same { provider, apiKey(decrypted), model } shape; the key
// is decrypted in main and injected into the adapter, never leaving the main process.
function getOcrRecord() {
  ensureTable();
  const db = getDb();
  const rows = db.prepare(
    'SELECT provider, api_key_encrypted, model, is_default FROM ai_providers WHERE enabled = 1'
  ).all();
  const candidates = rows.map(r => ({
    provider: r.provider,
    isDefault: !!r.is_default,
    ocrCapable: PROVIDERS[r.provider]?.meta?.capabilities?.ocr === true,
    _enc: r.api_key_encrypted,
    _model: r.model,
  }));
  const { pickOcrProvider } = require('./ocrSelect');
  const pickedId = pickOcrProvider(candidates);
  if (!pickedId) {
    const err = new Error('No OCR-capable provider configured [noProvider]');
    err.code = 'noProvider';
    throw err;
  }
  const picked = candidates.find(c => c.provider === pickedId);
  return { provider: pickedId, apiKey: decryptKey(picked._enc), model: picked._model };
}

async function analyze(body) {
  const rec = getDefaultRecord();
  return PROVIDERS[rec.provider].analyze(rec.apiKey, rec.model, body);
}

async function ocr(body) {
  const rec = getOcrRecord();
  const { buildPrompt } = require('./ocrPromptBuilder');
  const prompt = buildPrompt(body.accountingLocale || 'CN', body.uiLanguage || 'zh-CN');
  return PROVIDERS[rec.provider].ocr(rec.apiKey, rec.model, { ...body, ocrPrompt: prompt });
}

async function chat(body) {
  const rec = getDefaultRecord();
  return PROVIDERS[rec.provider].chat(rec.apiKey, rec.model, body);
}

// 只读查账 agent 对话（R2b-1）。agent loop 跑在主进程，解密后的 API Key 仅注入 adapter、
// 全程不出主进程。R2b-1 仅 Anthropic 实现工具调用；其余 provider 优雅回退普通 chat（无工具），
// 返回同样的 { text, toolTrace } 形状，渲染端无需区分。
async function agentChat(body) {
  const rec = getDefaultRecord();
  const adapter = PROVIDERS[rec.provider];
  if (typeof adapter.chatWithTools !== 'function') {
    const r = await adapter.chat(rec.apiKey, rec.model, body);
    return { text: r.text || '', toolTrace: [] };
  }
  const { runAgentLoop } = require('./agent');
  const history = typeof adapter.toNativeHistory === 'function'
    ? adapter.toNativeHistory(body.messages)
    : (body.messages || []);
  return runAgentLoop({
    adapter,
    apiKey: rec.apiKey,
    model: rec.model,
    history,
    system: body.systemInstruction || '',
  });
}

// 语音功能（TTS / Live Audio）已于 AI 助手重设计 R1 移除——
// 不再暴露 tts()/liveKey()（明文 key 出主进程的安全洞随之消除）。

module.exports = {
  // 管理面
  list, hasAny, save, remove, setDefault, test,
  // 业务面
  analyze, ocr, chat, agentChat,
};
