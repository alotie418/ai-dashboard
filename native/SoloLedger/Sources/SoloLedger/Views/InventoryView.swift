import SwiftUI
import SoloLedgerCore

/// The inventory page — one product's stock movements, its running balance, and the panel that
/// records a new movement.
///
/// **Reached from the `.inventory` sidebar section** (N-PR-6) through the split view's detail
/// switch — one enum case serving both the sidebar list and the menu-bar picker. The entry point
/// was a separate change, deliberately: until that case existed this page was compiled, tested and
/// unreachable, exactly as the products page was before its own activation.
/// `InventoryMountingTests` pins the single construction site by scanning the tree.
///
/// Every key drawn below comes from ``InventoryPageComposition``: the subviews take their slice of
/// that value and render exactly what the slice names. There is not one literal in the copy's
/// namespace in this file, which is what lets a test prove what the page can and cannot say — and
/// it is why the accessibility identifiers are spelled `inventoryPage.…` rather than
/// `inventory.…`, which would read to every scanner as the view having grown its own copy.
struct InventoryView: View {
    @EnvironmentObject var model: AppModel

    private var page: InventoryPageComposition.Page {
        InventoryPageComposition.compose(model.inventoryInput)
    }

    var body: some View {
        let page = self.page
        VStack(alignment: .leading, spacing: 16) {
            InventoryPageHeader(page: page)
            if let messageKey = page.errorKeys.first {
                InventoryErrorBanner(messageKey: messageKey)
            }
            if let block = page.balance {
                InventoryBalanceCard(block: block)
            }
            list(page)
            if page.openingHintKeys.count == 2 {
                InventoryOpeningHint(titleKey: page.openingHintKeys[0],
                                     messageKey: page.openingHintKeys[1])
            }
            if let block = page.exceptions {
                InventoryExceptionList(block: block)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(model.t(page.titleKey))
        // Lazy on purpose: this product's movements are read when the page appears and never as
        // part of the app-wide refresh, so the six sections that are not this one cost no query
        // — and the read is a whole history with no paging behind it.
        .task { model.reloadInventory() }
        .sheet(isPresented: Binding(
            get: { page.form != nil },
            set: { if !$0 { model.cancelInventoryForm() } }
        )) {
            if let block = page.form {
                InventoryFormSheet(block: block).environmentObject(model)
            }
        }
        // The opening-stock wizard's ONE mount. `interactiveDismissDisabled()` is UNCONDITIONAL
        // and that is the point: a system dismissal — Escape, a swipe, the window's own close —
        // writes `false` straight into the presentation binding without going through
        // `dismissInventoryOpening()`, so the sheet would vanish while the state stayed on a
        // blocked or outcome page. The next press of the entry point then hits its
        // `guard case .idle` and does nothing at all: a button that has silently stopped working.
        .sheet(isPresented: $model.showingInventoryOpening) {
            InventoryOpeningView()
                .environmentObject(model)
                .interactiveDismissDisabled()
        }
        .confirmationDialog(reverseTitle(page.reverse), isPresented: Binding(
            get: { page.reverse != nil },
            set: { if !$0 { model.cancelInventoryReversal() } }
        ), titleVisibility: .visible) {
            if let block = page.reverse {
                Button(model.t(block.confirmActionKey), role: .destructive) {
                    model.confirmInventoryReversal()
                }
                Button(model.t(block.cancelActionKey), role: .cancel) {
                    model.cancelInventoryReversal()
                }
            }
        } message: {
            if let block = page.reverse { Text(model.t(block.messageKey)) }
        }
    }

    /// The list, or — when there is nothing to list — whichever empty render the composition
    /// chose. They are mutually exclusive there: "no products yet" and "no movements for this
    /// product" are different statements and only one of them can be true.
    @ViewBuilder private func list(_ page: InventoryPageComposition.Page) -> some View {
        if let block = page.list {
            InventoryMovementTable(block: block)
        } else if page.emptyKeys.count == 2 {
            EmptyStateView(systemImage: "tray.full",
                           title: model.t(page.emptyKeys[0]),
                           message: model.t(page.emptyKeys[1]))
        }
    }

    private func reverseTitle(_ block: InventoryPageComposition.ReverseBlock?) -> String {
        guard let block else { return "" }
        return model.t(block.titleKey)
    }
}

// MARK: - Header

private struct InventoryPageHeader: View {
    @EnvironmentObject var model: AppModel
    let page: InventoryPageComposition.Page

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(page.headerKeys, id: \.self) { key in
                    Text(model.t(key)).font(.subheadline).foregroundStyle(.secondary)
                }
                // The three standing declarations: how stock is costed, that those costs stop
                // here and reach no report, and where the units come from.
                ForEach(page.noteKeys, id: \.self) { key in
                    Text(model.t(key))
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 8) {
                if !page.products.isEmpty {
                    // No "nothing selected" option. There is no copy for that state, and every
                    // sentence this page owns would be false in it, so a product is always
                    // selected while one exists. This is not the products panel's rule about NOT
                    // pre-selecting a unit: that one exists because a pre-selected value would be
                    // written back into the ledger on save, and this control writes nothing at
                    // all — it only chooses what to read.
                    Picker("", selection: productSelection) {
                        ForEach(page.products) { product in
                            Text(product.name).tag(Optional(product.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                    .accessibilityIdentifier("inventoryPage.productPicker")
                }
                ForEach(page.actionKeys, id: \.self) { key in
                    Button(model.t(key)) { model.newInventoryMovement() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.inventoryWriteIsPending || page.products.isEmpty)
                        .accessibilityIdentifier(key)
                }
                // The opening-stock wizard's entry point. Enabled even on an empty catalogue: the
                // wizard's own `noProduct` page says what to do about it, which is more use than
                // a disabled button with nothing to explain it.
                Button(model.t(page.openingActionKey)) { model.beginInventoryOpening() }
                    .disabled(model.inventoryWriteIsPending)
                    .help(model.t(page.openingHintKey))
                    .accessibilityIdentifier("inventoryPage.openingCTA")
            }
        }
    }

    private var productSelection: Binding<String?> {
        Binding(get: { page.selectedProductID },
                set: { if let id = $0 { model.selectInventoryProduct(id) } })
    }
}

// MARK: - The refusal

/// One of eighteen sentences, and never anything else. The engine's own words cannot get here:
/// `InventoryPostingError` has no associated values to print.
private struct InventoryErrorBanner: View {
    @EnvironmentObject var model: AppModel
    let messageKey: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            Text(model.t(messageKey))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button { model.dismissInventoryError() } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityIdentifier("inventoryPage.errorBanner")
    }
}

// MARK: - The balance

/// The three figures the ledger holds for this product, and the standing note about the currency
/// they are held in. No currency symbol and no code beside the numbers: the copy has no caption
/// to label one with, and an unlabelled code is a value this page cannot say the meaning of.
private struct InventoryBalanceCard: View {
    @EnvironmentObject var model: AppModel
    let block: InventoryPageComposition.BalanceBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.t(block.titleKey, ["name": block.productName])).font(.headline)
            HStack(alignment: .top, spacing: 28) {
                figure(block.quantityLabelKey, quantityText)
                figure(block.costLabelKey,
                       InventoryPageComposition.amountText(block.costBalanceMinor,
                                                           language: model.language))
                figure(block.unitCostLabelKey,
                       InventoryPageComposition.averageText(block.unitCostMicro,
                                                            language: model.language))
            }
            Text(model.t(block.currencyNoteKey))
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: 720, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("inventoryPage.balance")
    }

    private var quantityText: String {
        let number = InventoryPageComposition.quantityText(block.quantityMilli,
                                                           language: model.language)
        let unit = unitText(block.unit)
        return unit.isEmpty ? number : "\(number) \(unit)"
    }

    private func figure(_ labelKey: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.t(labelKey)).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3).monospacedDigit()
        }
    }

    private func unitText(_ unit: InventoryPageComposition.UnitLabel) -> String {
        switch unit {
        case .key(let key):       return model.t(key)
        case .verbatim(let text): return text
        case .none:               return ""
        }
    }
}

