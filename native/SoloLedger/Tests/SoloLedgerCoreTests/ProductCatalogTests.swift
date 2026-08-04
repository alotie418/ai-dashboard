import XCTest
@testable import SoloLedgerCore

/// Tests for the product master-data mirror (`Inventory/ProductCatalog.swift`).
///
/// One proposition per test. The corrupt-storage cases assert the storage class SQLite actually
/// ended up with (`typeof()`) before asserting what the decoder made of it — affinity rewrites
/// some bindings on the way in, and a test that assumed otherwise would be pinning a value the
/// column can never hold.
final class ProductCatalogTests: LedgerTestCase {

    // MARK: - Helpers

    /// Insert a row bypassing the write API — the only way to reach the storage classes the
    /// public surface cannot express.
    private func insertRaw(_ store: LedgerStore, _ columns: [String: SQLiteValue]) throws {
        let names = columns.keys.sorted()
        let placeholders = names.map { _ in "?" }.joined(separator: ", ")
        try store.db.run("INSERT INTO products (\(names.joined(separator: ", "))) VALUES (\(placeholders))",
                         names.map { columns[$0]! })
    }

    /// SQLite's own opinion of what is stored in a cell.
    private func storageClass(_ store: LedgerStore, id: String, column: String) throws -> String {
        try store.db.query("SELECT typeof(\(column)) AS t FROM products WHERE id = ?", [.text(id)])
            .first?.string("t") ?? "<no row>"
    }

    private func only(_ page: ProductCatalogPage) throws -> Product {
        try XCTUnwrap(page.products.first, "expected exactly one product, got \(page.products.count)")
    }

    // MARK: - T-A · per-column round trip

    func testEveryColumnSurvivesARoundTrip() throws {
        let store = try makeStore()
        let id = try store.createProduct(name: "Widget",
                                         unit: ProductUnit.box.rawValue,
                                         defaultUnitCost: 12.5,
                                         isService: true,
                                         isActive: false,
                                         sortOrder: 7)
        let product = try only(store.productCatalog())
        XCTAssertEqual(product.id, id)
        XCTAssertEqual(product.name, "Widget")
        XCTAssertEqual(product.unit, "box")
        XCTAssertEqual(product.defaultUnitCost, 12.5)
        XCTAssertTrue(product.isService)
        XCTAssertFalse(product.isActive)
        XCTAssertEqual(product.sortOrder, 7)
        XCTAssertNotNil(product.createdAt)
        XCTAssertNotNil(product.updatedAt)
    }

    func testTheNameIsTrimmedIncludingTheZeroWidthSpaceJavaScriptAlsoTrims() throws {
        let store = try makeStore()
        _ = try store.createProduct(name: "\u{FEFF} \t Widget \n")
        XCTAssertEqual(try only(store.productCatalog()).name, "Widget")
    }

    func testANameOfNothingButTrimmableCharactersIsRefused() throws {
        let store = try makeStore()
        for blank in ["", "   ", "\t\n", "\u{FEFF}"] {
            XCTAssertThrowsError(try store.createProduct(name: blank), "\(blank.debugDescription) must be refused") {
                XCTAssertEqual($0 as? ProductCatalogError, .nameRequired)
            }
        }
        XCTAssertEqual(try store.productCatalog().products.count, 0)
    }

    func testALongNameIsStoredWholeBecauseTheHandlerImposesNoLengthCap() throws {
        let store = try makeStore()
        let long = String(repeating: "名", count: 400)
        _ = try store.createProduct(name: long)
        XCTAssertEqual(try only(store.productCatalog()).name, long)
    }

    func testSortOrderAcceptsNegativeZeroAndPositive() throws {
        for value in [-5, 0, 42] {
            let store = try makeStore()
            _ = try store.createProduct(name: "P", sortOrder: value)
            XCTAssertEqual(try only(store.productCatalog()).sortOrder, value)
        }
    }

    // MARK: - T-B · the unit whitelist

