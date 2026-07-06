// PDF → image rasterizer for vision OCR. Chinese e-invoices are mostly PDF, but the image_url
// vision path (e.g. Qwen qwen-vl-max) only accepts images — so we render PAGE 1 of the PDF to a PNG
// before OCR. pdfjs-dist is loaded dynamically (mirrors CsvImportModal's xlsx import) so it never
// bloats the initial bundle; the worker is bundled at BUILD TIME (Vite ?url asset) — NOT a CDN — so
// the offline DMG keeps working. The key never touches this file; rasterization is renderer-only.

// @ts-ignore — Vite ?url asset: the pdf.js worker, bundled at build time (no CDN) for offline DMG.
import pdfWorkerUrl from 'pdfjs-dist/build/pdf.worker.min.mjs?url';

const MAX_LONG_SIDE = 2200; // cap the rendered PNG's long side to stay well under per-image limits

export async function rasterizePdfFirstPage(file: File): Promise<{ base64: string; mimeType: 'image/png' }> {
  const pdfjs: any = await import('pdfjs-dist');
  pdfjs.GlobalWorkerOptions.workerSrc = pdfWorkerUrl;

  const data = await file.arrayBuffer();
  // isEvalSupported:false — 生产 CSP 的 script-src 无 'unsafe-eval'；默认 true 时 pdf.js 会
  // 探测 new Function（编译 PostScript Type-4 函数）产生一次被捕获的 CSP 违规（功能会自动
  // 降级、不坏，但污染“零违规”验收）。显式关闭 = 直接走纯 JS 解释器，行为不变、无违规噪声。
  const pdf = await pdfjs.getDocument({ data, isEvalSupported: false }).promise;
  try {
    const page = await pdf.getPage(1); // first page only
    const unit = page.getViewport({ scale: 1 });
    const scale = Math.min(2, MAX_LONG_SIDE / Math.max(unit.width, unit.height)) || 1;
    const viewport = page.getViewport({ scale });
    const canvas = document.createElement('canvas');
    canvas.width = Math.ceil(viewport.width);
    canvas.height = Math.ceil(viewport.height);
    const ctx = canvas.getContext('2d');
    if (!ctx) throw new Error('canvas 2d context unavailable');
    await page.render({ canvasContext: ctx, viewport }).promise;
    const dataUrl = canvas.toDataURL('image/png');
    const comma = dataUrl.indexOf(',');
    return { base64: comma >= 0 ? dataUrl.slice(comma + 1) : '', mimeType: 'image/png' };
  } finally {
    try { pdf.cleanup?.(); } catch { /* noop */ }
  }
}
