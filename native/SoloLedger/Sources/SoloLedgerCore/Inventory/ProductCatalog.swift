import Foundation

/// Product / service-item master data — a faithful mirror of `electron/handlers/products.js`.
///
/// **Scope is master data ONLY.** `defaultUnitCost` is *stored*, never *computed with*: the
/// weighted-average inventory valuation in `electron/handlers/inventory.js:67-72` is a later
/// slice and is blocked pending accountant confirmation of its four accounting choices. Nothing
/// in this file reads or writes any other table, joins anything, or produces a total.
///
/// Nothing in this file is reachable from the App target yet — the read/write layer lands
/// before the copy and the view, and a test asserts the absence of every construction site.
///
/// Mirror boundaries worth stating once, because they are decisions and not oversights:
///
///  * The read path performs **no validation**. `electron/handlers/products.js:11-18` selects
///    and returns whatever is stored; the unit whitelist is enforced on write only (`:26`,
///    `:61`). A row holding an out-of-vocabulary unit therefore reads back verbatim on both
///    sides rather than being repaired on the way out.
///  * Ordering happens **in SQL** (`:15`), never in Swift. SQLite orders by storage class
///    (NULL < numeric < TEXT < BLOB); no in-memory comparison over the decoded model
///    reproduces that, so re-sorting here would silently diverge from Electron on any ledger
///    holding a mistyped cell.
///  * A row that cannot be identified is **counted, not dropped**. See ``ProductCatalogPage``.

// MARK: - Units

/// The write-side unit whitelist — `VALID_UNITS` at `electron/handlers/products.js:8`, which
/// that file's own header requires to mirror `PRODUCT_UNIT_KEYS`
/// (`components/accountingHelpers.ts:206`). Same eleven keys, same order.
///
/// Only the *keys* live here. Their human labels are a presentation concern and belong with the
/// six-language copy, not with the store.
public enum ProductUnit: String, CaseIterable, Sendable {
    case piece, box, bag, kg, ton, liter, bottle, pack, session, hour, month
}

// MARK: - Model

/// One row of the `products` table.
public struct Product: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String

    /// The stored unit key, or `nil` when the cell has no text reading at all (a BLOB).
    ///
    /// Optional rather than defaulted on purpose: the column carries `NOT NULL DEFAULT 'piece'`,
    /// so substituting `"piece"` here would report a unit the ledger does not hold, and `""`
    /// would claim the unit is empty text when in fact it is bytes. `nil` preserves the readable
    /// storage fact — *there is no text reading* — and leaves the presentation decision to the
    /// layer that has copy to spend on it.
    public let unit: String?

    /// Tax-exclusive default unit price. **Stored only** — no code in this module multiplies,
    /// sums or compares it. A cell with no numeric reading (TEXT `"abc"`, a BLOB) reads as `0`,
    /// which is the column's own declared default (`REAL DEFAULT 0`), not a value invented here.
    public let defaultUnitCost: Double

    public let isService: Bool
    public let isActive: Bool

    /// A stored REAL such as `1.5` — reachable, because `electron/handlers/products.js:40` binds
    /// the caller's raw `Number` and NUMERIC affinity only demotes losslessly-integral floats —
    /// truncates toward zero here, since the model types this as an integer.
    public let sortOrder: Int

    public let createdAt: String?
    public let updatedAt: String?

    public init(id: String, name: String, unit: String?, defaultUnitCost: Double,
                isService: Bool, isActive: Bool, sortOrder: Int,
                createdAt: String? = nil, updatedAt: String? = nil) {
        self.id = id
        self.name = name
        self.unit = unit
        self.defaultUnitCost = defaultUnitCost
        self.isService = isService
        self.isActive = isActive
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Decode one row, or `nil` when the row cannot be identified.
    ///
    /// **Only `id` and `name` gate the decode.** A row missing either cannot be pointed at (no
    /// id) or cannot be named on screen (no name), so it is not usable as a product; every other
    /// column has a declared default in the schema and falls back to it. `unit` deliberately does
    /// NOT gate: "this is a product" does not depend on its unit being readable.
    ///
    /// Unlike `Category.from` / `Transaction.from`, whose `nil` return is consumed by
    /// `compactMap` and therefore vanishes without trace, this `nil` is **counted** by the only
    /// caller — see ``ProductCatalogPage``.
    static func from(_ row: SQLiteRow) -> Product? {
        guard let id = row.string("id"), let name = row.string("name") else { return nil }
        return Product(
            id: id,
            name: name,
            unit: row.string("unit"),
            // `row.double`, never `row.int`: `Int(Double.infinity)` traps, and an infinity is
            // reachable in a REAL column (SQLite stores NaN as NULL but keeps infinities).
            defaultUnitCost: row.double("default_unit_cost") ?? 0,
            isService: jsTruthy(row["is_service"], storedType: row.string("is_service_type")),
            isActive: jsTruthy(row["is_active"], storedType: row.string("is_active_type")),
            sortOrder: row.int("sort_order") ?? 0,
            createdAt: row.string("created_at"),
            updatedAt: row.string("updated_at"))
    }
}

