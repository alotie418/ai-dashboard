// Node ESM loader hook: resolve extensionless TS imports to .ts files.
// Used by check-locale-matrix.mjs so we can import the same TS modules
// the app uses without modifying source.
import { stat } from 'node:fs/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';

export async function resolve(specifier, context, nextResolve) {
  try {
    return await nextResolve(specifier, context);
  } catch (e) {
    if (e.code !== 'ERR_MODULE_NOT_FOUND') throw e;
    // Try with .ts extension
    for (const ext of ['.ts', '.tsx', '/index.ts', '/index.tsx']) {
      const tryUrl = new URL(specifier + ext, context.parentURL).href;
      try {
        const p = fileURLToPath(tryUrl);
        await stat(p);
        return { url: tryUrl, shortCircuit: true, format: ext.endsWith('tsx') ? 'module' : 'module' };
      } catch {}
    }
    throw e;
  }
}
