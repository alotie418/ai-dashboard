import Foundation

// MARK: - 2B-3 C11b: shared active-slot verification gates

/// The active-slot verification gates, extracted MECHANICALLY from
/// `PreparedImportActivator` (2B-3 C10) so that C11 (finalize) brackets its path-based
/// apply/audit/complete steps with EXACTLY the same checks the activator used — one
/// implementation, no drift. Bodies, syscalls, error mapping and hash counts are
/// unchanged from C10; the activator now delegates here.
///
/// All three gates are POINT-IN-TIME (registered residual, same class as C6–C10): they
/// detect a swap/change that already happened; they cannot pin a name.
enum ActiveSlotGates {

    /// The published active DB's WHOLE ENVELOPE is still ours: the active name resolves to
    /// the bound active inode, none of the three sidecars exist, and the owner record is
    /// still bound + content-matching.
    static func assertEnvelope(active: BoundRegularFile, activeName: String,
                               ownerRecord: BoundRegularFile, expected: ActivationRecord,
                               in parent: DirectoryHandle) throws {
        guard (try? active.matchesChild(named: activeName, in: parent)) == true else {
            throw ActivationError.publishedActiveMismatch("active name no longer resolves to the published inode")
        }
        try assertNoSidecars(activeName: activeName, in: parent)
        try assertRecordStillBound(ownerRecord, expected: expected, named: PreparedImportActivator.recordName, in: parent)
    }

    /// The owner record must STILL be ours: the final name resolves to the bound inode AND
    /// the bound fd decodes to exactly the expected record. Point-in-time (registered
    /// residual): it detects a swap/change that already happened, it cannot pin the name.
    static func assertRecordStillBound(_ rec: BoundRegularFile, expected: ActivationRecord,
                                       named name: String, in parent: DirectoryHandle) throws {
        guard (try? rec.matchesChild(named: name, in: parent)) == true else {
            throw ActivationError.recordUnboundDuringActivation("'\(name)' no longer resolves to the bound owner record")
        }
        guard (try? rec.decode(ActivationRecord.self)) == expected else {
            throw ActivationError.recordUnboundDuringActivation("owner record content changed")
        }
    }

    static func assertNoSidecars(activeName: String, in parent: DirectoryHandle) throws {
        for s in PreparedImportActivator.sidecarSuffixes {
            let name = activeName + s
            let fp: FileFingerprint?
            do { fp = try parent.fingerprint(named: name) }
            catch { throw ActivationError.sidecarAppeared("\(name): metadata error (failing closed): \(error)") }
            if fp != nil { throw ActivationError.sidecarAppeared(name) }
        }
    }
}
