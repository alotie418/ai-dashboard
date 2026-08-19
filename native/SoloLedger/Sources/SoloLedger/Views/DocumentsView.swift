import SwiftUI
import SoloLedgerCore

/// The business-documents page — quotations, sales orders, proforma and commercial invoices, and
/// statements of account.
///
/// **Not reachable.** There is no sidebar section for it, no branch in the detail switch and no
/// construction site anywhere in this target; it is compiled, tested and unreachable, exactly as the
/// inventory page was between N-PR-4 and N-PR-6. `DocumentMountingTests` pins all three zeroes, and
/// the entry point is D-6's.
///
/// Every key drawn below comes from ``DocumentPageComposition``: each subview takes its slice of
/// that value and renders exactly what the slice names. There is not one document copy literal in
/// this file, which is what lets a test prove what the page can and cannot say.
///
/// The accessibility identifiers use a `documentsPage.` prefix rather than the copy namespace. The
/// products page can get away with `products.` because its namespace is the singular `product.`;
/// this page has no such luck, and a `documents.`-prefixed identifier would be indistinguishable
/// from a copy key to the scan that keeps this file literal-free. The page's own action buttons
/// carry their copy key as the identifier instead — a variable, not a literal — which is the
/// convention the products, inventory and report pages already share.
struct DocumentsView: View {
    @EnvironmentObject var model: AppModel

    private var page: DocumentPageComposition.Page {
        DocumentPageComposition.compose(model.documentInput)
    }

    var body: some View {
        let page = self.page
        VStack(alignment: .leading, spacing: 16) {
            DocumentsPageHeader(page: page)
            if let block = page.error {
                DocumentsErrorBanner(block: block)
            }
            DocumentsFilterBar(block: page.filter)
            list(page)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(model.t(page.titleKey))
        // Lazy on purpose: the list is read when this page appears and never as part of the
        // app-wide refresh, so a session that never opens it pays no query for it.
        .task { model.reloadDocuments() }
        .sheet(isPresented: Binding(
            get: { page.editor != nil },
            set: { if !$0 { model.cancelDocumentEditor() } }
        )) {
            if let block = page.editor { DocumentEditorSheet(block: block, error: page.error) }
        }
        .sheet(isPresented: Binding(
            get: { page.taxInvoice != nil },
            set: { if !$0 { model.cancelTaxInvoice() } }
        )) {
            if let block = page.taxInvoice { TaxInvoiceSheet(block: block, error: page.error) }
        }
        .confirmationDialog(title(page.voidConfirm), isPresented: Binding(
            get: { page.voidConfirm != nil },
            set: { if !$0 { model.cancelDocumentVoid() } }
        ), titleVisibility: .visible) {
            if let block = page.voidConfirm {
                Button(model.t(block.confirmActionKey), role: .destructive) {
                    model.confirmDocumentVoid()
                }
                Button(model.t(block.cancelActionKey), role: .cancel) { model.cancelDocumentVoid() }
            }
        } message: {
            if let block = page.voidConfirm { Text(model.t(block.messageKey)) }
        }
        .confirmationDialog(title(page.deleteConfirm), isPresented: Binding(
            get: { page.deleteConfirm != nil },
            set: { if !$0 { model.cancelDocumentDelete() } }
        ), titleVisibility: .visible) {
            if let block = page.deleteConfirm {
                Button(model.t(block.confirmActionKey), role: .destructive) {
                    model.confirmDocumentDelete()
                }
                Button(model.t(block.cancelActionKey), role: .cancel) { model.cancelDocumentDelete() }
            }
        } message: {
            if let block = page.deleteConfirm { Text(model.t(block.messageKey)) }
        }
    }

    @ViewBuilder private func list(_ page: DocumentPageComposition.Page) -> some View {
        if let block = page.list {
            DocumentsTable(block: block)
        } else if let emptyKey = page.emptyKeys.first {
            EmptyStateView(systemImage: "doc.text",
                           title: model.t(emptyKey),
                           message: "")
        }
    }

    private func title(_ block: DocumentPageComposition.ConfirmBlock?) -> String {
        guard let block else { return "" }
        return model.t(block.titleKey)
    }
}

// MARK: - Header

private struct DocumentsPageHeader: View {
    @EnvironmentObject var model: AppModel
    let page: DocumentPageComposition.Page

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(page.headerKeys, id: \.self) { key in
                    Text(model.t(key))
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            Spacer(minLength: 16)
            ForEach(page.actionKeys, id: \.self) { key in
                Button(model.t(key)) { model.newDocument() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.documentWriteIsPending)
                    .accessibilityIdentifier(key)
            }
        }
    }
}

