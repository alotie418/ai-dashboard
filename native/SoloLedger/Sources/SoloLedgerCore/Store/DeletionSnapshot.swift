import Foundation

/// A `legacy_migrations` row (the sales/purchases → transactions mapping) captured
/// for undo, so deleting a migrated transaction and undoing it restores the mapping
/// too — including its original primary key `id`, restored verbatim.
public struct LegacyMapping: Equatable, Sendable {
    public var id: Int
    public var legacyTable: String
    public var legacyId: String
    public var newId: String
    public var migratedAt: String?

    public init(id: Int, legacyTable: String, legacyId: String, newId: String, migratedAt: String?) {
        self.id = id
        self.legacyTable = legacyTable
        self.legacyId = legacyId
        self.newId = newId
        self.migratedAt = migratedAt
    }
}

/// Everything needed to fully undo a batch delete: the complete transaction rows
/// (all fields, including the original `created_at` / `updated_at`) and every related
/// `legacy_migrations` mapping. `restore` reinstates all of it verbatim.
public struct DeletionSnapshot: Equatable, Sendable {
    public var transactions: [Transaction]
    public var legacyMappings: [LegacyMapping]

    public init(transactions: [Transaction], legacyMappings: [LegacyMapping]) {
        self.transactions = transactions
        self.legacyMappings = legacyMappings
    }

    public var isEmpty: Bool { transactions.isEmpty && legacyMappings.isEmpty }
    public var count: Int { transactions.count }
}
