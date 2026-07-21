import SwiftUI
import SoloLedgerCore

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var residualBannerDismissed = false

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

    // Every branch below is a leaf of the SINGLE pure `MigrationPresenter.route` decision — the
    // production model, the DEBUG preview and the routing unit tests all feed the same function,
    // so no path bypasses routing.
    @ViewBuilder private var content: some View {
        let resolved = resolvedRouteAndData
        #if DEBUG
        render(resolved.0, resolved.1)
            .safeAreaInset(edge: .bottom) { DebugActionWitnessBar() }
        #else
        render(resolved.0, resolved.1)
        #endif
    }

    /// (route, view-data). Production feeds the real model through `route`; the DEBUG preview
    /// feeds SYNTHETIC primitives through the SAME `route` (it never constructs a leaf view).
    private var resolvedRouteAndData: (MigrationPresenter.MigrationRoute, MigrationViewData) {
        #if DEBUG
        if let preview = DebugMigrationPreview.current {
            let route = MigrationPresenter.route(bootError: false, migrationFailure: false,
                                                 input: preview.input, ready: preview.ready,
                                                 onboardingDone: preview.onboardingDone)
            return (route, preview.data)
        }
        #endif
        let route = MigrationPresenter.route(
            bootError: model.bootError != nil,
            migrationFailure: model.migrationFailure != nil,
            input: MigrationPresenter.routeInput(for: model.migrationUIState),
            ready: model.ready, onboardingDone: model.onboardingDone)
        return (route, productionData)
    }

    /// The render inputs extracted from the real model state (public data + intent closures).
    /// A one-liner over the SINGLE production mapping seam (`MigrationViewData.production`),
    /// which the hosted productionData-mapping guards consume too — no second switch exists.
    private var productionData: MigrationViewData {
        .production(for: model.migrationUIState, model: model)
    }

    @ViewBuilder private func render(_ route: MigrationPresenter.MigrationRoute, _ data: MigrationViewData) -> some View {
        switch route {
        case .bootError:
            BootErrorView(message: model.bootError ?? "")
        case .legacyRecovery:
            MigrationRecoveryView(error: model.migrationFailure ?? "")   // legacy restore/blank live ONLY here
        case .running:
            MigrationProgressView()
        case .acknowledgement:
            MigrationAckView(unresolved: data.unresolved, onAcknowledge: data.onAcknowledge)
        case .importSelection:
            MigrationSelectionView(candidates: data.candidates, onSelect: data.onSelect, onCancel: data.onCancel)
        case .chooseSource:
            MigrationSourceChoiceView(onMigrate: data.onChooseMigrate, onCreateFresh: data.onConfirmCreateFresh)
        case .chainRecovery(let severity):
            MigrationChainRecoveryView(messageKey: data.chainMessageKey, severity: severity)
        case .loading:
            ProgressView(model.t("common.loading")).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .onboarding:
            OnboardingView()
        case .main(let showResidualBanner):
            MainSplitView()
                .safeAreaInset(edge: .top) {
                    if showResidualBanner, let importID = data.residualImportID, !residualBannerDismissed {
                        ResidualBanner(importID: importID, onDismiss: { residualBannerDismissed = true })
                    }
                }
        }
    }
}

/// Render inputs for a migration route — value data + intent closures only; the app never
/// constructs Core-internal types, so both the model (production) and the DEBUG preview can
/// supply this.
struct MigrationViewData {
    var unresolved = UnresolvedReport(items: [])
    var candidates: [MigrationCandidateVM] = []
    var residualImportID: String?
    var chainMessageKey = "migration.msg.internalError"
    var onAcknowledge: () -> Void = {}
    var onSelect: (String) -> Void = { _ in }
    var onCancel: () -> Void = {}
    /// Source-choice intents (N7.2). `onChooseMigrate` opens the directory picker;
    /// `onConfirmCreateFresh` is called ONLY by the confirmation dialog's confirm button.
    var onChooseMigrate: () -> Void = {}
    var onConfirmCreateFresh: () -> Void = {}
}