/// The result of reading the catalogue: the rows that decoded, and how many did not.
///
/// The count exists because the alternative — `compactMap` — makes a corrupt row
/// indistinguishable from an absent one while `SELECT COUNT(*)` keeps counting it, so a list and
/// a total drawn from the same table can disagree with nothing to explain the gap. What the count
/// should look like on screen is a copy decision and is not made here; that it must be *available*
/// is the decision this type records.
public struct ProductCatalogPage: Equatable, Sendable {
    public let products: [Product]
    public let unreadableCount: Int

    public init(products: [Product], unreadableCount: Int) {
        self.products = products
        self.unreadableCount = unreadableCount
    }
}

// MARK: - Errors

/// Why a catalogue write was refused.
///
/// **Every case is payload-free, and that is the point.** `SQLiteError`'s text carries the
/// statement and the driver's own wording; 2a-4's third ruling is that such a leak must be
/// impossible in the *type* rather than avoided by discipline at each call site. With no
/// associated values there is nothing for a presentation layer to print even by accident, and
/// `description` below is an exhaustive switch over fixed literals — a new case fails to compile
/// here instead of falling into a bucket someone would fill with the offending value.
public enum ProductCatalogError: Error, Equatable, Sendable, CustomStringConvertible {
    /// An empty id was supplied — `electron/handlers/products.js:49`, `:83` (`'Invalid ID'`).
    case invalidID
    /// The name was empty, or whitespace only — `products.js:24`, `:57`.
    case nameRequired
    /// The unit is not one of ``ProductUnit`` — `products.js:26`, `:61`.
    case unitNotRecognized
    /// No such product — `products.js:51`, `:85` (`'Product not found'`).
    case notFound
    /// The generated id was already taken. Unreachable with a UUID, kept so the write path has
    /// somewhere honest to land instead of surfacing a raw SQLite constraint failure.
    case idCollision
    /// Any other refusal from the database.
    case storageFailure

    public var description: String {
        switch self {
        case .invalidID:          return "invalidID"
        case .nameRequired:       return "nameRequired"
        case .unitNotRecognized:  return "unitNotRecognized"
        case .notFound:           return "notFound"
        case .idCollision:        return "idCollision"
        case .storageFailure:     return "storageFailure"
        }
    }
}

// MARK: - Coercion rules

/// JS `!!value` over a SQLite storage class — the rule `electron/handlers/products.js:17`
/// applies to `is_service` / `is_active` on the way out.
///
/// Written for the values that COULD arrive rather than the ones that do, which is the shape
/// already adjudicated for the same JS operator over `is_cogs` (see `isCogsTruthy` in
/// `Reports/ReportRow.swift`). That symbol is deliberately not reused: it lives inside the
/// reports guard's scope and means "is this category a cost of goods sold", which is not what is
/// being asked here.
///
/// Every Electron write path binds an integer (`products.js:38-39`, `:68-69`), so on a ledger
/// only ever touched by that app the `.integer` arm is the only one taken. The other four exist
/// because a migrated, imported or externally-edited file can hold anything, and on those values
/// the two apps must still agree.
///
/// `storedType` is `typeof(column)` asked of SQLite itself, and it is required rather than
/// decorative. A **zero-length BLOB** cannot be told apart from SQL NULL by the value alone:
/// `sqlite3_column_blob` returns a null pointer for one, so `SQLiteDatabase.readColumn` takes its
/// `else` branch and hands back `.null`. JavaScript disagrees loudly about those two — a
/// zero-length `Buffer` is still an object and therefore truthy, while `null` is falsy — so
/// without asking SQLite what it actually holds, a product flagged with an empty blob would read
/// as inactive here and active there. Asking `typeof` costs one extra column and settles it.
private func jsTruthy(_ value: SQLiteValue, storedType: String?) -> Bool {
    // Checked before the value, because this is exactly the case the value cannot express.
    if storedType == "blob" { return true }              // JS: every object is truthy
    switch value {
    case .null:            return false
    case .integer(let i):  return i != 0
    case .real(let d):     return !(d == 0 || d.isNaN)   // JS: 0, -0 and NaN are falsy
    case .text(let s):     return !s.isEmpty             // JS: only "" is falsy
    case .blob:            return true
    }
}

