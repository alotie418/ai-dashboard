import SwiftUI
import Charts
import SoloLedgerCore

struct OverviewView: View {
    @EnvironmentObject var model: AppModel

    private var currency: String { model.accountingLocale.defaultCurrency }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                summaryRow
                Divider()
                chartSection
                Spacer(minLength: 0)
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
                Button {
                    model.newTransaction()
                } label: {
                    Label(model.t("cmd.newTransaction"), systemImage: "plus")
                }
            }
        }
    }

    private var summaryRow: some View {
        HStack(alignment: .top, spacing: 0) {
            StatView(title: model.t("overview.income"),
                     value: Money.string(model.summary.incomeTotal, currency: currency),
                     tint: .green)
            Divider().frame(height: 40)
            StatView(title: model.t("overview.expense"),
                     value: Money.string(model.summary.expenseTotal, currency: currency),
                     tint: .red)
            Divider().frame(height: 40)
            StatView(title: model.t("overview.net"),
                     value: Money.string(model.summary.net, currency: currency),
                     tint: model.summary.net >= 0 ? .primary : .red)
            Divider().frame(height: 40)
            StatView(title: model.t("overview.count"),
                     value: "\(model.summary.incomeCount + model.summary.expenseCount)")
        }
    }

    @ViewBuilder private var chartSection: some View {
        Text(model.t("overview.monthlyTitle"))
            .font(.headline)

        if model.monthly.isEmpty {
            EmptyStateView(systemImage: "chart.bar",
                           title: model.t("overview.empty.title"),
                           message: model.t("overview.empty.message"))
            .frame(height: 240)
        } else {
            Chart {
                ForEach(model.monthly) { row in
                    BarMark(
                        x: .value(model.t("overview.month"), row.month),
                        y: .value(model.t("overview.income"), row.income)
                    )
                    .foregroundStyle(by: .value("series", model.t("overview.income")))
                    .position(by: .value("series", model.t("overview.income")))

                    BarMark(
                        x: .value(model.t("overview.month"), row.month),
                        y: .value(model.t("overview.expense"), row.expense)
                    )
                    .foregroundStyle(by: .value("series", model.t("overview.expense")))
                    .position(by: .value("series", model.t("overview.expense")))
                }
            }
            .chartForegroundStyleScale([
                model.t("overview.income"): Color.green,
                model.t("overview.expense"): Color.red,
            ])
            .chartLegend(position: .top, alignment: .leading)
            .frame(height: 260)
            .accessibilityLabel(model.t("overview.monthlyTitle"))
        }
    }
}
