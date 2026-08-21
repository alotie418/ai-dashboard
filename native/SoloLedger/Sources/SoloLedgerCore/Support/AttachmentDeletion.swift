import Foundation

/// Removing ONE attachment copy that nothing points at any more — the third item of the twelfth
/// ruling, and the primitive `docs/BUSINESS_DOCUMENTS_SPEC.md` §3 requires to exist and to be proven
/// BEFORE any deleting seam is connected.
///
/// ## D-6 connects all five seams
///
/// D-4's ruling ③ left five places where a copy is orphaned — re-pick, remove, cancel, replace-or-
/// clear on save, and delete-the-document — and connected NONE of them. The storage-atomicity round
/// landed this primitive and its proofs so that connecting would be a wiring change against something
/// already measured, rather than a new mechanism written under the pressure of a page that needs to
/// ship. **D-6 connected all five**, once the thirteenth ruling answered the two prerequisites the
/// residuals below demand.
///
/// The App reaches ``deleteIfUnreferenced(_:in:using:)``, which returns **nothing**. That is the
/// fourteenth ruling and it is structural, not stylistic: the twelfth ruling forbids a failed cleanup
/// from being reported as a failed save, and a `Void` entry point makes writing that impossible
/// rather than merely wrong. ``attemptDeleteIfUnreferenced(_:in:using:hooks:)`` keeps the outcome and
/// the test hook, and stays internal.
///
/// ## What it will not do
///
///  * **It does not know where attachments live.** The directory is a parameter. `AppPaths`'s
///    accessor CREATES the directory it names, so calling it from Core would make a mere deletion
///    attempt materialise a real folder — under the preview data root during tests, and under the
///    production container in an unsandboxed harness. The capability is the caller's to hand over.
///  * **It does not follow a name.** The directory is bound `O_NOFOLLOW` and every step afterwards
///    runs against THAT descriptor (`openat` / `fstatat` / `unlinkat`). Renaming the directory, or
///    swapping a parent component, cannot redirect the `unlink` onto something else: a descriptor
///    tracks the inode, not the path.
///  * **It does not trust the name either.** The file is bound as a regular-file inode first
///    (`BoundRegularFile.open`, `O_NOFOLLOW`, `fstat` `S_IFREG`), and the `unlink` runs only after the
///    name has been seen to resolve to that same device+inode (`unlinkIfStillBound`). A symlink, a
///    directory, a device node, or a stand-in put there before that check is left exactly where it is
///    — but see the adjacent-syscall residual below for the part that check cannot cover.
///  * **It does not accept a path it cannot parse.** ``AttachmentRelPath`` is the closed set:
///    `attachments/docs/<name>` and nothing else. Absolute paths, traversal, extra slashes, empty or
///    non-ASCII names are refused before the filesystem is touched at all.
///  * **It does not throw.** Deleting a copy is best-effort on both sides — `attachments.js`'s
///    `safeDeleteAttachment` swallows its own failure — and the database write that orphaned the copy
///    has already succeeded by the time anyone gets here. Turning a failed cleanup into a save error
///    would report a successful write as a failure. The outcome is returned for tests and for a
///    future log, never for a user-facing message: no new error case, no new key, no new copy.
///
/// ## The two authoritative reference columns
///
/// `transactions.attachment_path` and `business_documents.tax_invoice_attachment_path`. **Both**, not
/// just the documents one: the same `attachments/docs/` directory holds the copies BOTH features
/// make, Electron's importer wrote them side by side, and `AttachmentReferenceAuditor` already treats
/// the pair as the ledger's complete reference set. Consulting only the documents column would delete
/// a receipt a transaction still points at.
///
/// Matching is deliberately **wider** than the comparison `DocumentStore` uses for ownership. There,
/// `StatementText.areEqual` reproduces JS `===` (code-unit identity) because the mirror's rule is
/// "exactly equal". Here the two mistakes are not symmetric: calling a referenced file unreferenced
/// destroys it, calling an unreferenced file referenced merely keeps it. So a stored value counts as
/// a reference whenever its final path segment names the same file — canonical equivalence, and
/// **case-insensitively**, which catches the spellings the whitelist would reject and a code-unit
/// test would miss.
///
/// **The case fold is not decoration; it is the difference between keeping a file and destroying
/// one.** The default macOS volume is case-INSENSITIVE (measured: `A.pdf` and `a.pdf` are one inode
/// on APFS as shipped), and `AttachmentName` admits `A-Z`. A reference stored as
/// `attachments/docs/A.pdf` and a deletion asked for `attachments/docs/a.pdf` therefore name ONE
/// file; a case-sensitive scan would report it unreferenced and `openat` would then hand back the
/// very inode the other row points at. Folding here costs at most an unreferenced copy left on disk
/// on a case-sensitive volume — the harmless direction.
///
/// ## The window that IS closed, and the one that is NOT
///
/// **Closed — D, between the scan and the `unlink`.** Both happen inside
/// ``SQLiteDatabase/immediateTransaction(_:)``, so the write lock is held across them and no other
/// connection can commit a new reference in between. `AttachmentDeletionTests` proves it with a real
/// second connection on the same file.
///
/// **NOT closed — the adjacent-syscall window inside the unlink itself (raised in review of #494;
/// the thirteenth ruling ACCEPTS AND REGISTERS it).** `unlinkIfStillBound` is `fstatat` and then `unlinkat(parent.fd, name, 0)`,
/// and `unlinkat` removes a NAME. A same-UID process that swaps the entry between those two calls has
/// its replacement removed instead of the bound inode — so "a replacement is left alone" holds for a
/// swap that is already in place when the identity check runs, and NOT for one landing inside those
/// two adjacent syscalls. The `matchesChild` call above it does not narrow this: it is a second check-then-act, and
/// it is there to REPORT ``Outcome/movedUnderUs`` rather than to prevent anything.
///
/// **Darwin offers no unlink-by-inode**, so this cannot be closed by writing the call differently; a
/// rename-to-unique-then-unlink scheme moves the window rather than removing it and adds an orphan on
/// failure. The twelfth ruling directed this primitive to REUSE `unlinkIfStillBound` and not to ship a
/// variant of it, so the shape is not the implementation's to change. It is the same class of
/// same-UID, point-in-time residual `PreparedImportActivator` already registers for its own
/// fingerprint→rename gaps, and Electron's `safeDeleteAttachment` is strictly weaker (`fs.rmSync` by
/// path, no identity check at all). **Registered, not fixed, and not defended as harmless.**
///
/// **The thirteenth ruling accepted it as registered residual** — candidate (a) of the three the spec
/// listed, the others being a rename-then-unlink scheme and an exclusively-owned directory. It keeps
/// `unlinkIfStillBound` as it is, ships no variant, and explicitly acknowledges that a same-UID
/// process swapping the entry between those two syscalls can have its stand-in removed. Four
/// sentences are forbidden anywhere in this chapter as a result: that a stand-in is never removed,
/// that the deletion is atomic against the bound inode, that the adjacent-syscall window is closed,
/// and that the directory is exclusively owned at the system level. The ruling is void — and deletion
/// wiring must be suspended — if a supported in-App path can concurrently replace a directory entry,
/// if the attachments directory becomes shared or synced, or if the product must promise resistance
/// to same-UID writers.
///
/// **NOT closed — E, after the file is gone.** Nothing in this design stops a non-cooperating or
/// stale writer from claiming the same relative path afterwards: the name is free again the moment
/// the entry is unlinked, and a writer that computed `attachments/docs/<name>` before the deletion can
/// still store it. **Nothing here pretends otherwise.** It is registered in the spec as the
/// storage-atomicity residual, and it WAS a mandatory prerequisite for D-6.
///
/// **The thirteenth ruling answered it: coordination among cooperating writers, with NO schema
/// change** — the first of the two candidates the spec listed, the second being a schema-level
/// ownership record Q9 forbids without its own ruling. Supported App writers keep four promises: a
/// fresh name every pick, no-overwrite on create, never re-storing a path the draft has lost, and one
/// deletion entry point — this one. **The same ruling ACCEPTS what that leaves**: an external or stale
/// writer can still re-claim a freed name, and E must not be described as closed. An upgrade clause
/// voids the ruling the moment supported multi-process writing, cloud sync, a watched folder, an
/// external editor writing back, or any supported path that caches a stored path across a deletion
/// arrives.
///
/// There is no test here that "closes" E, because a green test for something unfixed is worse than
/// the gap it hides.
///
/// ## Two contracts for whoever wires this up
///
///  * **Never call it from inside a transaction.** It opens its own `BEGIN IMMEDIATE`; SQLite has no
///    nested transactions, so a nested call fails, is caught, and reports ``Outcome/unavailable`` —
///    correct and fail-closed, but it means the copy is silently never removed. **All five of D-6's
///    seams run outside any transaction** — the two that consume a returned orphan call this only
///    after the store's own transaction has committed — and `DocumentMountingTests` pins that.
///  * **The directory argument carries authority.** It is bound `O_NOFOLLOW` on its LAST component
///    only, like every other directory bind in this package, so a symlink at an ANCESTOR is followed
///    — the caller has, in effect, named whatever that resolves to. Registered rather than tightened:
///    `openNoFollowAny` would refuse a data root reached through any symlinked ancestor (including
///    `/var` on this platform), and the guarantee that actually matters here does not come from the
///    walk — it comes from binding an inode and unlinking only while the name still resolves to it.
public enum AttachmentDeletion {