/// `String.prototype.trim()`'s character set.
///
/// ECMAScript trims WhiteSpace ∪ LineTerminator, and its WhiteSpace set includes U+FEFF, which
/// Foundation's `.whitespacesAndNewlines` does not. The difference is load-bearing rather than
/// cosmetic: the emptiness check is performed on the *trimmed* value, so a name consisting of one
/// U+FEFF is refused by Electron and has to be refused here too. (U+FEFF renders as nothing —
/// the same property that made it worth escaping on the settings screen.)
private let jsTrimSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))

/// `products.js:27` + `:37` / `:66` — `Number(v)`, then `isFinite(n) && n >= 0 ? n : 0`.
/// An omitted field is `Number(undefined)`, i.e. `NaN`, which fails the finite test and lands on
/// zero; `nil` here means the same thing and takes the same branch.
private func normalizedUnitCost(_ value: Double?) -> Double {
    guard let value, value.isFinite, value >= 0 else { return 0 }
    return value
}

/// Mirrors the ROLE of `products.js:29` (`prod-<base36 ts>-<4 random chars>`), not its FORMAT.
/// The random suffix there exists solely to break same-millisecond `Date.now()` collisions — a
/// window a UUID does not have, and one Electron has a dedicated 50-create burst test for. Both
/// sides only ever store and compare this as opaque TEXT; nothing on either side parses it, so
/// the shape is free to differ. Prefix-plus-lowercased-UUID matches
/// `IDGenerator.transactionID()`, which is intentionally left alone: this slice adds no public
/// symbol outside this file.
private func newProductID() -> String {
    "prod-" + UUID().uuidString.lowercased()
}

/// Map a raw database failure onto the closed set above, so no SQLite text can travel further.
///
/// The constraint code is matched as a delimiter-bearing token, never as a bare substring: the
/// message is assembled as `"… (code N)"` by `SQLiteDatabase.run`, and a loose search for a
/// number would match digits belonging to the statement instead. `products` carries exactly one
/// unique index — its primary key (`idx_products_active` is not unique) — so a constraint
/// violation on this table can only be an id collision.
private func mapWriteFailure(_ error: Error) -> ProductCatalogError {
    guard let sqlite = error as? SQLiteError, case .step(let message) = sqlite else {
        return .storageFailure
    }
    return message.contains("(code 19)") ? .idCollision : .storageFailure
}

// MARK: - Store

public extension LedgerStore {

    /// `GET /api/products` — `electron/handlers/products.js:11-18`.
    ///
    /// Same explicit column list and same `ORDER BY` as the handler; no filter and no row cap, so
    /// inactive and service items are included exactly as they are there.
    func productCatalog() throws -> ProductCatalogPage {
        // The two `typeof` columns are not decoration — see `jsTruthy`. They are the only way to
        // tell a zero-length BLOB from SQL NULL, which JavaScript treats as opposites.
        let rows = try db.query("""
            SELECT id, name, unit, default_unit_cost, is_service, is_active, sort_order,
                   created_at, updated_at,
                   typeof(is_service) AS is_service_type,
                   typeof(is_active)  AS is_active_type
              FROM products
             ORDER BY is_active DESC, sort_order, name
            """)
        var decoded: [Product] = []
        decoded.reserveCapacity(rows.count)
        var unreadable = 0
        for row in rows {
            if let product = Product.from(row) { decoded.append(product) } else { unreadable += 1 }
        }
        return ProductCatalogPage(products: decoded, unreadableCount: unreadable)
    }

