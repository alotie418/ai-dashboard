import Foundation
import SoloLedgerCore

/// What the products page draws, region by region, as a value a test can hold.
///
/// ## Why this exists
///
/// The same reason `ReportPageComposition` and `LegacyConversionComposition` do: the claims
/// that matter here — that all forty-one adjudicated strings have a render that uses them, that a
/// refusal reaches the screen as one of seven sentences and never as the driver's own words,
/// that the "records that could not be read" notice appears on exactly the ledgers that have
/// such records — have to be provable without driving the UI, and XCUITest cannot run in a
/// headless session.
///
/// So the view has no other source of keys. Each subview is handed its slice of these values
/// and renders exactly what the slice names; a key that is not composed cannot reach the
/// screen. `ProductsView.swift` therefore contains no `product.*` string literal at all.
///
/// ## One difference from the two earlier compositions, and why
///
/// Their `placement` is `[String: Region]` — one key, one place. This page cannot be described
/// that way, and it is a fact about the page rather than a looseness here: `product.col.name`,
/// `product.col.unit` and `product.col.cost` label a table column AND the matching form field,
/// and the eleven `product.unit.*` labels appear both in a row's unit cell and in the form's
/// unit picker. Forcing one region per key would either lose half of those placements or need
/// fourteen new keys. The map is therefore `[String: Set<Region>]`, and everything that reads
/// it — the closure test, the region-coverage test, the same-slot ambiguity test — reads a set.
///
/// `ProductsView` is constructed once, by the detail switch: 2b-A4 gave the page its
/// `SidebarSection` case and its `RootView` branch — one enum case serving both the sidebar list
/// and the menu-bar picker — and `ProductMountingTests` pins that single construction site.
/// Until it existed the page shipped compiled, tested and unreachable, which is why every
/// intermediate `main` shipped the product unchanged.
enum ProductPageComposition {

    // MARK: - Regions

    /// Where on the page a key is drawn.
    enum Region: String, CaseIterable, Equatable {
        /// Page subtitle. The title is drawn by the window's navigation title.
        case header
        /// The standing declaration that the default unit price is recorded and not computed with.
        case note
        /// The one control that opens the new-item form.
        case action
        /// The single sentence a refused write leaves behind.
        case errorBanner
        /// The five column headings.
        case listHeader
        case typeCell
        case statusCell
        case unitCell
        /// The inline new/edit panel.
        case form
        /// The eleven options inside that panel's unit control.
        case unitPicker
        /// Per-row edit / delete controls. Reached only by ``sharedKeys``.
        case rowAction
        case deleteDialog
        case empty
        case unreadable
    }

    // MARK: - Placement

    /// Every `product.*` key this page can draw, and the regions it belongs to.
    ///
    /// Total over the `product.*` namespace by construction, and asserted to be — the forty
    /// keys 2b-A2 landed, no more and no fewer. There are no exemptions: two of the six error
    /// sentences (`invalidID`, `idCollision`) describe refusals this page's own controls cannot
    /// provoke, but they are placed all the same, because the mapping below is exhaustive over
    /// `ProductCatalogError` and a case with nowhere to land would be a raw enum on screen.
    static let placement: [String: Set<Region>] = [
        // MARK: header (2)
        "product.page.title": [.header],
        "product.page.subtitle": [.header],
        // MARK: note (1)
        "product.page.note": [.note],
        // MARK: listHeader + form field labels (5)
        "product.col.name": [.listHeader, .form],
        "product.col.unit": [.listHeader, .form],
        "product.col.cost": [.listHeader, .form],
        "product.col.type": [.listHeader],
        "product.col.status": [.listHeader],
        // MARK: typeCell (2)
        "product.type.product": [.typeCell],
        "product.type.service": [.typeCell],
        // MARK: statusCell (2)
        "product.status.active": [.statusCell],
        "product.status.inactive": [.statusCell],
        // MARK: unitCell + unitPicker (11)
        "product.unit.piece": [.unitCell, .unitPicker],
        "product.unit.box": [.unitCell, .unitPicker],
        "product.unit.bag": [.unitCell, .unitPicker],
        "product.unit.kg": [.unitCell, .unitPicker],
        "product.unit.ton": [.unitCell, .unitPicker],
        "product.unit.liter": [.unitCell, .unitPicker],
        "product.unit.bottle": [.unitCell, .unitPicker],
        "product.unit.pack": [.unitCell, .unitPicker],
        "product.unit.session": [.unitCell, .unitPicker],
        "product.unit.hour": [.unitCell, .unitPicker],
        "product.unit.month": [.unitCell, .unitPicker],
        // MARK: form (5)
        "product.form.newTitle": [.form],
        "product.form.editTitle": [.form],
        "product.form.namePlaceholder": [.form],
        "product.form.isService": [.form],
        "product.form.isServiceHint": [.form],
        // MARK: action (1)
        "product.action.add": [.action],
        // MARK: deleteDialog (2)
        "product.delete.confirmTitle": [.deleteDialog],
        "product.delete.confirmMessage": [.deleteDialog],
        // MARK: empty (2)
        "product.empty.title": [.empty],
        "product.empty.message": [.empty],
        // MARK: errorBanner (6)
        "product.error.invalidID": [.errorBanner],
        "product.error.nameRequired": [.errorBanner],
        "product.error.unitNotRecognized": [.errorBanner],
        "product.error.notFound": [.errorBanner],
        "product.error.idCollision": [.errorBanner],
        "product.error.hasInventoryMovements": [.errorBanner],
        "product.error.storageFailure": [.errorBanner],
        // MARK: unreadable (1)
        "product.unreadable.notice": [.unreadable],
    ]