extension MigrationViewData {
    /// The ONE production `MigrationUIState` → render-data / intent-closure mapping the app
    /// ships — `RootView.productionData` is only "this seam + the environment model", and the
    /// hosted productionData-mapping guards in `DormantSourceChoiceBootTests` consume this
    /// SAME function (no hand-copied switch), so an emptied or swapped production closure
    /// (e.g. `onChooseMigrate = {}`) fails those tests instead of surviving unseen behind
    /// the preview's synthetic closures.
    @MainActor
    static func production(for state: MigrationUIState, model: AppModel) -> MigrationViewData {
        var d = MigrationViewData()
        switch state {
        case .awaitingAcknowledgement(let request, let unresolved):
            d.unresolved = unresolved
            d.onAcknowledge = { model.submitAcknowledgement(request.acknowledge()) }
        case .awaitingImportSelection(let candidates):
            d.candidates = candidates.map { MigrationCandidateVM($0) }
            d.onSelect = { model.resolveImportSelection(importID: $0) }
            d.onCancel = { model.cancelImportSelection() }
        case .retriable(let block), .terminal(let block):
            d.chainMessageKey = MigrationPresenter.messageKey(for: block)
        case .cleanupResidual(let residual):
            d.residualImportID = residual.importID
        case .awaitingSourceChoice:
            d.onChooseMigrate = { model.chooseMigrationSourceViaPanel() }
            d.onConfirmCreateFresh = { model.confirmCreateFresh() }
        case .none, .running:
            break
        }
        return d
    }
}

