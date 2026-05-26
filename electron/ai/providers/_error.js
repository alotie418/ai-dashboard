// 跨 provider 共享的错误解析
// 目标：把各家不同结构的错误 JSON 翻译为 { status, code, message, friendly }
// 让前端能展示可操作的提示（model_not_found / 401 / 429 等）

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

function friendlyHint(status, code, message) {
  const m = `${code || ''} ${message || ''}`.toLowerCase();
  if (status === 401 || /invalid_api_key|unauthorized/.test(m)) {
    return 'API Key 无效或已过期，请检查 Key 是否正确';
  }
  if (status === 403 || /permission|forbidden/.test(m)) {
    return '没有访问该模型的权限，可能需要在服务商后台开通或加入白名单';
  }
  if (status === 429 || /rate_limit|quota|exceeded|insufficient_quota/.test(m)) {
    return '请求超限或额度已用完，请稍后重试或前往服务商账单页面充值';
  }
  if (status === 404 || /model.*not.*found|invalid_model|unknown.*model|does.*not.*exist/.test(m)) {
    return '模型 ID 不存在或不可用，请在设置页改成该服务商当前发布的可用 ID';
  }
  if (status === 400 || /invalid_request|bad_request/.test(m)) {
    return '请求参数无效，常见原因：模型 ID 拼写错误、不支持的功能（如 Vision）';
  }
  if (status >= 500) return '服务商接口异常，请稍后重试';
  return '';
}

// 用于 fetch 非 2xx 响应；返回的 Error 含 status / code / friendly 字段
async function buildHttpError(response, providerLabel) {
  const { json, text } = await readBody(response);
  const status = response.status;

  // 各家错误字段位置不同：
  // OpenAI:    { error: { message, code, type } }
  // Anthropic: { type: "error", error: { type, message } }
  // Gemini:    { error: { code, message, status } }
  const code = pickField(json,
    'error.code', 'error.type', 'error.status',
    'code', 'type', 'status'
  ) || `http_${status}`;
  const message = pickField(json,
    'error.message', 'message', 'error.error.message'
  ) || (text ? text.slice(0, 300) : `HTTP ${status}`);

  const friendly = friendlyHint(status, String(code), String(message));
  const err = new Error(
    `${providerLabel} ${status}` +
    (code ? ` [${code}]` : '') +
    (friendly ? ` — ${friendly}` : '') +
    (message ? ` (${message})` : '')
  );
  err.status = status;
  err.code = String(code);
  err.providerMessage = String(message);
  err.friendly = friendly;
  err.providerLabel = providerLabel;
  return err;
}

// 用于网络错误（fetch 抛错、超时、JSON 解析失败等）
function wrapNetworkError(err, providerLabel) {
  const msg = err?.message || String(err);
  const e = new Error(`${providerLabel} 网络错误 — ${msg}`);
  e.code = 'network_error';
  e.friendly = '无法连接到服务商，请检查网络或代理设置';
  e.providerLabel = providerLabel;
  return e;
}

module.exports = { buildHttpError, wrapNetworkError };