    /// The keys this page borrows from the shared vocabulary, and where they land.
    ///
    /// Kept OUT of ``placement`` on purpose. That map's contract is "total over `product.*`",
    /// and the closure test compares it to the namespace as an equality in both directions;
    /// folding four `common.*` keys in would weaken that comparison into a filtered one, which
    /// is precisely the closure that must not slip.
    static let sharedKeys: [String: Set<Region>] = [
        "common.edit": [.rowAction],
        "common.delete": [.rowAction, .deleteDialog],
        "common.cancel": [.form, .deleteDialog],
        "common.save": [.form],
    ]

    /// The window title. Named here rather than written into the view, so every string the page
    /// draws is reachable from this one file.
    static let pageTitleKey = "product.page.title"

    // MARK: - Error copy

    /// The one place a `ProductCatalogError` becomes a sentence.
    ///
    /// Exhaustive with no `default`: an eighth case stops this file compiling instead of
    /// silently falling into a bucket. `ProductCatalogError` carries no payload, so there is
    /// nothing here that could print a statement, a path or the driver's own wording even by
    /// accident — the leak is impossible in the type, and this switch keeps it impossible in
    /// the copy.
    static func key(for error: ProductCatalogError) -> String {
        switch error {
        case .invalidID:          return "product.error.invalidID"
        case .nameRequired:       return "product.error.nameRequired"
        case .unitNotRecognized:  return "product.error.unitNotRecognized"
        case .notFound:           return "product.error.notFound"
        case .idCollision:        return "product.error.idCollision"
        case .hasInventoryMovements: return "product.error.hasInventoryMovements"
        case .storageFailure:     return "product.error.storageFailure"
        }
    }

    // MARK: - Cell rules

    /// How a unit reads on screen — `getProductUnitLabel` at
    /// `components/accountingHelpers.ts:212-217`, mirrored.
    ///
    /// That function returns `''` for a falsy key, the key ITSELF for one it does not know, and
    /// the label otherwise. All three arms are reachable here: the column is `NOT NULL DEFAULT
    /// 'piece'` but a migrated file can hold a BLOB (which `Product.unit` reads as `nil`) or a
    /// unit that was never on the whitelist, and the read path validates nothing on purpose.
    enum UnitDisplay: Equatable {
        /// One of the eleven — draw `product.unit.<key>`.
        case key(String)
        /// Stored text that is not one of the eleven. Drawn as it stands; inventing a label for
        /// it would be this app claiming to know a unit it does not.
        case verbatim(String)
        /// No text reading at all, or empty text. Electron draws nothing here, and so does this.
        case none
    }