// MARK: - The refusal

/// One of fifteen sentences, and never anything else.
///
/// The store's twelve refusals arrive as enum cases; the only one with a payload carries two
/// closed-set statuses, and both are resolved to their own copy keys here rather than printed. So a
/// SQLite message, a file path or a raw status word cannot reach this banner.
private struct DocumentsErrorBanner: View {
    @EnvironmentObject var model: AppModel
    let block: DocumentPageComposition.ErrorBlock

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            Text(model.t(block.messageKey, block.keyReplacements.mapValues { model.t($0) }))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button { model.dismissDocumentError() } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityIdentifier("documentsPage.errorBanner")
    }
}

// MARK: - The type filter

/// Six pills, the first of which is "all". The filter is applied by the QUERY, not by the view —
/// picking one re-reads the list, exactly as the other app does.
private struct DocumentsFilterBar: View {
    @EnvironmentObject var model: AppModel
    let block: DocumentPageComposition.FilterBlock

    var body: some View {
        HStack(spacing: 8) {
            ForEach(block.options) { option in
                Button(model.t(option.labelKey)) { model.setDocumentFilter(option.filter) }
                    .buttonStyle(.borderless)
                    .fontWeight(option.filter == block.selected ? .semibold : .regular)
                    .foregroundStyle(option.filter == block.selected ? Color.accentColor : .secondary)
            }
        }
        .accessibilityIdentifier("documentsPage.filter")
    }
}

// MARK: - The list

/// ## Why the cells below take plain values
///
/// `Table` materialises its cell views again, outside the render pass, when an accessibility client
/// walks the page, and in that context the environment is not attached — an `@EnvironmentObject`
/// lookup traps there. So the model is read HERE, once, while the environment is guaranteed, and
/// the cells receive resolved text and intent closures. `DocumentMountingTests` keeps the rule as a
/// source guard, with the enclosing container as its own counter-example.
private struct DocumentsTable: View {
    @EnvironmentObject var model: AppModel
    let block: DocumentPageComposition.ListBlock

    var body: some View {
        Table(block.rows) {
            TableColumn(model.t(block.numberHeaderKey)) { row in
                DocumentTextCell(text: row.document.number, isMonospaced: true)
            }
            .width(min: 110, ideal: 140)

            TableColumn(model.t(block.typeHeaderKey)) { row in
                DocumentTextCell(text: model.t(row.typeKey), isSecondary: true)
            }
            .width(min: 92, ideal: 120)

            TableColumn(model.t(block.dateHeaderKey)) { row in
                DocumentDateCell(date: row.document.date, period: row.period)
            }
            .width(min: 96, ideal: 128)

            TableColumn(model.t(block.customerHeaderKey)) { row in
                DocumentTextCell(text: row.document.customerName)
            }

            TableColumn(model.t(block.totalHeaderKey)) { row in
                DocumentAmountCell(text: money(row))
            }
            .width(min: 96, ideal: 128)

            TableColumn(model.t(block.statusHeaderKey)) { row in
                DocumentTextCell(text: model.t(row.statusKey), isSecondary: true)
            }
            .width(min: 72, ideal: 92)

            TableColumn(model.t(block.taxInvoiceHeaderKey)) { row in
                DocumentTaxInvoiceCell(label: model.t(row.taxInvoice.labelKey),
                                       isRecorded: row.taxInvoice.isRecorded,
                                       hasAttachment: row.taxInvoice.hasAttachment)
            }
            .width(min: 92, ideal: 116)

            // The other app's list has an unlabelled action column, and so does this one.
            TableColumn("") { row in
                DocumentRowActions(actions: row.actions.map {
                    DocumentRowActions.Item(id: $0.id,
                                            label: model.t($0.labelKey),
                                            isDestructive: $0.isDestructive)
                },
                                   isDisabled: model.documentWriteIsPending,
                                   perform: { id in model.performDocumentRowAction(id, on: row.document) })
            }
            .width(min: 220, ideal: 280)
        }
        .accessibilityIdentifier("documentsPage.table")
    }