// MARK: - The list

/// ## Why the cells below take plain values
///
/// `Table` materialises its cell views again, outside the render pass, when an accessibility
/// client walks the page — VoiceOver, the Accessibility Inspector, any UI automation — and in
/// that context the environment is not attached, so an `@EnvironmentObject` declared inside a
/// cell traps with `Fatal error: No ObservableObject of type AppModel found`. That is a defect
/// the products page had to be repaired for; this page is built without it from the first line.
///
/// The exposure here is larger than it was there: a product's movements are read whole, with no
/// paging behind them, and this page keeps a second block on screen beside the table — the
/// exception list — which is the other half of the condition that reproduced it.
///
/// So the model is read HERE, once, while the environment is guaranteed, and the cells receive
/// resolved text and intent closures. `InventoryMountingTests` keeps the rule as a source guard.
private struct InventoryMovementTable: View {
    @EnvironmentObject var model: AppModel
    let block: InventoryPageComposition.ListBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Table(block.rows) {
                TableColumn(model.t(block.dateHeaderKey)) { row in
                    InventoryTextCell(text: row.occurredOn)
                }
                .width(min: 84, ideal: 96)

                TableColumn(model.t(block.typeHeaderKey)) { row in
                    InventoryTextCell(text: model.t(row.typeKey))
                }
                .width(min: 96, ideal: 120)

                TableColumn(model.t(block.quantityHeaderKey)) { row in
                    InventoryAmountCell(amountText: quantityText(row))
                }
                .width(min: 90, ideal: 116)

                TableColumn(model.t(block.unitCostHeaderKey)) { row in
                    InventoryAmountCell(amountText: row.unitCostMicro.map(averageText))
                }
                .width(min: 96, ideal: 124)

                TableColumn(model.t(block.costHeaderKey)) { row in
                    InventoryAmountCell(amountText: row.totalCostMinor.map(amountText))
                }
                .width(min: 90, ideal: 116)

                TableColumn(model.t(block.sourceHeaderKey)) { row in
                    InventoryTextCell(text: row.source)
                }
                .width(min: 80, ideal: 110)

                TableColumn(model.t(block.noteHeaderKey)) { row in
                    InventoryTextCell(text: row.note)
                }
                .width(min: 80, ideal: 130)

                TableColumn(model.t(block.statusHeaderKey)) { row in
                    InventoryStatusCell(label: model.t(row.statusKey),
                                        isSuperseded: row.isSuperseded)
                }
                .width(min: 74, ideal: 92)

                // An unlabelled action column, and only the last live row puts anything in it.
                TableColumn("") { row in
                    if let key = row.reverseActionKey {
                        InventoryRowActions(reverseLabel: model.t(key),
                                            isDisabled: model.inventoryWriteIsPending,
                                            reverse: { model.requestInventoryReversal(row.id) })
                    }
                }
                .width(min: 72, ideal: 88)
            }
            .accessibilityIdentifier("inventoryPage.table")

