import SwiftUI
import Charts
import SoloLedgerCore

struct OverviewView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                periodBar
                summarySection
                Divider()
                chartSection
                Divider()
                metricsSection
                Divider()
                recentSection
                LegacyLedgerBanner()
                Text(model.t("overview.dataSourceNote"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
        }
        .navigationTitle(model.t("nav.overview"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.newTransaction() } label: {
                    Label(model.t("cmd.newTransaction"), systemImage: "plus")
                }
            }
        }
    }

    private var periodBar: some View {
        HStack {
            Picker(model.t("overview.period"), selection: Binding(
                get: { model.overviewPeriod },
                // The metrics block below always describes a whole calendar year, so this
                // control cannot change it. Rebuilding it here would run two full reports for
                // a value already on screen — see `AppModel.reloadAll(rebuildingMetrics:)`.
                set: { model.overviewPeriod = $0; model.reloadAll(rebuildingMetrics: false) }
            )) {
                ForEach(OverviewPeriod.allCases) { Text(model.t($0.titleKey)).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Spacer()
        }
    }

    // MARK: - Summary (per-currency; never a blended total)

    @ViewBuilder private var summarySection: some View {
        if model.currencySummaries.isEmpty {
            emptyState
        } else if model.currencySummaries.count == 1, let s = model.currencySummaries.first {
            singleCurrencyHero(s)
        } else {
            multiCurrencyGrid
        }
    }

    private func singleCurrencyHero(_ s: CurrencySummary) -> some View {
        HStack(alignment: .top, spacing: 0) {
            StatView(title: model.t("overview.income"), value: Money.string(s.incomeTotal, currency: s.currency), tint: .green)
            Divider().frame(height: 40)
            StatView(title: model.t("overview.expense"), value: Money.string(s.expenseTotal, currency: s.currency), tint: .red)
            Divider().frame(height: 40)
            StatView(title: model.t("overview.net"), value: Money.string(s.net, currency: s.currency), tint: s.net >= 0 ? .primary : .red)
            Divider().frame(height: 40)
            StatView(title: model.t("overview.count"), value: "\(s.count)")
        }
    }

    private var multiCurrencyGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.t("overview.byCurrency")).font(.headline)
            Grid(alignment: .trailing, horizontalSpacing: 22, verticalSpacing: 6) {
                GridRow {
                    Text(model.t("overview.currency")).gridColumnAlignment(.leading)
                    Text(model.t("overview.income"))
                    Text(model.t("overview.expense"))
                    Text(model.t("overview.net"))
                    Text(model.t("overview.count"))
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(model.currencySummaries) { s in
                    GridRow {
                        Text(s.currency).monospaced().fontWeight(.medium).gridColumnAlignment(.leading)
                        Text(Money.string(s.incomeTotal, currency: s.currency)).foregroundStyle(.green).monospacedDigit()
                        Text(Money.string(s.expenseTotal, currency: s.currency)).foregroundStyle(.red).monospacedDigit()
                        Text(Money.string(s.net, currency: s.currency)).fontWeight(.semibold).monospacedDigit()
                        Text("\(s.count)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            Label(model.t("overview.multiCurrencyNote"), systemImage: "info.circle")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var emptyState: some View {
        if model.legacyLedger.holdsHiddenRecords {
            // Not an empty ledger at all — the records are in tables this app does not
            // read. Checked before the period branch: "no data this period" would be
            // just as misleading for a ledger whose every record is hidden.
            LegacyLedgerNotice().frame(maxWidth: .infinity)
        } else if model.overviewPeriod == .all {
            VStack(spacing: 12) {
                EmptyStateView(systemImage: "chart.pie",
                               title: model.t("overview.empty.title"),
                               message: model.t("overview.empty.message"))
                #if DEBUG
                if model.canLoadDemoData {
                    Button(model.t("overview.loadDemo")) { model.loadDemoData() }
                        .buttonStyle(.bordered)
                }
                #endif
            }
            .frame(maxWidth: .infinity)
        } else {
            // Data exists in other periods, but not this one.
            EmptyStateView(systemImage: "calendar.badge.exclamationmark",
                           title: model.t("overview.emptyPeriod.title"),
                           message: model.t("overview.emptyPeriod.message"))
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Monthly chart (single primary currency)

    @ViewBuilder private var chartSection: some View {
        HStack(spacing: 6) {
            Text(model.t("overview.monthlyTitle")).font(.headline)
            if let c = model.currencySummaries.first?.currency {
                Text("· \(c)").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        if model.monthly.isEmpty {
            EmptyStateView(systemImage: "chart.bar",
                           title: model.t("overview.empty.title"),
                           message: model.t("overview.empty.message"))
            .frame(height: 200)
        } else {
            Chart {
                ForEach(model.monthly) { row in
                    BarMark(x: .value(model.t("overview.month"), row.month),
                            y: .value(model.t("overview.income"), row.income))
                        .foregroundStyle(by: .value("series", model.t("overview.income")))
                        .position(by: .value("series", model.t("overview.income")))
                    BarMark(x: .value(model.t("overview.month"), row.month),
                            y: .value(model.t("overview.expense"), row.expense))
                        .foregroundStyle(by: .value("series", model.t("overview.expense")))
                        .position(by: .value("series", model.t("overview.expense")))
                }
            }
            .chartForegroundStyleScale([
                model.t("overview.income"): Color.green,
                model.t("overview.expense"): Color.red,
            ])
            .chartLegend(position: .top, alignment: .leading)
            .frame(height: 240)
        }
    }

    // MARK: - Month on month / year on year (fixed calendar year)

    /// Drawn from `OverviewPageComposition`, and only when the model has an input for it —
    /// every reason the block cannot be trusted (no regime, no currency, a period holding more
    /// than one, a failed read) leaves that input `nil` and this section empty. The block's own
    /// copy cannot describe those situations, and borrowing a sentence that describes something
    /// else would be worse than saying nothing.
    ///
    /// Deliberately NOT a `Table`: its cells are rebuilt outside the environment during an
    /// accessibility traversal, where an `@EnvironmentObject` lookup is fatal. This follows the
    /// report page's monthly table instead, which is a stack of rows and has no such second
    /// materialisation.
    ///
    /// The year is drawn as a bare numeral beside the heading, the way the chart above already
    /// draws its currency code. It is data, not copy — which is why it needs no key, and why
    /// the block can say which year it means without inventing a sentence to do it.
    @ViewBuilder private var metricsSection: some View {
        if let input = model.overviewMetrics {
            let page = OverviewPageComposition.compose(input)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(model.t(page.titleKey)).font(.headline)
                    Text("· \(page.year)").font(.subheadline)
                        .foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                }
                if page.rows.isEmpty {
                    if page.emptyKeys.count == 2 {
                        EmptyStateView(systemImage: "percent",
                                       title: model.t(page.emptyKeys[0]),
                                       message: model.t(page.emptyKeys[1]))
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    metricsTable(page, currency: input.currency)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(page.captionKeys, id: \.self) { key in
                            Text(model.t(key)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(page.noteKeys, id: \.self) { key in
                        Text(model.t(key)).font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("overviewMetrics.block")
        }
    }

    private func metricsTable(_ page: OverviewPageComposition.Page, currency: String) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: 22, verticalSpacing: 4) {
            GridRow {
                Text(model.t("overview.month")).gridColumnAlignment(.leading)
                ForEach(page.columnHeaderKeys, id: \.self) { Text(model.t($0)) }
            }
            .font(.caption).foregroundStyle(.secondary)
            ForEach(page.rows) { row in
                GridRow {
                    Text("\(row.month)").monospacedDigit().gridColumnAlignment(.leading)
                    Text(OverviewPageComposition.revenueText(row.revenue, currency: currency) ?? "—")
                        .monospacedDigit()
                    Text(OverviewPageComposition.percentText(row.mom, language: model.language) ?? "—")
                        .monospacedDigit()
                    Text(OverviewPageComposition.percentText(row.yoy, language: model.language) ?? "—")
                        .monospacedDigit()
                }
                .font(.caption)
            }
        }
        .accessibilityIdentifier("overviewMetrics.table")
    }

    // MARK: - Recent transactions

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.t("overview.recent")).font(.headline)
            if model.recent.isEmpty {
                Text(model.t("txn.empty.title")).font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(model.recent) { t in
                    HStack(spacing: 12) {
                        Text(t.date).font(.callout).monospacedDigit()
                            .foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
                        Text(model.t("type.\(t.type.rawValue)")).font(.caption)
                            .foregroundStyle(t.type == .income ? Color.green : Color.red)
                            .frame(width: 40, alignment: .leading)
                        Text(t.counterparty.isEmpty ? categoryName(t.categoryID) : t.counterparty).lineLimit(1)
                        Spacer()
                        Text(Money.string(t.amount, currency: t.currency)).monospacedDigit()
                            .foregroundStyle(t.type == .income ? Color.green : Color.primary)
                    }
                    .padding(.vertical, 3)
                    Divider()
                }
            }
        }
    }

    private func categoryName(_ id: String?) -> String {
        guard let id, let c = model.categories.first(where: { $0.id == id }) else { return "—" }
        return model.categoryLabel(c)
    }
}
