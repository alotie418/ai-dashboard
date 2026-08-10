import XCTest
@testable import SoloLedgerCore

/// The write boundary refuses a money value this ledger cannot record, instead of silently
/// recording a different one.
///
/// The defect this suite pins was not "±Infinity reaches SQLite" — it never did through
/// `LedgerStore`. `Transaction.normalized()` has replaced every non-finite number with `0`
/// (and `amountNet` with `nil`) since the first prototype, and `LedgerStoreTests` recorded
/// that as acceptable. In a ledger it is not: the user typed one thing and the row records
/// another, with nothing on screen to say so. Four of the five money columns are not even
/// displayed in the transaction list, so the substitution left no trace at all.
///
/// Such rows are reachable in production. `electron/handlers/transactions.js` normalizes with
/// `Number(x) || 0`, and `Infinity` is truthy, so it passes straight through; its `validate`
/// checks only `amount`. The DMG line therefore writes ±Infinity into `tax_amount`,
/// `tax_rate`, `paid_amount` and `amount_net`, and the native app adopts those databases
/// whole-file. Opening such a row here and pressing Save used to rewrite four columns.
final class NonFiniteWriteGateTests: LedgerTestCase {

    private func good() -> Transaction {
        Transaction(type: .income, date: "2026-01-01", amount: 100)
    }

    // MARK: - Controls: the three facts the design rests on, measured rather than assumed

    /// `Double(_: String)` follows `strtod`, so an overflowing literal is an infinity — not
    /// `nil`. This is why the CSV parser has to judge finiteness itself: a hand-edited cell
    /// reading `1e400` parses successfully and would otherwise reach the store.
    func testControlSwiftParsesAnOverflowingLiteralAsInfinity() {
        XCTAssertEqual(Double("1e400"), .infinity)
        XCTAssertEqual(Double("-1e400"), -.infinity)
        XCTAssertEqual(Double("inf"), .infinity)
        XCTAssertTrue(Double("nan")?.isNaN == true)
        XCTAssertNil(Double("banana"), "control: a non-number is still nil")
    }

    /// `"\(error)"` — what `AppModel` used to put on screen for every failure — dispatches to
    /// `CustomStringConvertible.description`. Asserted because the new refusal deliberately
    /// does NOT travel that way: its payload is a field list, mapped to localized copy.
    func testControlStringInterpolationOfAnErrorUsesItsDescription() {
        let error = LedgerError.nonFiniteAmounts([.taxRate])
        XCTAssertEqual("\(error)", error.description)
        XCTAssertEqual(error.description, "not a recordable number: taxRate")
    }

    /// The formatter behind `TextField(value:format:.number)`. The editor's note has to be
    /// legible without it: whatever this renders is not something a user can retype, which is
    /// why the copy tells them to replace the value rather than naming what they see.
    func testControlTheNumberFormatterRendersANonFiniteValueAsSomethingUnretypable() {
        let rendered = Double.infinity.formatted(.number)
        XCTAssertNil(Double(rendered),
                     "if this round-tripped, a user could retype it and the note would be wrong")
    }

    // MARK: - The gate reads the RAW input

    /// The property that makes call ORDER the whole gate.
    ///
    /// `normalized()` destroys the evidence, so a check placed after it finds nothing. That is
    /// not hypothetical: `Transaction.validationErrors()` has carried `!amount.isFinite` since
    /// `f2207ca` and has never once fired in production for exactly this reason. Moving
    /// `refuseNonFiniteAmounts` below `normalized()` in `LedgerStore` makes every rejection
    /// test in this file pass a finite value and go green — this assertion is what says why.
    func testNormalizationDestroysTheEvidenceTheGateNeedsSoOrderIsLoadBearing() {
        var t = good()
        t.taxRate = .infinity
        XCTAssertEqual(t.nonFiniteAmountFields(), [.taxRate], "raw input: the fault is visible")
        XCTAssertEqual(t.normalized().nonFiniteAmountFields(), [],
                       "after normalized() there is nothing left to find — hence the order")
        XCTAssertEqual(t.normalized().taxRate, 0, "…because it was replaced by a plausible 0")
    }

