import SwiftUI
import SoloLedgerCore

/// The products / service-items page — master data only.
///
/// **Nothing constructs this view yet.** The sidebar has no case for it and the detail switch
/// has no branch, so this stage ships the page compiled, tested and unreachable, exactly as the
/// report page did before its own activation. `ProductMountingTests` asserts the absence of
/// every construction site by scanning the tree.
///
/// Every key drawn below comes from ``ProductPageComposition``: the subviews take their slice of
/// that value and render exactly what the slice names. There is not one `product.*` literal in
/// this file, which is what lets a test prove what the page can and cannot say.
struct ProductsView: View {
    @EnvironmentObject var model: AppModel

    private var page: ProductPageComposition.Page {
        ProductPageComposition.compose(model.productInput)
    }

    var body: some View {
        let page = self.page
        VStack(alignment: .leading, spacing: 16) {
            ProductPageHeader(page: page)
            if let messageKey = page.errorKeys.first {
                ProductErrorBanner(messageKey: messageKey)
            }
            list(page)
            // Directly under the list, because the sentence says "not listed above".
            if let messageKey = page.unreadableKeys.first {
                ProductUnreadableNotice(messageKey: messageKey, count: page.unreadableCount)
            }
            if let form = page.form {
                ProductFormPanel(block: form)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(model.t(page.titleKey))
        // Lazy on purpose: the catalogue is read when this page appears and never as part of
        // the app-wide refresh, so an unreachable page costs no query.
        .task { model.reloadProducts() }
        .confirmationDialog(deleteTitle(page.delete), isPresented: Binding(
            get: { page.delete != nil },
            set: { if !$0 { model.cancelProductDelete() } }
        ), titleVisibility: .visible) {
            if let block = page.delete {
                Button(model.t(block.deleteActionKey), role: .destructive) {
                    model.confirmProductDelete()
                }
                Button(model.t(block.cancelActionKey), role: .cancel) {
                    model.cancelProductDelete()
                }
            }
        } message: {
            if let block = page.delete { Text(model.t(block.messageKey)) }
        }
    }

    /// The list, or — on a ledger with nothing to list — whichever of the two empty renders the
    /// composition chose. They are mutually exclusive there: a ledger whose product rows all
    /// failed to decode gets the notice, never "you have no products yet".
    @ViewBuilder private func list(_ page: ProductPageComposition.Page) -> some View {
        if let block = page.list {
            ProductTable(block: block)
        } else if page.emptyKeys.count == 2 {
            EmptyStateView(systemImage: "shippingbox",
                           title: model.t(page.emptyKeys[0]),
                           message: model.t(page.emptyKeys[1]))
        }
    }

    private func deleteTitle(_ block: ProductPageComposition.DeleteBlock?) -> String {
        guard let block else { return "" }
        return model.t(block.titleKey, ["name": block.productName])
    }
}

// MARK: - Header

private struct ProductPageHeader: View {
    @EnvironmentObject var model: AppModel
    let page: ProductPageComposition.Page

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(page.headerKeys, id: \.self) { key in
                    Text(model.t(key)).font(.subheadline).foregroundStyle(.secondary)
                }
                // The standing declaration: the price on this page is recorded, not computed
                // with. It sits beside the column it qualifies rather than in a page footer.
                ForEach(page.noteKeys, id: \.self) { key in
                    Text(model.t(key))
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            Spacer(minLength: 16)
            ForEach(page.actionKeys, id: \.self) { key in
                Button(model.t(key)) { model.newProduct() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.productWriteIsPending)
                    .accessibilityIdentifier(key)
            }
        }
    }
}

// MARK: - The refusal

/// One of six sentences, and never anything else. The store's own words cannot get here:
/// `ProductCatalogError` has no associated values to print.
private struct ProductErrorBanner: View {
    @EnvironmentObject var model: AppModel
    let messageKey: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            Text(model.t(messageKey))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button { model.dismissProductError() } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityIdentifier("products.errorBanner")
    }
}

// MARK: - The list

/// ## Why the cells below take plain values
///
/// Every one of them used to be an `@EnvironmentObject` view of its own, and that crashed the
/// app. `Table` materialises its cell views again, outside the render pass, when an
/// accessibility client walks the page — VoiceOver, the Accessibility Inspector, any UI
/// automation — and in that context the environment is not attached, so the lookup traps with
/// `Fatal error: No ObservableObject of type AppModel found`. It took a ledger holding a product
/// row this app cannot decode (so the notice is on screen) plus an accessibility traversal to
/// reproduce; neither alone does it.
///
/// So the model is read HERE, once, while the environment is guaranteed, and the cells receive
/// resolved text and intent closures. That is what `TransactionListView` and `CategoriesView`
/// have always done — their cells are closures over the enclosing view's model, and neither has
/// ever had this defect. `ProductMountingTests` keeps the rule as a source guard.
private struct ProductTable: View {
    @EnvironmentObject var model: AppModel
    let block: ProductPageComposition.ListBlock