    /// What one best-effort attempt did. Never localized and never surfaced to a user.
    ///
    /// ``deleted`` and ``alreadyGone`` are BOTH success for a caller: the ruling's rule is that a
    /// missing file counts as done. They stay separate cases because a test — and, later, a log —
    /// needs to tell "we removed it" from "there was nothing to remove".
    enum Outcome: Equatable {
        /// `unlinkat` reported success for that NAME, and the name no longer resolves to the bound
        /// inode afterwards.
        ///
        /// **It does not say the bound inode is what was removed.** `unlinkIfStillBound` checks
        /// identity with `fstatat` and then unlinks by name; an entry swapped inside those two
        /// adjacent syscalls is what `unlinkat` takes. That window is registered — see this type's
        /// note — and cannot be closed on Darwin, so this case is exactly as strong as the syscall
        /// pair is, and no stronger.
        case deleted
        /// No entry at that name. Success.
        case alreadyGone
        /// A row in one of the two authoritative columns still points at it. Left alone.
        case stillReferenced
        /// The stored reference is not `attachments/docs/<valid name>`. Nothing was touched.
        case rejectedReference
        /// Something is at the name, but it is not a regular file — a symlink, a directory, a device.
        case notARegularFile
        /// **At the identity check**, the name did not resolve to the bound inode, so this call did
        /// not go on to unlink anything.
        ///
        /// It is a statement about that one observation and nothing more. It does NOT say that a
        /// replacement is safe in general: one that lands AFTER the check — including inside
        /// `unlinkIfStillBound`'s own `fstatat`→`unlinkat` gap — is not covered by it, and is the
        /// registered residual.
        case movedUnderUs
        /// The directory could not be bound, the ledger could not be asked, or the `unlink` did not
        /// take. Fail-closed: nothing was removed.
        case unavailable
    }