    /// `POST /api/products` — `electron/handlers/products.js:21-43`. Returns the new id.
    ///
    /// The defaults reproduce the handler's, including the two places where it treats a missing
    /// field differently from `update`: an omitted `sortOrder` becomes **999** here and **0**
    /// there (`:40` vs `:70`), and `is_active` is defaulted true. Electron reaches that second
    /// default through `is_active === false ? 0 : 1`, which also lets `0`, `null` and `"no"`
    /// through as *active*; typing the parameter `Bool` removes those inputs from the domain
    /// rather than reproducing the quirk, and on the values both sides can express the two agree.
    @discardableResult
    func createProduct(name: String,
                       unit: String = ProductUnit.piece.rawValue,
                       defaultUnitCost: Double? = nil,
                       isService: Bool = false,
                       isActive: Bool = true,
                       sortOrder: Int? = nil) throws -> String {
        let trimmedName = name.trimmingCharacters(in: jsTrimSet)
        guard !trimmedName.isEmpty else { throw ProductCatalogError.nameRequired }
        guard ProductUnit(rawValue: unit) != nil else { throw ProductCatalogError.unitNotRecognized }

        let id = newProductID()
        do {
            try db.run("""
                INSERT INTO products
                  (id, name, unit, default_unit_cost, is_service, is_active, sort_order)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, [.text(id),
                      .text(trimmedName),
                      .text(unit),
                      .real(normalizedUnitCost(defaultUnitCost)),
                      .integer(isService ? 1 : 0),
                      .integer(isActive ? 1 : 0),
                      .integer(Int64(sortOrder ?? 999))])
        } catch {
            throw mapWriteFailure(error)
        }
        return id
    }

    /// `PUT /api/products/:id` — `electron/handlers/products.js:46-77`.
    ///
    /// Strictly partial: `nil` means *omitted*, and an omitted field is neither written nor
    /// cleared, which is what the handler's `!== undefined` test achieves. When nothing at all is
    /// supplied the row is not touched and `updated_at` does not move (`:71`) — the same "a write
    /// that would change nothing is not a write" rule the settings screen already follows.
    func updateProduct(id: String,
                       name: String? = nil,
                       unit: String? = nil,
                       defaultUnitCost: Double? = nil,
                       isService: Bool? = nil,
                       isActive: Bool? = nil,
                       sortOrder: Int? = nil) throws {
        guard !id.isEmpty else { throw ProductCatalogError.invalidID }
        guard try productRowExists(id) else { throw ProductCatalogError.notFound }

        var assignments: [String] = []
        var bindings: [SQLiteValue] = []

        if let name {
            let trimmedName = name.trimmingCharacters(in: jsTrimSet)
            guard !trimmedName.isEmpty else { throw ProductCatalogError.nameRequired }
            assignments.append("name = ?"); bindings.append(.text(trimmedName))
        }
        if let unit {
            guard ProductUnit(rawValue: unit) != nil else { throw ProductCatalogError.unitNotRecognized }
            assignments.append("unit = ?"); bindings.append(.text(unit))
        }
        if let defaultUnitCost {
            assignments.append("default_unit_cost = ?")
            bindings.append(.real(normalizedUnitCost(defaultUnitCost)))
        }
        if let isService {
            assignments.append("is_service = ?"); bindings.append(.integer(isService ? 1 : 0))
        }
        if let isActive {
            assignments.append("is_active = ?"); bindings.append(.integer(isActive ? 1 : 0))
        }
        if let sortOrder {
            assignments.append("sort_order = ?"); bindings.append(.integer(Int64(sortOrder)))
        }
        guard !assignments.isEmpty else { return }

        assignments.append("updated_at = datetime('now')")
        bindings.append(.text(id))
        do {
            try db.run("UPDATE products SET \(assignments.joined(separator: ", ")) WHERE id = ?",
                       bindings)
        } catch {
            throw mapWriteFailure(error)
        }
    }

    /// `DELETE /api/products/:id` — `electron/handlers/products.js:80-88`.
    ///
    /// A bare delete, mirrored as-is: no cascade, no reference check, no cleanup of the
    /// `product_id` columns on `purchases` / `sales` / `purchase_items` / `sales_items` /
    /// `business_document_items`. Those columns are plain TEXT on purpose — `electron/db/index.js`
    /// records at `:390-392` and `:679-682` that an enforced foreign key would make exactly this
    /// statement fail, since `foreign_keys` is ON — so a dangling reference is the accepted
    /// outcome on both sides rather than an accident.
    ///
    /// Two consequences are worth naming because they are invisible from here. Once inventory
    /// exists, a deleted product takes its on-hand quantity and cost with it: Electron's summary
    /// is anchored `FROM products` with the movements LEFT JOINed on, so the row simply stops
    /// being produced while its purchases and sales remain in the file. And telling the user what
    /// a delete will orphan is a screen, not a store — that decision belongs to the slice that
    /// builds the screen.
    func deleteProduct(id: String) throws {
        guard !id.isEmpty else { throw ProductCatalogError.invalidID }
        guard try productRowExists(id) else { throw ProductCatalogError.notFound }
        do {
            try db.run("DELETE FROM products WHERE id = ?", [.text(id)])
        } catch {
            throw mapWriteFailure(error)
        }
    }
}

private extension LedgerStore {
    /// The handler's own existence probe — `electron/handlers/products.js:50`, `:84`.
    /// Not-found is decided by a read, never by a changes count, which is how `update` already
    /// decides it for transactions.
    func productRowExists(_ id: String) throws -> Bool {
        try db.query("SELECT id FROM products WHERE id = ?", [.text(id)]).isEmpty == false
    }
}
