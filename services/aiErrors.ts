// AI 错误码 → i18n 映射（R3c）
// 主进程把【稳定 code】以 "AI_ERR:<code>" 前缀塞进 Error.message（Electron IPC 不传 Error 自定义字段）。
// 这里确定性提取 code，并对非 AI_ERR 来源（web fetch / 渲染端超时）做 regex 兜底，
// 最终由调用方 t(`aiError.${code}`) 渲染本地化文案（随 uiLanguage）。

// 稳定错误码枚举（与主进程 electron/ai/providers/_error.js + i18n aiError.* 对齐）。camelCase = i18n leaf。
export const AI_ERROR_CODES = [
  'noProvider', 'auth', 'permission', 'quota', 'modelNotFound',
  'badRequest', 'serverError', 'parseFailed', 'emptyResponse', 'network', 'timeout', 'unknown',
] as const;
export type AiErrorCode = typeof AI_ERROR_CODES[number];

const KNOWN = new Set<string>(AI_ERROR_CODES as readonly string[]);

type TFn = (key: string) => string;

/** 把 code 归一化到已知枚举，未知一律 'unknown'（防 raw provider code 漏入 i18n key）。 */
export function safeAiErrorCode(code: string | undefined | null): AiErrorCode {
  return code && KNOWN.has(code) ? (code as AiErrorCode) : 'unknown';
}

/** 从抛出的 Error 提取稳定 code：先认 "AI_ERR:<code>" 前缀，再按状态码/关键字 regex 兜底。 */
export function parseAiErrorCode(err: any): AiErrorCode {
  const msg = String(err?.message ?? err ?? '');
  const tagged = msg.match(/AI_ERR:([A-Za-z]+)/);
  if (tagged && KNOWN.has(tagged[1])) return tagged[1] as AiErrorCode;
  const m = msg.toLowerCase();
  if (/\bno_?provider\b|尚未配置/.test(m)) return 'noProvider';
  if (/\b401\b|invalid_api_key|unauthorized/.test(m)) return 'auth';
  if (/\b403\b|permission|forbidden/.test(m)) return 'permission';
  if (/\b429\b|quota|rate.?limit|exceeded|spending.?cap/.test(m)) return 'quota';
  if (/\b404\b|model.*not.*found|invalid_model/.test(m)) return 'modelNotFound';
  if (/\b400\b|bad_request|invalid_request/.test(m)) return 'badRequest';
  if (/\b5\d\d\b|server.?error/.test(m)) return 'serverError';
  if (/timeout|超时|逾時/.test(m)) return 'timeout';
  if (/parse|解析/.test(m)) return 'parseFailed';
  if (/network|fetch|cancelled|econn|enotfound/.test(m)) return 'network';
  return 'unknown';
}

// 疑似「模型不存在 / 模型不可用 / 需在控制台启用」的 provider 原文特征（已脱敏，仅用于判定，不展示）。
// 覆盖各家常见英文措辞 + 中文措辞；DeepSeek 实测返回 "Model Not Exist"（→ "model not exist"）。
const MODEL_ERROR_PATTERN =
  /model\s*(?:not\s*found|does\s*not\s*exist|not\s*exist|unavailable|not\s*supported)|invalid\s*model|unsupported\s*model|unknown\s*model|模型不存在|模型不可用|模型不支持/i;

/**
 * 测试连接失败时，判断是否「疑似模型不可用」，用于在设置页引导用户改填账号当前可用的 model ID。
 * 触发：稳定 code 为 modelNotFound；或 providerMessage（已在主进程脱敏）命中模型不存在/不可用关键词
 * —— 后者覆盖了「badRequest 下 provider 原文提示模型问题」的情形。provider 中立、不显示原始错误串。
 */
export function looksLikeModelError(code: string | undefined | null, providerMessage?: string | null): boolean {
  // modelNotFound = 模型不存在/不可用；emptyResponse = 2xx 成功但模型无可用内容（该 model ID 可能
  // 不支持此测试 / 未完整开通 / 需换 ID）——两者都引导用户检查 Model ID（不误判为 Key 错）。
  const c = safeAiErrorCode(code);
  if (c === 'modelNotFound' || c === 'emptyResponse') return true;
  return !!providerMessage && MODEL_ERROR_PATTERN.test(String(providerMessage));
}

/** code → 本地化文案（用于已拿到结构化 code 的场景，如 providers:test 回传）。 */
export function aiErrorMessageFromCode(code: string | undefined | null, t: TFn): string {
  return t(`aiError.${safeAiErrorCode(code)}`);
}

/** Error → 本地化文案（用于 catch 到的异常）。 */
export function aiErrorMessage(err: any, t: TFn): string {
  return t(`aiError.${parseAiErrorCode(err)}`);
}