    /// `nil` from the composition draws the em dash: a header total the ledger never recorded is
    /// not a zero somebody chose.
    private func money(_ row: DocumentPageComposition.RowBlock) -> String? {
        DocumentPageComposition.money(row.document.total, style: row.style,
                                      locale: Locale.autoupdatingCurrent)
    }
}

private struct DocumentTextCell: View {
    let text: String
    var isMonospaced: Bool = false
    var isSecondary: Bool = false

    var body: some View {
        Text(text)
            .monospaced(isMonospaced)
            .foregroundStyle(isSecondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
    }
}

/// The date, with a statement's period underneath it — the other app's own two-line cell, and only
/// for a statement that records both ends.
private struct DocumentDateCell: View {
    let date: String
    let period: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(date).monospacedDigit()
            if let period {
                Text(period).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

private struct DocumentAmountCell: View {
    /// `nil` draws the em dash.
    let text: String?

    var body: some View {
        Group {
            if let text {
                Text(text).monospacedDigit()
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Two states and a paperclip that is independent of them: whether an invoice was recorded, and
/// whether a copy of it is attached. Four combinations, all reachable.
private struct DocumentTaxInvoiceCell: View {
    let label: String
    let isRecorded: Bool
    let hasAttachment: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .fontWeight(isRecorded ? .semibold : .regular)
                .foregroundStyle(isRecorded ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            if hasAttachment {
                Image(systemName: "paperclip").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct DocumentRowActions: View {
    struct Item: Identifiable {
        let id: String
        let label: String
        let isDestructive: Bool
    }

    let actions: [Item]
    let isDisabled: Bool
    let perform: (String) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(actions) { action in
                Button(action.label, role: action.isDestructive ? .destructive : nil) {
                    perform(action.id)
                }
            }
        }
        .buttonStyle(.link)
        .disabled(isDisabled)
    }
}

// MARK: - The editor

/// New and edit, in one sheet.
///
/// Its body has three shapes and the type decides which: a statement being CREATED shows the
/// generator, a statement being EDITED shows its lines read-only, and the other four types show the
/// editable line table. That is ruling ① expressed as structure — there is no arrangement of this
/// view in which a statement's lines can be typed into and sent.
private struct DocumentEditorSheet: View {
    @EnvironmentObject var model: AppModel
    let block: DocumentPageComposition.EditorBlock
    /// The page's refusal, drawn again HERE while the sheet is open.
    ///
    /// The page's own banner is behind the sheet, so a save the ledger refused would leave the user
    /// looking at an unchanged form with the reason hidden underneath it. The other app puts the
    /// same sentence at the top of its modal for the same reason. Found by walking the page, not by
    /// reading it.
    let error: DocumentPageComposition.ErrorBlock?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.t(block.titleKey))
                .font(.headline)
                .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 12)
            if let error {
                DocumentsErrorBanner(block: error)
                    .padding(.horizontal, 20).padding(.bottom, 10)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    typeControl
                    fields
                    body(for: block.body)
                    if let notes = block.notesField {
                        DocumentFieldRow(block: notes, isMultiline: true)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            Divider()
            HStack {
                Spacer()
                Button(model.t(block.cancelActionKey)) { model.cancelDocumentEditor() }
                if let saveKey = block.saveActionKey {
                    Button(model.t(saveKey)) { model.saveDocumentEditor() }
                        .buttonStyle(.borderedProminent)
                        // The other app's form refuses the submit outright when a control's own
                        // `min` / `max` / `step` or a date's shape is violated. No sentence is
                        // invented to explain it: the explanation over there comes from the
                        // browser, not from this app's copy.
                        .disabled(!block.canSubmit)
                }
            }
            .padding(16)
        }
        .frame(width: 760, height: 620)
        .accessibilityIdentifier("documentsPage.editor")
    }

    private var typeControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.t(block.typeLabelKey)).font(.caption).foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { model.documentEditorType },
                set: { model.setDocumentEditorType($0) }
            )) {
                ForEach(block.typeOptions) { option in
                    Text(model.t(option.labelKey)).tag(option.type)
                }
            }
            .labelsHidden()
            // The other app locks the control once the document exists, though its own handler
            // would accept the change. Mirrored on the tighter side.
            .disabled(block.typeIsLocked)
            .accessibilityIdentifier("documentsPage.editor.type")
        }
    }

