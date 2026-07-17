import Foundation

/// Faithful Swift port of `electron/db/index.js`'s migration ladder.
///
/// Reproducing the FULL 23-version ladder (not just the Phase-1 tables) means a
/// database this migrator creates is byte-schema-compatible with the Electron
/// app: same 26 tables, same indexes, same `PRAGMA user_version = 23`. That is
/// the strongest possible compatibility claim for the data layer, and lets the
/// same file be opened by either app in a later phase.
///
/// Versioning mechanism is identical to the JS app: the SQLite `user_version`
/// pragma, no migrations table. Each migration runs in its own transaction and
/// bumps `user_version` in the same transaction.
public enum SchemaMigrator {

    /// Must equal the JS app's `SCHEMA_VERSION` (= MIGRATIONS.length).
    public static let schemaVersion = 23

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
    /// ladder (one CREATE TABLE per name at v23) by `testRequiredTablesMatchLadder`.
    public static let requiredTables: [String] = [
        "accounts", "ai_providers", "alerts", "assistant_conversations", "assistant_messages",
        "business_document_items", "business_documents", "categories", "ecommerce_connections",
        "ecommerce_staged_orders", "ecommerce_sync_log", "equity", "fixed_assets", "home_office",
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

    // MARK: - The ladder (v1 … v23), one closure per version

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
    ]
}
