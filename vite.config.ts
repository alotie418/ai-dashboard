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
        // After the vendor split the only >600 kB chunk is `index` (~900 kB) — the app's own pages,
        // which are eagerly imported in App.tsx. Splitting that further needs route-level React.lazy
        // (a deferred follow-up). The limit is raised just above it because this is an Electron app
        // that loads dist/ from the LOCAL disk — there is no network download, so the size warning
        // (a web-download heuristic) is cosmetic here; the split still helps parse time + caching.
        chunkSizeWarningLimit: 950,
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