    var body: some View {
        Table(block.rows) {
            TableColumn(model.t(block.nameHeaderKey)) { row in
                Text(row.product.name)
            }
            TableColumn(model.t(block.unitHeaderKey)) { row in
                ProductUnitCell(text: unitText(row.unit))
            }
            .width(min: 60, ideal: 80)

            TableColumn(model.t(block.typeHeaderKey)) { row in
                Text(model.t(row.typeKey)).foregroundStyle(.secondary)
            }
            .width(min: 56, ideal: 72)

            TableColumn(model.t(block.costHeaderKey)) { row in
                ProductCostCell(amountText: amountText(row.cost))
            }
            .width(min: 90, ideal: 120)

            TableColumn(model.t(block.statusHeaderKey)) { row in
                ProductStatusCell(label: model.t(row.statusKey),
                                  hint: model.t(row.toggleHintKey),
                                  isDisabled: model.productWriteIsPending,
                                  toggle: { model.toggleProductActive(row.product) })
            }
            .width(min: 66, ideal: 84)

            // The other app's list has an unlabelled action column, and so does this one.
            TableColumn("") { row in
                ProductRowActions(editLabel: model.t(row.editActionKey),
                                  deleteLabel: model.t(row.deleteActionKey),
                                  isDisabled: model.productWriteIsPending,
                                  edit: { model.editProduct(row.product) },
                                  delete: { model.requestProductDelete(row.product) })
            }
            .width(min: 96, ideal: 116)
        }
        .accessibilityIdentifier("products.table")
    }

    /// `getProductUnitLabel`'s three answers. A unit that was never on the whitelist is shown as
    /// it stands — naming it would be claiming to know a unit this app does not know — and a
    /// cell with no text reading draws nothing, exactly as the other app does.
    private func unitText(_ unit: ProductPageComposition.UnitDisplay) -> String {
        switch unit {
        case .key(let key):       return model.t(key)
        case .verbatim(let text): return text
        case .none:               return ""
        }
    }

    /// `nil` for the em dash. No currency symbol: the `products` table records no currency, so
    /// putting one here would state something the ledger never said.
    private func amountText(_ cost: ProductPageComposition.CostDisplay) -> String? {
        guard case .amount(let value) = cost else { return nil }
        return ReportFormat.money(value, language: model.language)
    }
}

private struct ProductUnitCell: View {
    let text: String

    var body: some View {
        Text(text).foregroundStyle(.secondary)
    }
}

private struct ProductCostCell: View {
    /// `nil` draws the em dash.
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

/// The status cell IS the control, mirroring the other app: the label is the current state and
/// pressing it flips the row. The hint names the state it would move to, so the button says what
/// it does without a fourteenth status string.
private struct ProductStatusCell: View {
    let label: String
    let hint: String
    let isDisabled: Bool
    let toggle: () -> Void

    var body: some View {
        Button(label) { toggle() }
            .buttonStyle(.link)
            .disabled(isDisabled)
            .accessibilityHint(Text(hint))
    }
}

private struct ProductRowActions: View {
    let editLabel: String
    let deleteLabel: String
    let isDisabled: Bool
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(editLabel) { edit() }
            Button(deleteLabel, role: .destructive) { delete() }
        }
        .buttonStyle(.link)
        .disabled(isDisabled)
    }
}

// MARK: - Rows that could not be read

/// How many product rows the ledger holds that could not be decoded, said plainly.
///
/// It exists because the alternative — dropping them — makes a damaged row and an absent one
/// look the same. The sentence promises the rows are untouched, and they are: nothing on this
/// page writes to a row it could not read.
private struct ProductUnreadableNotice: View {
    @EnvironmentObject var model: AppModel
    let messageKey: String
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
            Text(model.t(messageKey, ["count": String(count)]))
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 620, alignment: .leading)
        .accessibilityIdentifier("products.unreadableNotice")
    }
}

// MARK: - The new / edit panel

/// Four fields and no fifth. `is_active` is not among them on either side — the list cell is its
/// control — and nothing here can reach any other column of the row.
private struct ProductFormPanel: View {
    @EnvironmentObject var model: AppModel
    let block: ProductPageComposition.FormBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.t(block.titleKey)).font(.headline)
            HStack(alignment: .top, spacing: 16) {
                field(block.nameLabelKey) {
                    TextField(model.t(block.placeholderKey), text: name)
                        .accessibilityIdentifier("products.form.name")
                }
                field(block.unitLabelKey) {
                    Picker("", selection: unit) {
                        // No selection at all when the row holds a unit the whitelist does not
                        // contain. Seeding the first option and writing it back on save would
                        // replace bytes the user never chose.
                        Text("").tag(String?.none)
                        ForEach(block.unitOptions) { option in
                            Text(model.t(option.labelKey)).tag(String?.some(option.rawValue))
                        }
                    }
                    .labelsHidden()
                    .accessibilityIdentifier("products.form.unit")
                }
                field(block.costLabelKey) {
                    TextField("", text: costText)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .accessibilityIdentifier("products.form.cost")
                }
            }
            Toggle(model.t(block.serviceLabelKey), isOn: isService)
                .accessibilityIdentifier("products.form.isService")
            Text(model.t(block.serviceHintKey))
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(model.t(block.cancelActionKey)) { model.cancelProductForm() }
                Button(model.t(block.saveActionKey)) { model.saveProductForm() }
                    .buttonStyle(.borderedProminent)
                    .disabled(nameIsBlank)
            }
        }
        .padding(12)
        .frame(maxWidth: 720, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("products.form")
    }

    private func field<Content: View>(_ labelKey: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.t(labelKey)).font(.caption).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var nameIsBlank: Bool {
        (model.productForm?.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var name: Binding<String> {
        Binding(get: { model.productForm?.name ?? "" }, set: { model.productForm?.name = $0 })
    }
    private var unit: Binding<String?> {
        Binding(get: { model.productForm?.unit }, set: { model.productForm?.unit = $0 })
    }
    private var costText: Binding<String> {
        Binding(get: { model.productForm?.costText ?? "" },
                set: { model.productForm?.costText = $0 })
    }
    private var isService: Binding<Bool> {
        Binding(get: { model.productForm?.isService ?? false },
                set: { model.productForm?.isService = $0 })
    }
}
