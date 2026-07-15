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
