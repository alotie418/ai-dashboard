import Foundation

/// Where a migration/import reads FROM. Unifies the four legitimate origins so the rest
/// of the pipeline is source-agnostic. Each source resolves a database URL, an optional
/// WAL sidecar, and an optional attachments root, and brokers read access.
///
/// WAL POLICY (deliberate, per the P0 design): only sources that are LIVE Electron data
/// directories may carry a `-wal`. A standalone `.db` or an export bundle is REQUIRED to
/// be already checkpointed, so we never read a sibling `-wal` for those — reading a stale
/// or unrelated WAL over a copied DB can corrupt it. A user whose live Electron data still
/// has an un-checkpointed WAL must select the whole data DIRECTORY, not a lone `.db`.
///
/// AUTHORIZATION: user-selected URLs are read inside a security scope obtained from the
/// open panel, scoped to a single `withAccess` call — nothing is persisted. This matches
/// the staging-first design: the entire ingest happens within one grant window, so no
/// cross-launch security-scoped bookmark (and no `bookmarks.app-scope` entitlement) is
/// needed.
public enum MigrationSource {
    /// Auto-discovered Electron data inside the app's OWN sandbox container. Only
    /// meaningful when the prior Electron was the MAS build sharing this container.
    case masContainer
    /// A user-selected Electron DATA DIRECTORY (e.g. a non-sandboxed DMG build's
    /// `~/Library/Application Support/SoloLedger/`). May carry a live `-wal`.
    case userSelectedDataDir(URL)
    /// A user-selected export BUNDLE folder (`<dir>/sololedger.db` + `attachments/docs/`).
    /// Already checkpointed → NO wal.
    case exportBundle(URL)
    /// A user-selected standalone, already-checkpointed `.db`. No attachments, NO wal.
    case legacySingleDB(URL)

    /// Stable tag for the import manifest / diagnostics.
    public var kind: String {
        switch self {
        case .masContainer: return "masContainer"
        case .userSelectedDataDir: return "userSelectedDataDir"
        case .exportBundle: return "exportBundle"
        case .legacySingleDB: return "legacySingleDB"
        }
    }

    public func databaseURL() throws -> URL {
        switch self {
        case .masContainer: return try AppPaths.electronLegacyDatabaseURL()
        case .userSelectedDataDir(let dir): return dir.appendingPathComponent(AppPaths.databaseFileName)
        case .exportBundle(let dir): return dir.appendingPathComponent(AppPaths.databaseFileName)
        case .legacySingleDB(let file): return file
        }
    }

    /// The candidate WAL sidecar path (`<db>-wal`), ONLY for live data-directory sources.
    /// `nil` for export bundles and standalone `.db` (which must be pre-checkpointed).
    /// Existence is checked by the caller — this is only the path, not a guarantee.
    public func walURL() throws -> URL? {
        switch self {
        case .masContainer, .userSelectedDataDir:
            return URL(fileURLWithPath: try databaseURL().path + "-wal")
        case .exportBundle, .legacySingleDB:
            return nil
        }
    }

    /// The candidate attachments root (`attachments/docs/`). `nil` for a standalone `.db`.
    /// Existence is checked by the caller.
    public func attachmentsRootURL() throws -> URL? {
        switch self {
        case .masContainer:
            return try AppPaths.electronLegacyAttachmentsURL()
        case .userSelectedDataDir(let dir), .exportBundle(let dir):
            return dir.appendingPathComponent("attachments", isDirectory: true)
                .appendingPathComponent("docs", isDirectory: true)
        case .legacySingleDB:
            return nil
        }
    }

    /// Broker read access for the duration of `body`. User-selected URLs are accessed with
    /// a security scope (from the open panel); the container/auto source needs none. Access
    /// is scoped to THIS call only — no bookmark is persisted. A non-security-scoped URL
    /// (e.g. a plain temp path in tests) simply reads without a scope.
    public func withAccess<T>(_ body: () throws -> T) rethrows -> T {
        switch self {
        case .masContainer:
            return try body()
        case .userSelectedDataDir(let url), .exportBundle(let url), .legacySingleDB(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try body()
        }
    }
}
