import Foundation

/// The window a report covers, constructed once and carried, never re-derived.
///
/// No wall-clock default anywhere. `ReportDispatcher.batchTwo`'s `year ?? currentYear`
/// makes output depend on the day it runs, which is the dependency the goldens are
/// generated with an explicit year to avoid; a caller here must say which period it means.
public struct ReportPeriod: Equatable, Sendable {
    public let year: String
    public let from: String
    public let to: String

    /// A full calendar year — `index.js from` / `to`'s own default, spelled explicitly.
    public init(year: String) {
        self.year = year
        self.from = "\(year)-01-01"
        self.to = "\(year)-12-31"
    }

    /// An arbitrary window inside `year`.
    ///
    /// `year` is NOT derived from `from`, because the two are read by different things and
    /// the difference is visible: `monthlyBreakdown` lays out twelve calendar months of
    /// `year` regardless of `[from, to]` (Appendix A9). Both travel in the result so a
    /// view can see the mismatch instead of inheriting it silently.
    public init(year: String, from: String, to: String) {
        self.year = year
        self.from = from
        self.to = to
    }
}

/// A report, or a stated refusal to produce one.
///
/// `throws` is reserved for I/O faults — a closed connection, a corrupt file. Everything a
/// USER could cause and could fix is a ``ReportBlocker``, because those need to be shown,
/// not thrown.
public enum ReportOutcome: Equatable, Sendable {
    case report(PresentedReport)
    case blocked(ReportBlocker)
}

/// Why no report was produced. Every case carries the facts a repair screen needs, and
/// **nothing here writes to the ledger or infers a value on the user's behalf.**
public enum ReportBlocker: Equatable, Sendable {

    /// `settings.accounting_locale` has no row.
    ///
    /// Deliberately NOT the `"CN"` fallback `ReportSettings.string` applies. That fallback
    /// is faithful to `index.js locale` and it silently picks Chinese accounting policy for a
    /// ledger that never chose one — which CLAUDE.md forbids and which the safe façade
    /// exists to stop. Reachable only when the row was removed externally or the ledger
    /// predates schema v3, which seeds it (`SchemaMigrator` v3).
    case accountingLocaleNotConfigured

    /// The row exists and does not name one of the six regimes — not a JSON string, an
    /// empty one, or a value outside `CN/US/JP/EU/KR/TW`.
    ///
    /// `storedText` is the `settings.value` TEXT verbatim, so a repair screen can show what
    /// is actually there. It is the ONLY place the value is surfaced; nothing coerces it.
    case accountingLocaleInvalid(storedText: String)

    /// `settings.currency` has no row. `periodCurrencies` is what the period's rows are
    /// actually denominated in, and `regimeDefault` is the regime's preset — both offered
    /// as CANDIDATES for a repair screen, neither applied.
    case currencyNotConfigured(periodCurrencies: [String], regimeDefault: String)

    /// The row exists and is not a usable currency code.
    case currencyInvalid(storedText: String, periodCurrencies: [String], regimeDefault: String)

    /// The period holds no rows in `transactions`, so the dispatcher's source decision is
    /// `.legacy` — and this app does not read the legacy `sales` / `purchases` tables at all
    /// (plan §6.1, per #395).
    ///
    /// **Why this blocks instead of reporting zeros.** Running the engines over empty arrays
    /// produces a complete-looking statement of zeros: revenue 0, gross profit 0, twelve
    /// months of 0, cash flow {0,0,0}. Electron, which DOES read those tables, reports real
    /// money for exactly such a period — `base-CN-2024` records inflow 9040 / outflow 7780 /
    /// net 1260. A zero there is not "no data", it is a confident and wrong claim that
    /// nothing happened, which is the placeholder-metric CLAUDE.md's product boundary forbids.
    ///
    /// And the two situations CANNOT be told apart from here: without reading the legacy
    /// tables, "this ledger genuinely has nothing in this period" and "this ledger's money
    /// for this period lives in tables we do not read" produce identical inputs. Both must
    /// therefore stop, which is why this carries no "is it really empty" hint — there is no
    /// honest way to compute one.
    case legacySourceUnavailable

    /// The ledger's currency and the period's single currency disagree.
    ///
    /// Note what is NOT a blocker: a stored currency that differs from the REGIME DEFAULT.
    /// The Electron accounting screen lets a user set the currency directly, so a US ledger
    /// kept in EUR is a legitimate choice, not an error. Only a disagreement with the money
    /// actually recorded in the period is one.
    case currencyMismatch(storedCurrency: String, periodCurrency: String)

    /// The period's rows carry more than one currency.
    ///
    /// The engines sum without a currency predicate (`ReportFetch.rowSQL` has none), so a
    /// mixed period would be arithmetic on incomparable units presented under one symbol.
    /// Adding a filter would change the mirrored formula; refusing does not.
    case multipleCurrenciesInPeriod(codes: [String])
}
