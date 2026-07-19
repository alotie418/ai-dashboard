import XCTest
@testable import SoloLedgerCore

/// 2B-3 C12b-1: LedgerStore open-intent extension + the pure, synchronous MigrationBootDriver
/// store-open sequencer. The class is `@MainActor` so `attemptOpen` (a `@MainActor` function)
/// is callable synchronously and the store factory it invokes demonstrably runs on the main
/// thread — i.e. `attemptOpen` constructs its LedgerStore on the main actor. (This says nothing
/// about how a store is used AFTER it is returned — that isolation is C12b-2's job.)
@MainActor
final class MigrationBootDriverTests: LedgerTestCase {

    private let fm = FileManager.default

    // A decodable owner record, purely to synthesize an `.openExistingCompleted` authorization
    // value (the driver switches on the CASE, never inspecting the evidence).
    private func completedAuthorization() throws -> StoreOpenAuthorization {
        let json = #"{"formatVersion":1,"importID":"x","snapshotIdentitySHA256":"s","attachmentManifestSHA256":"a","sourceDBSHA256":"d","walSHA256":null,"preparedDBIdentity":"sha256:x","transactionsMigrated":0}"#
        let record = try JSONDecoder().decode(ActivationRecord.self, from: Data(json.utf8))
        return .openExistingCompleted(CompletionEvidence(record: record))
    }

    private final class Counters { var confirm = 0; var factory = 0 }

    private func failingFactory(_ c: Counters) -> (StoreOpenIntent) throws -> LedgerStore {
        { _ in c.factory += 1; XCTFail("store factory must not be called"); throw Crash() }
    }
    private struct Crash: Error {}

    // MARK: - LedgerStore open-intent extension

    func testDefaultInitStillCreatesNewDatabase() throws {
        let url = try trackedTempDir().appendingPathComponent("new.db")
        XCTAssertFalse(fm.fileExists(atPath: url.path))
        let store = try LedgerStore(databaseURL: url)                     // source-compatible default
        XCTAssertEqual(try store.schemaVersion(), SchemaMigrator.schemaVersion)
        XCTAssertEqual(try store.categories(locale: .CN).count, 9)        // migrated + seeded
        XCTAssertTrue(fm.fileExists(atPath: url.path))
    }

    func testCreateIfMissingCreatesAndMigrates() throws {
        let url = try trackedTempDir().appendingPathComponent("cim.db")
        XCTAssertFalse(fm.fileExists(atPath: url.path))
        let store = try LedgerStore(databaseURL: url, open: .createIfMissing)
        XCTAssertEqual(try store.schemaVersion(), SchemaMigrator.schemaVersion)
        XCTAssertEqual(try store.categories(locale: .CN).count, 9)
        XCTAssertTrue(fm.fileExists(atPath: url.path))
    }

    func testExistingOnlyOpensExistingDatabase() throws {
        let url = try trackedTempDir().appendingPathComponent("eo.db")
        _ = try LedgerStore(databaseURL: url)                             // create first
        let store = try LedgerStore(databaseURL: url, open: .existingOnly)
        XCTAssertEqual(try store.schemaVersion(), SchemaMigrator.schemaVersion)
    }

    func testExistingOnlyThrowsOnMissingPathAndCreatesNothing() throws {
        let url = try trackedTempDir().appendingPathComponent("ghost.db")
        XCTAssertFalse(fm.fileExists(atPath: url.path))
        XCTAssertThrowsError(try LedgerStore(databaseURL: url, open: .existingOnly))
        XCTAssertFalse(fm.fileExists(atPath: url.path),
                       "existingOnly must never fabricate an empty database at a vanished path")
    }

    // MARK: - openIntent(for:) — authorization → open mode (no default)

    func testOpenIntentMapping() throws {
        XCTAssertEqual(MigrationBootDriver.openIntent(for: .createFreshExpectedAbsent), .createIfMissing)
        XCTAssertEqual(MigrationBootDriver.openIntent(for: .openExistingPlain), .existingOnly)
        XCTAssertEqual(MigrationBootDriver.openIntent(for: try completedAuthorization()), .existingOnly)
    }

    // MARK: - classifyOutcome — ack / selection / blocked never reach an authorization

