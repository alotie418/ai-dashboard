// Generic e-commerce connector provider interface (transport-agnostic).
//
// Every platform connector (Shopify = GraphQL, WooCommerce = REST, …) implements
// this ONE contract. The abstraction is the INTERFACE, not a specific transport:
// a provider declares how it talks to the platform (meta.transport) and exposes a
// small set of methods; the registry (electron/ecommerce/index.js) only ever calls
// through this contract, so adding a platform never touches the management layer.
//
//   meta: {
//     id: string,                    // stable id, e.g. 'shopify'
//     name: string,                  // display name, e.g. 'Shopify'
//     transport: 'graphql' | 'rest', // how this provider talks to the platform
//     authMode: 'manual_token' | 'key_secret' | 'oauth2' | 'signed_openapi' | 'partner_authorization',
//     status: 'available' | 'needs_authorization' | 'planned',  // catalog status (default 'available')
//     shopField: { key, label, placeholder } | null,   // the non-secret store identifier the UI collects
//     credentialFields: [{ key, label, placeholder, secret }],  // secret inputs the UI collects
//     docsUrl: string,               // official API docs (UI "how to get a token" link)
//   }
//
//   async testConnection(creds): { ok, storeInfo?, code?, providerMessage? }
//     creds = { shop?, ...credentialFields }. MUST NOT throw for expected
//     auth/network failures — return { ok:false, code, providerMessage } instead
//     (mirrors the AI provider test() contract). The decrypted secret is injected
//     here in the main process and never returned to the renderer.
//
// NOTE: pullOrders / normalizeOrder are FUTURE-phase methods and are intentionally
// NOT part of this MVP interface — this slice is connection settings only.

const REQUIRED_META_FIELDS = ['id', 'name', 'transport', 'authMode'];
const VALID_TRANSPORTS = ['graphql', 'rest'];
// The 5 generalised auth modes. A *registered* provider (one with a real adapter
// in ECOMMERCE_PROVIDERS) must declare one of these; catalog-only display entries
// may also carry oauth2 / signed_openapi / partner_authorization for information.
const VALID_AUTH_MODES = ['manual_token', 'key_secret', 'oauth2', 'signed_openapi', 'partner_authorization'];
const VALID_STATUSES = ['available', 'needs_authorization', 'planned'];

// Runtime validator so every registered provider is guaranteed to satisfy the
// contract (fail fast at module load, not at first user action). Only providers
// with a real adapter go through this — they must be connectable (status
// 'available') and expose testConnection().
function assertValidProvider(adapter) {
  if (!adapter || typeof adapter !== 'object') {
    throw new Error('[ecommerce] provider must be an object');
  }
  const meta = adapter.meta;
  if (!meta || typeof meta !== 'object') {
    throw new Error('[ecommerce] provider is missing meta');
  }
  for (const f of REQUIRED_META_FIELDS) {
    if (!meta[f]) throw new Error(`[ecommerce] provider meta missing required field: ${f}`);
  }
  if (!VALID_TRANSPORTS.includes(meta.transport)) {
    throw new Error(`[ecommerce] provider '${meta.id}' has invalid transport: ${meta.transport}`);
  }
  if (!VALID_AUTH_MODES.includes(meta.authMode)) {
    throw new Error(`[ecommerce] provider '${meta.id}' has invalid authMode: ${meta.authMode}`);
  }
  if (meta.status && !VALID_STATUSES.includes(meta.status)) {
    throw new Error(`[ecommerce] provider '${meta.id}' has invalid status: ${meta.status}`);
  }
  if (typeof adapter.testConnection !== 'function') {
    throw new Error(`[ecommerce] provider '${meta.id}' must implement testConnection()`);
  }
  return true;
}

// Public, renderer-safe view of a provider's meta (no functions). The UI uses
// this to render the "add connection" form fields per platform.
function publicMeta(adapter) {
  const m = adapter.meta;
  return {
    id: m.id,
    name: m.name,
    transport: m.transport,
    authMode: m.authMode,
    status: m.status || 'available',
    shopField: m.shopField || null,
    credentialFields: (m.credentialFields || []).map((f) => ({
      key: f.key, label: f.label, placeholder: f.placeholder || '', secret: !!f.secret,
    })),
    docsUrl: m.docsUrl || '',
  };
}

module.exports = {
  REQUIRED_META_FIELDS,
  VALID_TRANSPORTS,
  VALID_AUTH_MODES,
  VALID_STATUSES,
  assertValidProvider,
  publicMeta,
};