    func testAllElevenUnitsAreAccepted() throws {
        XCTAssertEqual(ProductUnit.allCases.count, 11)
        XCTAssertEqual(ProductUnit.allCases.map(\.rawValue),
                       ["piece", "box", "bag", "kg", "ton", "liter", "bottle", "pack",
                        "session", "hour", "month"],
                       "the keys and their order mirror VALID_UNITS in products.js:8")
        for unit in ProductUnit.allCases {
            let store = try makeStore()
            _ = try store.createProduct(name: "P", unit: unit.rawValue)
            XCTAssertEqual(try only(store.productCatalog()).unit, unit.rawValue)
        }
    }

    func testAnUnrecognisedUnitIsRefusedOnCreateAndOnUpdate() throws {
        let store = try makeStore()
        for bad in ["", "parsec", "KG", "Piece", " kg"] {
            XCTAssertThrowsError(try store.createProduct(name: "P", unit: bad), bad.debugDescription) {
                XCTAssertEqual($0 as? ProductCatalogError, .unitNotRecognized)
            }
        }
        let id = try store.createProduct(name: "P")
        for bad in ["", "parsec", "KG"] {
            XCTAssertThrowsError(try store.updateProduct(id: id, unit: bad), bad.debugDescription) {
                XCTAssertEqual($0 as? ProductCatalogError, .unitNotRecognized)
            }
        }
        XCTAssertEqual(try only(store.productCatalog()).unit, "piece", "a refused unit changed nothing")
    }

    // MARK: - T-C · create defaults

    func testCreateAppliesTheHandlersDefaults() throws {
        let store = try makeStore()
        _ = try store.createProduct(name: "Bare")
        let product = try only(store.productCatalog())
        XCTAssertEqual(product.unit, "piece")
        XCTAssertEqual(product.defaultUnitCost, 0)
        XCTAssertFalse(product.isService)
        XCTAssertTrue(product.isActive)
        XCTAssertEqual(product.sortOrder, 999)
    }

    func testANegativeOrNonFiniteCostIsCoercedToZero() throws {
        for bad in [-5, -0.01, Double.nan, .infinity, -.infinity] {
            let store = try makeStore()
            _ = try store.createProduct(name: "P", defaultUnitCost: bad)
            XCTAssertEqual(try only(store.productCatalog()).defaultUnitCost, 0, "\(bad) must land on 0")
        }
    }

    // MARK: - T-D · partial update

    func testUpdatingOneFieldLeavesEveryOtherFieldAlone() throws {
        let store = try makeStore()
        let id = try store.createProduct(name: "Widget", unit: ProductUnit.kg.rawValue,
                                         defaultUnitCost: 3, isService: true, isActive: false,
                                         sortOrder: 5)
        try store.updateProduct(id: id, name: "Widget v2")
        let product = try only(store.productCatalog())
        XCTAssertEqual(product.name, "Widget v2")
        XCTAssertEqual(product.unit, "kg")
        XCTAssertEqual(product.defaultUnitCost, 3)
        XCTAssertTrue(product.isService)
        XCTAssertFalse(product.isActive)
        XCTAssertEqual(product.sortOrder, 5)
    }

    func testUpdateRefusesAnEmptyNameWithoutWritingAnything() throws {
        let store = try makeStore()
        let id = try store.createProduct(name: "Widget")
        XCTAssertThrowsError(try store.updateProduct(id: id, name: "  ")) {
            XCTAssertEqual($0 as? ProductCatalogError, .nameRequired)
        }
        XCTAssertEqual(try only(store.productCatalog()).name, "Widget")
    }

    func testUpdatingAMissingProductThrowsNotFoundAndAnEmptyIDThrowsInvalidID() throws {
        let store = try makeStore()
        XCTAssertThrowsError(try store.updateProduct(id: "nope", name: "x")) {
            XCTAssertEqual($0 as? ProductCatalogError, .notFound)
        }
        XCTAssertThrowsError(try store.updateProduct(id: "", name: "x")) {
            XCTAssertEqual($0 as? ProductCatalogError, .invalidID)
        }
    }

    // MARK: - T-E · the two adjudicated create/update asymmetries