    /// Internal test seam. No global state: it is passed in, defaults to nothing, and is invisible to
    /// the App target.
    struct Hooks {
        /// Fires AFTER the reference scan and BEFORE the `unlink`, **inside** the write lock. This is
        /// the D window; a test commits a conflicting claim from a second connection here.
        var afterScanBeforeUnlink: (() -> Void)? = nil
    }

    /// **The App's entry point — D-6's five seams call THIS one.**
    ///
    /// It returns nothing, by the fourteenth ruling. Cleanup is best-effort on both sides and the
    /// database write that orphaned the copy has already committed by the time anyone arrives here,
    /// so reporting a failed cleanup as a failed save would be a lie. A `Void` signature makes that
    /// lie unwriteable rather than merely forbidden: there is no value at the seam to branch on, no
    /// error to surface, no new case, no new key and no new copy. The outcome — for tests, and for a
    /// future log — stays on ``attemptDeleteIfUnreferenced(_:in:using:hooks:)``, which is internal.
    ///
    /// Public only because the App target links `SoloLedgerCore` as a separate module and cannot
    /// otherwise name an internal symbol. Measured, not assumed: `_ = AttachmentDeletion.self` in
    /// `FilePanels.swift` fails the App build with `cannot find 'AttachmentDeletion' in scope`.
    ///
    /// - Parameters:
    ///   - storedPath: the value as STORED, e.g. `attachments/docs/doc-1-abc.pdf`.
    ///   - attachmentsDirectory: the directory the caller has decided is the attachments root. It is
    ///     opened, never created — the capability is the caller's to hand over.
    ///   - db: the connection whose ledger owns the two reference columns.
    public static func deleteIfUnreferenced(_ storedPath: String,
                                            in attachmentsDirectory: URL,
                                            using db: SQLiteDatabase) {
        _ = attemptDeleteIfUnreferenced(storedPath, in: attachmentsDirectory, using: db)
    }

