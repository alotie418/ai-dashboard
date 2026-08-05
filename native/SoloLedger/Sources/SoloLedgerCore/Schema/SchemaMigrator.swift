import Foundation

/// The migration ladder: v1…v23 are a faithful Swift port of `electron/db/index.js`,
/// and v24 onwards are native-only rungs Electron has no counterpart for.
///
/// Reproducing the FULL 23-version shared ladder (not just the Phase-1 tables) means the
/// v1…v23 prefix of a database this migrator creates is byte-schema-compatible with the
/// Electron app: same 26 tables, same indexes, same `PRAGMA user_version = 23`.
///
/// **The ladder is now two segments, and the difference is load-bearing.**
/// ``sharedLadderVersion`` is the last rung Electron also has; ``nativeOnlyVersions`` lists
/// every rung above it, one by one. `SchemaVersionParityTests` compares the SHARED segment
/// against Electron's authoritative `SCHEMA_VERSION` — comparing the head against it, which
/// is what it used to do, would now report drift on every native-only rung and would have to
/// be deleted, taking the real protection (a native head BEHIND Electron rejects every real
/// production DB as `.unknownVersion`) with it.
///
/// A v24 ledger is NOT refused by Electron: its `runMigrations` loop simply runs zero times
/// (`for (let v = 24; v < 23; v++)`) and it reads and writes the v23 tables as usual, unaware
/// of the inventory ones. The one-way property is a convention, not an enforcement — see the
/// declaration in `docs/SWIFTUI_FEATURE_GAP.md` §4, which states it in those terms.
///
/// Versioning mechanism is identical to the JS app: the SQLite `user_version`
/// pragma, no migrations table. Each migration runs in its own transaction and
/// bumps `user_version` in the same transaction.
public enum SchemaMigrator {

    /// The native head — what a fully-migrated database reaches. Equals
    /// ``sharedLadderVersion`` + ``nativeOnlyVersions``.count, asserted in
    /// `SchemaVersionParityTests`.
    public static let schemaVersion = 24

    /// The last rung the native ladder SHARES with Electron. MUST equal the JS app's
    /// `SCHEMA_VERSION` (= MIGRATIONS.length); `SchemaVersionParityTests` reads that value
    /// from the real module and fails closed if the two drift. Electron adding a migration
    /// means porting it into the shared segment and bumping this — NOT appending it above
    /// the native-only rungs, which would silently renumber them.
    public static let sharedLadderVersion = 23

    /// The rungs that exist ONLY natively, listed explicitly so none can appear by accident.
    /// `SchemaVersionParityTests` asserts this equals both the literal declared list and the
    /// contiguous range `(sharedLadderVersion + 1) … schemaVersion`.
    ///
    /// * **v24** — the native inventory ledger (`inventory_movements` / `inventory_balances`
    ///   / `inventory_exceptions`). Purely additive; nothing in v1…v23 is touched.
    public static let nativeOnlyVersions = [24]

    public enum MigrationError: Error, CustomStringConvertible {
        case newerThanSupported(found: Int, supported: Int)
        /// A negative `user_version` (a corrupt/tampered source). Rejected fail-closed
        /// BEFORE the migration loop, which would otherwise index `migrations[negative]`
        /// and trap the process.
        case corruptVersion(found: Int)
        public var description: String {
            switch self {
            case let .newerThanSupported(found, supported):
                return "Database user_version \(found) is newer than supported \(supported); refusing to migrate."
            case let .corruptVersion(found):
                return "Database user_version \(found) is negative (corrupt/tampered); refusing to migrate."
            }
        }
    }

    /// The complete set of tables a fully-migrated (head) database must contain — the
    /// authoritative list, defined ONCE. A consumer that needs to prove a database reached
    /// head verifies every one of these, not an ad-hoc subset. Kept in lockstep with the
    /// ladder (one CREATE TABLE per name at head) by `testRequiredTablesMatchLadder`.
    ///
    /// The three `inventory_*` names arrived with v24, so `PreparedImportRunner`'s schema gate
    /// (which filters this list against the prepared database) now refuses a prepared library
    /// that claims head but lacks them.
    public static let requiredTables: [String] = [
        "accounts", "ai_providers", "alerts", "assistant_conversations", "assistant_messages",
        "business_document_items", "business_documents", "categories", "ecommerce_connections",
        "ecommerce_staged_orders", "ecommerce_sync_log", "equity", "fixed_assets", "home_office",
        "inventory_balances", "inventory_exceptions", "inventory_movements",
        "legacy_migrations", "liabilities", "mileage_logs", "price_history", "products",
        "purchase_items", "purchases", "sales", "sales_items", "settings", "tax_payments",
        "transactions",
    ]

