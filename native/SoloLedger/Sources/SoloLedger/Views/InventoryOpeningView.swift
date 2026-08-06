import SwiftUI
import SoloLedgerCore

/// The opening-stock wizard — one scrolling sheet, not a multi-step flow.
///
/// The adjudicated copy has an opening paragraph, a list, one confirm button and a cancel, and no
/// next/back labels: the decision is made on one page after reading it. That is the same shape the
/// legacy-conversion wizard has, and for the same reason.
///
/// **Nothing outside `InventoryView` constructs this**, and `InventoryView` itself is constructed
/// by nobody — the sidebar has no case for the inventory page and the detail switch has no branch.
/// So the whole chain is unreachable, which is what this stage ships. `InventoryMountingTests`
/// asserts both halves of that.
///
/// Every key comes from ``InventoryOpeningComposition``; there is not one literal in the copy's
/// namespace in this file. The accessibility identifiers are spelled `inventoryOpening.…` rather
/// than `inventory.opening.…` for the same reason the page's are `inventoryPage.…`: the latter
/// would read to every scanner as the view having grown its own source of strings.
///
/// There is deliberately no `Table` here. The page's movement list needs one and pays for it with
/// the cell rule PM13 enforces; this list is a handful of rows with two text fields each, so a
/// `VStack` draws it without ever putting a view where an accessibility traversal can rebuild it
/// outside the environment.
struct InventoryOpeningView: View {
    @EnvironmentObject var model: AppModel

    private var page: InventoryOpeningComposition.Page {
        InventoryOpeningComposition.compose(model.inventoryOpening)
    }

    var body: some View {
        let page = self.page
        VStack(spacing: 0) {
            header(page)
            Divider()
            ScrollView {
                content(page)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer(page)
        }
        .frame(minWidth: 680, idealWidth: 780, minHeight: 460, idealHeight: 580)
        .accessibilityIdentifier("inventoryOpening.sheet")
    }

    @ViewBuilder private func header(_ page: InventoryOpeningComposition.Page) -> some View {
        if let titleKey = page.titleKey {
            Text(model.t(titleKey))
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 10)
        }
    }

    @ViewBuilder private func content(_ page: InventoryOpeningComposition.Page) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(page.noteKeys, id: \.self) { key in
                Text(model.t(key))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if page.blockedKeys.count == 2 {
                InventoryOpeningBlockedView(titleKey: page.blockedKeys[0],
                                            messageKey: page.blockedKeys[1])
            }
            if let form = page.form {
                InventoryOpeningDateField(block: form)
            }
            if let list = page.list {
                InventoryOpeningLines(block: list)
            }
            if let form = page.form {
                InventoryOpeningHints(block: form)
            }
            if let confirm = page.confirm {
                InventoryOpeningConfirmNote(block: confirm)
            }
            if let outcome = page.outcome {
                InventoryOpeningOutcomeView(block: outcome)
            }
        }
    }

    /// The only actions this sheet ever offers, and which of them exists depends on whether there
    /// is still a decision to make.
    @ViewBuilder private func footer(_ page: InventoryOpeningComposition.Page) -> some View {
        HStack {
            Spacer()
            if let key = page.blockedDismissKey {
                Button(model.t(key)) { model.dismissInventoryOpening() }
                    .keyboardShortcut(.cancelAction)
            }
            if let confirm = page.confirm {
                Button(model.t(confirm.cancelActionKey)) { model.dismissInventoryOpening() }
                    .keyboardShortcut(.cancelAction)
                Button(model.t(confirm.submitActionKey)) { model.confirmInventoryOpening() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!confirm.canSubmit)
                    .accessibilityIdentifier("inventoryOpening.submit")
            }
            if let outcome = page.outcome {
                Button(model.t(outcome.dismissActionKey)) { model.dismissInventoryOpening() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }
}

// MARK: - Blocked

private struct InventoryOpeningBlockedView: View {
    @EnvironmentObject var model: AppModel
    let titleKey: String
    let messageKey: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.t(titleKey)).font(.headline)
            Text(model.t(messageKey))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 620, alignment: .leading)
        .accessibilityIdentifier("inventoryOpening.blocked")
    }
}

// MARK: - The switch-over date