    /// A-1. Electron's create reads `is_active === false ? 0 : 1` and its update reads
    /// `b.is_active ? 1 : 0`, so `0` / `null` / `"no"` mean *active* on one path and *inactive*
    /// on the other. Typing the parameter `Bool` removes those inputs from the domain; on the
    /// two values both sides can express, create and update must agree.
    func testCreateAndUpdateAgreeOnEveryBooleanTheAPICanExpress() throws {
        for flag in [true, false] {
            let created = try makeStore()
            _ = try created.createProduct(name: "P", isService: flag, isActive: flag)
            let viaCreate = try only(created.productCatalog())

            let updated = try makeStore()
            let id = try updated.createProduct(name: "P", isService: !flag, isActive: !flag)
            try updated.updateProduct(id: id, isService: flag, isActive: flag)
            let viaUpdate = try only(updated.productCatalog())

            XCTAssertEqual(viaCreate.isService, flag)
            XCTAssertEqual(viaUpdate.isService, flag)
            XCTAssertEqual(viaCreate.isActive, flag)
            XCTAssertEqual(viaUpdate.isActive, flag)
        }
    }

    /// A-2. The 999-vs-0 default is a real difference in the handler, kept rather than smoothed:
    /// create defaults an omitted `sortOrder` to 999, and update treats an omitted one as "do not
    /// touch this column" instead of defaulting it at all.
    func testAnOmittedSortOrderMeansNineNineNineOnCreateAndUntouchedOnUpdate() throws {
        let store = try makeStore()
        let id = try store.createProduct(name: "P")
        XCTAssertEqual(try only(store.productCatalog()).sortOrder, 999)

        try store.updateProduct(id: id, name: "P2")
        XCTAssertEqual(try only(store.productCatalog()).sortOrder, 999, "an omitted sortOrder is not reset")

        try store.updateProduct(id: id, sortOrder: 0)
        XCTAssertEqual(try only(store.productCatalog()).sortOrder, 0, "an explicit 0 is honoured")
    }

    // MARK: - T-F · every storage class, every column (D-1 … D-7)

    /// D-1 / D-7. `id` and `name` are what identifies a row; a cell with no text reading there
    /// makes the row unusable, and it is COUNTED rather than dropped.
    func testARowWhoseIdOrNameHasNoTextReadingIsCountedNotDropped() throws {
        for broken in ["id", "name"] {
            let store = try makeStore()
            _ = try store.createProduct(name: "Good")
            var columns: [String: SQLiteValue] = ["id": .text("p2"), "name": .text("Bad")]
            columns[broken] = .blob(Data([0x00, 0xff]))
            try insertRaw(store, columns)

            let page = try store.productCatalog()
            XCTAssertEqual(page.products.count, 1, "\(broken): the good row still decodes")
            XCTAssertEqual(page.unreadableCount, 1, "\(broken): the broken row is counted")
            XCTAssertEqual(page.products.map(\.name), ["Good"])
        }
    }

    /// A NULL id is reachable: `id TEXT PRIMARY KEY` does not imply NOT NULL in SQLite.
    func testANullIdIsReachableAndCounted() throws {
        let store = try makeStore()
        try insertRaw(store, ["id": .null, "name": .text("Orphan")])
        XCTAssertEqual(try store.db.query("SELECT COUNT(*) AS c FROM products WHERE id IS NULL")
                        .first?.int("c"), 1, "SQLite really did store a NULL primary key")
        let page = try store.productCatalog()
        XCTAssertEqual(page.products.count, 0)
        XCTAssertEqual(page.unreadableCount, 1)
    }

    /// The count is the ONLY difference from a silent drop, so it has to add up over several rows.
    func testTheUnreadableCountIsTheNumberOfUndecodableRows() throws {
        let store = try makeStore()
        _ = try store.createProduct(name: "A")
        _ = try store.createProduct(name: "B")
        for index in 0..<3 {
            try insertRaw(store, ["id": .text("broken-\(index)"), "name": .blob(Data([0x01]))])
        }
        let page = try store.productCatalog()
        XCTAssertEqual(page.products.count, 2)
        XCTAssertEqual(page.unreadableCount, 3)
    }