            // Said once, under the list, because that is where the missing controls are.
            Text(model.t(block.onlyLastNoteKey))
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("inventoryPage.onlyLastNote")
        }
    }

    private func quantityText(_ row: InventoryPageComposition.RowBlock) -> String {
        let number = InventoryPageComposition.quantityText(row.quantityMilli,
                                                           language: model.language)
        let unit = unitText(block.unit)
        return unit.isEmpty ? number : "\(number) \(unit)"
    }

    private func amountText(_ minor: Int64) -> String {
        InventoryPageComposition.amountText(minor, language: model.language)
    }

    private func averageText(_ micro: Int64) -> String {
        InventoryPageComposition.averageText(micro, language: model.language)
    }

    /// The already-classified unit label, rendered. Which stored value belongs to which arm is
    /// decided once, by the products page's own rule, and reaches this page as a value.
    private func unitText(_ unit: InventoryPageComposition.UnitLabel) -> String {
        switch unit {
        case .key(let key):       return model.t(key)
        case .verbatim(let text): return text
        case .none:               return ""
        }
    }
}

private struct InventoryTextCell: View {
    let text: String

    var body: some View {
        Text(text).foregroundStyle(.secondary)
    }
}

private struct InventoryAmountCell: View {
    /// `nil` draws the em dash — an average-priced issue carries no unit cost of its own.
    let amountText: String?

