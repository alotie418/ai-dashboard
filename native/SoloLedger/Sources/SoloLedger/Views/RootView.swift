import SwiftUI
import SoloLedgerCore

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        content
            .sheet(isPresented: $model.showingEditor) {
                TransactionEditor(existing: model.editingTransaction)
                    .environmentObject(model)
            }
            .alert(model.t("common.error"), isPresented: Binding(
                get: { model.actionError != nil },
                set: { if !$0 { model.actionError = nil } }
            )) {
                Button(model.t("common.ok"), role: .cancel) { model.actionError = nil }
            } message: {
                Text(model.actionError ?? "")
            }
    }

    @ViewBuilder private var content: some View {
        if let error = model.bootError {
            BootErrorView(message: error)
        } else if let failure = model.migrationFailure {
            MigrationRecoveryView(error: failure)   // blocking — never masked by an empty ledger
        } else if !model.ready {
            ProgressView(model.t("common.loading"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !model.onboardingDone {
            OnboardingView()
        } else {
            MainSplitView()
        }
    }
}

/// Blocking recovery shown when an Electron database exists but its upgrade failed.
/// The original data is never modified; the user must choose how to proceed.
private struct MigrationRecoveryView: View {
    @EnvironmentObject var model: AppModel
    let error: String
    @State private var showingError = false
    @State private var confirmingBlank = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text(model.t("recovery.title")).font(.title2).fontWeight(.semibold)
            Text(model.t("recovery.message"))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)

            VStack(spacing: 10) {
                Button { model.retryMigration() } label: {
                    Label(model.t("recovery.retry"), systemImage: "arrow.clockwise").frame(maxWidth: 320)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button { model.restoreFromBackupViaPanel() } label: {
                    Label(model.t("recovery.restore"), systemImage: "tray.and.arrow.down").frame(maxWidth: 320)
                }
                Button { showingError.toggle() } label: {
                    Label(model.t("recovery.viewError"), systemImage: "doc.text.magnifyingglass").frame(maxWidth: 320)
                }
                Button(role: .destructive) { confirmingBlank = true } label: {
                    Label(model.t("recovery.blank"), systemImage: "doc.badge.plus").frame(maxWidth: 320)
                }
            }

            if showingError {
                ScrollView {
                    Text(error)
                        .font(.caption).monospaced()
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: 460, maxHeight: 140)
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }

            Text(model.t("recovery.safeNote"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog(model.t("recovery.blankConfirmTitle"), isPresented: $confirmingBlank, titleVisibility: .visible) {
            Button(model.t("recovery.blankConfirm"), role: .destructive) { model.createBlankLedgerConfirmed() }
            Button(model.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(model.t("recovery.blankConfirmMessage"))
        }
    }
}

private struct MainSplitView: View {
    @EnvironmentObject var model: AppModel

    private var sectionSelection: Binding<SidebarSection?> {
        Binding(get: { model.section }, set: { model.section = $0 ?? model.section })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: sectionSelection) {
                Section(model.t("nav.section")) {
                    ForEach(SidebarSection.allCases) { section in
                        Label(model.t(section.titleKey), systemImage: section.systemImage)
                            .tag(section)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) { SidebarFooter() }
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(model.t("app.name"))
    }

    @ViewBuilder private var detail: some View {
        switch model.section {
        case .overview: OverviewView()
        case .transactions: TransactionListView()
        case .categories: CategoriesView()
        }
    }
}

private struct SidebarFooter: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Divider()
            Text(model.companyName.isEmpty ? model.t("app.name") : model.companyName)
                .font(.callout).fontWeight(.medium)
                .lineLimit(1)
            Text("\(model.accountingLocale.rawValue) · \(model.accountingLocale.defaultCurrency) · schema v\(model.schemaVersionText)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct BootErrorView: View {
    @EnvironmentObject var model: AppModel
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text(model.t("boot.error.title")).font(.title3).fontWeight(.semibold)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