    /// G2. `unit` does NOT gate the decode; a unit with no text reading is reported as `nil` and
    /// the row is still a product.
    func testAUnitWithNoTextReadingKeepsTheRowAndReadsAsNil() throws {
        let store = try makeStore()
        try insertRaw(store, ["id": .text("p1"), "name": .text("Widget"), "unit": .blob(Data([0x01, 0x02]))])
        XCTAssertEqual(try storageClass(store, id: "p1", column: "unit"), "blob")
        let page = try store.productCatalog()
        XCTAssertEqual(page.unreadableCount, 0)
        let product = try only(page)
        XCTAssertEqual(product.name, "Widget")
        XCTAssertNil(product.unit)
    }

    /// The read path re-validates nothing — an out-of-whitelist unit comes back verbatim, exactly
    /// as `products.js:11-18` returns it.
    func testAnOutOfWhitelistUnitReadsBackVerbatim() throws {
        let store = try makeStore()
        try insertRaw(store, ["id": .text("p1"), "name": .text("Widget"), "unit": .text("parsec")])
        XCTAssertEqual(try only(store.productCatalog()).unit, "parsec")
    }

    /// D-2 / D-3 / D-4. `is_service` / `is_active` follow JS truthiness over the storage class, so
    /// the two apps agree on every value the column can hold. The first column of each case is
    /// what SQLite actually stores after affinity — a text "0" never survives as text.
    func testTheBooleanColumnsFollowJavaScriptTruthinessForEveryStorageClass() throws {
        let cases: [(bound: SQLiteValue, expectedStorage: String, truthy: Bool, label: String)] = [
            (.null, "null", false, "NULL"),
            (.integer(0), "integer", false, "INTEGER 0"),
            (.integer(1), "integer", true, "INTEGER 1"),
            (.integer(-1), "integer", true, "INTEGER -1"),
            (.real(0.5), "real", true, "REAL 0.5 — JS !!0.5 is true"),
            (.real(0), "integer", false, "REAL 0 (affinity demotes it to INTEGER 0)"),
            (.text(""), "text", false, "TEXT \"\" — the only falsy string"),
            (.text("abc"), "text", true, "TEXT \"abc\""),
            (.text("0"), "integer", false, "TEXT \"0\" (affinity converts it to INTEGER 0)"),
            (.blob(Data()), "blob", true, "zero-length BLOB — every object is truthy"),
            (.blob(Data([0x00])), "blob", true, "BLOB 0x00"),
        ]
        for column in ["is_service", "is_active"] {
            for testCase in cases {
                let store = try makeStore()
                try insertRaw(store, ["id": .text("p1"), "name": .text("W"), column: testCase.bound])
                XCTAssertEqual(try storageClass(store, id: "p1", column: column),
                               testCase.expectedStorage,
                               "\(column) / \(testCase.label): storage class")
                let product = try only(store.productCatalog())
                let read = column == "is_service" ? product.isService : product.isActive
                XCTAssertEqual(read, testCase.truthy, "\(column) / \(testCase.label): decoded value")
            }
        }
    }

    /// The reason the decoder asks SQLite for `typeof` instead of trusting the value: a
    /// zero-length BLOB reaches Swift as `.null`, because `sqlite3_column_blob` returns a null
    /// pointer for one and `SQLiteDatabase.readColumn` falls through to its `else`. JavaScript
    /// treats those two as opposites — an empty `Buffer` is truthy, `null` is falsy — so without
    /// the `typeof` column an empty-blob flag would read inactive here and active in Electron.
    ///
    /// Pinning the wrapper's behaviour here means removing the `typeof` columns as a
    /// "simplification" turns this red, with the reason attached.
    func testAZeroLengthBlobReachesSwiftAsNullWhichIsWhyTypeofIsConsulted() throws {
        let store = try makeStore()
        try insertRaw(store, ["id": .text("p1"), "name": .text("W"), "is_active": .blob(Data())])
        XCTAssertEqual(try storageClass(store, id: "p1", column: "is_active"), "blob",
                       "SQLite stores it as a blob")
        let raw = try XCTUnwrap(store.db.query("SELECT is_active FROM products WHERE id = 'p1'").first)
        XCTAssertEqual(raw["is_active"], .null,
                       "but the wrapper collapses a zero-length blob to .null — the whole problem")
        XCTAssertTrue(try only(store.productCatalog()).isActive,
                      "the decoder still agrees with JS because it asked typeof")
    }

