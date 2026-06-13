// 跨 provider 共享的错误解析（R3c）
// 目标：把各家不同结构的错误归一化为带【稳定 code】的 Error（code ∈ 有限枚举）。
// 不再生成本地化中文 friendly 串——渲染端按 code 映射到 i18n（aiError.*），
// 错误文案随 uiLanguage。message 仅保留英文调试信息（label/status/code/providerMessage）。

// 稳定错误码枚举（与渲染端 services/aiErrors.ts + i18n aiError.* 对齐）。camelCase = i18n leaf。
const AI_ERROR_CODES = [
  'noProvider', 'auth', 'permission', 'quota', 'modelNotFound',
  'badRequest', 'serverError', 'parseFailed', 'network', 'timeout', 'unknown',
];

async function readBody(response) {
  try {
    const text = await response.text();
    try { return { json: JSON.parse(text), text }; } catch { return { json: null, text }; }
  } catch {
    return { json: null, text: '' };
  }
}

function pickField(obj, ...candidates) {
  for (const path of candidates) {
    const segs = path.split('.');
    let cur = obj;
    let ok = true;
    for (const s of segs) {
      if (cur && typeof cur === 'object' && s in cur) cur = cur[s];
      else { ok = false; break; }
    }
    if (ok && cur != null && cur !== '') return cur;
  }
  return undefined;
}

// 由 HTTP status + 原始 code/message 归一化到稳定枚举。
function normalizeCode(status, rawCode, message) {
  const m = `${rawCode || ''} ${message || ''}`.toLowerCase();
  if (status === 401 || /invalid_api_key|unauthorized/.test(m)) return 'auth';
  if (status === 403 || /permission|forbidden/.test(m)) return 'permission';
  if (status === 429 || status === 402 || /rate_limit|quota|exceeded|insufficient_quota|insufficient.?balance|spending.?cap/.test(m)) return 'quota';
  if (status === 404 || /model.*not.*found|invalid_model|unknown.*model|does.*not.*exist|not.*supported/.test(m)) return 'modelNotFound';
  if (status === 400 || /invalid_request|bad_request/.test(m)) return 'badRequest';
  if (typeof status === 'number' && status >= 500) return 'serverError';
  return 'unknown';
}

// 用于 fetch 非 2xx 响应；返回的 Error 含 status / code（稳定枚举）/ providerMessage 字段。
async function buildHttpError(response, providerLabel) {
  const { json, text } = await readBody(response);
  const status = response.status;

  // 各家错误字段位置不同：
  // OpenAI:    { error: { message, code, type } }
  // Anthropic: { type: "error", error: { type, message } }
  // Gemini:    { error: { code, message, status } }
  const rawCode = pickField(json,
    'error.code', 'error.type', 'error.status',
    'code', 'type', 'status'
  );
  const providerMessage = pickField(json,
    'error.message', 'message', 'error.error.message'
  ) || (text ? text.slice(0, 300) : `HTTP ${status}`);

  const code = normalizeCode(status, rawCode != null ? String(rawCode) : '', String(providerMessage));
  const err = new Error(
    `${providerLabel} ${status} [${code}] (${String(providerMessage).slice(0, 200)})`
  );
  err.status = status;
  err.code = code;
  err.providerMessage = String(providerMessage);
  err.providerLabel = providerLabel;
  return err;
}

// 用于网络错误（fetch 抛错、超时、连接失败等）。
function wrapNetworkError(err, providerLabel) {
  const msg = err?.message || String(err);
  const e = new Error(`${providerLabel} network error [network] (${msg})`);
  e.code = 'network';
  e.providerMessage = msg;
  e.providerLabel = providerLabel;
  return e;
}

// 用于 provider 返回内容解析失败（非 HTTP 错误，如 JSON / OCR 解析为空）。
function parseError(providerLabel, detail) {
  const e = new Error(`${providerLabel} parse failed [parseFailed]${detail ? ' (' + detail + ')' : ''}`);
  e.code = 'parseFailed';
  e.providerLabel = providerLabel;
  return e;
}

module.exports = { buildHttpError, wrapNetworkError, parseError, normalizeCode, AI_ERROR_CODES };
