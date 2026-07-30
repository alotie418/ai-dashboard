import Foundation
import OSLog
import SoloLedgerCore

/// The report page's whole state — four cases, and every non-empty one carries ITS OWN year.
///
/// ## Why the year rides in the state
///
/// A page that reads the heading's year from the picker and the numbers from a stored result
/// can show 2024's figures under a 2025 title for as long as the two disagree. Here they
/// cannot disagree, because there is only one of them: `.report` answers with
/// `PresentedReport.period.year`, and the two refusal cases carry the year they refused.
/// A view that renders `state.year` is rendering the year those numbers describe, by
/// construction rather than by discipline.
///
/// ## Why `.failed` carries nothing
///
/// `ReportBuilder.build` reserves `throws` for I/O faults — a closed connection, a corrupt
/// file. Those messages name paths and SQLite internals, and CLAUDE.md forbids showing raw
/// technical strings. So this case has **nowhere to put one**: there is no `Error`, no
/// `String`, and therefore no way for a view to leak one even by accident. The detail goes
/// to ``ReportDiagnostics`` instead.
///
/// There is deliberately **no `.loading`**. `ReportBuilder.build` runs synchronously on the
/// main actor inside a single `AppModel` turn, so a loading frame is never rendered; a case
/// for it would be a spinner the user can never see. If the build is ever moved off the main
/// actor, that change adds the case — and the compiler will then ask every `switch` about it.
enum ReportPageState: Equatable {
    /// No report has been asked for yet, or the previous one was cleared before rebuilding.
    case notRequested
    /// A report. The year is `report.period.year`.
    case report(PresentedReport)
    /// The builder refused, and said why. `year` is the period that was asked for.
    case blocked(year: String, ReportBlocker)
    /// An I/O fault. Carries the year and NOTHING else — see the note above.
    case failed(year: String)

    /// The year these contents describe, or `nil` when there are no contents.
    var year: String? {
        switch self {
        case .notRequested:          return nil
        case .report(let report):    return report.period.year
        case .blocked(let year, _):  return year
        case .failed(let year):      return year
        }
    }
}

/// Where technical failure detail goes instead of the UI.
///
/// The year is `.public` because it is the user's own input and is already on screen. The
/// error is `.private`, so it is redacted in collected logs and visible only when someone is
/// attached to the machine deliberately.
enum ReportDiagnostics {
    static let logger = Logger(subsystem: "com.alotie418.sololedger", category: "reports")

    static func buildFailed(year: String, error: Error) {
        logger.error("""
            report build failed for year \(year, privacy: .public): \
            \(String(describing: error), privacy: .private)
            """)
    }
}
