import Foundation

/// Mirror of `electron/reports/_reportSource.js` — which table a report PERIOD
/// reads from.
///
/// The decision is made PER PERIOD, not from a whole-table count: a single
/// transaction anywhere used to force every year onto the transactions model, so
/// a year holding only legacy `sales`/`purchases` reported 0 instead of falling
/// back. `periodTxnCount` is the count WITHIN `[from, to]`.
///
/// This helper has no production caller in batch 1 — the caller is the dispatcher,
/// which is a later batch. It ships here because the plan lists it as a batch-1
/// shared helper, and because the batch-1 parity tests use it to state which
/// source each golden period was generated from.
///
/// NOTE the asymmetry with the native app: `.legacy` is a value this function can
/// RETURN, but the native app does not read the legacy tables (plan §6.1, per
/// #395). The engines are pure functions of the rows they are handed; choosing
/// where rows come from is the dispatcher's job, and the dispatcher will not offer
/// the legacy option.
public enum ReportSource: String, Equatable, Sendable {
    case transactions
    case legacy
}

/// `selectReportSource` — `_reportSource.js:15-18`.
func selectReportSource(hasTransactionsTable: Bool, periodTxnCount: Int) -> ReportSource {
    if hasTransactionsTable && periodTxnCount > 0 { return .transactions }
    return .legacy
}