    private var fields: some View {
        ForEach(block.fields) { field in
            DocumentFieldRow(block: field, isMultiline: false)
        }
    }

    @ViewBuilder private func body(
        for body: DocumentPageComposition.EditorBody) -> some View {
        switch body {
        case .lines(let lineBlock):
            DocumentLineEditor(block: lineBlock)
        case .readOnlyLines(let displayBlock):
            DocumentLineDisplay(block: displayBlock)
        case .generator(let statementBlock):
            DocumentStatementPanel(block: statementBlock)
        }
    }
}

/// One header field. The label, an optional hint under it, and a control bound by ``EditorField``
/// so this view never has to know a column name.
private struct DocumentFieldRow: View {
    @EnvironmentObject var model: AppModel
    let block: DocumentPageComposition.FieldBlock
    let isMultiline: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.t(block.labelKey)).font(.caption).foregroundStyle(.secondary)
            if isMultiline {
                TextEditor(text: text)
                    .frame(height: 56)
                    .border(.quaternary)
                    .accessibilityIdentifier("documentsPage.editor.\(block.field.rawValue)")
            } else {
                TextField(placeholder, text: text)
                    .accessibilityIdentifier("documentsPage.editor.\(block.field.rawValue)")
            }
            if let hintKey = block.hintKey {
                Text(model.t(hintKey)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var placeholder: String {
        block.placeholderKey.map { model.t($0) } ?? ""
    }

    private var text: Binding<String> {
        Binding(get: { model.documentEditorField(block.field) },
                set: { model.setDocumentEditorField(block.field, to: $0) })
    }
}

// MARK: - The editable line table

/// A stack of cards rather than a grid, which is the other app's own arrangement: each line owns a
/// product control, a description, four numbers and its two running figures.
private struct DocumentLineEditor: View {
    @EnvironmentObject var model: AppModel
    let block: DocumentPageComposition.LineEditorBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.t(block.headers.titleKey)).font(.headline)
            ForEach(block.lines) { line in
                DocumentLineCard(block: block, line: line)
            }
            Button(model.t(block.addActionKey)) { model.addDocumentLine() }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("documentsPage.editor.addLine")
            DocumentTotalsRow(block: block.totals)
        }
    }
}

