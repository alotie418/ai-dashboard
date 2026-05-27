// AI Provider 统一接口
// - 管理面：list / save / remove / setDefault / test
// - 业务面：analyze / ocr / chat / tts / dataAnalysis
//
// API Key 全程加密：safeStorage encrypt → base64 → ai_providers.api_key_encrypted
// 渲染端永远拿不到明文，主进程从 DB 解密后注入到 provider adapter

const { getDb } = require('../db');

const anthropic = require('./providers/anthropic');
const openai = require('./providers/openai');
const gemini = require('./providers/gemini');

const PROVIDERS = {
  anthropic,
  openai,
  gemini,
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
      supportsTTS: meta.capabilities.tts,
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
  if (!apiKey) throw new Error('apiKey is required for test');
  const adapter = PROVIDERS[provider];
  return await adapter.test(apiKey.trim(), model);
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
    const err = new Error('尚未配置任何 AI Provider，请在「系统设置 → AI 服务商」中添加 API Key');
    err.code = 'NO_PROVIDER';
    throw err;
  }
  return {
    provider: row.provider,
    apiKey: decryptKey(row.api_key_encrypted),
    model: row.model,
  };
}

// 找一个支持指定能力的 provider（如 TTS 只有 Gemini 支持）
function getRecordForCapability(capability) {
  ensureTable();
  const db = getDb();
  const candidates = db.prepare('SELECT provider, api_key_encrypted, model FROM ai_providers WHERE enabled = 1 ORDER BY is_default DESC, updated_at DESC').all();
  for (const row of candidates) {
    const meta = PROVIDERS[row.provider]?.meta;
    if (meta?.capabilities?.[capability]) {
      return {
        provider: row.provider,
        apiKey: decryptKey(row.api_key_encrypted),
        model: row.model,
      };
    }
  }
  return null;
}

async function analyze(body) {
  const rec = getDefaultRecord();
  return PROVIDERS[rec.provider].analyze(rec.apiKey, rec.model, body);
}

async function ocr(body) {
  const rec = getDefaultRecord();
  const { buildPrompt } = require('./ocrPromptBuilder');
  const prompt = buildPrompt(body.accountingLocale || 'CN', body.uiLanguage || 'zh-CN');
  return PROVIDERS[rec.provider].ocr(rec.apiKey, rec.model, { ...body, ocrPrompt: prompt });
}

async function chat(body) {
  const rec = getDefaultRecord();
  return PROVIDERS[rec.provider].chat(rec.apiKey, rec.model, body);
}

async function tts(body) {
  // TTS 只 Gemini 支持，优先找支持的 provider；找不到给清晰错误
  const rec = getRecordForCapability('tts');
  if (!rec) {
    const err = new Error('当前所有已配置的 Provider 都不支持 TTS。请配置 Gemini API Key 以使用语音功能。');
    err.code = 'NO_CAPABILITY';
    throw err;
  }
  return PROVIDERS[rec.provider].tts(rec.apiKey, rec.model, body);
}

async function dataAnalysis(body) {
  const rec = getDefaultRecord();
  return PROVIDERS[rec.provider].dataAnalysis(rec.apiKey, rec.model, body);
}

// 兼容旧的 /api/ai/live-key（仅 Gemini 支持 Live Audio）
function liveKey() {
  const rec = getRecordForCapability('tts'); // tts == gemini
  if (!rec) {
    const err = new Error('Live Audio 需要 Gemini API Key');
    err.code = 'NO_CAPABILITY';
    throw err;
  }
  return { key: rec.apiKey, provider: rec.provider, model: rec.model };
}

module.exports = {
  // 管理面
  list, hasAny, save, remove, setDefault, test,
  // 业务面
  analyze, ocr, chat, tts, dataAnalysis, liveKey,
};
