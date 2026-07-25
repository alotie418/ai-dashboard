import SwiftUI
import SoloLedgerCore

struct TransactionEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let existing: Transaction?

    @State private var type: TransactionType = .expense
    @State private var date = Date()
    @State private var amount: Double = 0
    @State private var currency = "CNY"
    @State private var categoryID: String?
    @State private var counterparty = ""
    @State private var paymentStatus: PaymentStatus = .paid
    @State private var invoiceStatus: InvoiceStatus = .na
    @State private var note = ""
    @State private var taxAmount: Double = 0
    @State private var taxRate: Double = 0
    @State private var invoiceNo = ""
    @State private var amountNet: Double?
    @State private var paidAmount: Double?
    @State private var paymentDate: Date?
    @State private var dueDate: Date?
    @State private var initialPaymentDate: Date?
    @State private var initialDueDate: Date?
    @State private var didInit = false

    private var isNew: Bool { existing == nil }

    var body: some View {
        VStack(spacing: 0) {
            Text(isNew ? model.t("editor.titleNew") : model.t("editor.titleEdit"))
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 8)

            Form {
                Picker(model.t("editor.type"), selection: $type) {
                    ForEach(TransactionType.allCases) { t in
                        Text(model.t("type.\(t.rawValue)")).tag(t)
                    }
                }
                .pickerStyle(.segmented)

                DatePicker(model.t("editor.date"), selection: $date, displayedComponents: .date)

                TextField(model.t("editor.amount"), value: $amount, format: .number)
                    .multilineTextAlignment(.trailing)

                TextField(model.t("editor.currency"), text: $currency)

                Picker(model.t("editor.category"), selection: $categoryID) {
                    Text(model.t("editor.uncategorized")).tag(String?.none)
                    ForEach(model.categories(for: type)) { category in
                        Text(model.categoryLabel(category)).tag(Optional(category.id))
                    }
                }

                TextField(model.t("editor.counterparty"), text: $counterparty)

                Picker(model.t("editor.payment"), selection: $paymentStatus) {
                    ForEach(PaymentStatus.allCases) { s in
                        Text(model.t("payment.\(s.rawValue)")).tag(s)
                    }
                }

                TextField(model.t("editor.note"), text: $note, axis: .vertical)
                    .lineLimit(2...4)

                // Optional factual inputs the schema already carries (mirrors
                // transactions.js normalize): recorded verbatim, never derived
                // from amount/status. Empty dates/amount_net persist NULL; an
                // empty paid amount persists Electron's normalize default of 0.
                Section(model.t("editor.paymentSection")) {
                    TextField(model.t("editor.paidAmount"), value: $paidAmount, format: .number)
                        .multilineTextAlignment(.trailing)
                    OptionalDateRow(label: model.t("editor.paymentDate"), date: $paymentDate,
                                    unparsedValue: OptionalDateEdit.unparsedFallback(original: existing?.paymentDate, initial: initialPaymentDate, current: paymentDate))
                    OptionalDateRow(label: model.t("editor.dueDate"), date: $dueDate,
                                    unparsedValue: OptionalDateEdit.unparsedFallback(original: existing?.dueDate, initial: initialDueDate, current: dueDate))
                }

                Section(model.t("editor.moreSection")) {
                    Picker(model.t("editor.invoice"), selection: $invoiceStatus) {
                        ForEach(InvoiceStatus.allCases) { s in
                            Text(model.t("invoice.\(invoiceKey(s))")).tag(s)
                        }
                    }
                    TextField(model.t("editor.invoiceNo"), text: $invoiceNo)
                    TextField(model.t("editor.amountNet"), value: $amountNet, format: .number)
                        .multilineTextAlignment(.trailing)
                    TextField(model.t("editor.taxAmount"), value: $taxAmount, format: .number)
                        .multilineTextAlignment(.trailing)
                    TextField(model.t("editor.taxRate"), value: $taxRate, format: .number)
                        .multilineTextAlignment(.trailing)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(model.t("common.cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(model.t("common.save")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!amount.isFinite)
            }
            .padding(16)
        }
        .frame(width: 460, height: 640)
        .onChange(of: type) { _ in reconcileCategory() }
        .onAppear(perform: initializeIfNeeded)
    }

    private func invoiceKey(_ s: InvoiceStatus) -> String {
        switch s {
        case .issued: return "issued"
        case .pending: return "pending"
        case .na: return "na"
        }
    }

    private func initializeIfNeeded() {
        guard !didInit else { return }
        didInit = true
        if let t = existing {
            type = t.type
            date = DateFormat.date(from: t.date) ?? Date()
            amount = t.amount
            currency = t.currency
            categoryID = t.categoryID
            counterparty = t.counterparty
            paymentStatus = t.paymentStatus
            invoiceStatus = t.invoiceStatus
            note = t.description
            taxAmount = t.taxAmount
            taxRate = t.taxRate
            invoiceNo = t.invoiceNo
            amountNet = t.amountNet
            paidAmount = t.paidAmount == 0 ? nil : t.paidAmount
            paymentDate = t.paymentDate.flatMap { DateFormat.date(from: $0) }
            dueDate = t.dueDate.flatMap { DateFormat.date(from: $0) }
            initialPaymentDate = paymentDate
            initialDueDate = dueDate
        } else {
            currency = model.defaultCurrency
            reconcileCategory()
        }
    }

    /// Keep the selected category consistent with the chosen type.
    private func reconcileCategory() {
        let options = model.categories(for: type)
        if let categoryID, options.contains(where: { $0.id == categoryID }) { return }
        categoryID = options.first?.id
    }

    private func save() {
        var t = existing ?? Transaction()
        t.type = type
        t.date = DateFormat.string(from: date)
        t.amount = amount
        t.currency = currency
        t.categoryID = categoryID
        t.counterparty = counterparty
        t.paymentStatus = paymentStatus
        t.invoiceStatus = invoiceStatus
        t.description = note
        t.taxAmount = taxAmount
        t.taxRate = taxRate
        t.invoiceNo = invoiceNo
        t.amountNet = amountNet
        t.paidAmount = paidAmount ?? 0
        t.paymentDate = OptionalDateEdit.persisted(original: existing?.paymentDate, initial: initialPaymentDate, edited: paymentDate)
        t.dueDate = OptionalDateEdit.persisted(original: existing?.dueDate, initial: initialDueDate, edited: dueDate)
        model.save(t, isNew: isNew)
        dismiss()
    }
}

/// A nullable date row: the checkbox records whether the date exists at all —
/// unchecked persists NULL (an unrecorded fact), never a default date. When the
/// stored value exists but is unparseable, it is shown verbatim instead of a
/// picker so the recorded fact never disappears from view.
private struct OptionalDateRow: View {
    let label: String
    @Binding var date: Date?
    var unparsedValue: String? = nil

    var body: some View {
        HStack {
            Toggle(label, isOn: Binding(
                get: { date != nil },
                set: { on in date = on ? (date ?? Date()) : nil }
            ))
            .toggleStyle(.checkbox)
            Spacer()
            if date != nil {
                // Manual binding (no force-unwrap): a stale end-editing commit
                // arriving after the checkbox cleared the date is dropped
                // instead of crashing or resurrecting the value.
                DatePicker("", selection: Binding(
                    get: { date ?? Date() },
                    set: { newValue in if date != nil { date = newValue } }
                ), displayedComponents: .date)
                .labelsHidden()
            } else if let unparsedValue {
                Text(unparsedValue)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(unparsedValue)
            }
        }
    }
}