private struct DocumentLineCard: View {
    @EnvironmentObject var model: AppModel
    let block: DocumentPageComposition.LineEditorBlock
    let line: DocumentPageComposition.LineBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Picker("", selection: Binding(
                    get: { line.productID },
                    set: { model.pickDocumentProduct(lineID: line.id, productID: $0) }
                )) {
                    Text("").tag("")
                    ForEach(block.productOptions) { product in
                        Text(product.name).tag(product.id)
                    }
                }
                .labelsHidden()
                Spacer(minLength: 8)
                if model.documentEditorCanRemoveLines {
                    Button(model.t(block.removeActionKey), role: .destructive) {
                        model.removeDocumentLine(id: line.id)
                    }
                    .buttonStyle(.link)
                }
            }
            field(block.headers.descriptionKey) {
                TextField("", text: binding(.description))
            }
            HStack(alignment: .top, spacing: 12) {
                field(block.headers.quantityKey) { TextField("", text: binding(.quantity)) }
                field(block.headers.unitKey) {
                    Picker("", selection: binding(.unit)) {
                        ForEach(line.unitOptions) { option in
                            unitLabel(option).tag(option.rawValue)
                        }
                    }
                    .labelsHidden()
                }
                field(block.headers.unitPriceKey) { TextField("", text: binding(.unitPrice)) }
                field(block.headers.taxRateKey) { TextField("", text: binding(.taxRatePercent)) }
            }
            HStack(spacing: 16) {
                Spacer()
                runningFigure(block.headers.amountKey, value: line.amount)
                runningFigure(block.headers.taxAmountKey, value: line.taxAmount)
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private func unitLabel(
        _ option: DocumentPageComposition.UnitOption) -> some View {
        if let key = option.labelKey {
            Text(model.t(key))
        } else {
            Text(option.verbatim ?? "")
        }
    }

    private func runningFigure(_ labelKey: String, value: Double) -> some View {
        HStack(spacing: 4) {
            Text(model.t(labelKey)).font(.caption).foregroundStyle(.secondary)
            Text(model.documentMoney(value) ?? "—").font(.caption).monospacedDigit()
        }
    }

    private func field<Content: View>(_ labelKey: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.t(labelKey)).font(.caption).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func binding(_ field: DocumentPageComposition.LineField) -> Binding<String> {
        Binding(get: { model.documentLineValue(id: line.id, field) },
                set: { model.setDocumentLineValue(id: line.id, field, to: $0) })
    }
}

// MARK: - The read-only line table

/// A generated statement's lines, shown and never sent.
///
/// The dash note under it says what a dash means, because dashes are the normal case here: a period
/// summary records no quantity, no unit, no unit price and no rate, and a source transaction that
/// recorded no tax keeps its `NULL` rather than becoming a zero nobody entered.
private struct DocumentLineDisplay: View {
    @EnvironmentObject var model: AppModel
    let block: DocumentPageComposition.LineDisplayBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.t(block.headers.titleKey)).font(.headline)
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                ForEach(block.lines) { line in
                    row(line)
                    Divider()
                }
            }
            .accessibilityIdentifier("documentsPage.editor.storedLines")
            Text(model.t(block.dashNoteKey))
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DocumentTotalsRow(block: block.totals)
        }
    }

    /// Q2-b's four columns, and only four. The date is its OWN column here — the other app glues it
    /// to the front of the description, and this chapter deliberately does not.
    private var header: some View {
        HStack(spacing: 10) {
            cell(model.t(block.headers.descriptionKey), isWide: true, alignment: .leading)
            cell(model.t(block.headers.dateKey), isWide: false, alignment: .leading)
            cell(model.t(block.headers.taxAmountKey), isWide: false, alignment: .trailing)
            cell(model.t(block.headers.amountKey), isWide: false, alignment: .trailing)
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.vertical, 4)
    }

    private func row(_ line: DocumentPageComposition.DisplayLineBlock) -> some View {
        HStack(spacing: 10) {
            cell(line.description, isWide: true, alignment: .leading)
            cell(line.date ?? "—", isWide: false, alignment: .leading)
            cell(money(line.taxAmount), isWide: false, alignment: .trailing)
            cell(money(line.amount), isWide: false, alignment: .trailing)
        }
        .font(.callout)
        .padding(.vertical, 4)
    }

    private func money(_ value: Double?) -> String {
        model.documentMoney(value) ?? "—"
    }

    /// The description column takes what is left; the six figures take a fixed, equal width.
    ///
    /// Fixed MINIMUM widths were the first spelling and they were wrong: seven of them plus their
    /// spacing exceed the sheet, and SwiftUI resolves that by pushing the whole sheet's content
    /// sideways — the field labels above the table slid out of view. Measured on screen, not
    /// reasoned about.
    private func cell(_ text: String, isWide: Bool, alignment: Alignment) -> some View {
        Text(text)
            .frame(maxWidth: isWide ? .infinity : 96, alignment: alignment)
            .fixedSize(horizontal: false, vertical: true)
            .lineLimit(2)
    }
}