    var body: some View {
        Group {
            if let amountText {
                Text(amountText).monospacedDigit()
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct InventoryStatusCell: View {
    let label: String
    /// A reversed row and a reversal row are both still in the ledger and neither is part of the
    /// balance; they are drawn back rather than hidden, because removing them would make the
    /// audit view disagree with itself.
    let isSuperseded: Bool

    var body: some View {
        Text(label)
            .foregroundStyle(isSuperseded ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
    }
}

private struct InventoryRowActions: View {
    let reverseLabel: String
    let isDisabled: Bool
    let reverse: () -> Void

    var body: some View {
        Button(reverseLabel, role: .destructive) { reverse() }
            .buttonStyle(.link)
            .disabled(isDisabled)
    }
}

// MARK: - The opening advice

/// Shown exactly while an opening balance is still legal — the engine refuses one the moment a
/// live movement exists, so past that point this would be advice the user cannot act on.
private struct InventoryOpeningHint: View {
    @EnvironmentObject var model: AppModel
    let titleKey: String
    let messageKey: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.t(titleKey)).font(.footnote.weight(.semibold))
                Text(model.t(messageKey))
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
        .accessibilityIdentifier("inventoryPage.openingHint")
    }
}

// MARK: - Records worth a second look

/// What the engine flagged while posting: a return whose origin document it could not find, a
/// cost adjusted by hand, an opening entered by hand. Ordered by the movement each belongs to,
/// because the store returns them ordered by an identifier that means nothing on screen.
private struct InventoryExceptionList: View {
    @EnvironmentObject var model: AppModel
    let block: InventoryPageComposition.ExceptionBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.t(block.titleKey)).font(.footnote.weight(.semibold))
            ForEach(block.rows) { row in
                Text(model.t(row.messageKey))
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
        .accessibilityIdentifier("inventoryPage.exceptions")
    }
}

// MARK: - The new-movement panel

/// Four to five fields, and which ones depends on the kind: the engine decides what a movement
/// carries, and this panel shows exactly that. Nothing here can reach a field the selected kind
/// does not use, so leftover text in a hidden one never travels to the ledger.
private struct InventoryFormSheet: View {
    @EnvironmentObject var model: AppModel
    let block: InventoryPageComposition.FormBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.t(block.titleKey)).font(.headline)

            HStack(alignment: .top, spacing: 16) {
                field(block.dateLabelKey) {
                    DatePicker("", selection: occurredOn, displayedComponents: .date)
                        .labelsHidden()
                        .accessibilityIdentifier("inventoryPage.form.date")
                }
                field(block.typeLabelKey) {
                    Picker("", selection: typeSelection) {
                        ForEach(block.typeOptions) { option in
                            Text(model.t(option.labelKey)).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .accessibilityIdentifier("inventoryPage.form.type")
                }
            }

            HStack(alignment: .top, spacing: 16) {
                if let labelKey = block.quantityLabelKey {
                    field(labelKey, suffix: unitText(block.unit)) {
                        TextField(block.quantityPlaceholderKey.map(model.t) ?? "", text: quantityText)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .accessibilityIdentifier("inventoryPage.form.quantity")
                    }
                }
                if let labelKey = block.unitCostLabelKey {
                    field(labelKey) {
                        TextField("", text: unitCostText)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .accessibilityIdentifier("inventoryPage.form.unitCost")
                    }
                }
                if let labelKey = block.costDeltaLabelKey {
                    field(labelKey) {
                        TextField("", text: costDeltaText)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .accessibilityIdentifier("inventoryPage.form.costDelta")
                    }
                }
            }

            if let hintKey = block.unitCostHintKey {
                hint(hintKey)
            }
            if let hintKey = block.costDeltaHintKey {
                hint(hintKey)
            }

            HStack(alignment: .top, spacing: 16) {
                field(block.sourceLabelKey) {
                    TextField(model.t(block.sourcePlaceholderKey), text: sourceText)
                        .accessibilityIdentifier("inventoryPage.form.source")
                }
                field(block.noteLabelKey) {
                    TextField("", text: noteText)
                        .accessibilityIdentifier("inventoryPage.form.note")
                }
            }

            HStack {
                Spacer()
                Button(model.t(block.cancelActionKey)) { model.cancelInventoryForm() }
                Button(model.t(block.submitActionKey)) { model.submitInventoryForm() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!block.canSubmit)
            }
        }
        .padding(20)
        .frame(minWidth: 640, alignment: .leading)
        .accessibilityIdentifier("inventoryPage.form")
    }

    private func field<Content: View>(_ labelKey: String, suffix: String = "",
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(model.t(labelKey)).font(.caption).foregroundStyle(.secondary)
                if !suffix.isEmpty {
                    Text(suffix).font(.caption).foregroundStyle(.secondary)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hint(_ key: String) -> some View {
        Text(model.t(key))
            .font(.footnote).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func unitText(_ unit: InventoryPageComposition.UnitLabel) -> String {
        switch unit {
        case .key(let key):       return model.t(key)
        case .verbatim(let text): return text
        case .none:               return ""
        }
    }

    private var occurredOn: Binding<Date> {
        Binding(get: { model.inventoryForm.flatMap { DateFormat.date(from: $0.occurredOn) } ?? Date() },
                set: { model.inventoryForm?.occurredOn = DateFormat.string(from: $0) })
    }
    private var typeSelection: Binding<String> {
        Binding(get: { model.inventoryFormTypeRawValue },
                set: { model.selectInventoryFormType($0) })
    }
    private var quantityText: Binding<String> {
        Binding(get: { model.inventoryForm?.quantityText ?? "" },
                set: { model.inventoryForm?.quantityText = $0 })
    }
    private var unitCostText: Binding<String> {
        Binding(get: { model.inventoryForm?.unitCostText ?? "" },
                set: { model.inventoryForm?.unitCostText = $0 })
    }
    private var costDeltaText: Binding<String> {
        Binding(get: { model.inventoryForm?.costDeltaText ?? "" },
                set: { model.inventoryForm?.costDeltaText = $0 })
    }
    private var sourceText: Binding<String> {
        Binding(get: { model.inventoryForm?.sourceText ?? "" },
                set: { model.inventoryForm?.sourceText = $0 })
    }
    private var noteText: Binding<String> {
        Binding(get: { model.inventoryForm?.noteText ?? "" },
                set: { model.inventoryForm?.noteText = $0 })
    }
}
