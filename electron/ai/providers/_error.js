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

// 对疑似密钥/令牌片段脱敏：只替换敏感子串，保留其余调试信息（不吞错误、不改 code/status）。
// 覆盖 Authorization: Bearer、sk-/sk-ant- 前缀（OpenAI/Anthropic/DeepSeek/Kimi/Qwen 等）、
// JWT（含 GLM/智谱签名令牌）、以及 api_key/token/secret/authorization 字段后的取值。
function redactSecrets(input) {
  if (input == null) return input;
  return String(input)
    .replace(/Bearer\s+[A-Za-z0-9._~+/=-]+/gi, 'Bearer [REDACTED]')
    .replace(/sk-(?:ant-)?[A-Za-z0-9._-]{6,}/gi, 'sk-[REDACTED]')
    .replace(/eyJ[A-Za-z0-9._-]{8,}\.[A-Za-z0-9._-]{8,}\.[A-Za-z0-9._-]{8,}/g, '[REDACTED_JWT]')
    .replace(/("?(?:api[_-]?key|access[_-]?token|authorization|secret|token)"?\s*[:=]\s*"?)([A-Za-z0-9._-]{6,})/gi, '$1[REDACTED]');
}

// 由 HTTP status + 原始 code/message 归一化到稳定枚举。
function normalizeCode(status, rawCode, message) {
  const m = `${rawCode || ''} ${message || ''}`.toLowerCase();
  if (status === 401 || /invalid_api_key|unauthorized/.test(m)) return 'auth';
  if (status === 403 || /permission|forbidden/.test(m)) return 'permission';
  if (status === 429 || status === 402 || /rate_limit|quota|exceeded|insufficient_quota|insufficient.?balance|spending.?cap/.test(m)) return 'quota';
  if (status === 404 || /model.*not.*(found|exist)|invalid[_ ]model|unknown.*model|unsupported.*model|does.*not.*exist|not.*supported|模型不存在|模型不可用|模型不支持/.test(m)) return 'modelNotFound';
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
  const rawProviderMessage = pickField(json,
    'error.message', 'message', 'error.error.message'
  ) || (text ? text.slice(0, 300) : `HTTP ${status}`);

  // code 用原始文案分类（最准确）；对外/日志展示的 message 与 providerMessage 做密钥脱敏。
  const code = normalizeCode(status, rawCode != null ? String(rawCode) : '', String(rawProviderMessage));
  const providerMessage = redactSecrets(String(rawProviderMessage));
  const err = new Error(
    `${providerLabel} ${status} [${code}] (${String(providerMessage).slice(0, 200)})`
  );
  err.status = status;
  err.code = code;
  err.providerMessage = providerMessage;
  err.providerLabel = providerLabel;
  return err;
}

// 用于「HTTP 2xx 但响应体其实是错误/无可用内容」的情况：不少 OpenAI 兼容服务商会把
// 「模型不可用 / 余额不足」等塞进 200 响应体（而非 4xx）。据此从已解析的 body 归一化出
// 带【稳定 code】的 Error，并对外/日志展示的 providerMessage 做密钥脱敏 + 截断。
// status 设为 undefined（这并非真正的 HTTP 错误状态），分类完全依赖 body 里的 code/message。
function buildBodyError(json, providerLabel) {
  const rawCode = pickField(json, 'error.code', 'error.type', 'error.status', 'code', 'type', 'status');
  const rawMessage = pickField(json, 'error.message', 'message', 'error.error.message')
    || (json != null ? JSON.stringify(json).slice(0, 300) : 'empty response');
  const code = normalizeCode(undefined, rawCode != null ? String(rawCode) : '', String(rawMessage));
  const providerMessage = redactSecrets(String(rawMessage)).slice(0, 200);
  const err = new Error(`${providerLabel} [${code}] (${providerMessage})`);
  err.code = code;
  err.providerMessage = providerMessage;
  err.providerLabel = providerLabel;
  return err;
}

// 用于网络错误（fetch 抛错、超时、连接失败等）。
function wrapNetworkError(err, providerLabel) {
  const msg = redactSecrets(err?.message || String(err));
  const e = new Error(`${providerLabel} network error [network] (${msg})`);
  e.code = 'network';
  e.providerMessage = msg;
  e.providerLabel = providerLabel;
  return e;
}

// 用于 provider 返回内容解析失败（非 HTTP 错误，如 JSON / OCR 解析为空）。
function parseError(providerLabel, detail) {
  const safeDetail = detail != null ? redactSecrets(String(detail)) : detail;
  const e = new Error(`${providerLabel} parse failed [parseFailed]${safeDetail ? ' (' + safeDetail + ')' : ''}`);
  e.code = 'parseFailed';
  e.providerLabel = providerLabel;
  return e;
}

module.exports = { buildHttpError, buildBodyError, wrapNetworkError, parseError, normalizeCode, redactSecrets, AI_ERROR_CODES };