/// Blocking recovery shown when an Electron database exists but its upgrade failed.
/// The original data is never modified; the user must choose how to proceed.
private struct MigrationRecoveryView: View {
    @EnvironmentObject var model: AppModel
    let error: String
    @State private var showingError = false
    @State private var confirmingBlank = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text(model.t("recovery.title")).font(.title2).fontWeight(.semibold)
            Text(model.t("recovery.message"))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)

            VStack(spacing: 10) {
                Button { model.retryMigration() } label: {
                    Label(model.t("recovery.retry"), systemImage: "arrow.clockwise").frame(maxWidth: 320)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button { model.restoreFromBackupViaPanel() } label: {
                    Label(model.t("recovery.restore"), systemImage: "tray.and.arrow.down").frame(maxWidth: 320)
                }
                .accessibilityIdentifier("recovery.restore")   // legacy-only; asserted ABSENT in chain terminal UI
                Button { showingError.toggle() } label: {
                    Label(model.t("recovery.viewError"), systemImage: "doc.text.magnifyingglass").frame(maxWidth: 320)
                }
                Button(role: .destructive) { confirmingBlank = true } label: {
                    Label(model.t("recovery.blank"), systemImage: "doc.badge.plus").frame(maxWidth: 320)
                }
                .accessibilityIdentifier("recovery.blank")     // legacy-only; asserted ABSENT in chain terminal UI
            }

            if showingError {
                ScrollView {
                    Text(error)
                        .font(.caption).monospaced()
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: 460, maxHeight: 140)
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }

            Text(model.t("recovery.safeNote"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog(model.t("recovery.blankConfirmTitle"), isPresented: $confirmingBlank, titleVisibility: .visible) {
            Button(model.t("recovery.blankConfirm"), role: .destructive) { model.createBlankLedgerConfirmed() }
            Button(model.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(model.t("recovery.blankConfirmMessage"))
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
            .accessibilityIdentifier("main.sidebar")
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

// MARK: - C12 migration state views (C12b-3)

private struct MigrationProgressView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(model.t("migration.running.message"))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("migration.running")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Retriable / terminal chain recovery. Offers ONLY "retry" + "export diagnostics" — never
/// restore / create-blank (those live exclusively in the legacy `MigrationRecoveryView`).
/// Severity drives the visual language: retriable = orange (transient), terminal = red.
private struct MigrationChainRecoveryView: View {
    @EnvironmentObject var model: AppModel
    let messageKey: String
    let severity: MigrationPresenter.ChainSeverity

    private var titleKey: String { severity == .retriable ? "migration.retriable.title" : "migration.terminal.title" }
    private var tint: Color { severity == .retriable ? .orange : .red }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: severity == .retriable ? "exclamationmark.triangle" : "xmark.octagon")
                .font(.system(size: 40)).foregroundStyle(tint)
            Text(model.t(titleKey)).font(.title2).fontWeight(.semibold)
            Text(model.t(messageKey))
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
            VStack(spacing: 10) {
                Button { model.retryProbe() } label: {
                    Label(model.t("migration.action.retry"), systemImage: "arrow.clockwise").frame(maxWidth: 320)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut("r", modifiers: .command)
                .accessibilityIdentifier("migration.action.retry")
                .accessibilityLabel(model.t("migration.action.retry"))
                Button { model.exportDiagnosticsViaPanel() } label: {
                    Label(model.t("migration.action.exportDiagnostics"), systemImage: "doc.text.magnifyingglass").frame(maxWidth: 320)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .accessibilityIdentifier("migration.action.exportDiagnostics")
                .accessibilityLabel(model.t("migration.action.exportDiagnostics"))
            }
        }
        .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One unresolved item: its NAME plus the LOCALIZED reason (kind). Never shows `detail`
/// (which may carry technical text) and never a raw kind.
private struct MigrationAckItemRow: View {
    @EnvironmentObject var model: AppModel
    let item: UnresolvedReport.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.name).font(.callout).lineLimit(1)
            Text(model.t(MigrationPresenter.unresolvedKindKey(for: item.kind)))
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Acknowledgement: shows EACH unresolved item (name + localized reason) so the user knows what
/// they are confirming. ONLY "confirm and continue" — there is deliberately NO in-app cancel.
private struct MigrationAckView: View {
    @EnvironmentObject var model: AppModel
    let unresolved: UnresolvedReport
    let onAcknowledge: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "questionmark.circle").font(.system(size: 40)).foregroundStyle(.orange)
            Text(model.t("migration.acknowledgement.title")).font(.title2).fontWeight(.semibold)
            Text(model.t("migration.acknowledgement.message"))
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
            Text(model.t("migration.acknowledgement.unresolvedCount", ["count": String(unresolved.items.count)]))
                .font(.callout)
            List(unresolved.items.indices, id: \.self) { idx in
                MigrationAckItemRow(item: unresolved.items[idx])
            }
            .frame(maxWidth: 460, maxHeight: 200)
            .accessibilityIdentifier("migration.acknowledgement.items")
            Button { onAcknowledge() } label: {
                Label(model.t("migration.action.acknowledge"), systemImage: "checkmark.circle").frame(maxWidth: 320)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .accessibilityIdentifier("migration.action.acknowledge")
            .accessibilityLabel(model.t("migration.action.acknowledge"))
        }
        .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// N7.2 (§1): the pre-open source-choice screen — fully independent of onboarding (which
/// continues unchanged after a store is adopted). Two actions only: "migrate old data" opens
/// the directory picker (cancel = pure no-op, stays here); "create new ledger" NEVER creates
/// directly — it first raises the confirmation dialog, whose confirm button alone fires
/// `onCreateFresh` (the `.confirmCreateFresh` intent). "Go back" dismisses the dialog and
/// stays on this screen without any intent. All copy goes through `model.t(key)` — never a
/// raw enum, path, or error string.
private struct MigrationSourceChoiceView: View {
    @EnvironmentObject var model: AppModel
    let onMigrate: () -> Void
    let onCreateFresh: () -> Void
    @State private var confirmingCreateFresh = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(model.t("migration.chooseSource.title")).font(.title2).fontWeight(.semibold)
            Text(model.t("migration.chooseSource.body"))
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
            VStack(spacing: 10) {
                Button { onMigrate() } label: {
                    Label(model.t("migration.chooseSource.migrate.button"),
                          systemImage: "arrow.down.doc").frame(maxWidth: 320)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .accessibilityIdentifier("migration.chooseSource.migrate")
                .accessibilityLabel(model.t("migration.chooseSource.migrate.button"))
                Text(model.t("migration.chooseSource.migrate.hint"))
                    .font(.caption).foregroundStyle(.secondary)
                Button { confirmingCreateFresh = true } label: {
                    Label(model.t("migration.chooseSource.createNew.button"),
                          systemImage: "doc.badge.plus").frame(maxWidth: 320)
                }
                .accessibilityIdentifier("migration.chooseSource.createNew")
                .accessibilityLabel(model.t("migration.chooseSource.createNew.button"))
                Text(model.t("migration.chooseSource.createNew.hint"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog(model.t("migration.chooseSource.confirm.title"),
                            isPresented: $confirmingCreateFresh, titleVisibility: .visible) {
            Button(model.t("migration.chooseSource.confirm.create")) { onCreateFresh() }
                .accessibilityIdentifier("migration.chooseSource.confirm.create")
            Button(model.t("migration.chooseSource.confirm.back"), role: .cancel) {}
                .accessibilityIdentifier("migration.chooseSource.confirm.back")
        } message: {
            Text(model.t("migration.chooseSource.confirm.body"))
        }
    }
}

/// App-side view model for a recoverable-import candidate — reads only PUBLIC properties, so it
/// can be built from a real `RecoverableImport` or synthesized in the DEBUG preview.
struct MigrationCandidateVM: Identifiable {
    let importID: String
    let status: RecoverableImport.Status
    let createdAt: String?
    let sourceKind: String?
    let ingestedCount: Int?
    var id: String { importID }

    init(_ r: RecoverableImport) {
        importID = r.importID; status = r.status
        createdAt = r.createdAt; sourceKind = r.sourceKind; ingestedCount = r.ingestedCount
    }
    init(importID: String, status: RecoverableImport.Status,
         createdAt: String? = nil, sourceKind: String? = nil, ingestedCount: Int? = nil) {
        self.importID = importID; self.status = status
        self.createdAt = createdAt; self.sourceKind = sourceKind; self.ingestedCount = ingestedCount
    }
}

private struct MigrationCandidateRow: View {
    @EnvironmentObject var model: AppModel
    let candidate: MigrationCandidateVM
    let onSelect: (String) -> Void

    // Transient (unavailable) is NOT red; only terminal (invalid) is. Valid is neutral.
    private var statusColor: Color {
        switch candidate.status {
        case .valid:       return .secondary
        case .unavailable: return .orange
        case .invalid:     return .red
        }
    }

    /// Valid candidates show real source / date / count; non-valid show a placeholder — never
    /// a fabricated value, never a raw sourceKind string.
    private var metadataLine: String {
        guard case .valid = candidate.status else { return model.t("migration.candidate.noMeta") }
        let source = model.t(MigrationPresenter.sourceKindKey(for: candidate.sourceKind ?? ""))
        var parts = [source]
        if let created = candidate.createdAt, !created.isEmpty { parts.append(created) }
        if let count = candidate.ingestedCount {
            parts.append(model.t("migration.candidate.entries", ["count": String(count)]))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let selectable = MigrationPresenter.isSelectable(candidate.status)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.importID).font(.callout).lineLimit(1)
                Text(model.t(MigrationPresenter.candidateStatusKey(for: candidate.status)))
                    .font(.caption).foregroundStyle(statusColor)
                Text(metadataLine).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button(model.t("migration.action.select")) { onSelect(candidate.importID) }
                .disabled(!selectable)
                .accessibilityIdentifier("migration.action.select.\(candidate.importID)")
        }
        .accessibilityValue(model.t(MigrationPresenter.candidateHintKey(for: candidate.status)))
    }
}

private struct MigrationSelectionView: View {
    @EnvironmentObject var model: AppModel
    let candidates: [MigrationCandidateVM]
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(model.t("migration.selection.title")).font(.title2).fontWeight(.semibold)
            Text(model.t("migration.selection.message"))
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
            List(candidates) { c in
                MigrationCandidateRow(candidate: c, onSelect: onSelect)
            }
            .frame(maxWidth: 460, maxHeight: 240)
            Button(model.t("migration.action.cancel")) { onCancel() }
                .accessibilityIdentifier("migration.action.cancel")
                .accessibilityLabel(model.t("migration.action.cancel"))
        }
        .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Non-blocking cleanup-residual banner over the main UI (ready == true).
private struct ResidualBanner: View {
    @EnvironmentObject var model: AppModel
    let importID: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text(model.t("migration.residual.note", ["importID": importID])).font(.callout).lineLimit(2)
                .accessibilityIdentifier("migration.residual.note")
            Spacer()
            Button(model.t("migration.residual.dismiss")) { onDismiss() }
                .accessibilityIdentifier("migration.residual.dismiss")
        }
        .padding(10)
        .background(.quaternary)
        .accessibilityIdentifier("migration.residual.banner")
    }
}

#if DEBUG
/// TEST-ONLY (DEBUG) action witness: identifier-encoded invocation counters read by the
/// UI-test guards (rendering alone cannot catch an emptied action). TWO recording modes
/// share it, each guarding a different layer:
///  - `--migration-ui-preview chooseSource`: the preview's synthetic closures record
///    `onMigrate` / `onCreateFresh` — the SwiftUI Button → SUPPLIED-closure guard for
///    `MigrationSourceChoiceView`;
///  - `--migration-boot-harness chooseSource`: the scripted runner and the panel-runner
///    override record the panel/intent keys (`DebugBootHarness.witnessKeys`) — the guard
///    for RootView's NON-preview `productionData` production path.
/// (The supplier itself — `MigrationViewData.production` → AppModel — is guarded by the
/// hosted productionData-mapping tests, which never touch these counters.) An ordinary
/// production boot with neither argument records nothing and renders nothing, and none of
/// this is compiled into Release. Mutated exclusively from main-thread actions / read from
/// rendering, both on the main thread.
final class DebugActionWitness: ObservableObject {
    static let shared = DebugActionWitness()
    @Published private(set) var counts: [String: Int] = [:]
    func record(_ action: String) { counts[action, default: 0] += 1 }
}

/// The witness read-out (DEBUG): stable-identifier labels the UI tests assert on. Renders
/// ONLY under the `chooseSource` preview (supplied-closure witnesses) or the boot harness
/// (production-path witnesses, see `DebugBootHarness`) — every other route and every
/// production boot contributes an empty inset.
private struct DebugActionWitnessBar: View {
    @ObservedObject private var witness = DebugActionWitness.shared

    private var keys: [String]? {
        if DebugBootHarness.isActive { return DebugBootHarness.witnessKeys }
        if DebugMigrationPreview.current?.input == .sourceChoice { return ["onMigrate", "onCreateFresh"] }
        return nil
    }

    var body: some View {
        if let keys {
            // The COUNT is encoded in the accessibility IDENTIFIER (identifier queries are
            // the one AX surface that proved reliable for this inset on macOS SwiftUI): the
            // tests assert existence of `…witness.<key>.<count>` — a missed or doubled
            // invocation makes the expected identifier never exist.
            HStack(spacing: 12) {
                ForEach(keys, id: \.self) { key in
                    Text("\(key)=\(witness.counts[key, default: 0])")
                        .accessibilityIdentifier("migration.debug.witness.\(key).\(witness.counts[key, default: 0])")
                }
            }
            .font(.caption2).foregroundStyle(.secondary).padding(4)
        }
    }
}

/// DEBUG/TEST-ONLY preview seam for the migration states, driven by the
/// `--migration-ui-preview <state>` launch argument (or `MIGRATION_UI_PREVIEW` env var). It is
/// compiled ONLY in DEBUG, so no arbitrary state-injection entry point exists in Release.
///
/// It supplies SYNTHETIC primitives (a `RouteInput` + ready/onboarding flags) and view data —
/// RootView feeds these through the SAME `MigrationPresenter.route`, so the preview exercises the
/// real routing (it does NOT construct target leaf views directly).
enum DebugMigrationPreview {
    struct Preview {
        let input: MigrationPresenter.RouteInput
        let ready: Bool
        let onboardingDone: Bool
        let data: MigrationViewData
    }

    static var current: Preview? {
        guard let raw = previewName() else { return nil }
        switch raw {
        case "running":
            return Preview(input: .running, ready: false, onboardingDone: false, data: MigrationViewData())
        case "retriable":
            var d = MigrationViewData(); d.chainMessageKey = "migration.msg.ioTransient"
            return Preview(input: .retriable, ready: false, onboardingDone: false, data: d)
        case "terminal":
            var d = MigrationViewData(); d.chainMessageKey = "migration.msg.stagingTampered"
            return Preview(input: .terminal, ready: false, onboardingDone: false, data: d)
        case "ack":
            var d = MigrationViewData()
            d.unresolved = UnresolvedReport(items: [
                UnresolvedReport.Item(name: "invoice-scan.pdf", kind: .missingStagedFile),
                UnresolvedReport.Item(name: "logo.png", kind: .skippedSymlink),
            ])
            return Preview(input: .acknowledgement, ready: false, onboardingDone: false, data: d)
        case "selection":
            var d = MigrationViewData()
            d.candidates = [
                MigrationCandidateVM(importID: "import-valid-1", status: .valid,
                                     createdAt: "2026-01-02", sourceKind: "userSelectedDataDir", ingestedCount: 128),
                MigrationCandidateVM(importID: "import-unavail-1", status: .unavailable(.ioTransient)),
                MigrationCandidateVM(importID: "import-invalid-1", status: .invalid(.stagingTampered)),
            ]
            return Preview(input: .importSelection, ready: false, onboardingDone: false, data: d)
        case "residual":
            var d = MigrationViewData(); d.residualImportID = "import-residual-1"
            return Preview(input: .cleanupResidual, ready: true, onboardingDone: true, data: d)
        case "chooseSource":
            // Synthetic intents that record into the TEST-ONLY witness: the preview renders
            // the REAL source-choice screen and its confirmation dialog (view-local state)
            // without a model or a live chain, and UI tests click the real buttons and read
            // the witness counts to prove the button → closure wiring.
            var d = MigrationViewData()
            d.onChooseMigrate = { DebugActionWitness.shared.record("onMigrate") }
            d.onConfirmCreateFresh = { DebugActionWitness.shared.record("onCreateFresh") }
            return Preview(input: .sourceChoice, ready: false, onboardingDone: false, data: d)
        case "none":
            // Deterministic neutral state: .none + ready==false ⇒ loading (NOT a real boot).
            return Preview(input: .none, ready: false, onboardingDone: false, data: MigrationViewData())
        default:
            return nil
        }
    }

    private static func previewName() -> String? {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--migration-ui-preview"), i + 1 < args.count { return args[i + 1] }
        return ProcessInfo.processInfo.environment["MIGRATION_UI_PREVIEW"]
    }
}
#endif