// MARK: - The three footer amounts

private struct DocumentTotalsRow: View {
    @EnvironmentObject var model: AppModel
    let block: DocumentPageComposition.TotalsBlock

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            row(block.subtotalLabelKey, value: block.subtotal, isTotal: false)
            row(block.taxLabelKey, value: block.taxAmount, isTotal: false)
            row(block.totalLabelKey, value: block.total, isTotal: true)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityIdentifier("documentsPage.editor.totals")
    }

    private func row(_ labelKey: String, value: Double?, isTotal: Bool) -> some View {
        HStack(spacing: 12) {
            Text(model.t(labelKey)).foregroundStyle(.secondary)
            Text(text(value)).monospacedDigit()
                .fontWeight(isTotal ? .bold : .regular)
        }
        .font(isTotal ? .body : .callout)
    }

    private func text(_ value: Double?) -> String {
        DocumentPageComposition.money(value, style: block.style,
                                      locale: Locale.autoupdatingCurrent) ?? "—"
    }
}

// MARK: - The statement generator

/// How a statement comes into being.
///
/// The two standing notes are not decoration. One says what a native statement IS — a period
/// summary of one customer's income transactions, not an itemised invoice and not a tax document.
/// The other says what pressing the button does when the period holds more than one currency: one
/// document per currency, and that many numbers used in a row.
private struct DocumentStatementPanel: View {
    @EnvironmentObject var model: AppModel
    let block: DocumentPageComposition.StatementBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(block.noteKeys, id: \.self) { key in
                Text(model.t(key))
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .bottom, spacing: 12) {
                field(block.customerLabelKey) {
                    Picker("", selection: Binding(
                        get: { model.documentEditor?.statementCustomer ?? "" },
                        set: { model.setStatementCustomer($0) }
                    )) {
                        Text("").tag("")
                        ForEach(block.customers, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .accessibilityIdentifier("documentsPage.editor.statementCustomer")
                }
                field(block.periodStartLabelKey) {
                    TextField("", text: Binding(
                        get: { model.documentEditor?.statementPeriodStart ?? "" },
                        set: { model.setStatementPeriodStart($0) }
                    ))
                    .accessibilityIdentifier("documentsPage.editor.statementStart")
                }
                field(block.periodEndLabelKey) {
                    TextField("", text: Binding(
                        get: { model.documentEditor?.statementPeriodEnd ?? "" },
                        set: { model.setStatementPeriodEnd($0) }
                    ))
                    .accessibilityIdentifier("documentsPage.editor.statementEnd")
                }
                Button(model.t(block.generateActionKey)) { model.generateStatements() }
                    .buttonStyle(.borderedProminent)
                    // This button is the write, so it carries the submit's refusal: a document
                    // date the other app's control could not have produced blocks it, with no
                    // invented sentence. The period bounds are refused with a sentence instead —
                    // "not filled in" is true of them, and it is what the panel already says.
                    .disabled(!block.canGenerate)
                    .accessibilityIdentifier("documentsPage.editor.generate")
            }
            if let messageKey = block.messageKey {
                Text(model.t(messageKey))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func field<Content: View>(_ labelKey: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.t(labelKey)).font(.caption).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - The formal-invoice association

/// Records an invoice somebody ELSE issued. It never issues one and it never invents a number — the
/// compliance line at the top says exactly that, and the number field's hint says it again.
private struct TaxInvoiceSheet: View {
    @EnvironmentObject var model: AppModel
    let block: DocumentPageComposition.TaxInvoiceBlock
    /// Same reason as the editor's: the page's banner is behind this sheet.
    let error: DocumentPageComposition.ErrorBlock?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.t(block.titleKey)).font(.headline)
                Text(block.documentNumber).font(.caption).monospaced().foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 12)
            if let error {
                DocumentsErrorBanner(block: error)
                    .padding(.horizontal, 20).padding(.bottom, 10)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(model.t(block.complianceKey))
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let noticeKey = block.readOnlyNoticeKey {
                        Text(model.t(noticeKey))
                            .font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("documentsPage.taxInvoice.readOnly")
                    }
                    Toggle(model.t(block.issuedLabelKey), isOn: Binding(
                        get: { model.taxInvoiceDraft?.issued ?? false },
                        set: { model.setTaxInvoiceIssued($0) }
                    ))
                    .disabled(block.saveActionKey == nil)
                    .accessibilityIdentifier("documentsPage.taxInvoice.issued")

                    field(block.numberLabelKey, hintKey: block.numberHintKey) {
                        TextField("", text: Binding(
                            get: { model.taxInvoiceDraft?.number ?? "" },
                            set: { model.setTaxInvoiceNumber($0) }
                        ))
                        .disabled(block.saveActionKey == nil)
                        .accessibilityIdentifier("documentsPage.taxInvoice.number")
                    }
                    field(block.dateLabelKey, hintKey: nil) {
                        TextField("", text: Binding(
                            get: { model.taxInvoiceDraft?.date ?? "" },
                            set: { model.setTaxInvoiceDate($0) }
                        ))
                        .disabled(block.saveActionKey == nil)
                        .accessibilityIdentifier("documentsPage.taxInvoice.date")
                    }
                    field(block.attachmentLabelKey, hintKey: nil) {
                        TaxInvoiceAttachment(block: block.attachment)
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 16)
            }

            Divider()
            HStack {
                Spacer()
                Button(model.t(block.cancelActionKey)) { model.cancelTaxInvoice() }
                if let saveKey = block.saveActionKey {
                    Button(model.t(saveKey)) { model.saveTaxInvoice() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!block.canSubmit)
                }
            }
            .padding(16)
        }
        .frame(width: 560, height: 520)
        .accessibilityIdentifier("documentsPage.taxInvoice")
    }

