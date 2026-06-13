// OCR provider selection — PURE (no electron/db deps) so it is offline-testable.
//
// Principle: OCR follows the configured providers' OWN keys — there is NO separate OCR key.
//   - If the user's default provider supports OCR, use it.
//   - Otherwise fall back to any configured provider that supports OCR, in this priority order.
//   - If none supports OCR, return null (the caller surfaces "configure Qwen / Gemini …").
// DeepSeek / Kimi / GLM are text-only (no visionModel → capabilities.ocr=false) so they never
// qualify here; Qwen (qwen-vl-max) / Gemini / Anthropic / OpenAI do.

const OCR_PROVIDER_PRIORITY = ['qwen', 'doubao', 'gemini', 'anthropic', 'openai'];

// candidates: Array<{ provider: string, isDefault: boolean, ocrCapable: boolean }>
// (each entry is already known to be enabled + configured with a key)
function pickOcrProvider(candidates) {
  const ocr = (candidates || []).filter(c => c && c.ocrCapable);
  if (!ocr.length) return null;
  const def = ocr.find(c => c.isDefault);
  if (def) return def.provider;                       // default provider supports OCR → use it
  const rank = (p) => {
    const i = OCR_PROVIDER_PRIORITY.indexOf(p);
    return i === -1 ? OCR_PROVIDER_PRIORITY.length : i;
  };
  return [...ocr].sort((a, b) => rank(a.provider) - rank(b.provider))[0].provider; // priority fallback
}

module.exports = { pickOcrProvider, OCR_PROVIDER_PRIORITY };