    /// Apply all pending migrations. Index `i` reaches `user_version = i + 1`.
    public static func migrate(_ db: SQLiteDatabase) throws {
        let current = try db.userVersion()
        guard current >= 0 else { throw MigrationError.corruptVersion(found: current) }
        if current > schemaVersion {
            throw MigrationError.newerThanSupported(found: current, supported: schemaVersion)
        }
        for version in current..<migrations.count {
            try db.transaction {
                try migrations[version](db)
                try db.setUserVersion(version + 1)
            }
        }
    }

    // MARK: - Helpers

    private static func columnNames(_ db: SQLiteDatabase, _ table: String) throws -> [String] {
        try db.query("PRAGMA table_info(\(table))").compactMap { $0.string("name") }
    }

    private static func addColumn(_ db: SQLiteDatabase, _ table: String, _ name: String, _ definition: String) throws {
        let cols = try columnNames(db, table)
        if !cols.contains(name) {
            try db.execute("ALTER TABLE \(table) ADD COLUMN \(name) \(definition)")
        }
    }

    // MARK: - The ladder (v1 … v24), one closure per version
    //
    // v1…v23 are the SHARED segment — a faithful port of `electron/db/index.js`. Nothing
    // below this line may be edited to accommodate a native-only rung; v24 exists precisely
    // so that it does not have to be.