    func testClassifyOutcomeRoutesNonOpenToUI() {
        // blocked → ui(classify) by classification
        let term = MigrationBlock(code: .sentinelConflict, classification: .terminal)
        XCTAssertEqual(MigrationBootDriver.classifyOutcome(.blocked(term)), .ui(.terminal(term)))
        let retr = MigrationBlock(code: .ioTransient, classification: .retriable)
        XCTAssertEqual(MigrationBootDriver.classifyOutcome(.blocked(retr)), .ui(.retriable(retr)))
        // selection → ui(awaitingImportSelection)
        XCTAssertEqual(MigrationBootDriver.classifyOutcome(.requiresImportSelection([])),
                       .ui(.awaitingImportSelection([])))
        // openStore → an authorization step (the only path that can reach attemptOpen)
        let residual = MigrationResidual(importID: "abc")
        XCTAssertEqual(MigrationBootDriver.classifyOutcome(.openStore(authorization: .openExistingPlain, residual: residual)),
                       .openStore(.openExistingPlain, residual))
    }

    /// Acknowledgement must route to `.ui(.awaitingAcknowledgement(request, unresolved))` with
    /// the SAME payload — never to selection / terminal / an openStore authorization. Exact
    /// equality on the OutcomeStep catches any misrouting (a mismatched case or dropped payload).
    func testClassifyOutcomeRoutesAcknowledgementToUI() {
        let request = AcknowledgementRequest(importID: "imp-1",
                                             snapshotIdentitySHA256: "s",
                                             attachmentManifestSHA256: "a",
                                             preparedDBIdentity: "sha256:p",
                                             unresolvedReportHash: "h")
        let unresolved = UnresolvedReport(items: [
            UnresolvedReport.Item(name: "x.pdf", kind: .missingStagedFile)
        ])
        XCTAssertEqual(
            MigrationBootDriver.classifyOutcome(.requiresAcknowledgement(request: request, unresolved: unresolved)),
            .ui(.awaitingAcknowledgement(request, unresolved)))
        // Guard against a misroute silently passing: it must NOT equal the other UI states.
        let step = MigrationBootDriver.classifyOutcome(.requiresAcknowledgement(request: request, unresolved: unresolved))
        XCTAssertNotEqual(step, .ui(.awaitingImportSelection([])))
        XCTAssertNotEqual(step, .openStore(.openExistingPlain, nil))
    }

    // MARK: - attemptOpen — confirm→open sequencing

    func testProceedOpensExactlyOnceOnMainThread() throws {
        let c = Counters()
        let url = try trackedTempDir().appendingPathComponent("proceed.db")
        let result = MigrationBootDriver.attemptOpen(
            authorization: .createFreshExpectedAbsent, residual: nil,
            confirm: { _ in c.confirm += 1; return .proceed },
            openStore: { intent in
                c.factory += 1
                XCTAssertTrue(Thread.isMainThread, "LedgerStore must be constructed on the main thread")
                XCTAssertEqual(intent, .createIfMissing)
                return try LedgerStore(databaseURL: url, open: intent)
            })
        guard case .opened(let store, let residual) = result else { return XCTFail("expected opened, got \(result)") }
        XCTAssertNil(residual)
        XCTAssertEqual(try store.schemaVersion(), SchemaMigrator.schemaVersion)
        XCTAssertEqual(c.confirm, 1, "confirm must run exactly once")
        XCTAssertEqual(c.factory, 1, "factory must run exactly once")
    }

    func testProceedCarriesResidualThrough() throws {
        let url = try trackedTempDir().appendingPathComponent("res.db")
        // Pre-create the database BEFORE the attempt, so the factory's existingOnly open finds
        // it — the factory itself never creates (that would blur the openExisting authorization
        // boundary this test exists to protect).
        _ = try LedgerStore(databaseURL: url, open: .createIfMissing)
        let residualIn = MigrationResidual(importID: "leftover-1")
        let result = MigrationBootDriver.attemptOpen(
            authorization: try completedAuthorization(), residual: residualIn,
            confirm: { _ in .proceed },
            openStore: { intent in
                XCTAssertEqual(intent, .existingOnly)
                return try LedgerStore(databaseURL: url, open: .existingOnly)
            })
        guard case .opened(_, let residualOut) = result else { return XCTFail() }
        XCTAssertEqual(residualOut, residualIn)
    }