    /// The same attempt, with the outcome and the test hook kept. Internal: the App must not be able
    /// to read a result it is forbidden to act on.
    ///
    /// - Parameters:
    ///   - storedPath: the value as STORED, e.g. `attachments/docs/doc-1-abc.pdf`.
    ///   - attachmentsDirectory: the directory the caller has decided is the attachments root. It is
    ///     opened, never created.
    ///   - db: the connection whose ledger owns the two reference columns.
    @discardableResult
    static func attemptDeleteIfUnreferenced(_ storedPath: String,
                                            in attachmentsDirectory: URL,
                                            using db: SQLiteDatabase,
                                            hooks: Hooks = Hooks()) -> Outcome {
        guard let name = AttachmentRelPath.bareName(of: storedPath) else { return .rejectedReference }

        // The directory is bound BEFORE anything is asked of the ledger, so every later step names a
        // child of one descriptor rather than re-walking a string that may have changed meaning.
        guard let parent = try? DirectoryHandle.open(at: attachmentsDirectory) else { return .unavailable }

        let file: BoundRegularFile
        do {
            file = try BoundRegularFile.open(in: parent, named: name)
        } catch {
            switch classify(error) {
            case .absent:         return .alreadyGone
            case .notRegular:     return .notARegularFile
            case .other:          return .unavailable
            }
        }

        do {
            return try db.immediateTransaction { () -> Outcome in
                guard try !isReferenced(name, in: db) else { return .stillReferenced }
                hooks.afterScanBeforeUnlink?()

                // Checked here as well as inside `unlinkIfStillBound`, so a replacement that is
                // already in place is REPORTED rather than being indistinguishable from a success.
                // It narrows nothing: this is a second check-then-act, and the gap inside the unlink
                // itself stays open (see this type's note).
                guard (try? file.matchesChild(named: name, in: parent)) == true else {
                    return .movedUnderUs
                }
                file.unlinkIfStillBound(named: name, in: parent)

                // Fail-closed confirmation: if the bound inode is still the one at the name, the
                // unlink did not take and this must not be reported as a deletion.
                if let after = try? parent.fingerprint(named: name),
                   after.isRegularFile, after.device == file.device, after.inode == file.inode {
                    return .unavailable
                }
                return .deleted
            }
        } catch {
            // A failed `BEGIN IMMEDIATE` (another writer holds the lock) or a failed read. Nothing
            // was unlinked; the caller's database write already succeeded and is not disturbed.
            return .unavailable
        }
    }

    // MARK: - Internals

    /// Whether either authoritative column still names this file.
    ///
    /// Read as whole columns rather than as an equality test in SQL, because SQL `=` on TEXT is byte
    /// comparison and the stored spelling need not be byte-identical to the one being deleted. The
    /// rows are filtered to the non-empty ones in SQL so the scan carries only what could match.
    ///
    /// **`CAST(… AS TEXT)` is load-bearing.** These columns are declared TEXT, but SQLite stores what
    /// it was given, and ``SQLiteValue/stringValue`` answers `nil` for a BLOB — so a reference a
    /// foreign writer stored as a blob would read as no reference at all and the file would go. The
    /// cast makes every storage class arrive as text; the same class of foreign value the chapter
    /// already reasons about for `''`.
    static func isReferenced(_ name: String, in db: SQLiteDatabase) throws -> Bool {
        for (table, column) in referenceColumns {
            let rows = try db.query("""
                SELECT CAST(\(column) AS TEXT) AS ref FROM \(table)
                 WHERE \(column) IS NOT NULL AND \(column) <> ''
                """)
            for row in rows where row.string("ref").map({ namesTheSameFile($0, name) }) == true {
                return true
            }
        }
        return false
    }

    /// The complete set of columns in this ledger that can hold an `attachments/docs/` reference.
    /// The same pair `AttachmentReferenceAuditor` audits; adding a third column to the schema without
    /// adding it here is what `AttachmentDeletionTests` pins.
    static let referenceColumns: [(table: String, column: String)] = [
        ("transactions", "attachment_path"),
        ("business_documents", "tax_invoice_attachment_path"),
    ]

    /// Canonical equivalence AND a case fold on the final path segment — see this type's note on why
    /// the wider comparison is the safe one here, and why the case fold specifically is what keeps a
    /// referenced file alive on the case-insensitive volume this app actually ships on.
    static func namesTheSameFile(_ storedValue: String, _ name: String) -> Bool {
        let segments = storedValue.split(separator: "/", omittingEmptySubsequences: false)
        let last = String(segments.last ?? "")
        return last == name || last.lowercased() == name.lowercased()
    }

    /// Why a bind failed, in the three shapes the outcome distinguishes.
    enum BindFailure { case absent, notRegular, other }

    static func classify(_ error: Error) -> BindFailure {
        guard let hash = error as? FileHashError else { return .other }
        switch hash {
        case .notARegularFile:            return .notRegular
        case .unreadable(_, let errno):   return errno == ENOENT ? .absent : .other
        default:                          return .other
        }
    }
}