    /// A cell with no numeric reading falls back to the column's own declared default, and the
    /// row is kept — cost is stored, never computed with, at this slice.
    func testACostWithNoNumericReadingReadsAsZeroAndKeepsTheRow() throws {
        for (bound, expectedStorage) in [(SQLiteValue.null, "null"),
                                         (.text("abc"), "text"),
                                         (.blob(Data([0x09])), "blob")] {
            let store = try makeStore()
            try insertRaw(store, ["id": .text("p1"), "name": .text("W"), "default_unit_cost": bound])
            XCTAssertEqual(try storageClass(store, id: "p1", column: "default_unit_cost"), expectedStorage)
            let page = try store.productCatalog()
            XCTAssertEqual(page.unreadableCount, 0)
            XCTAssertEqual(try only(page).defaultUnitCost, 0)
        }
    }

    /// D-5. A REAL `sort_order` is reachable because the handler binds the caller's raw number;
    /// the model types it as an integer, so it truncates toward zero.
    func testAFractionalSortOrderTruncatesTowardZero() throws {
        let store = try makeStore()
        try insertRaw(store, ["id": .text("p1"), "name": .text("W"), "sort_order": .real(1.5)])
        XCTAssertEqual(try storageClass(store, id: "p1", column: "sort_order"), "real")
        XCTAssertEqual(try only(store.productCatalog()).sortOrder, 1)
    }

    func testASortOrderWithNoIntegerReadingFallsBackToTheColumnDefault() throws {
        for bound in [SQLiteValue.null, .text("abc"), .blob(Data([0x01]))] {
            let store = try makeStore()
            try insertRaw(store, ["id": .text("p1"), "name": .text("W"), "sort_order": bound])
            XCTAssertEqual(try only(store.productCatalog()).sortOrder, 0)
        }
    }

    /// Timestamps are optional on the model, so a cell with no text reading is representable
    /// without losing the row.
    func testTimestampsWithNoTextReadingDecodeAsNilWithoutLosingTheRow() throws {
        let store = try makeStore()
        try insertRaw(store, ["id": .text("p1"), "name": .text("W"),
                              "created_at": .blob(Data([0x01])), "updated_at": .blob(Data([0x02]))])
        let page = try store.productCatalog()
        XCTAssertEqual(page.unreadableCount, 0)
        let product = try only(page)
        XCTAssertNil(product.createdAt)
        XCTAssertNil(product.updatedAt)
    }

    // MARK: - T-G · the infinity rule

    /// D-6. `Int(Double.infinity)` traps in Swift, so the cost must be read with `row.double` and
    /// never with `row.int`. Reading an infinity back intact is the observable proof that it is.
    func testAnInfiniteCostIsReadBackIntactRatherThanTrapping() throws {
        let store = try makeStore()
        try insertRaw(store, ["id": .text("p1"), "name": .text("W"),
                              "default_unit_cost": .real(.infinity)])
        XCTAssertEqual(try storageClass(store, id: "p1", column: "default_unit_cost"), "real")
        let product = try only(store.productCatalog())
        XCTAssertEqual(product.defaultUnitCost, .infinity)
        XCTAssertTrue(product.defaultUnitCost.isInfinite)
    }

    // MARK: - T-H · id uniqueness

    func testTheGeneratedIdsAreUniqueAcrossARapidBurst() throws {
        let store = try makeStore()
        var ids = Set<String>()
        for index in 0..<200 {
            ids.insert(try store.createProduct(name: "Burst-\(index)"))
        }
        XCTAssertEqual(ids.count, 200)
        XCTAssertEqual(try store.productCatalog().products.count, 200)
        XCTAssertTrue(ids.allSatisfy { $0.hasPrefix("prod-") })
    }

    // MARK: - T-I · delete (Q-D3)