    /// Every money field, both writes. `amountNet` is absent-able and absence is not a fault.
    func testEveryMoneyFieldIsRefusedOnCreateAndOnUpdate() throws {
        let store = try makeStore()
        try store.create(good())
        let existing = try XCTUnwrap(try store.listTransactions().first)

        let cases: [(TransactionAmountField, (inout Transaction) -> Void)] = [
            (.amount,     { $0.amount = .infinity }),
            (.amountNet,  { $0.amountNet = -.infinity }),
            (.taxAmount,  { $0.taxAmount = .nan }),
            (.taxRate,    { $0.taxRate = .infinity }),
            (.paidAmount, { $0.paidAmount = .nan }),
        ]
        for (field, damage) in cases {
            var fresh = good(); damage(&fresh)
            XCTAssertThrowsError(try store.create(fresh), "create must refuse \(field)") { error in
                XCTAssertEqual(error as? LedgerError, .nonFiniteAmounts([field]))
            }
            var edited = existing; damage(&edited)
            XCTAssertThrowsError(try store.update(edited), "update must refuse \(field)") { error in
                XCTAssertEqual(error as? LedgerError, .nonFiniteAmounts([field]))
            }
        }
        XCTAssertEqual(try store.listTransactions().count, 1, "no refusal may have written a row")
    }

    /// An absent `amountNet` is "not recorded", which the engines read as SQL NULL and fall
    /// back from (`amount_net || amount`). Only a PRESENT non-finite value is a fault.
    func testAnAbsentAmountNetIsNotAFault() throws {
        let store = try makeStore()
        var t = good(); t.amountNet = nil
        XCTAssertNoThrow(try store.create(t))
    }

    /// The refusal names every offending field, in a stable order, so the UI can say all of it.
    func testTheRefusalCarriesEveryOffendingFieldInAStableOrder() throws {
        let store = try makeStore()
        var t = good()
        t.paidAmount = .infinity; t.amount = .infinity; t.taxRate = .nan
        XCTAssertThrowsError(try store.create(t)) { error in
            XCTAssertEqual(error as? LedgerError,
                           .nonFiniteAmounts([.amount, .taxRate, .paidAmount]))
        }
    }

    /// The repair path, which is the reason the editor disables Save rather than locking the
    /// row: replacing the value with a number makes the same write succeed.
    func testReplacingTheValueWithANumberMakesTheSameWriteSucceed() throws {
        let store = try makeStore()
        var t = good(); t.taxAmount = .infinity
        XCTAssertThrowsError(try store.create(t))
        t.taxAmount = 13
        XCTAssertNoThrow(try store.create(t))
        XCTAssertEqual(try store.listTransactions().first?.taxAmount, 13)
    }

    // MARK: - CSV: judged at the parse layer, so the store's gate is unreachable there

    /// A non-finite cell is skipped and counted, exactly as a missing type/date/amount is.
    ///
    /// It must NOT reach `create`: `importTransactionsCSV` runs every row inside one
    /// transaction with no per-row catch, so a throw there would roll back the whole file —
    /// turning one bad cell into a failed import of every good row beside it.
    func testCSVSkipsNonFiniteCellsInsteadOfLettingThemReachTheStore() throws {
        let store = try makeStore()
        let csv = """
        type,date,amount,tax_amount,tax_rate,paid_amount,amount_net
        income,2026-01-01,100,1,2,3,90
        income,2026-01-02,1e400,1,2,3,90
        expense,2026-01-03,50,1e400,2,3,45
        expense,2026-01-04,50,1,1e400,3,45
        expense,2026-01-05,50,1,2,1e400,45
        expense,2026-01-06,50,1,2,3,1e400
        income,2026-01-07,200,1,2,3,190
        """
        let parsed = TransactionCSV.parse(csv)
        XCTAssertEqual(parsed.skipped, 5, "one per money column")
        XCTAssertEqual(parsed.transactions.count, 2)
        XCTAssertTrue(parsed.transactions.allSatisfy { $0.nonFiniteAmountFields().isEmpty },
                      "the store's gate must be unreachable from here")

        let result = try store.importTransactionsCSV(csv)
        XCTAssertEqual(result.imported, 2)
        XCTAssertEqual(result.skipped, 5)
        XCTAssertEqual(try store.listTransactions().count, 2,
                       "the good rows landed — one bad cell did not roll back the file")
    }

    // MARK: - Structure

    /// The gate guards two call sites because there are exactly two. If a third appears, it
    /// will not have the gate, and this goes red before anyone finds out the hard way.
    func testTheLedgerHasExactlyTwoValueWritesIntoTransactions() throws {
        var dir = URL(fileURLWithPath: #filePath)
        dir.deleteLastPathComponent()                       // …/SoloLedgerCoreTests
        dir.deleteLastPathComponent()                       // …/Tests
        dir.deleteLastPathComponent()                       // …/SoloLedger
        let sources = dir.appendingPathComponent("Sources/SoloLedgerCore")

        var insert = 0, update = 0, files = 0
        let walker = FileManager.default.enumerator(atPath: sources.path)
        while let rel = walker?.nextObject() as? String {
            guard rel.hasSuffix(".swift") else { continue }
            files += 1
            let text = try String(contentsOf: sources.appendingPathComponent(rel), encoding: .utf8)
            for line in text.split(separator: "\n")
            where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                if line.contains("INSERT INTO transactions") { insert += 1 }
                if line.contains("UPDATE transactions") { update += 1 }
            }
        }
        XCTAssertGreaterThan(files, 40, "the source tree did not resolve")
        XCTAssertEqual(insert, 1, "a second INSERT would bypass the gate")
        XCTAssertEqual(update, 1, "a second UPDATE would bypass the gate")
    }