    static func unit(_ stored: String?) -> UnitDisplay {
        guard let stored, !stored.isEmpty else { return .none }
        return ProductUnit(rawValue: stored) == nil ? .verbatim(stored)
                                                    : .key("product.unit.\(stored)")
    }

    /// How the default unit price reads — `ProductsSection.tsx:111`, mirrored: a positive value
    /// is shown, anything else becomes an em dash.
    ///
    /// A cell with no numeric reading was already read as `0` by the store (the column's own
    /// declared default), so a damaged value and a genuine zero are indistinguishable by the
    /// time they arrive — both land on ``dash``, exactly as they do in the other app. Infinity
    /// is reachable and is positive, so it takes the ``amount`` arm.
    enum CostDisplay: Equatable {
        case dash
        case amount(Double)
    }

    static func cost(_ value: Double) -> CostDisplay {
        value > 0 ? .amount(value) : .dash
    }

    // MARK: - The page's input

    /// Everything the composition needs, and nothing that could let it read the ledger itself.
    struct Input: Equatable {
        var catalog: ProductCatalogPage
        /// The inline new/edit panel, or `nil` when it is closed.
        var form: ProductFormDraft?
        /// The row a delete is awaiting confirmation for.
        var pendingDelete: Product?
        /// The last refused write, or `nil`.
        var error: ProductCatalogError?

        init(catalog: ProductCatalogPage = ProductCatalogPage(products: [], unreadableCount: 0),
             form: ProductFormDraft? = nil,
             pendingDelete: Product? = nil,
             error: ProductCatalogError? = nil) {
            self.catalog = catalog
            self.form = form
            self.pendingDelete = pendingDelete
            self.error = error
        }
    }

    // MARK: - One render

    struct RowBlock: Equatable, Identifiable {
        let product: Product
        let typeKey: String
        /// The row's current status, which is also the control's label.
        let statusKey: String
        /// The status the control would move it to — the accessibility hint, so the button can
        /// say what it does without a fourteenth status string.
        let toggleHintKey: String
        let unit: UnitDisplay
        let cost: CostDisplay
        /// ``sharedKeys``' two row controls.
        let editActionKey: String
        let deleteActionKey: String

        var id: String { product.id }
        var actionKeys: [String] { [editActionKey, deleteActionKey] }
        var allKeys: [String] {
            var keys = [typeKey, statusKey, toggleHintKey] + actionKeys
            if case .key(let unitKey) = unit { keys.append(unitKey) }
            return keys
        }
    }

    struct ListBlock: Equatable {
        /// The five headings in DRAW order — `ProductsSection.tsx:90-94`'s order, which is the
        /// other app's screen and not the order the copy file happens to list them in.
        let nameHeaderKey: String
        let unitHeaderKey: String
        let typeHeaderKey: String
        let costHeaderKey: String
        let statusHeaderKey: String
        let rows: [RowBlock]

        var headerKeys: [String] {
            [nameHeaderKey, unitHeaderKey, typeHeaderKey, costHeaderKey, statusHeaderKey]
        }
        var allKeys: [String] { headerKeys + rows.flatMap(\.allKeys) }
    }

    /// One option of the unit control: what would be written, and what it reads as.
    struct UnitOption: Equatable, Identifiable {
        let rawValue: String
        let labelKey: String
        var id: String { rawValue }
    }

    struct FormBlock: Equatable {
        let titleKey: String
        /// Borrowed from the column headings — the form has no field labels of its own.
        let nameLabelKey: String
        let unitLabelKey: String
        let costLabelKey: String
        let placeholderKey: String
        let serviceLabelKey: String
        let serviceHintKey: String
        /// All eleven, always: the control offers the whole whitelist whatever the row holds.
        let unitOptions: [UnitOption]
        let cancelActionKey: String
        let saveActionKey: String

        var fieldLabelKeys: [String] { [nameLabelKey, unitLabelKey, costLabelKey] }
        var actionKeys: [String] { [cancelActionKey, saveActionKey] }
        var allKeys: [String] {
            [titleKey] + fieldLabelKeys + [placeholderKey, serviceLabelKey, serviceHintKey]
                + unitOptions.map(\.labelKey) + actionKeys
        }
    }

