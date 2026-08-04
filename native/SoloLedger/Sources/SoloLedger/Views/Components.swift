import SwiftUI

/// A restrained label/value stat (no card chrome, no gradient) for the overview.
struct StatView: View {
    let title: String
    let value: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}

/// Says plainly that the ledger holds legacy sales/purchase records this app cannot
/// display. Shown INSTEAD of a plain "no records" empty state, which would otherwise
/// tell a migrated user their data is gone when it is sitting in the file untouched.
///
/// Which of the two notices this is — and therefore whether it offers a conversion — is
/// decided by ``LegacyConversionComposition/notice(_:)`` rather than by a ternary here.
/// `legacy.other.*` describes invoices, fixed assets and the rest: the preflight never scans
/// those tables and the runner cannot carry them, so an entry point on that branch would be a
/// button that can only ever report "nothing to convert".
struct LegacyLedgerNotice: View {
    @EnvironmentObject var model: AppModel

    private var block: LegacyConversionComposition.NoticeBlock {
        LegacyConversionComposition.notice(model.legacyLedger)
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "archivebox")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(model.t(block.titleKey, ["count": "\(model.legacyLedger.unconverted)"]))
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(model.t(block.messageKey))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if block.offersConversion {
                LegacyConversionEntry(compact: false)
            }
        }
        .frame(maxWidth: 420)
        .padding(40)
        .accessibilityElement(children: .contain)
    }
}

/// One-line counterpart of `LegacyLedgerNotice` for a ledger that DOES have
/// transactions to show: the list is real but incomplete, and saying so beats letting
/// the user conclude records went missing.
struct LegacyLedgerBanner: View {
    @EnvironmentObject var model: AppModel

    private var block: LegacyConversionComposition.BannerBlock {
        LegacyConversionComposition.banner(model.legacyLedger, ledgerIsEmpty: model.isLedgerEmpty)
    }

    var body: some View {
        if let labelKey = block.labelKey {
            HStack(spacing: 10) {
                Label(model.t(labelKey, ["count": "\(model.legacyLedger.unconverted)"]),
                      systemImage: "archivebox")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if block.offersConversion {
                    LegacyConversionEntry(compact: true)
                }
            }
        }
    }
}

/// The conversion call to action. The ONLY thing that opens the wizard.
///
/// It draws `LegacyConversionComposition.entryKeys` and nothing else, and it is constructed
/// only from the `hasUnconverted` branch of the notice and the banner — which is what
/// `LegacyConversionWizardTests` asserts, in both directions.
private struct LegacyConversionEntry: View {
    @EnvironmentObject var model: AppModel
    /// The banner is one line inside a list; the notice is a centred empty state with room
    /// for the sentence under the button.
    let compact: Bool

    var body: some View {
        if compact {
            Button(model.t("legacy.convert.cta")) { model.beginLegacyConversion() }
                .buttonStyle(.link)
                .font(.footnote)
                .help(model.t("legacy.convert.cta.hint"))
        } else {
            VStack(spacing: 6) {
                Button(model.t("legacy.convert.cta")) { model.beginLegacyConversion() }
                    .buttonStyle(.borderedProminent)
                Text(model.t("legacy.convert.cta.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        }
    }
}

/// A plain empty-state (ContentUnavailableView is macOS 14+, so this is a
/// deployment-target-13 stand-in).
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .accessibilityElement(children: .combine)
    }
}