    private func field<Content: View>(_ labelKey: String,
                                      hintKey: String?,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.t(labelKey)).font(.caption).foregroundStyle(.secondary)
            content()
            if let hintKey {
                Text(model.t(hintKey))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Pick a file, open it, or drop the reference.
///
/// **Dropping the reference does not delete the copy** — ruling ③. The file stays in the
/// attachments directory until the round that owns deleting it connects that seam; until then a
/// replaced or cleared attachment leaves a copy behind, which is registered rather than hidden.
private struct TaxInvoiceAttachment: View {
    @EnvironmentObject var model: AppModel
    let block: DocumentPageComposition.AttachmentBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let fileName = block.fileName {
                HStack(spacing: 8) {
                    Image(systemName: "paperclip").foregroundStyle(.secondary)
                    Text(fileName).font(.callout).lineLimit(2)
                    Spacer(minLength: 8)
                    Button(model.t(block.openActionKey)) { model.openTaxInvoiceAttachment() }
                        .buttonStyle(.link)
                    if block.canRemove {
                        Button(model.t(block.removeActionKey), role: .destructive) {
                            model.removeTaxInvoiceAttachment()
                        }
                        .buttonStyle(.link)
                    }
                }
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            } else if block.canPick {
                Button(model.t(block.pickActionKey)) { model.pickTaxInvoiceAttachment() }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
            }
            if let messageKey = block.messageKey {
                Text(model.t(messageKey))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("documentsPage.taxInvoice.attachment")
    }
}
