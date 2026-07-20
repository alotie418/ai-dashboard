import path from 'path';
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// 生产构建注入的 meta CSP（策略与逐条依据见 docs/CSP_PLAN.md §3）。
// 仅 build 注入（apply:'build'）——dev/HMR 依赖 inline script/eval/ws://，注入会直接
// 破坏 npm run dev；file:// 无 HTTP 响应头，meta 是生产环境唯一注入形式。
// script-src 无 'unsafe-eval'：pdf.js 已显式 isEvalSupported:false（services/pdfRaster.ts）。
// 形态由 scripts/check-csp.mjs 守卫（dist 必须有且仅有这一个 CSP meta；源 index.html 必须没有）。
const CSP_POLICY = [
  "default-src 'self'",
  "script-src 'self'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data: blob:",
  "font-src 'self'",
  "connect-src 'self'",
  "worker-src 'self' blob:",
  "object-src 'none'",
  "base-uri 'self'",
  "form-action 'none'",
].join('; ');

const injectCspMeta = () => ({
  name: 'inject-csp-meta',
  apply: 'build' as const,
  transformIndexHtml(html: string) {
    return {
      html,
      tags: [{
        tag: 'meta',
        attrs: { 'http-equiv': 'Content-Security-Policy', content: CSP_POLICY },
        // head-prepend：meta CSP 只约束其后的内容，置于 <head> 最前保证全覆盖（含内联 <style>）
        injectTo: 'head-prepend' as const,
      }],
    };
  },
});

export default defineConfig(({ mode }) => {
    // Mac App Store build flag. `build:mas` sets SOLOLEDGER_MAS=1 before vite build, so
    // `__MAS_BUILD__` becomes the literal `true` and every `if (!__MAS_BUILD__)` /
    // `!__MAS_BUILD__ && …` branch guarding an AI / BYOK-API-key feature is dead-code
    // eliminated; the now-unused AI imports (assistant, OCR, provider settings, AI briefing)
    // are then tree-shaken out of dist. The normal `npm run build` (DMG line) leaves it false
    // → AI stays fully bundled. Verified by grepping dist after `SOLOLEDGER_MAS=1 npm run build`.
    const isMasBuild = process.env.SOLOLEDGER_MAS === '1';
    return {
      define: {
        __MAS_BUILD__: JSON.stringify(isMasBuild),
      },
      // Electron 加载本地 dist/index.html 时必须用相对路径
      base: mode === 'production' ? './' : '/',
      build: {
        // Provider logos (assets/provider-logos/) must be emitted as STANDALONE files, never inlined
        // as base64 data: URIs (Vite inlines assets < 4KB by default). Return false → never inline for
        // these; undefined → keep Vite's default behavior for every other asset.
        assetsInlineLimit: (filePath: string) => (filePath.includes('provider-logos') ? false : undefined),
        rollupOptions: {
          output: {
            // Split big, rarely-changing vendor libs out of the single ~1.7 MB index chunk into their
            // own cached chunks (parallel load + better long-term caching; the app chunk no longer
            // rebuilds when only a component changes). xlsx / pdfjs-dist stay lazy-loaded via dynamic
            // import() (CsvImportModal / pdfRaster) and are NOT listed here. All chunks are self-hosted
            // under dist/assets and referenced relatively — no runtime CDN (check:offline stays green).
            // Function form (matches by node_modules path) so it also catches react/jsx-runtime,
            // react-dom/client, scheduler, and the markdown lib's micromark/mdast/unist/hast deps.
            manualChunks(id: string) {
              if (!id.includes('node_modules')) return undefined;
              if (/[\\/]node_modules[\\/](react|react-dom|scheduler)[\\/]/.test(id)) return 'react-vendor';
              if (/[\\/]node_modules[\\/](recharts|d3-|victory-)/.test(id)) return 'charts';
              if (/[\\/]node_modules[\\/](react-markdown|remark|micromark|mdast|unist|hast|property-information|vfile|decode-named-character|character-entities|space-separated|comma-separated|trim-lines|html-url-attributes)/.test(id)) return 'markdown';
              if (/[\\/]node_modules[\\/](i18next|react-i18next)/.test(id)) return 'i18n';
              return undefined;
            },
          },
        },
        // After vendor splitting AND route-level React.lazy (App.tsx loads each page as its own
        // chunk), the largest chunk is `index` (~565 kB: app shell + the eager default dashboard).
        // A 600 kB limit covers it with a small margin and still flags a real regression. (This is
        // an Electron app loading dist/ from local disk, so the size warning — a web-download
        // heuristic — is mild here anyway; the split mainly helps parse time + long-term caching.)
        chunkSizeWarningLimit: 600,
      },
      server: {
        port: 3000,
        host: '0.0.0.0',
      },
      plugins: [react(), injectCspMeta()],
      resolve: {
        alias: {
          '@': path.resolve(__dirname, '.'),
        }
      }
    };
});
