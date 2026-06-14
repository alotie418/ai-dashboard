// Batch transaction re-categorization (PR-T5-2B-1) — PURE handler, db injected.
//
// Lives separate from transactions.js so it can be unit-tested without loading
// better-sqlite3 (an Electron-ABI native module that won't dlopen under plain
// node). transactions.recategorize wraps this with the real getDb().
//
// Contract — a MANAGEMENT classification adjustment only; it never changes any
// money/date field, only category_id + updated_at:
//   body = { fromCategoryId, toCategoryId, dryRun: boolean, expectedAffected?: number }
//   - dryRun MUST be an explicit boolean (missing/non-boolean → 400; it never
//     defaults to performing an UPDATE).
//   - from/to must both exist, both be type 'expense', share one locale, and that
//     locale must equal the current accounting_locale. (The schema has no
//     book/account/profile dimension; a category's locale is the only scope, and
//     category_id is locale-specific, so WHERE category_id = ? is locale-scoped.)
//   - dryRun:true  → { dryRun:true, affected }            (COUNT only, no write)
//   - dryRun:false → re-COUNT inside a transaction; if expectedAffected is given
//     and differs from the live count → 409 (no write); otherwise UPDATE only
//     category_id + updated_at, scoped to type='expense' → { dryRun:false, moved }.

function httpError(status, message) {
  const e = new Error(message);
  e.status = status;
  return e;
}

function readAccountingLocale(db) {
  try {
    const row = db.prepare('SELECT value FROM settings WHERE key = ?').get('accounting_locale');
    return row ? JSON.parse(row.value) : 'CN';
  } catch {
    return 'CN';
  }
}

function recategorize({ body, db }) {
  const { fromCategoryId, toCategoryId, dryRun, expectedAffected } = body || {};

  // (1) dryRun is mandatory and must be an explicit boolean — never default to UPDATE.
  if (typeof dryRun !== 'boolean') {
    throw httpError(400, 'dryRun must be an explicit boolean (true = preview, false = commit)');
  }
  if (!fromCategoryId || !toCategoryId) throw httpError(400, 'fromCategoryId and toCategoryId are required');
  if (fromCategoryId === toCategoryId) throw httpError(400, 'fromCategoryId and toCategoryId must differ');
  if (expectedAffected != null && (!Number.isInteger(expectedAffected) || expectedAffected < 0)) {
    throw httpError(400, 'expectedAffected must be a non-negative integer when provided');
  }

  const from = db.prepare('SELECT id, type, locale FROM categories WHERE id = ?').get(fromCategoryId);
  const to = db.prepare('SELECT id, type, locale FROM categories WHERE id = ?').get(toCategoryId);
  if (!from || !to) throw httpError(400, 'fromCategoryId / toCategoryId must reference existing categories');
  if (from.type !== 'expense' || to.type !== 'expense') throw httpError(400, 'recategorize is limited to expense categories');
  if (from.locale !== to.locale) throw httpError(400, 'fromCategoryId and toCategoryId must belong to the same locale');

  const accLocale = readAccountingLocale(db);
  if (from.locale !== accLocale) {
    throw httpError(400, `categories must belong to the current accounting locale (${accLocale})`);
  }

  const countFrom = () =>
    db.prepare("SELECT COUNT(*) AS n FROM transactions WHERE category_id = ? AND type = 'expense'").get(fromCategoryId).n;

  if (dryRun) {
    return { dryRun: true, fromCategoryId, toCategoryId, affected: countFrom() };
  }

  // Commit: re-count inside the transaction (guards against drift since preview),
  // honor expectedAffected (409 on mismatch → rolls back), and change ONLY
  // category_id + updated_at for expense rows of the from category.
  const run = db.transaction(() => {
    const current = countFrom();
    if (expectedAffected != null && expectedAffected !== current) {
      throw httpError(409, `affected count changed (expected ${expectedAffected}, found ${current}); re-preview before committing`);
    }
    const res = db
      .prepare("UPDATE transactions SET category_id = ?, updated_at = datetime('now') WHERE category_id = ? AND type = 'expense'")
      .run(toCategoryId, fromCategoryId);
    return res.changes;
  });
  const moved = run();
  return { dryRun: false, fromCategoryId, toCategoryId, moved };
}

module.exports = { recategorize, httpError };