    func testBlockedConfirmDoesNotOpen() {
        let c = Counters()
        let block = MigrationBlock(code: .sentinelConflict, classification: .terminal, params: ["importID": "z"])
        let result = MigrationBootDriver.attemptOpen(
            authorization: .openExistingPlain, residual: nil,
            confirm: { _ in c.confirm += 1; return .blocked(block) },
            openStore: failingFactory(c))
        guard case .ui(.terminal(let b)) = result else { return XCTFail("expected ui(.terminal), got \(result)") }
        XCTAssertEqual(b.code, .sentinelConflict)
        XCTAssertEqual(c.confirm, 1)
        XCTAssertEqual(c.factory, 0, "a blocked confirm must never construct a store")
    }

    func testReResolveConfirmDoesNotOpen() throws {
        let c = Counters()
        let result = MigrationBootDriver.attemptOpen(
            authorization: try completedAuthorization(), residual: nil,
            confirm: { _ in c.confirm += 1; return .reResolve },
            openStore: failingFactory(c))
        guard case .needsReResolve = result else { return XCTFail("expected needsReResolve, got \(result)") }
        XCTAssertEqual(c.confirm, 1)
        XCTAssertEqual(c.factory, 0, "a reResolve confirm must never construct a store")
    }

    func testFactoryThrowMapsToStoreOpenFailedWithoutLeakingErrorText() {
        struct SecretError: Error { let secret = "TOP_SECRET_abcdef" }
        let c = Counters()
        let result = MigrationBootDriver.attemptOpen(
            authorization: .createFreshExpectedAbsent, residual: nil,
            confirm: { _ in .proceed },
            openStore: { _ in c.factory += 1; throw SecretError() })
        guard case .ui(.retriable(let b)) = result else { return XCTFail("expected ui(.retriable), got \(result)") }
        XCTAssertEqual(b.code, .storeOpenFailed)
        XCTAssertEqual(b.classification, .retriable)
        XCTAssertEqual(c.factory, 1)
        for (_, v) in b.params {
            XCTAssertFalse(v.contains("TOP_SECRET"), "raw Error text must not leak into block params")
            XCTAssertFalse(v.contains("SecretError"), "raw Error type must not leak into block params")
        }
    }

    // MARK: - existingOnly-vanish: confirm passes, active unlinked before the open

    func testExistingOnlyVanishFailsClosedAndFabricatesNoDatabase() throws {
        let url = try trackedTempDir().appendingPathComponent("vanish.db")
        _ = try LedgerStore(databaseURL: url)                             // exists at confirm time
        XCTAssertTrue(fm.fileExists(atPath: url.path))
        let result = MigrationBootDriver.attemptOpen(
            authorization: .openExistingPlain, residual: nil,
            confirm: { _ in
                // The active database vanishes AFTER confirm decides .proceed, BEFORE the open.
                try? self.fm.removeItem(at: url)
                return .proceed
            },
            openStore: { intent in
                XCTAssertEqual(intent, .existingOnly)
                return try LedgerStore(databaseURL: url, open: intent)     // existingOnly on a missing path → throws
            })
        guard case .ui(.retriable(let b)) = result else {
            return XCTFail("a vanished active must map to retriable(.storeOpenFailed), got \(result)")
        }
        XCTAssertEqual(b.code, .storeOpenFailed)
        XCTAssertFalse(fm.fileExists(atPath: url.path),
                       "no empty database may be fabricated at the active path after it vanished")
    }

    // MARK: - MigrationUIState / MigrationStep / classify basics

    func testUIStateAndStepBasics() {
        XCTAssertEqual(MigrationStep.resolving, .resolving)
        XCTAssertEqual(MigrationUIState.running(.resolving), .running(.resolving))
        XCTAssertNotEqual(MigrationUIState.none, .running(.resolving))
        XCTAssertEqual(MigrationUIState.cleanupResidual(MigrationResidual(importID: "abc")),
                       .cleanupResidual(MigrationResidual(importID: "abc")))
        XCTAssertEqual(MigrationBootDriver.classify(MigrationBlock(code: .ioTransient, classification: .retriable)),
                       .retriable(MigrationBlock(code: .ioTransient, classification: .retriable)))
        XCTAssertEqual(MigrationBootDriver.classify(MigrationBlock(code: .stagingTampered, classification: .terminal)),
                       .terminal(MigrationBlock(code: .stagingTampered, classification: .terminal)))
    }
}
