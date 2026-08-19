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
        // `.ts` must be declared as TypeScript, not as plain ESM: naming the format at all
        // short-circuits node's own inference, and 'module' means "this is already JavaScript",
        // so the type annotations reach the parser and a bare `export type` is a syntax error.
        // Only files reached THROUGH this hook were affected — an import that already carries
        // its `.ts` extension never gets here, which is why this went unnoticed.
        return { url: tryUrl, shortCircuit: true,
                 format: ext.endsWith('tsx') ? 'module' : 'module-typescript' };
      } catch {}
    }
    throw e;
  }
}