    // MARK: - Copy

    /// One sentence per money field, in every language, and no more than that.
    ///
    /// Closed both ways: a sixth key under this prefix is as much a defect as a missing one,
    /// because the App layer's mapping is an exhaustive switch over five cases.
    func testTheRefusalCopyIsExactlyOneSentencePerFieldInEveryLanguage() throws {
        var dir = URL(fileURLWithPath: #filePath)
        dir.deleteLastPathComponent(); dir.deleteLastPathComponent(); dir.deleteLastPathComponent()
        let resources = dir.appendingPathComponent("Sources/SoloLedger/Resources")

        let expected = Set(TransactionAmountField.allCases.map { field -> String in
            switch field {
            case .amount:     return "txn.error.amountNotFinite"
            case .amountNet:  return "txn.error.amountNetNotFinite"
            case .taxAmount:  return "txn.error.taxAmountNotFinite"
            case .taxRate:    return "txn.error.taxRateNotFinite"
            case .paidAmount: return "txn.error.paidAmountNotFinite"
            }
        })
        XCTAssertEqual(expected.count, 5)

        for language in ["en", "zh-Hans", "zh-Hant", "ja", "ko", "fr"] {
            let file = resources.appendingPathComponent("\(language).lproj/Localizable.strings")
            let text = try String(contentsOf: file, encoding: .utf8)
            var found: [String: String] = [:]
            for line in text.split(separator: "\n") where line.hasPrefix("\"txn.error.") {
                let parts = line.split(separator: "\"").map(String.init)
                guard parts.count >= 3 else { continue }
                found[parts[0]] = parts[2]
            }
            XCTAssertEqual(Set(found.keys), expected, "\(language): the txn.error namespace moved")
            XCTAssertEqual(found.count, TransactionAmountField.allCases.count,
                           "\(language): one sentence per field, no more and no fewer")
            for (key, value) in found {
                XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty,
                               "\(language)/\(key) is blank")
                XCTAssertFalse(value.contains("∞") || value.lowercased().contains("infinit")
                               || value.contains("NaN"),
                               "\(language)/\(key) names a symbol the user cannot act on")
            }
        }
    }

    /// Each sentence is produced by exactly one file, and it is the mapping — not a view
    /// reaching for a key directly.
    ///
    /// This is the App-side half of the closed set, checked from here because the App target's
    /// generic test file exercises Core through its public API only and must not gain a
    /// `@testable import`. A key with no case, or a second place building these key strings by
    /// hand, fails here. (`ProductCopyTests` closes the product namespace the same way.)
    func testEachRefusalSentenceIsNamedByTheMappingAndByNothingElse() throws {
        var dir = URL(fileURLWithPath: #filePath)
        dir.deleteLastPathComponent(); dir.deleteLastPathComponent(); dir.deleteLastPathComponent()
        let app = dir.appendingPathComponent("Sources/SoloLedger")

        var namingFiles: [String: Set<String>] = [:]
        var scanned = 0
        let walker = FileManager.default.enumerator(atPath: app.path)
        while let rel = walker?.nextObject() as? String {
            guard rel.hasSuffix(".swift") else { continue }
            scanned += 1
            let text = try String(contentsOf: app.appendingPathComponent(rel), encoding: .utf8)
            for field in TransactionAmountField.allCases {
                let key = "txn.error.\(field == .amount ? "amount" : field.rawValue)NotFinite"
                if text.contains("\"\(key)\"") {
                    namingFiles[key, default: []].insert((rel as NSString).lastPathComponent)
                }
            }
        }
        XCTAssertGreaterThan(scanned, 20, "the app source tree did not resolve")
        for field in TransactionAmountField.allCases {
            let key = "txn.error.\(field == .amount ? "amount" : field.rawValue)NotFinite"
            XCTAssertEqual(namingFiles[key], ["TransactionEditor.swift"],
                           "\(key) is named by \(namingFiles[key]?.sorted() ?? []) — it must come "
                           + "from the one mapping, so the editor and the refusal cannot drift")
        }
    }
}
