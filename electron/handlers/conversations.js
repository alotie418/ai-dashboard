// AI 助手会话持久化 handler（R4a-1）。仅存聊天历史 —— 绝不存 API Key 或任何解密密钥。
// tool_trace 存的是 R2b 已脱敏的工具轨迹（名/参数摘要/行数/截断），无原始结果、无明细。
// 仅读写 assistant_conversations / assistant_messages 两表（不碰任何业务表）。

const { getDb } = require('../db');

function safeString(v, maxLen = 4000) {
  if (v == null) return '';
  return String(v).slice(0, maxLen);
}

function genId() {
  return `conv-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
}

// 标题：取首条用户消息前 40 字符（折叠空白），空则留 null（前端显示「新对话」）。
function deriveTitle(text) {
  const t = safeString(text, 200).replace(/\s+/g, ' ').trim();
  return t.slice(0, 40) || null;
}

function tryParseTrace(s) {
  if (!s) return undefined;
  try { const v = JSON.parse(s); return Array.isArray(v) ? v : undefined; } catch { return undefined; }
}

// GET /api/conversations — 会话头列表（最近更新在前）
async function list() {
  const db = getDb();
  return db.prepare(
    `SELECT id, title, acc_locale, ui_language, created_at, updated_at
       FROM assistant_conversations
      ORDER BY updated_at DESC, created_at DESC`
  ).all();
}

// POST /api/conversations — 新建空会话（懒建：前端首次发消息时调用）
async function create({ body }) {
  const db = getDb();
  const id = genId();
  db.prepare(
    'INSERT INTO assistant_conversations (id, title, acc_locale, ui_language) VALUES (?, ?, ?, ?)'
  ).run(
    id,
    body?.title ? safeString(body.title, 200) : null,
    safeString(body?.accLocale || '', 16) || null,
    safeString(body?.uiLanguage || '', 16) || null,
  );
  return { id };
}

// GET /api/conversations/:id/messages — 某会话全部消息（按 seq）
async function messages({ params }) {
  const db = getDb();
  const rows = db.prepare(
    'SELECT role, text, tool_trace FROM assistant_messages WHERE conversation_id = ? ORDER BY seq, id'
  ).all(params.id);
  return rows.map(r => {
    const toolTrace = tryParseTrace(r.tool_trace);
    return toolTrace ? { role: r.role, text: r.text, toolTrace } : { role: r.role, text: r.text };
  });
}

// POST /api/conversations/:id/messages — 追加一条消息 + 更新 updated_at（首条 user 自动标题）
async function appendMessage({ params, body }) {
  const db = getDb();
  const convId = params.id;
  const exists = db.prepare('SELECT title FROM assistant_conversations WHERE id = ?').get(convId);
  if (!exists) throw new Error('Conversation not found');

  const role = body?.role === 'model' ? 'model' : 'user';
  const text = safeString(body?.text, 100000);
  const toolTrace = Array.isArray(body?.toolTrace) && body.toolTrace.length
    ? JSON.stringify(body.toolTrace)
    : null;

  const tx = db.transaction(() => {
    const seqRow = db.prepare(
      'SELECT COALESCE(MAX(seq), 0) AS m FROM assistant_messages WHERE conversation_id = ?'
    ).get(convId);
    const seq = (seqRow?.m || 0) + 1;
    db.prepare(
      'INSERT INTO assistant_messages (conversation_id, role, text, tool_trace, seq) VALUES (?, ?, ?, ?, ?)'
    ).run(convId, role, text, toolTrace, seq);

    // 首条 user 消息且会话尚无标题 → 自动标题；其余只刷新 updated_at。
    if (role === 'user' && !exists.title) {
      const title = deriveTitle(text);
      db.prepare("UPDATE assistant_conversations SET title = ?, updated_at = datetime('now') WHERE id = ?")
        .run(title, convId);
    } else {
      db.prepare("UPDATE assistant_conversations SET updated_at = datetime('now') WHERE id = ?")
        .run(convId);
    }
  });
  tx();
  return { ok: true };
}

// DELETE /api/conversations/:id — 删除会话（CASCADE 删其消息）。用于「清空当前对话」。
async function remove({ params }) {
  const db = getDb();
  db.prepare('DELETE FROM assistant_conversations WHERE id = ?').run(params.id);
  return { ok: true };
}

module.exports = { list, create, messages, appendMessage, remove };
