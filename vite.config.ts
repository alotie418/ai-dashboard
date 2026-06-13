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
      },
      server: {
        port: 3000,
        host: '0.0.0.0',
        // Web 版开发时仍可代理到 Express；Electron 走 IPC 时该配置不生效
        proxy: {
          '/api': 'http://localhost:8080',
          '/auth': 'http://localhost:8080',
          '/health': 'http://localhost:8080',
        },
      },
      plugins: [react()],
      resolve: {
        alias: {
          '@': path.resolve(__dirname, '.'),
        }
      }
    };
});
