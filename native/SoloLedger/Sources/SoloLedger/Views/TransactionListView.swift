import SwiftUI
import SoloLedgerCore

struct TransactionListView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection = Set<Transaction.ID>()
    @State private var sortOrder = [KeyPathComparator(\Transaction.date, order: .reverse)]

    private var isFiltered: Bool {
        !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty || model.dateFrom != nil || model.dateTo != nil
    }

    var body: some View {
        Group {
            if model.transactions.isEmpty {
                if isFiltered {
                    EmptyStateView(systemImage: "magnifyingglass",
                                   title: model.t("txn.noResults.title"),
                                   message: model.t("txn.noResults.message"))
                } else {
                    emptyLedger
                }
            } else {
                table
            }
        }
        .navigationTitle(model.t("nav.transactions"))
        .searchable(text: $model.searchText, placement: .toolbar, prompt: model.t("txn.searchPrompt"))
        .onChange(of: model.searchText) { _ in model.reloadTransactions() }
        .onChange(of: model.filter) { _ in selection.removeAll(); model.reloadTransactions() }
        .onChange(of: sortOrder) { applySort($0) }
        .toolbar { toolbarContent }
        .onDeleteCommand(perform: selection.isEmpty ? nil : requestDeleteSelection)
        .confirmationDialog(
            model.t("delete.confirmTitle"),
            isPresented: Binding(get: { model.pendingDeleteIDs != nil },
                                 set: { if !$0 { model.cancelDelete() } }),
            titleVisibility: .visible
        ) {
            Button(model.t("delete.confirmButton", ["count": String(model.pendingDeleteCount)]), role: .destructive) {
                model.confirmDelete(); selection.removeAll()
            }
            Button(model.t("common.cancel"), role: .cancel) { model.cancelDelete() }
        } message: {
            Text(model.t("delete.confirmMessage", ["count": String(model.pendingDeleteCount)]))
        }
        .safeAreaInset(edge: .bottom) { undoBar }
    }

    // MARK: - Table (sort is query-driven, applied before LIMIT)

    private var table: some View {
        Table(model.transactions, selection: $selection, sortOrder: $sortOrder) {
            TableColumn(model.t("txn.col.date"), value: \.date) { t in
                Text(t.date).monospacedDigit()
            }
            .width(min: 92, ideal: 100)

            TableColumn(model.t("txn.col.type")) { t in
                Text(model.t("type.\(t.type.rawValue)"))
                    .foregroundStyle(t.type == .income ? Color.green : Color.red)
            }
            .width(min: 56, ideal: 66)

            TableColumn(model.t("txn.col.category")) { t in Text(categoryName(t.categoryID)) }

            TableColumn(model.t("txn.col.counterparty")) { t in
                Text(t.counterparty.isEmpty ? "—" : t.counterparty)
            }

            TableColumn(model.t("txn.col.amount"), value: \.amount) { t in
                Text(Money.string(t.amount, currency: t.currency))
                    .monospacedDigit()
                    .foregroundStyle(t.type == .income ? Color.green : Color.primary)
            }
            .width(min: 100, ideal: 124)

            TableColumn(model.t("txn.col.payment")) { t in
                Text(model.t("payment.\(t.paymentStatus.rawValue)")).foregroundStyle(.secondary)
            }
            .width(min: 66, ideal: 80)
        }
        .contextMenu(forSelectionType: Transaction.ID.self) { ids in
            if ids.count == 1, let t = transaction(ids.first!) {
                Button(model.t("common.edit")) { model.edit(t) }
                Button(model.t("common.duplicate")) { model.duplicate(id: t.id) }
                Divider()
            }
            if !ids.isEmpty {
                Button(model.t("common.delete"), role: .destructive) { model.requestDelete(ids) }
            }
        } primaryAction: { ids in
            if let id = ids.first, let t = transaction(id) { model.edit(t) }
        }
    }

    /// Map the clicked column header to AppModel.sort and re-run the DB query, so the
    /// ORDER BY applies BEFORE the LIMIT (not a local sort of the loaded page).
    private func applySort(_ order: [KeyPathComparator<Transaction>]) {
        guard let c = order.first else { return }
        let ascending = c.order == .forward
        if c.keyPath == \Transaction.amount {
            model.sort = ascending ? .amountAscending : .amountDescending
        } else {
            model.sort = ascending ? .dateAscending : .dateDescending
        }
        model.reloadTransactions()
    }

    @ViewBuilder private var undoBar: some View {
        if model.canUndoDelete {
            HStack {
                Image(systemName: "trash")
                Text(model.t("delete.deleted", ["count": String(model.undoDeleteCount)]))
                Spacer()
                Button(model.t("delete.undo")) { model.undoDelete() }
                Button { model.dismissUndo() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.regularMaterial)
        }
    }

    private var emptyLedger: some View {
        VStack(spacing: 12) {
            EmptyStateView(systemImage: "tray",
                           title: model.t("txn.empty.title"),
                           message: model.t("txn.empty.message"))
            #if DEBUG
            Button(model.t("overview.loadDemo")) { model.loadDemoData() }.buttonStyle(.bordered)
            #endif
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker(model.t("filter.label"), selection: $model.filter) {
                ForEach(TransactionFilter.allCases) { f in Text(model.t(f.titleKey)).tag(f) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        ToolbarItem(placement: .navigation) {
            Menu {
                Button(model.t("date.all")) { setDateRange(nil, nil) }
                Button(model.t("date.thisMonth")) { applyPeriod(.month) }
                Button(model.t("date.thisYear")) { applyPeriod(.year) }
            } label: {
                Label(dateFilterLabel, systemImage: "calendar")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                if let id = selection.first, let t = transaction(id) { model.edit(t) }
            } label: { Label(model.t("common.edit"), systemImage: "pencil") }
            .disabled(selection.count != 1)

            Button(role: .destructive, action: requestDeleteSelection) {
                Label(model.t("common.delete"), systemImage: "trash")
            }
            .disabled(selection.isEmpty)

            Button { model.importCSVViaPanel() } label: { Label(model.t("cmd.importCSV"), systemImage: "square.and.arrow.down") }
            Button { model.exportCSVViaPanel() } label: { Label(model.t("cmd.exportCSV"), systemImage: "square.and.arrow.up") }
            Button { model.newTransaction() } label: { Label(model.t("cmd.newTransaction"), systemImage: "plus") }
                .keyboardShortcut("n", modifiers: .command)
        }
    }

    private var dateFilterLabel: String {
        model.dateFrom == nil && model.dateTo == nil ? model.t("date.all") : model.t("date.filtered")
    }

    private func applyPeriod(_ period: OverviewPeriod) {
        let (from, to) = period.range()
        setDateRange(from.flatMap(DateFormat.date(from:)), to.flatMap(DateFormat.date(from:)))
    }

    private func setDateRange(_ from: Date?, _ to: Date?) {
        model.dateFrom = from; model.dateTo = to
        selection.removeAll()
        model.reloadTransactions()
    }

    private func requestDeleteSelection() { model.requestDelete(selection) }

    private func transaction(_ id: Transaction.ID) -> Transaction? { model.transactions.first { $0.id == id } }

    private func categoryName(_ id: String?) -> String {
        guard let id else { return "—" }
        if let cat = model.categories.first(where: { $0.id == id }) { return model.categoryLabel(cat) }
        return id
    }
}
