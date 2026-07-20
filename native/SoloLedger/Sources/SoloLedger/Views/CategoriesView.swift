import SwiftUI
import SoloLedgerCore

/// Read-only view of the seeded accounting categories for the active regime.
/// Safe to browse; switching the accounting locale changes which set is shown.
struct CategoriesView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Table(model.categories) {
            TableColumn(model.t("txn.col.type")) { c in
                Text(model.t("type.\(c.type.rawValue)"))
                    .foregroundStyle(c.type == .income ? Color.green : Color.red)
            }
            .width(min: 60, ideal: 72)

            TableColumn(model.t("cat.col.label")) { c in
                Text(model.categoryLabel(c))
            }

            TableColumn(model.t("cat.col.slug")) { c in
                Text(c.slug).foregroundStyle(.secondary).monospaced()
            }

            TableColumn(model.t("cat.col.schedule")) { c in
                Text(c.scheduleLine ?? "—").foregroundStyle(.secondary)
            }

            TableColumn("COGS") { c in
                if c.isCOGS { Text("COGS").font(.caption).foregroundStyle(.orange) }
            }
            .width(min: 44, ideal: 52)
        }
        .navigationTitle(model.t("nav.categories"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker(model.t("settings.accountingLocale"), selection: Binding(
                    get: { model.accountingLocale },
                    set: { model.setAccountingLocale($0) }
                )) {
                    ForEach(AccountingLocale.allCases) { locale in
                        Text(locale.displayName).tag(locale)
                    }
                }
            }
        }
    }
}
