import Foundation

/// One database row captured VERBATIM for undo: the ordered column names paired
/// with their raw `SQLiteValue`s, preserving each column's NULL state and storage
/// class exactly.
///
/// This deliberately bypasses the UI `Transaction` model, which is lossy for undo:
/// `Transaction.from` coerces a stored SQL `NULL` to `""` (counterparty / invoice_no
/// / description) or to `0` / a default enum, and re-inserting through the model
/// would persist those coerced values instead of the original `NULL`. Snapshotting
/// the raw row and restoring it column-by-column makes a restored row byte-for-byte
/// identical to the deleted one — including `NULL`s and the exact SQLite storage
/// class (INTEGER vs REAL vs TEXT). `columns` and `values` are strictly parallel.
public struct RawRow: Equatable, Sendable {
    public var columns: [String]
    public var values: [SQLiteValue]   // parallel to `columns`

    public init(columns: [String], values: [SQLiteValue]) {
        self.columns = columns
        self.values = values
    }

    /// Capture a queried row verbatim, preserving column order and each column's
    /// raw value (including `.null`). Iterating `row.columns` guarantees every key
    /// is present, so a stored `NULL` is captured as `.null` — never dropped.
    public init(_ row: SQLiteRow) {
        self.columns = row.columns
        self.values = row.columns.map { row[$0] }
    }

    /// The raw value of a column, or `nil` if the column is absent from this row.
    public func value(_ column: String) -> SQLiteValue? {
        guard let i = columns.firstIndex(of: column) else { return nil }
        return values[i]
    }
}

/// Everything needed to fully undo a batch delete, captured as RAW rows so every
/// column — including SQL `NULL`s and exact storage classes — is restored verbatim.
/// `restore(_:)` re-inserts each row column-by-column with no model normalization.
public struct DeletionSnapshot: Equatable, Sendable {
    /// The deleted `transactions` rows, verbatim.
    public var transactionRows: [RawRow]
    /// Every related `legacy_migrations` row (the sales/purchases → transactions
    /// mapping), verbatim — including its original primary key `id` and `migrated_at`.
    public var legacyMappingRows: [RawRow]

    public init(transactionRows: [RawRow], legacyMappingRows: [RawRow]) {
        self.transactionRows = transactionRows
        self.legacyMappingRows = legacyMappingRows
    }

    public var isEmpty: Bool { transactionRows.isEmpty && legacyMappingRows.isEmpty }
    /// Number of transactions in the snapshot (drives the undo bar's "N deleted").
    public var count: Int { transactionRows.count }
}
