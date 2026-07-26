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
struct LegacyLedgerNotice: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "archivebox")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(model.legacyLedger.hasUnconverted
                 ? model.t("legacy.notice.title", ["count": "\(model.legacyLedger.unconverted)"])
                 : model.t("legacy.other.title"))
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(model.legacyLedger.hasUnconverted
                 ? model.t("legacy.notice.message")
                 : model.t("legacy.other.message"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 420)
        .padding(40)
        .accessibilityElement(children: .combine)
    }
}

/// One-line counterpart of `LegacyLedgerNotice` for a ledger that DOES have
/// transactions to show: the list is real but incomplete, and saying so beats letting
/// the user conclude records went missing.
struct LegacyLedgerBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.legacyLedger.hasUnconverted && !model.isLedgerEmpty {
            Label(model.t("legacy.banner", ["count": "\(model.legacyLedger.unconverted)"]),
                  systemImage: "archivebox")
                .font(.footnote)
                .foregroundStyle(.secondary)
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