/// The date field, and N-6's consequence said right beside it — not on the way out, where it
/// would be a fact about a decision already taken.
private struct InventoryOpeningDateField: View {
    @EnvironmentObject var model: AppModel
    let block: InventoryOpeningComposition.FormBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.t(block.dateLabelKey)).font(.caption).foregroundStyle(.secondary)
            DatePicker("", selection: occurredOn, displayedComponents: .date)
                .labelsHidden()
                .accessibilityIdentifier("inventoryOpening.date")
            Text(model.t(block.dateNoteKey))
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 620, alignment: .leading)
    }

    private var occurredOn: Binding<Date> {
        Binding(get: { DateFormat.date(from: block.occurredOn) ?? Date() },
                set: { model.setInventoryOpeningDate(DateFormat.string(from: $0)) })
    }
}

// MARK: - The lines

private struct InventoryOpeningLines: View {
    @EnvironmentObject var model: AppModel
    let block: InventoryOpeningComposition.ListBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(model.t(block.productHeaderKey)).frame(maxWidth: .infinity, alignment: .leading)
                Text(model.t(block.quantityHeaderKey)).frame(width: 120, alignment: .trailing)
                Text(model.t(block.amountHeaderKey)).frame(width: 140, alignment: .trailing)
                Text(model.t(block.unitCostHeaderKey)).frame(width: 130, alignment: .trailing)
            }
            .font(.caption).foregroundStyle(.secondary)
            Divider()
            ForEach(Array(block.rows.enumerated()), id: \.element.id) { index, row in
                InventoryOpeningLineRow(row: row,
                                        impliedUnitCostText: impliedUnitCostText(row),
                                        quantity: quantity(at: index),
                                        amount: amount(at: index))
            }
        }
        .accessibilityIdentifier("inventoryOpening.lines")
    }

    /// `nil` draws the em dash: half a line implies no unit cost, and showing one derived from
    /// half an input would be a number the ledger never agreed to.
    private func impliedUnitCostText(_ row: InventoryOpeningComposition.RowBlock) -> String? {
        row.impliedUnitCostMicro.map {
            InventoryPageComposition.averageText($0, language: model.language)
        }
    }

    private func quantity(at index: Int) -> Binding<String> {
        Binding(get: { model.inventoryOpeningDraft?.lines[safe: index]?.quantityText ?? "" },
                set: { model.setInventoryOpeningQuantity($0, at: index) })
    }

    private func amount(at index: Int) -> Binding<String> {
        Binding(get: { model.inventoryOpeningDraft?.lines[safe: index]?.amountText ?? "" },
                set: { model.setInventoryOpeningAmount($0, at: index) })
    }
}

private struct InventoryOpeningLineRow: View {
    let row: InventoryOpeningComposition.RowBlock
    let impliedUnitCostText: String?
    @Binding var quantity: String
    @Binding var amount: String

    var body: some View {
        HStack(spacing: 12) {
            Text(row.productName).frame(maxWidth: .infinity, alignment: .leading)
            TextField("", text: $quantity)
                .multilineTextAlignment(.trailing).monospacedDigit()
                .frame(width: 120)
            TextField("", text: $amount)
                .multilineTextAlignment(.trailing).monospacedDigit()
                .frame(width: 140)
            Group {
                if let impliedUnitCostText {
                    Text(impliedUnitCostText).monospacedDigit()
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .frame(width: 130, alignment: .trailing)
        }
    }
}

// MARK: - The three things said beside the fields

private struct InventoryOpeningHints: View {
    @EnvironmentObject var model: AppModel
    let block: InventoryOpeningComposition.FormBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach([block.quantityHintKey, block.amountHintKey, block.roundingNoteKey],
                    id: \.self) { key in
                Text(model.t(key))
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
        .accessibilityIdentifier("inventoryOpening.hints")
    }
}

// MARK: - What pressing the button will do

private struct InventoryOpeningConfirmNote: View {
    @EnvironmentObject var model: AppModel
    let block: InventoryOpeningComposition.ConfirmBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.t(block.summaryKey, ["count": String(block.countedProducts)]))
                .font(.callout)
            Text(model.t(block.currencyNoteKey))
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 620, alignment: .leading)
        .accessibilityIdentifier("inventoryOpening.confirm")
    }
}

// MARK: - What it did

private struct InventoryOpeningOutcomeView: View {
    @EnvironmentObject var model: AppModel
    let block: InventoryOpeningComposition.OutcomeBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.t(block.titleKey)).font(.headline)
            Text(model.t(block.messageKey, ["count": String(block.refusedCount)]))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(block.refusals, id: \.productName) { refusal in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(refusal.productName).font(.callout)
                    Text(model.t(refusal.messageKey))
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
        .accessibilityIdentifier("inventoryOpening.outcome")
    }
}

// MARK: - Bounds

private extension Array {
    /// The draft can change under a binding that was made for an older row count, so an index is
    /// asked for rather than assumed. Out of range reads as empty and writes nothing.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