    func testDeleteRemovesTheRowAndRefusesAMissingOrEmptyID() throws {
        let store = try makeStore()
        let keep = try store.createProduct(name: "Keep")
        let drop = try store.createProduct(name: "Drop")
        try store.deleteProduct(id: drop)
        XCTAssertEqual(try store.productCatalog().products.map(\.id), [keep])

        XCTAssertThrowsError(try store.deleteProduct(id: drop), "a second delete is not silent") {
            XCTAssertEqual($0 as? ProductCatalogError, .notFound)
        }
        XCTAssertThrowsError(try store.deleteProduct(id: "")) {
            XCTAssertEqual($0 as? ProductCatalogError, .invalidID)
        }
    }

    /// Q-D1. The delete is bare: rows that referenced the product keep a dangling `product_id`,
    /// because an enforced foreign key would make this very statement fail.
    func testDeleteLeavesReferencingRowsInPlaceWithADanglingProductID() throws {
        let store = try makeStore()
        let id = try store.createProduct(name: "Steel")
        try store.db.run("""
            INSERT INTO purchases (id, date, product_id, product_name_snapshot, unit_snapshot)
            VALUES ('pu1', '2026-01-01', ?, 'Steel', 'kg')
            """, [.text(id)])
        try store.deleteProduct(id: id)

        let rows = try store.db.query("SELECT product_id, product_name_snapshot FROM purchases WHERE id = 'pu1'")
        XCTAssertEqual(rows.count, 1, "the purchase survives its product")
        XCTAssertEqual(rows.first?.string("product_id"), id, "the reference is left dangling, not cleared")
        XCTAssertEqual(rows.first?.string("product_name_snapshot"), "Steel")
    }

    // MARK: - T-L · idempotency, proved with a sentinel

    /// An update that supplies nothing must not touch the row. `updated_at` cannot prove this on
    /// its own — `datetime('now')` has one-second resolution, so a rewrite inside the same second
    /// is invisible. A sentinel only this test knows can only survive if nothing was written.
    func testAnUpdateThatSuppliesNothingDoesNotTouchTheRow() throws {
        let store = try makeStore()
        let id = try store.createProduct(name: "Widget")
        let sentinel = "SENTINEL-9d1f4c0b-not-a-timestamp"
        try store.db.run("UPDATE products SET updated_at = ? WHERE id = ?", [.text(sentinel), .text(id)])

        try store.updateProduct(id: id)

        let after = try only(store.productCatalog())
        XCTAssertEqual(after.updatedAt, sentinel, "the empty update wrote nothing")
        XCTAssertEqual(after.name, "Widget")
    }

    func testAnUpdateThatSuppliesAFieldDoesMoveTheTimestamp() throws {
        let store = try makeStore()
        let id = try store.createProduct(name: "Widget")
        let sentinel = "SENTINEL-9d1f4c0b-not-a-timestamp"
        try store.db.run("UPDATE products SET updated_at = ? WHERE id = ?", [.text(sentinel), .text(id)])

        try store.updateProduct(id: id, name: "Widget v2")

        let after = try only(store.productCatalog())
        XCTAssertNotEqual(after.updatedAt, sentinel, "a real update stamps updated_at")
    }

    // MARK: - T-M · the write is durable, not just in memory

    func testEveryWriteIsVisibleToASecondConnection() throws {
        let url = try tempDatabaseURL()
        let writer = try LedgerStore(databaseURL: url)
        let id = try writer.createProduct(name: "Widget", unit: ProductUnit.kg.rawValue,
                                          defaultUnitCost: 4, sortOrder: 3)
        XCTAssertEqual(try LedgerStore(databaseURL: url).productCatalog().products.map(\.name), ["Widget"])

        try writer.updateProduct(id: id, name: "Widget v2")
        XCTAssertEqual(try LedgerStore(databaseURL: url).productCatalog().products.map(\.name), ["Widget v2"])

        try writer.deleteProduct(id: id)
        XCTAssertEqual(try LedgerStore(databaseURL: url).productCatalog().products.count, 0)
    }

    // MARK: - Ordering

