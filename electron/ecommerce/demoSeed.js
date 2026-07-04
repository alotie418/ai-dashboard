// Demo data seeder — populates the ISOLATED demo DB (see electron/db/index.js isDemoMode) with
// sample data so the full e-commerce flow can be demoed with no real store and no real network.
//
// Behaviour (constraint compliance):
//   - Runs ONLY in demo mode (or with an explicit test override); writes only to the demo DB.
//   - Runs ONLY on an EMPTY demo DB: if the demo connection already exists it does NOTHING —
//     no overwrite, no reset, no append. Reset is by deleting userData/demo/ and relaunching.
//   - Stages the 9 sample orders through the REAL pull() using the in-memory demo provider
//     (zero network), commits two through the UNCHANGED commit.js, and deletes one committed
//     sale to leave an "orphan" the user can unlock & re-commit.
//   - Touches NO real ledger, NO schema/migration, NO commit.js / pull.js. Demo sales are tagged
//     platform_source='woocommerce' (the demo connection's platform) and live only in the demo DB.

const { getDb, isDemoMode } = require('../db');
const ecommerceCore = require('./index');
const { demoProviders, DEMO_STORE_CURRENCY } = require('./providers/demo');

const DEMO_CONNECTION_ID = 'ec-demo-store';
const DEMO_LABEL = 'Demo Store';
// Fixed NON-secret placeholder blob. pull() uses injected creds and never decrypts this, so no
// safeStorage is ever involved. It is not, and never decrypts to, a real credential.
const FAKE_ENC = 'REVNTy1QTEFDRUhPTERFUi1OT1QtQS1SRUFMLUNSRURFTlRJQUw=';

// seedDemoIfEmpty(opts) → { seeded: boolean, reason?, connectionId?, staged? }
//   opts._allowAnyEnv : test-only — bypass the demo-mode guard (tests inject on a :memory: DB)
//   opts.providers    : test-only — inject the demo provider registry (no network)
async function seedDemoIfEmpty(opts = {}) {
  if (!opts._allowAnyEnv && !isDemoMode()) {
    throw new Error('seedDemoIfEmpty refused: not in demo mode');
  }
  const db = getDb();

  // idempotency: already seeded → do nothing (no overwrite / reset / append)
  const existing = db.prepare('SELECT COUNT(*) AS c FROM ecommerce_connections WHERE id = ?').get(DEMO_CONNECTION_ID).c;
  if (existing > 0) return { seeded: false, reason: 'already_seeded' };

  // sample products — two active "Dup Item" rows drive the ambiguous-match demo
  const addProduct = (id, name) => db.prepare("INSERT INTO products (id, name, unit, is_active) VALUES (?, ?, 'piece', 1)").run(id, name);
  addProduct('demo-widget', 'Demo Widget');
  addProduct('demo-gadget', 'Demo Gadget');
  addProduct('demo-dup-1', 'Dup Item');
  addProduct('demo-dup-2', 'Dup Item');
  // opening stock so the derived-inventory read is observable when demo orders commit
  db.prepare("INSERT INTO purchases (id, date, supplier, tons, product_id, amountWithoutTax, totalAmount) VALUES ('demo-pu-w', '2026-01-01', 'Demo Supplier', 20, 'demo-widget', 900, 990)").run();

  // demo connection — platform 'woocommerce' so commit.js STATUS_MAP maps its statuses.
  // FAKE_ENC is never decrypted (pull uses injected creds).
  db.prepare(`INSERT INTO ecommerce_connections
      (id, platform, label, shop_identifier, credentials_encrypted, store_currency, enabled, last_test_at, last_test_ok)
      VALUES (?, 'woocommerce', ?, 'demo-store.local', ?, ?, 1, datetime('now'), 1)`)
    .run(DEMO_CONNECTION_ID, DEMO_LABEL, FAKE_ENC, DEMO_STORE_CURRENCY);

  // stage all 9 via the REAL pull() + in-memory demo provider (no network)
  const providers = opts.providers || demoProviders();
  await ecommerceCore.pull(DEMO_CONNECTION_ID, { providers, creds: { demo: true } });

  const staged = db.prepare('SELECT id, external_order_id FROM ecommerce_staged_orders WHERE connection_id = ?').all(DEMO_CONNECTION_ID);
  const byExt = Object.fromEntries(staged.map((s) => [s.external_order_id, s.id]));

  // commit 1008 (stays committed / read-only) and 1009 (about to become an orphan)
  ecommerceCore.commit({ connectionId: DEMO_CONNECTION_ID, stagedIds: [byExt['1008'], byExt['1009']] });
  // delete 1009's posted sale → its staged row is now a committed orphan (unlock & re-commit demo)
  db.prepare('DELETE FROM sales WHERE id = ?').run(`sale-ec-${byExt['1009']}`);

  return { seeded: true, connectionId: DEMO_CONNECTION_ID, staged: staged.length };
}

module.exports = { seedDemoIfEmpty, DEMO_CONNECTION_ID };
