import path from 'path';
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig(({ mode }) => {
    return {
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
      plugins: [react()],
      resolve: {
        alias: {
          '@': path.resolve(__dirname, '.'),
        }
      }
    };
});