    private static let migrations: [(SQLiteDatabase) throws -> Void] = [
        // v1: initial schema
        { db in try db.execute("""
            CREATE TABLE IF NOT EXISTS purchases (
              id TEXT PRIMARY KEY, date TEXT NOT NULL, supplier TEXT, tons REAL, pricePerTon REAL,
              totalAmount REAL, amountWithoutTax REAL, taxAmount REAL, taxRate REAL,
              invoiceNumber TEXT, invoiceStatus TEXT, payment_status TEXT DEFAULT 'unpaid',
              paid_amount REAL DEFAULT 0, due_date TEXT, payment_date TEXT,
              created_at TEXT DEFAULT (datetime('now'))
            );
            CREATE TABLE IF NOT EXISTS sales (
              id TEXT PRIMARY KEY, date TEXT NOT NULL, customer TEXT, tons REAL, pricePerTon REAL,
              totalAmount REAL, amountWithoutTax REAL, taxAmount REAL, taxRate REAL,
              shippingCost REAL DEFAULT 0, invoiceNumber TEXT, invoiceStatus TEXT,
              payment_status TEXT DEFAULT 'unpaid', paid_amount REAL DEFAULT 0,
              due_date TEXT, payment_date TEXT, created_at TEXT DEFAULT (datetime('now'))
            );
            CREATE TABLE IF NOT EXISTS settings (
              key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at TEXT DEFAULT (datetime('now'))
            );
            CREATE TABLE IF NOT EXISTS price_history (
              id INTEGER PRIMARY KEY AUTOINCREMENT, query TEXT NOT NULL, search_date TEXT NOT NULL,
              prices TEXT NOT NULL, created_at TEXT DEFAULT (datetime('now'))
            );
            CREATE TABLE IF NOT EXISTS alerts (
              id INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT NOT NULL, severity TEXT, title TEXT,
              body TEXT, related_id TEXT, is_read INTEGER DEFAULT 0, is_dismissed INTEGER DEFAULT 0,
              created_at TEXT DEFAULT (datetime('now'))
            );
            CREATE INDEX IF NOT EXISTS idx_sales_date ON sales(date);
            CREATE INDEX IF NOT EXISTS idx_purchases_date ON purchases(date);
            CREATE INDEX IF NOT EXISTS idx_alerts_read ON alerts(is_read);
            CREATE INDEX IF NOT EXISTS idx_sales_payment ON sales(payment_status);
            CREATE INDEX IF NOT EXISTS idx_purchases_payment ON purchases(payment_status);
            """) },

        // v2: ai_providers table + smooth migration of a legacy single gemini key
        { db in
            try db.execute("""
                CREATE TABLE IF NOT EXISTS ai_providers (
                  provider TEXT PRIMARY KEY, api_key_encrypted TEXT NOT NULL, model TEXT,
                  enabled INTEGER DEFAULT 1, is_default INTEGER DEFAULT 0,
                  created_at TEXT DEFAULT (datetime('now')), updated_at TEXT DEFAULT (datetime('now'))
                );
                """)
            let legacy = try db.query("SELECT value FROM settings WHERE key = 'gemini_key_encrypted'")
            if let value = legacy.first?.string("value"), !value.isEmpty {
                try db.run("""
                    INSERT OR REPLACE INTO ai_providers (provider, api_key_encrypted, model, enabled, is_default, updated_at)
                    VALUES ('gemini', ?, 'gemini-3.5-flash', 1, 1, datetime('now'))
                    """, [.text(value)])
                try db.run("DELETE FROM settings WHERE key = 'gemini_key_encrypted'")
            }
        },

        // v3: seed default accounting locale 'CN' (stored JSON-encoded, matching JSON.stringify('CN'))
        { db in
            let has = try db.query("SELECT 1 FROM settings WHERE key = 'accounting_locale'")
            if has.isEmpty {
                try db.run("INSERT INTO settings (key, value, updated_at) VALUES ('accounting_locale', ?, datetime('now'))",
                           [.text("\"CN\"")])
            }
        },

        // v4: categories table + 6-locale seed (78 rows)
        { db in
            try db.execute("""
                CREATE TABLE IF NOT EXISTS categories (
                  id TEXT PRIMARY KEY, locale TEXT NOT NULL,
                  type TEXT NOT NULL CHECK (type IN ('income', 'expense')), slug TEXT NOT NULL,
                  label_zh_cn TEXT NOT NULL, label_zh_tw TEXT, label_en TEXT NOT NULL,
                  label_ja TEXT, label_ko TEXT, label_fr TEXT, schedule_line TEXT,
                  is_deductible INTEGER DEFAULT 1, deductible_pct REAL DEFAULT 100, parent_id TEXT,
                  sort_order INTEGER DEFAULT 0, is_system INTEGER DEFAULT 1,
                  created_at TEXT DEFAULT (datetime('now')),
                  UNIQUE(locale, type, slug)
                );
                CREATE INDEX IF NOT EXISTS idx_categories_locale_type ON categories(locale, type);
                """)
            try CategorySeed.seed(into: db)
        },

        // v5: transactions (canonical income/expense ledger) + legacy_migrations mapping
        { db in try db.execute("""
            CREATE TABLE IF NOT EXISTS transactions (
              id TEXT PRIMARY KEY, type TEXT NOT NULL CHECK (type IN ('income', 'expense')),
              date TEXT NOT NULL, amount REAL NOT NULL, amount_net REAL,
              tax_amount REAL DEFAULT 0, tax_rate REAL DEFAULT 0, currency TEXT NOT NULL DEFAULT 'CNY',
              category_id TEXT, counterparty TEXT, invoice_no TEXT, invoice_status TEXT DEFAULT 'n/a',
              payment_status TEXT DEFAULT 'paid', paid_amount REAL DEFAULT 0,
              payment_date TEXT, due_date TEXT, description TEXT, attachment_path TEXT, source_meta TEXT,
              created_at TEXT DEFAULT (datetime('now')), updated_at TEXT DEFAULT (datetime('now')),
              FOREIGN KEY (category_id) REFERENCES categories(id)
            );
            CREATE INDEX IF NOT EXISTS idx_txn_date ON transactions(date);
            CREATE INDEX IF NOT EXISTS idx_txn_type_date ON transactions(type, date);
            CREATE INDEX IF NOT EXISTS idx_txn_category ON transactions(category_id);
            CREATE INDEX IF NOT EXISTS idx_txn_payment ON transactions(payment_status);
            CREATE TABLE IF NOT EXISTS legacy_migrations (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              legacy_table TEXT NOT NULL CHECK (legacy_table IN ('sales', 'purchases')),
              legacy_id TEXT NOT NULL, new_id TEXT NOT NULL, migrated_at TEXT DEFAULT (datetime('now')),
              UNIQUE(legacy_table, legacy_id)
            );
            CREATE INDEX IF NOT EXISTS idx_legacy_mig_new ON legacy_migrations(new_id);
            """) },

        // v6: mileage_logs (generated stored column) + home_office singleton
        { db in try db.execute("""
            CREATE TABLE IF NOT EXISTS mileage_logs (
              id TEXT PRIMARY KEY, date TEXT NOT NULL, start_location TEXT, end_location TEXT,
              miles REAL NOT NULL, purpose TEXT, round_trip INTEGER DEFAULT 0,
              rate_per_mile REAL DEFAULT 0.67,
              deduction REAL GENERATED ALWAYS AS (miles * rate_per_mile * (1 + round_trip)) STORED,
              created_at TEXT DEFAULT (datetime('now'))
            );
            CREATE INDEX IF NOT EXISTS idx_mileage_date ON mileage_logs(date);
            CREATE TABLE IF NOT EXISTS home_office (
              id INTEGER PRIMARY KEY CHECK (id = 1),
              method TEXT DEFAULT 'simplified' CHECK (method IN ('simplified', 'actual')),
              sqft REAL DEFAULT 0, rate_per_sqft REAL DEFAULT 5.0, max_sqft REAL DEFAULT 300,
              total_home_sqft REAL DEFAULT 0, annual_rent REAL DEFAULT 0, annual_utilities REAL DEFAULT 0,
              annual_insurance REAL DEFAULT 0, annual_depreciation REAL DEFAULT 0,
              updated_at TEXT DEFAULT (datetime('now'))
            );
            INSERT OR IGNORE INTO home_office (id) VALUES (1);
            """) },

        // v7: defensive alerts column add (no-op on a fresh DB that already has them)
        { db in
            let cols = try columnNames(db, "alerts")
            if !cols.contains("is_read") {
                try db.execute("ALTER TABLE alerts ADD COLUMN is_read INTEGER DEFAULT 0")
                if cols.contains("read") { try db.execute("UPDATE alerts SET is_read = `read`") }
            }
            if !cols.contains("is_dismissed") {
                try db.execute("ALTER TABLE alerts ADD COLUMN is_dismissed INTEGER DEFAULT 0")
            }
            try db.execute("CREATE INDEX IF NOT EXISTS idx_alerts_read ON alerts(is_read)")
        },

        // v8: repair non-integer alert flags
        { db in
            try db.execute("UPDATE alerts SET is_read = 0 WHERE typeof(is_read) != 'integer'")
            try db.execute("UPDATE alerts SET is_dismissed = 0 WHERE typeof(is_dismissed) != 'integer'")
        },

        // v9: products / service items
        { db in try db.execute("""
            CREATE TABLE IF NOT EXISTS products (
              id TEXT PRIMARY KEY, name TEXT NOT NULL, unit TEXT NOT NULL DEFAULT 'piece',
              default_unit_cost REAL DEFAULT 0, is_service INTEGER DEFAULT 0, is_active INTEGER DEFAULT 1,
              sort_order INTEGER DEFAULT 0, created_at TEXT DEFAULT (datetime('now')),
              updated_at TEXT DEFAULT (datetime('now'))
            );
            CREATE INDEX IF NOT EXISTS idx_products_active ON products(is_active);
            """) },

        // v10: per-record product reference + unit snapshot on purchases/sales
        { db in
            for table in ["purchases", "sales"] {
                try addColumn(db, table, "product_id", "TEXT")
                try addColumn(db, table, "product_name_snapshot", "TEXT")
                try addColumn(db, table, "unit_snapshot", "TEXT")
                try db.execute("CREATE INDEX IF NOT EXISTS idx_\(table)_product ON \(table)(product_id)")
            }
        },

        // v11: business documents header + line items
        { db in try db.execute("""
            CREATE TABLE IF NOT EXISTS business_documents (
              id TEXT PRIMARY KEY,
              doc_type TEXT NOT NULL CHECK(doc_type IN ('quotation','sales_order','proforma_invoice','commercial_invoice','statement')),
              doc_number TEXT NOT NULL,
              status TEXT NOT NULL DEFAULT 'draft' CHECK(status IN ('draft','issued','void')),
              doc_date TEXT NOT NULL, valid_until TEXT, customer_name TEXT NOT NULL, customer_tax_id TEXT,
              customer_address TEXT, customer_contact TEXT, acc_locale TEXT NOT NULL DEFAULT 'CN',
              subtotal REAL DEFAULT 0, tax_amount REAL DEFAULT 0, total REAL DEFAULT 0, notes TEXT,
              source_sales_id TEXT, period_start TEXT, period_end TEXT,
              tax_invoice_issued INTEGER DEFAULT 0, tax_invoice_number TEXT, tax_invoice_date TEXT,
              tax_invoice_attachment_path TEXT,
              created_at TEXT DEFAULT (datetime('now')), updated_at TEXT DEFAULT (datetime('now'))
            );
            CREATE UNIQUE INDEX IF NOT EXISTS idx_docs_type_number ON business_documents(doc_type, doc_number);
            CREATE INDEX IF NOT EXISTS idx_docs_type_date ON business_documents(doc_type, doc_date);
            CREATE TABLE IF NOT EXISTS business_document_items (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              doc_id TEXT NOT NULL REFERENCES business_documents(id) ON DELETE CASCADE,
              product_id TEXT, description TEXT NOT NULL, quantity REAL, unit TEXT, unit_price REAL,
              tax_rate TEXT, tax_amount REAL DEFAULT 0, amount REAL DEFAULT 0, line_no INTEGER DEFAULT 0,
              ref_sales_id TEXT, ref_date TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_doc_items_doc ON business_document_items(doc_id);
            """) },

        // v12: assistant conversation persistence
        { db in try db.execute("""
            CREATE TABLE IF NOT EXISTS assistant_conversations (
              id TEXT PRIMARY KEY, title TEXT, acc_locale TEXT, ui_language TEXT,
              created_at TEXT DEFAULT (datetime('now')), updated_at TEXT DEFAULT (datetime('now'))
            );
            CREATE INDEX IF NOT EXISTS idx_asst_conv_updated ON assistant_conversations(updated_at);
            CREATE TABLE IF NOT EXISTS assistant_messages (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              conversation_id TEXT NOT NULL REFERENCES assistant_conversations(id) ON DELETE CASCADE,
              role TEXT NOT NULL CHECK(role IN ('user','model')), text TEXT NOT NULL, tool_trace TEXT,
              seq INTEGER DEFAULT 0, created_at TEXT DEFAULT (datetime('now'))
            );
            CREATE INDEX IF NOT EXISTS idx_asst_msg_conv ON assistant_messages(conversation_id, seq);
            """) },

        // v13: categories.is_cogs flag + backfill
        { db in
            try addColumn(db, "categories", "is_cogs", "INTEGER DEFAULT 0")
            try db.execute("UPDATE categories SET is_cogs = 1 WHERE slug = 'cogs' OR (locale = 'EU' AND slug = 'purchases')")
        },

        // v14: cash / bank accounts
        { db in try db.execute("""
            CREATE TABLE IF NOT EXISTS accounts (
              id TEXT PRIMARY KEY, name TEXT NOT NULL,
              type TEXT NOT NULL DEFAULT 'cash' CHECK (type IN ('cash','bank')),
              currency TEXT, opening_balance REAL DEFAULT 0, opening_date TEXT, note TEXT,
              is_active INTEGER DEFAULT 1, sort_order INTEGER DEFAULT 0,
              created_at TEXT DEFAULT (datetime('now')), updated_at TEXT
            );
            """) },

        // v15: liabilities / loans ledger
        { db in try db.execute("""
            CREATE TABLE IF NOT EXISTS liabilities (
              id TEXT PRIMARY KEY, name TEXT NOT NULL, lender TEXT,
              liability_type TEXT NOT NULL DEFAULT 'loan' CHECK (liability_type IN ('loan','other')),
              currency TEXT, principal REAL, opening_balance REAL DEFAULT 0, opening_date TEXT,
              interest_rate REAL, maturity_date TEXT, note TEXT, is_active INTEGER DEFAULT 1,
              sort_order INTEGER DEFAULT 0, created_at TEXT DEFAULT (datetime('now')), updated_at TEXT
            );
            """) },

        // v16: fixed-assets register
        { db in try db.execute("""
            CREATE TABLE IF NOT EXISTS fixed_assets (
              id TEXT PRIMARY KEY, name TEXT NOT NULL, category TEXT, acquisition_date TEXT,
              original_value REAL DEFAULT 0, currency TEXT, supplier TEXT, serial_no TEXT, note TEXT,
              status TEXT NOT NULL DEFAULT 'in_use' CHECK (status IN ('in_use','idle','disposed')),
              is_active INTEGER DEFAULT 1, sort_order INTEGER DEFAULT 0,
              created_at TEXT DEFAULT (datetime('now')), updated_at TEXT
            );
            """) },

        // v17: equity / capital ledger
        { db in try db.execute("""
            CREATE TABLE IF NOT EXISTS equity (
              id TEXT PRIMARY KEY, name TEXT NOT NULL, owner TEXT,
              equity_type TEXT NOT NULL DEFAULT 'capital_contribution'
                CHECK (equity_type IN ('capital_contribution','owner_draw','adjustment','other')),
              amount REAL DEFAULT 0, currency TEXT, event_date TEXT, note TEXT,
              is_active INTEGER DEFAULT 1, sort_order INTEGER DEFAULT 0,
              created_at TEXT DEFAULT (datetime('now')), updated_at TEXT
            );
            """) },

        // v18: tax-payments ledger
        { db in try db.execute("""
            CREATE TABLE IF NOT EXISTS tax_payments (
              id TEXT PRIMARY KEY, name TEXT NOT NULL,
              tax_type TEXT NOT NULL DEFAULT 'vat'
                CHECK (tax_type IN ('vat','income_tax','surcharge','payroll_tax','sales_tax','other')),
              amount REAL DEFAULT 0, currency TEXT, payment_date TEXT, period_start TEXT, period_end TEXT,
              authority TEXT, reference_no TEXT, note TEXT, is_active INTEGER DEFAULT 1,
              sort_order INTEGER DEFAULT 0, created_at TEXT DEFAULT (datetime('now')), updated_at TEXT
            );
            """) },

        // v19: fixed-assets depreciation parameters (additive, nullable)
        { db in
            try addColumn(db, "fixed_assets", "depreciation_method", "TEXT DEFAULT 'straight_line'")
            try addColumn(db, "fixed_assets", "useful_life_months", "INTEGER")
            try addColumn(db, "fixed_assets", "salvage_rate", "REAL")
            try addColumn(db, "fixed_assets", "depreciation_start_policy", "TEXT DEFAULT 'next_month'")
            try addColumn(db, "fixed_assets", "disposal_date", "TEXT")
        },

        // v20: per-record line items for purchases / sales (schema only)
        { db in try db.execute("""
            CREATE TABLE IF NOT EXISTS purchase_items (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              purchase_id TEXT NOT NULL REFERENCES purchases(id) ON DELETE CASCADE,
              line_no INTEGER DEFAULT 0, product_id TEXT, description TEXT, unit_snapshot TEXT,
              quantity REAL, unit_price REAL, amount_net REAL DEFAULT 0, tax_rate REAL,
              tax_amount REAL DEFAULT 0, amount_gross REAL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_purchase_items_purchase ON purchase_items(purchase_id);
            CREATE INDEX IF NOT EXISTS idx_purchase_items_product ON purchase_items(product_id);
            CREATE TABLE IF NOT EXISTS sales_items (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              sale_id TEXT NOT NULL REFERENCES sales(id) ON DELETE CASCADE,
              line_no INTEGER DEFAULT 0, product_id TEXT, description TEXT, unit_snapshot TEXT,
              quantity REAL, unit_price REAL, amount_net REAL DEFAULT 0, tax_rate REAL,
              tax_amount REAL DEFAULT 0, amount_gross REAL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_sales_items_sale ON sales_items(sale_id);
            CREATE INDEX IF NOT EXISTS idx_sales_items_product ON sales_items(product_id);
            """) },

        // v21: e-commerce connection settings
        { db in try db.execute("""
            CREATE TABLE IF NOT EXISTS ecommerce_connections (
              id TEXT PRIMARY KEY, platform TEXT NOT NULL, label TEXT, shop_identifier TEXT,
              credentials_encrypted TEXT NOT NULL, store_currency TEXT, enabled INTEGER DEFAULT 1,
              last_test_at TEXT, last_test_ok INTEGER,
              created_at TEXT DEFAULT (datetime('now')), updated_at TEXT DEFAULT (datetime('now'))
            );
            CREATE INDEX IF NOT EXISTS idx_ecommerce_conn_platform ON ecommerce_connections(platform);
            """) },

        // v22: e-commerce order pull → staging + sync log
        { db in
            try addColumn(db, "ecommerce_connections", "last_cursor", "TEXT")
            try addColumn(db, "ecommerce_connections", "last_synced_at", "TEXT")
            try addColumn(db, "ecommerce_connections", "last_order_updated_at", "TEXT")
            try db.execute("""
                CREATE TABLE IF NOT EXISTS ecommerce_staged_orders (
                  id INTEGER PRIMARY KEY AUTOINCREMENT, connection_id TEXT NOT NULL, platform TEXT NOT NULL,
                  external_order_id TEXT NOT NULL, order_number TEXT, order_status TEXT,
                  order_created_at TEXT, order_updated_at TEXT, currency TEXT, total_gross REAL,
                  normalized_json TEXT, raw_excerpt_json TEXT, match_status TEXT DEFAULT 'unresolved',
                  stage_status TEXT DEFAULT 'staged', committed_sale_id TEXT,
                  first_seen_at TEXT DEFAULT (datetime('now')), last_pulled_at TEXT DEFAULT (datetime('now')),
                  error TEXT, updated_at TEXT DEFAULT (datetime('now'))
                );
                CREATE UNIQUE INDEX IF NOT EXISTS idx_staged_conn_ext ON ecommerce_staged_orders(connection_id, external_order_id);
                CREATE INDEX IF NOT EXISTS idx_staged_status ON ecommerce_staged_orders(stage_status);
                CREATE INDEX IF NOT EXISTS idx_staged_platform ON ecommerce_staged_orders(platform, external_order_id);
                CREATE TABLE IF NOT EXISTS ecommerce_sync_log (
                  id INTEGER PRIMARY KEY AUTOINCREMENT, connection_id TEXT, platform TEXT,
                  run_at TEXT DEFAULT (datetime('now')), status TEXT, pulled INTEGER DEFAULT 0,
                  staged_new INTEGER DEFAULT 0, staged_updated INTEGER DEFAULT 0, errors INTEGER DEFAULT 0,
                  pages INTEGER DEFAULT 0, since_used TEXT, cursor_before TEXT, cursor_after TEXT,
                  duration_ms INTEGER, error_json TEXT, created_at TEXT DEFAULT (datetime('now'))
                );
                CREATE INDEX IF NOT EXISTS idx_sync_log_conn ON ecommerce_sync_log(connection_id, run_at);
                """)
        },

        // v23: sales e-commerce provenance + commit idempotency
        { db in
            try addColumn(db, "sales", "external_order_id", "TEXT")
            try addColumn(db, "sales", "platform_source", "TEXT")
            try addColumn(db, "sales", "ecommerce_connection_id", "TEXT")
            try db.execute("""
                CREATE UNIQUE INDEX IF NOT EXISTS idx_sales_ec_conn_order
                  ON sales(ecommerce_connection_id, external_order_id)
                  WHERE ecommerce_connection_id IS NOT NULL AND external_order_id IS NOT NULL;
                CREATE INDEX IF NOT EXISTS idx_sales_platform_source ON sales(platform_source);
                """)
        },

        // ── v24 — FIRST NATIVE-ONLY RUNG ──────────────────────────────────────────────────
        //
        // The native inventory ledger. Electron has no counterpart: its `runMigrations` loop
        // over a v24 file runs zero times and it keeps reading and writing the v23 tables,
        // unaware these exist. See the one-way declaration in FEATURE_GAP §4.
        //
        // PURELY ADDITIVE, and that is a hard constraint rather than a happy accident: no
        // v1…v23 object is created, altered or dropped here, which is exactly what makes the
        // rollback form complete and mechanical —
        //
        //     DROP TABLE inventory_movements; DROP TABLE inventory_balances;
        //     DROP TABLE inventory_exceptions; PRAGMA user_version = 23;
        //
        // (indexes go with their tables) and leaves a database Electron opens as before.
        // `InventorySchemaTests` G3 performs that round trip rather than asserting it in prose.
        //
        // STRICT on all three. The audited Electron inventory read stored costs in REAL/TEXT
        // affinity columns where a corrupt value converts silently; STRICT makes the same
        // write fail at the point it happens. Note the documented carve-out STRICT does NOT
        // close: a value that is LOSSLESSLY convertible is still accepted (TEXT '5' into an
        // INTEGER column stores 5). `'abc'`, `1.5` and `'1.5'` are refused — measured, and
        // pinned by `InventorySchemaTests` H1/H2 in both directions.
        //
        // Integer scaling (N-8: money is stored as integers): quantity ×1e3, unit cost ×1e6,
        // line cost in minor currency units. Overflow handling for `quantity_milli ×
        // unit_cost_micro` belongs to the posting engine, not to the schema.
        { db in
            try db.execute("""
                CREATE TABLE IF NOT EXISTS inventory_movements (
                  id                TEXT    PRIMARY KEY,
                  product_id        TEXT    NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
                  occurred_on       TEXT    NOT NULL,
                  seq               INTEGER NOT NULL,
                  movement_type     TEXT    NOT NULL CHECK (movement_type IN (
                                       'purchase_in','sale_out','sale_return_in','purchase_return_out',
                                       'count_gain','count_loss','manual_adjust','opening')),
                  quantity_milli    INTEGER NOT NULL,
                  unit_cost_micro   INTEGER,
                  total_cost_minor  INTEGER,
                  currency          TEXT    NOT NULL,
                  source_type       TEXT,
                  source_id         TEXT,
                  reverses_id       TEXT,
                  note              TEXT,
                  created_at        TEXT    NOT NULL DEFAULT (datetime('now'))
                ) STRICT;
                CREATE UNIQUE INDEX IF NOT EXISTS idx_invm_product_order
                  ON inventory_movements(product_id, occurred_on, seq);
                CREATE INDEX IF NOT EXISTS idx_invm_product ON inventory_movements(product_id);
                CREATE INDEX IF NOT EXISTS idx_invm_source  ON inventory_movements(source_type, source_id);
                CREATE UNIQUE INDEX IF NOT EXISTS idx_invm_reverses
                  ON inventory_movements(reverses_id) WHERE reverses_id IS NOT NULL;

                CREATE TABLE IF NOT EXISTS inventory_balances (
                  product_id         TEXT    PRIMARY KEY,
                  quantity_milli     INTEGER NOT NULL DEFAULT 0,
                  cost_balance_minor INTEGER NOT NULL DEFAULT 0,
                  unit_cost_micro    INTEGER NOT NULL DEFAULT 0,
                  currency           TEXT,
                  last_movement_id   TEXT,
                  last_occurred_on   TEXT,
                  last_seq           INTEGER,
                  updated_at         TEXT    NOT NULL DEFAULT (datetime('now'))
                ) STRICT;

                CREATE TABLE IF NOT EXISTS inventory_exceptions (
                  id            TEXT    PRIMARY KEY,
                  product_id    TEXT,
                  movement_id   TEXT,
                  kind          TEXT    NOT NULL CHECK (kind IN (
                                   'return_origin_not_found','manual_adjust','opening_seeded')),
                  detail        TEXT,
                  created_at    TEXT    NOT NULL DEFAULT (datetime('now'))
                ) STRICT;
                CREATE INDEX IF NOT EXISTS idx_invx_product  ON inventory_exceptions(product_id);
                CREATE INDEX IF NOT EXISTS idx_invx_movement ON inventory_exceptions(movement_id);
                CREATE INDEX IF NOT EXISTS idx_invx_kind     ON inventory_exceptions(kind);
                """)

            // The evidence row. Electron's settings handler whitelists the keys it returns, so
            // this one is invisible to today's Electron UI — it is a marker a future Electron
            // build (or a support session reading the file) can act on, and the reason the
            // one-way declaration is phrased as "a hook exists" and not "Electron will warn".
            // OR REPLACE, not OR IGNORE: the rollback round trip re-runs this rung.
            try db.run("""
                INSERT OR REPLACE INTO settings (key, value, updated_at)
                VALUES ('native_inventory_active', ?, datetime('now'))
                """, [.text("\"24\"")])   // JSON-encoded, matching every other settings value
        },
    ]
}