    /// The handler orders in SQL and so does this. Reproducing it in Swift would need a comparison
    /// over storage classes that the decoded model no longer carries.
    func testTheListOrderIsActiveFirstThenSortOrderThenName() throws {
        let store = try makeStore()
        _ = try store.createProduct(name: "B active", sortOrder: 2)
        _ = try store.createProduct(name: "A active", sortOrder: 2)
        _ = try store.createProduct(name: "First", sortOrder: 1)
        _ = try store.createProduct(name: "Retired", isActive: false, sortOrder: 0)
        XCTAssertEqual(try store.productCatalog().products.map(\.name),
                       ["First", "A active", "B active", "Retired"])
    }

    // MARK: - T-K · nothing constructs any of this yet

    /// The read/write layer ships BEFORE the copy and the view, so no production source file may
    /// name any of it. Whole-identifier matching, and `//` comments are not uses — the declaring
    /// file names these symbols constantly and is excluded by path, not by pattern.
    func testNoProductionSourceFileNamesTheCatalogYet() throws {
        let forbidden = ["Product", "ProductUnit", "ProductCatalogPage", "ProductCatalogError",
                         "productCatalog", "createProduct", "updateProduct", "deleteProduct"]
        var offenders: [String] = []
        for (path, text) in try Self.productionSources() {
            let code = text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> String in
                    guard let comment = line.range(of: "//") else { return String(line) }
                    return String(line[line.startIndex..<comment.lowerBound])
                }
                .joined(separator: "\n")
            for symbol in forbidden {
                let pattern = "(^|[^A-Za-z0-9_])\(symbol)([^A-Za-z0-9_]|$)"
                if code.range(of: pattern, options: .regularExpression) != nil {
                    offenders.append("\(path): \(symbol)")
                }
            }
        }
        XCTAssertEqual(offenders, [], "the catalog must still be unreachable")
    }

    /// The scan is worthless if it cannot see a use, so prove it fires.
    func testTheUnreachabilityScanDetectsAUseAndIgnoresAComment() {
        let pattern = "(^|[^A-Za-z0-9_])createProduct([^A-Za-z0-9_]|$)"
        XCTAssertNotNil("let id = try store.createProduct(name: \"x\")".range(of: pattern, options: .regularExpression))
        XCTAssertNil("createProductLater()".range(of: pattern, options: .regularExpression),
                     "a longer identifier is not a hit")
        XCTAssertNil("recreateProduct()".range(of: pattern, options: .regularExpression),
                     "a longer identifier is not a hit")
    }

    /// The scan must actually be reading files, or an empty offender list proves nothing.
    func testTheUnreachabilityScanReadsTheWholeProductionTree() throws {
        let sources = try Self.productionSources()
        XCTAssertGreaterThan(sources.count, 40, "the production tree should be far larger than this")
        XCTAssertTrue(sources.contains { $0.path.hasSuffix("Store/LedgerStore.swift") })
        XCTAssertTrue(sources.contains { $0.path.hasSuffix("Views/RootView.swift") })
        XCTAssertFalse(sources.contains { $0.path.hasSuffix("Inventory/ProductCatalog.swift") },
                       "the declaring file is excluded by path")
    }

    // MARK: - Scan helpers

    /// …/native/SoloLedger/Tests/SoloLedgerCoreTests/<this>.swift → …/native/SoloLedger
    private static func packageRoot() -> URL {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { dir.deleteLastPathComponent() }
        return dir
    }

    /// Every `.swift` file under `Sources/` — both the Core library and the SwiftUI App target —
    /// except the one that declares the catalog.
    private static func productionSources() throws -> [(path: String, text: String)] {
        let root = packageRoot().appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(atPath: root.path) else {
            XCTFail("cannot enumerate \(root.path)"); return []
        }
        var out: [(String, String)] = []
        for case let relative as String in walker where relative.hasSuffix(".swift") {
            if relative.hasSuffix("Inventory/ProductCatalog.swift") { continue }
            let url = root.appendingPathComponent(relative)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                XCTFail("cannot read \(relative)"); continue
            }
            out.append((relative, text))
        }
        return out
    }
}