    struct DeleteBlock: Equatable {
        let titleKey: String
        let messageKey: String
        /// The name that fills `{name}`. Carried here so the view never looks anything up.
        let productName: String
        let deleteActionKey: String
        let cancelActionKey: String

        var actionKeys: [String] { [deleteActionKey, cancelActionKey] }
        var allKeys: [String] { [titleKey, messageKey] + actionKeys }
    }

    struct Page: Equatable {
        let titleKey: String
        let headerKeys: [String]
        let noteKeys: [String]
        let actionKeys: [String]
        /// One sentence, or none.
        let errorKeys: [String]
        /// `nil` when there is no row to draw.
        let list: ListBlock?
        /// Empty whenever the list is drawn, AND whenever rows exist that could not be read —
        /// "you have no products yet" would be false on a ledger whose products are unreadable.
        let emptyKeys: [String]
        let unreadableKeys: [String]
        let unreadableCount: Int
        let form: FormBlock?
        let delete: DeleteBlock?

        var allKeys: Set<String> {
            var keys: Set<String> = [titleKey]
            keys.formUnion(headerKeys)
            keys.formUnion(noteKeys)
            keys.formUnion(actionKeys)
            keys.formUnion(errorKeys)
            keys.formUnion(list?.allKeys ?? [])
            keys.formUnion(emptyKeys)
            keys.formUnion(unreadableKeys)
            keys.formUnion(form?.allKeys ?? [])
            keys.formUnion(delete?.allKeys ?? [])
            return keys
        }
    }

    /// Compose the page for one input.
    static func compose(_ input: Input) -> Page {
        let rows = input.catalog.products.map(row(for:))
        let unreadable = input.catalog.unreadableCount
        // The empty state and the unreadable notice are mutually exclusive on an empty list.
        // A ledger whose product rows all failed to decode is not a ledger with no products,
        // and the notice's own wording ("not listed above") stays true when there is nothing
        // above it.
        let showsEmptyState = rows.isEmpty && unreadable == 0
        return Page(
            titleKey: pageTitleKey,
            headerKeys: ["product.page.subtitle"],
            noteKeys: ["product.page.note"],
            actionKeys: ["product.action.add"],
            errorKeys: input.error.map { [key(for: $0)] } ?? [],
            list: rows.isEmpty ? nil : ListBlock(nameHeaderKey: "product.col.name",
                                                 unitHeaderKey: "product.col.unit",
                                                 typeHeaderKey: "product.col.type",
                                                 costHeaderKey: "product.col.cost",
                                                 statusHeaderKey: "product.col.status",
                                                 rows: rows),
            emptyKeys: showsEmptyState ? ["product.empty.title", "product.empty.message"] : [],
            unreadableKeys: unreadable > 0 ? ["product.unreadable.notice"] : [],
            unreadableCount: unreadable,
            form: input.form.map(formBlock(for:)),
            delete: input.pendingDelete.map(deleteBlock(for:)))
    }

    private static func row(for product: Product) -> RowBlock {
        RowBlock(product: product,
                 typeKey: product.isService ? "product.type.service" : "product.type.product",
                 statusKey: product.isActive ? "product.status.active"
                                             : "product.status.inactive",
                 toggleHintKey: product.isActive ? "product.status.inactive"
                                                 : "product.status.active",
                 unit: unit(product.unit),
                 cost: cost(product.defaultUnitCost),
                 editActionKey: "common.edit",
                 deleteActionKey: "common.delete")
    }

    private static func formBlock(for draft: ProductFormDraft) -> FormBlock {
        FormBlock(titleKey: draft.isEditing ? "product.form.editTitle" : "product.form.newTitle",
                  nameLabelKey: "product.col.name",
                  unitLabelKey: "product.col.unit",
                  costLabelKey: "product.col.cost",
                  placeholderKey: "product.form.namePlaceholder",
                  serviceLabelKey: "product.form.isService",
                  serviceHintKey: "product.form.isServiceHint",
                  unitOptions: ProductUnit.allCases.map {
                      UnitOption(rawValue: $0.rawValue, labelKey: "product.unit.\($0.rawValue)")
                  },
                  cancelActionKey: "common.cancel",
                  saveActionKey: "common.save")
    }

