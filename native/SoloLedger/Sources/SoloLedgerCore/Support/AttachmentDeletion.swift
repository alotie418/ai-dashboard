import Foundation

/// Removing ONE attachment copy that nothing points at any more — the third item of the twelfth
/// ruling, and the primitive `docs/BUSINESS_DOCUMENTS_SPEC.md` §3 requires to exist and to be proven
/// BEFORE any deleting seam is connected.
///
/// ## Nothing in the app calls this yet, and that is the design
///
/// D-4's ruling ③ left five places where a copy is orphaned — re-pick, remove, cancel, replace-or-
/// clear on save, and delete-the-document — and connected NONE of them: the App's two consumers of a
/// returned orphan still discard the value. D-6 connects them. This round lands the primitive and its
/// proofs so that connecting is a wiring change against something already measured, not a new
/// mechanism written under the pressure of a page that needs to ship.
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
///    (`BoundRegularFile.open`, `O_NOFOLLOW`, `fstat` `S_IFREG`), and the `unlink` happens only while
///    the name STILL resolves to that same device+inode (`unlinkIfStillBound`). A symlink, a
///    directory, a device node, or a stand-in put there after the bind is left exactly where it is.
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
/// a reference whenever its final path segment is canonically equal to the target name — which
/// catches the spellings the whitelist would reject and a code-unit test would miss.
///
/// ## The window that IS closed, and the one that is NOT
///
/// **Closed — D, between the scan and the `unlink`.** Both happen inside
/// ``SQLiteDatabase/immediateTransaction(_:)``, so the write lock is held across them and no other
/// connection can commit a new reference in between. `AttachmentDeletionTests` proves it with a real
/// second connection on the same file.
///
/// **NOT closed — E, after the file is gone.** Nothing in this design stops a non-cooperating or
/// stale writer from claiming the same relative path afterwards: the name is free again the moment
/// the entry is unlinked, and a writer that computed `attachments/docs/<name>` before the deletion can
/// still store it. **This round does not pretend otherwise.** It is registered in the spec as the
/// storage-atomicity residual, and the ruling makes it a MANDATORY prerequisite: before D-6 connects
/// any deleting seam, the user must rule on either
///
///  1. coordination among cooperating writers with no schema change — and on what to do about the
///     external-writer residue that leaves; or
///  2. a schema-level ownership record, which Q9 forbids without its own ruling.
///
/// There is no test here that "closes" E, because a green test for something unfixed is worse than
/// the gap it hides.
enum AttachmentDeletion {

    /// What one best-effort attempt did. Never localized and never surfaced to a user.
    ///
    /// ``deleted`` and ``alreadyGone`` are BOTH success for a caller: the ruling's rule is that a
    /// missing file counts as done. They stay separate cases because a test — and, later, a log —
    /// needs to tell "we removed it" from "there was nothing to remove".
    enum Outcome: Equatable {
        /// The bound inode's entry was removed.
        case deleted
        /// No entry at that name. Success.
        case alreadyGone
        /// A row in one of the two authoritative columns still points at it. Left alone.
        case stillReferenced
        /// The stored reference is not `attachments/docs/<valid name>`. Nothing was touched.
        case rejectedReference
        /// Something is at the name, but it is not a regular file — a symlink, a directory, a device.
        case notARegularFile
        /// The name stopped resolving to the inode that was bound. A stand-in is never removed.
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

    /// Remove the copy `storedPath` names, if and only if nothing in the ledger still points at it.
    ///
    /// - Parameters:
    ///   - storedPath: the value as STORED, e.g. `attachments/docs/doc-1-abc.pdf`.
    ///   - attachmentsDirectory: the directory the caller has decided is the attachments root. It is
    ///     opened, never created.
    ///   - db: the connection whose ledger owns the two reference columns.
    @discardableResult
    static func deleteIfUnreferenced(_ storedPath: String,
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

                // Checked before the unlink as well as inside it, so the "a stand-in survives"
                // outcome is REPORTED rather than silently indistinguishable from a success.
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
    static func isReferenced(_ name: String, in db: SQLiteDatabase) throws -> Bool {
        for (table, column) in referenceColumns {
            let rows = try db.query("""
                SELECT \(column) AS ref FROM \(table)
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

    /// Canonical equivalence on the final path segment — see this type's note on why the wider
    /// comparison is the safe one here.
    static func namesTheSameFile(_ storedValue: String, _ name: String) -> Bool {
        let segments = storedValue.split(separator: "/", omittingEmptySubsequences: false)
        return String(segments.last ?? "") == name
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
