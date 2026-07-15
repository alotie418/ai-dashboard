import SwiftUI
import SoloLedgerCore

struct TransactionListView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection = Set<Transaction.ID>()

    var body: some View {
        Group {
            if model.transactions.isEmpty {
                EmptyStateView(systemImage: "tray",
                               title: model.t("txn.empty.title"),
                               message: model.t("txn.empty.message"))
            } else {
                table
            }
        }
        .navigationTitle(model.t("nav.transactions"))
        .toolbar { toolbarContent }
        .onChange(of: model.filter) { _ in
            selection.removeAll()
            model.reloadTransactions()
        }
    }

    private var table: some View {
        Table(model.transactions, selection: $selection) {
            TableColumn(model.t("txn.col.date")) { t in
                Text(t.date).monospacedDigit()
            }
            .width(min: 92, ideal: 100)

            TableColumn(model.t("txn.col.type")) { t in
                Text(model.t("type.\(t.type.rawValue)"))
                    .foregroundStyle(t.type == .income ? Color.green : Color.red)
            }
            .width(min: 60, ideal: 70)

            TableColumn(model.t("txn.col.category")) { t in
                Text(categoryName(t.categoryID))
            }

            TableColumn(model.t("txn.col.counterparty")) { t in
                Text(t.counterparty.isEmpty ? "—" : t.counterparty)
            }

            TableColumn(model.t("txn.col.amount")) { t in
                Text(Money.string(t.amount, currency: t.currency))
                    .monospacedDigit()
                    .foregroundStyle(t.type == .income ? Color.green : Color.primary)
            }
            .width(min: 100, ideal: 120)

            TableColumn(model.t("txn.col.payment")) { t in
                Text(model.t("payment.\(t.paymentStatus.rawValue)"))
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 84)
        }
        .contextMenu(forSelectionType: Transaction.ID.self) { ids in
            if ids.count == 1, let t = transaction(ids.first!) {
                Button(model.t("common.edit")) { model.edit(t) }
            }
            if !ids.isEmpty {
                Button(model.t("common.delete"), role: .destructive) { model.delete(ids: ids) }
            }
        } primaryAction: { ids in
            if let id = ids.first, let t = transaction(id) { model.edit(t) }
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker(model.t("filter.label"), selection: $model.filter) {
                ForEach(TransactionFilter.allCases) { f in
                    Text(model.t(f.titleKey)).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                if let id = selection.first, let t = transaction(id) { model.edit(t) }
            } label: {
                Label(model.t("common.edit"), systemImage: "pencil")
            }
            .disabled(selection.count != 1)

            Button(role: .destructive) {
                model.delete(ids: selection)
                selection.removeAll()
            } label: {
                Label(model.t("common.delete"), systemImage: "trash")
            }
            .disabled(selection.isEmpty)

            Button {
                model.importCSVViaPanel()
            } label: {
                Label(model.t("cmd.importCSV"), systemImage: "square.and.arrow.down")
            }

            Button {
                model.exportCSVViaPanel()
            } label: {
                Label(model.t("cmd.exportCSV"), systemImage: "square.and.arrow.up")
            }

            Button {
                model.newTransaction()
            } label: {
                Label(model.t("cmd.newTransaction"), systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
        }
    }

    private func transaction(_ id: Transaction.ID) -> Transaction? {
        model.transactions.first { $0.id == id }
    }

    private func categoryName(_ id: String?) -> String {
        guard let id else { return "—" }
        if let cat = model.categories.first(where: { $0.id == id }) {
            return model.categoryLabel(cat)
        }
        return id
    }
}