    private static func deleteBlock(for product: Product) -> DeleteBlock {
        DeleteBlock(titleKey: "product.delete.confirmTitle",
                    messageKey: "product.delete.confirmMessage",
                    productName: product.name,
                    deleteActionKey: "common.delete",
                    cancelActionKey: "common.cancel")
    }
}

// MARK: - The form's draft

/// The new/edit panel's editable state, and the rule for what a save is allowed to write.
///
/// A value type rather than a handful of `@Published` fields, so the write-back rule below is a
/// pure function a test can exercise without a view, a model or a ledger.
struct ProductFormDraft: Equatable {
    /// The row being edited, or `nil` for a new item. Kept whole: the write-back rule compares
    /// against what the field is SHOWING, and what it is showing came from here.
    let editing: Product?
    var name: String
    /// The chosen unit, or `nil` for "nothing is selected".
    ///
    /// Optional on purpose, and it is the load-bearing part of the P4d guard. The picker offers
    /// exactly the eleven whitelisted units; a row holding a BLOB (`Product.unit == nil`) or a
    /// unit that was never on the whitelist has nothing to select. Seeding such a row with the
    /// first option and then writing it back on save would replace the ledger's own bytes with
    /// a value the user never chose — the same shape as the settings screen's
    /// focus-and-silently-rewrite defect. So it starts `nil`, the control shows no selection,
    /// and ``changes`` writes `unit` only after a deliberate pick.
    var unit: String?
    /// The price as typed. Text rather than a number so an unparseable field can be told apart
    /// from a zero, which is the other half of the same guard.
    var costText: String
    var isService: Bool

    var isEditing: Bool { editing != nil }

    /// Seed from a row, or from `create`'s own defaults.
    ///
    /// The defaults are the handler's — `piece`, zero, not a service (`products.js create`).
    /// `is_active` is deliberately absent from the whole draft: it is not a form field
    /// on either side, it is the row's own inline control.
    init(editing: Product?) {
        self.editing = editing
        guard let editing else {
            name = ""
            unit = ProductUnit.piece.rawValue
            costText = "0"
            isService = false
            return
        }
        name = editing.name
        unit = editing.unit.flatMap { ProductUnit(rawValue: $0) == nil ? nil : $0 }
        costText = Self.costText(editing.defaultUnitCost)
        isService = editing.isService
    }

    /// A plain decimal, or the empty string for a value that cannot be typed back.
    ///
    /// No grouping separators: the text is seeded here and parsed by ``parseCost(_:)``, and a
    /// formatter that writes `1,234.00` where the parser reads `Double` would make an untouched
    /// field look like an edit. Infinity is reachable in the column and cannot be re-entered, so
    /// it leaves the field empty — the same choice the settings screen makes for a stored value
    /// that needs repair, and the empty field then writes nothing.
    static func costText(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }

    /// `nil` for text that is not a number — including the empty string.
    static func parseCost(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces))
    }

    /// What a save is allowed to write.
    ///
    /// P4d's rule, in both directions: a field whose value equals what it is showing produces no
    /// assignment, and a field that cannot be read produces no assignment either. The first half
    /// keeps `updated_at` still and keeps a lenient read from being written back as if the user
    /// had confirmed it; the second half is why `costText` is text — an emptied or malformed
    /// price field must not land in the ledger as a zero.
    ///
    /// Only meaningful while editing. A new item has nothing to compare against and submits
    /// every field.
    var changes: Changes {
        guard let editing else { return Changes() }
        var out = Changes()
        if name != editing.name { out.name = name }
        if let unit, unit != editing.unit { out.unit = unit }
        if let parsed = Self.parseCost(costText), parsed != editing.defaultUnitCost {
            out.defaultUnitCost = parsed
        }
        if isService != editing.isService { out.isService = isService }
        return out
    }

    /// The assignments a save would make. All-nil means "a write that would change nothing",
    /// which is not a write.
    struct Changes: Equatable {
        var name: String?
        var unit: String?
        var defaultUnitCost: Double?
        var isService: Bool?

        var isEmpty: Bool {
            name == nil && unit == nil && defaultUnitCost == nil && isService == nil
        }
    }
}
