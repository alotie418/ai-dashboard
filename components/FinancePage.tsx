
import React, { useState, useEffect, useCallback } from 'react';
import { useTranslation } from 'react-i18next';
import { BusinessData } from '../types';
import { generateReport, fetchSettings, type ReportResult } from '../services/api';
import { formatMoney, getTaxLabel } from './accountingHelpers';

interface Props {
  data: BusinessData;
  selectedYear: string;
  selectedQuarter: string;
  selectedMonth: string;
}

type StatementType = 'pl' | 'balance' | 'cashflow';

const FinancePage: React.FC<Props> = ({ data, selectedYear, selectedQuarter, selectedMonth }) => {
  const { t, i18n } = useTranslation();
  const [activeTab, setActiveTab] = useState<StatementType>('pl');
  const [report, setReport] = useState<ReportResult | null>(null);
  const [locale, setLocale] = useState<string>('CN');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const loadReport = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const settings = await fetchSettings();
      const loc = (settings as any).accounting_locale || 'CN';
      setLocale(loc);
      const r = await generateReport({ locale: loc, year: selectedYear });
      setReport(r);
    } catch (e: any) {
      setError(e?.message || 'Failed to generate report');
      // Fallback: use old data.financialStatement
      setReport(null);
    } finally {
      setLoading(false);
    }
  }, [selectedYear]);

  useEffect(() => { loadReport(); }, [loadReport]);

  // Fallback P&L from old data model
  const fallbackPL = (() => {
    const fs = data.financialStatement;
    const revenue = fs.salesRevenue;
    const cost = fs.costOfSales;
    const grossProfit = revenue - cost;
    const netProfit = revenue - cost - fs.taxSurcharge - fs.shippingFee - fs.adminExpense - fs.incomeTax;
    const grossMargin = revenue === 0 ? 0 : +(grossProfit / revenue * 100).toFixed(2);
    const netMargin = revenue === 0 ? 0 : +(netProfit / revenue * 100).toFixed(2);
    return { grossProfit, netProfit, grossMargin, netMargin };
  })();

  const periodDisplay = selectedQuarter !== '全年'
    ? `${selectedYear} ${selectedQuarter}`
    : selectedMonth !== '全部'
      ? `${selectedYear} ${selectedMonth}`
      : t('header.yearLabel', { year: selectedYear });

  const fmt = (v: number) => formatMoney(v, locale, i18n.language);

  // Export CSV
  const exportCSV = () => {
    let csvContent = "data:text/csv;charset=utf-8,﻿";
    if (report && locale === 'US' && report.scheduleC) {
      csvContent += "Schedule C Line,Amount\n";
      for (const [key, val] of Object.entries(report.scheduleC)) {
        csvContent += `${key},${val}\n`;
      }
    } else {
      const fs = report?.incomeStatement || report?.profitLoss || data.financialStatement;
      csvContent += `${t('finance.plRevenue')},${fs.salesRevenue || fs.revenue || 0}\n`;
      csvContent += `${t('finance.plCost')},${fs.costOfSales || fs.costOfSales || 0}\n`;
      csvContent += `${t('finance.plGrossProfit')},${fs.grossProfit || 0}\n`;
      csvContent += `${t('finance.plNetProfit')},${fs.netProfit || 0}\n`;
    }
    const link = document.createElement("a");
    link.setAttribute("href", encodeURI(csvContent));
    link.setAttribute("download", `SoloLedger_${locale}_${activeTab}_${selectedYear}.csv`);
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
  };

  // Get the primary P&L data (works for CN/JP/KR/TW/EU)
  const getIncomeStatement = () => {
    if (!report) return null;
    return report.incomeStatement || report.profitLoss || null;
  };

  // Tab label for P&L varies by locale
  const plTabLabel = locale === 'US' ? 'Schedule C' : t('finance.tabPl');

  return (
    <div className="max-w-7xl mx-auto space-y-6 animate-in fade-in slide-in-from-bottom-4 duration-500">
      {/* Header */}
      <div className="flex justify-end space-x-3">
        <button onClick={exportCSV} className="flex items-center px-4 py-2 bg-white border border-[#e0ddd5] rounded-xl text-sm font-medium text-[#4a4a48] hover:text-[#191918] transition-all">
          <i className="fas fa-file-export mr-2 text-[#d97757]"></i> {t('finance.export')}
        </button>
        <button className="flex items-center px-4 py-2 bg-[#d97757] hover:bg-[#c56a4a] text-white rounded-xl text-sm font-medium transition-all" style={{ boxShadow: '0 4px 16px rgba(217,119,87,0.15)' }}>
          <i className="fas fa-print mr-2"></i> {t('finance.print')}
        </button>
      </div>

      {/* Quick KPIs */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
        <div className="bg-white/80 border border-[#e0ddd5] p-6 rounded-xl">
          <p className="text-[#5c5c5a] text-[10px] uppercase font-bold tracking-widest mb-1">{t('finance.kpiNetAssets')}</p>
          <h4 className="text-2xl font-bold text-[#191918] tracking-tight">{fmt(report?.incomeStatement?.netProfit || report?.profitLoss?.netProfit || report?.scheduleC?.line31_netProfit || 0)}</h4>
        </div>
        <div className="bg-white/80 border border-[#e0ddd5] p-6 rounded-xl">
          <p className="text-[#5c5c5a] text-[10px] uppercase font-bold tracking-widest mb-1">{locale === 'US' ? 'Gross Income' : t('finance.kpiDebtRatio')}</p>
          <h4 className="text-2xl font-bold text-[#191918] tracking-tight">
            {locale === 'US' ? fmt(report?.scheduleC?.line7_grossIncome || 0) : `${getIncomeStatement()?.grossMargin || 0}%`}
          </h4>
        </div>
        <div className="bg-white/80 border border-[#e0ddd5] p-6 rounded-xl">
          <p className="text-[#5c5c5a] text-[10px] uppercase font-bold tracking-widest mb-1">
            {locale === 'US' ? 'Est. Quarterly Tax' : t('finance.kpiCurrentRatio')}
          </p>
          <h4 className="text-2xl font-bold text-[#191918] tracking-tight">
            {locale === 'US' ? fmt(report?.estimatedTax?.quarterlyPayment || 0) : '0.0'}
          </h4>
        </div>
      </div>

      {/* Tabs */}
      <div className="flex bg-white/80 p-1.5 rounded-xl border border-[#e0ddd5] w-fit">
        <button onClick={() => setActiveTab('pl')} className={`px-6 py-2 rounded-lg text-sm font-medium transition-all ${activeTab === 'pl' ? 'bg-[#d97757] text-white' : 'text-[#4a4a48] hover:text-[#191918]'}`} style={activeTab === 'pl' ? { boxShadow: '0 4px 16px rgba(217,119,87,0.15)' } : {}}>
          {plTabLabel}
        </button>
        <button onClick={() => setActiveTab('balance')} className={`px-6 py-2 rounded-lg text-sm font-medium transition-all ${activeTab === 'balance' ? 'bg-[#d97757] text-white' : 'text-[#4a4a48] hover:text-[#191918]'}`} style={activeTab === 'balance' ? { boxShadow: '0 4px 16px rgba(217,119,87,0.15)' } : {}}>
          {t('finance.tabBalance')}
        </button>
        <button onClick={() => setActiveTab('cashflow')} className={`px-6 py-2 rounded-lg text-sm font-medium transition-all ${activeTab === 'cashflow' ? 'bg-[#d97757] text-white' : 'text-[#4a4a48] hover:text-[#191918]'}`} style={activeTab === 'cashflow' ? { boxShadow: '0 4px 16px rgba(217,119,87,0.15)' } : {}}>
          {t('finance.tabCashflow')}
        </button>
      </div>

      {/* Loading / Error */}
      {loading && (
        <div className="text-center py-8 text-sm text-[#7a7a78]">
          <i className="fas fa-spinner fa-spin mr-2 text-[#d97757]"></i>{t('common.loading')}
        </div>
      )}
      {error && (
        <div className="text-sm text-amber-700 bg-amber-50 border border-amber-200 rounded-lg px-4 py-2">
          <i className="fas fa-exclamation-triangle mr-2"></i>{error}
        </div>
      )}

      {/* Statement Content */}
      <div className="bg-white/80 border border-[#e0ddd5] rounded-xl overflow-hidden" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.05)' }}>

        {/* === P&L / Schedule C tab === */}
        {activeTab === 'pl' && !loading && (
          <div className="p-10">
            <div className="max-w-4xl mx-auto space-y-6">
              <div className="text-center mb-10">
                <h2 className="text-2xl font-bold text-[#191918]">
                  {locale === 'US' ? 'Schedule C — Profit or Loss From Business' : t('finance.plTitle')}
                </h2>
                <p className="text-[#5c5c5a] text-sm">{getTaxLabel(locale, i18n.language, 'plPeriodPrefix')}{periodDisplay}</p>
                {report?.warnings && report.warnings.length > 0 && (
                  <div className="mt-3 space-y-1">
                    {report.warnings.map((w, i) => (
                      <p key={i} className="text-xs text-amber-600"><i className="fas fa-info-circle mr-1"></i>{w}</p>
                    ))}
                  </div>
                )}
              </div>

              {locale === 'US' && report?.scheduleC ? (
                <USScheduleC data={report.scheduleC} fmt={fmt} />
              ) : (
                <GenericPL
                  is={getIncomeStatement()}
                  fs={data.financialStatement}
                  fallbackPL={fallbackPL}
                  fmt={fmt}
                  t={t}
                  locale={locale}
                  vatSummary={report?.vatSummary || report?.consumptionTax || report?.vatReturn || report?.businessTax}
                  taxIncSummary={report?.taxInclusiveSummary}
                />
              )}
            </div>
          </div>
        )}

        {/* === Balance Sheet (placeholder) === */}
        {activeTab === 'balance' && (
          <div className="grid grid-cols-1 md:grid-cols-2 divide-x divide-[#e0ddd5]">
            <div className="p-10">
              <h3 className="text-lg font-bold text-[#191918] mb-6 flex items-center">
                <i className="fas fa-coins mr-3 text-amber-500"></i> {t('finance.balanceAssets')}
              </h3>
              <div className="space-y-1">
                <h4 className="text-xs font-bold text-[#5c5c5a] uppercase tracking-widest py-2">{t('finance.balanceCurrentAssets')}</h4>
                <LineItem label={t('finance.balanceCash')} value={0.0} />
                <LineItem label={t('finance.balanceReceivables')} value={0.0} />
                <LineItem label={t('finance.balanceInventory')} value={0.0} />
                <div className="border-t border-[#e0ddd5] my-4"></div>
                <LineItem label={t('finance.balanceCurrentAssetsTotal')} value={0.0} bold />
                <h4 className="text-xs font-bold text-[#5c5c5a] uppercase tracking-widest py-2 mt-4">{t('finance.balanceNonCurrentAssets')}</h4>
                <LineItem label={t('finance.balanceFixedAssets')} value={0.0} />
                <div className="border-t border-[#e0ddd5] my-4"></div>
                <LineItem label={t('finance.balanceTotalAssets')} value={0.0} bold primary />
              </div>
            </div>
            <div className="p-10 bg-[#f9f9f8]/20">
              <h3 className="text-lg font-bold text-[#191918] mb-6 flex items-center">
                <i className="fas fa-hand-holding-dollar mr-3 text-rose-500"></i> {t('finance.balanceLiabilitiesEquity')}
              </h3>
              <div className="space-y-1">
                <h4 className="text-xs font-bold text-[#5c5c5a] uppercase tracking-widest py-2">{t('finance.balanceCurrentLiabilities')}</h4>
                <LineItem label={t('finance.balancePayables')} value={0.0} />
                <LineItem label={t('finance.balanceTaxPayable')} value={0.0} />
                <div className="border-t border-[#e0ddd5] my-4"></div>
                <LineItem label={t('finance.balanceTotalLiabilities')} value={0.0} bold />
                <h4 className="text-xs font-bold text-[#5c5c5a] uppercase tracking-widest py-2 mt-4">{t('finance.balanceEquity')}</h4>
                <LineItem label={t('finance.balancePaidInCapital')} value={0.0} />
                <LineItem label={t('finance.balanceRetainedEarnings')} value={0.0} />
                <div className="border-t border-[#e0ddd5] my-4"></div>
                <LineItem label={t('finance.balanceTotalLiabilitiesEquity')} value={0.0} bold primary />
              </div>
            </div>
          </div>
        )}

        {/* === Cashflow (placeholder) === */}
        {activeTab === 'cashflow' && (
          <div className="p-20 text-center text-[#5c5c5a] flex flex-col items-center">
            <i className="fas fa-faucet-drip text-6xl mb-6 opacity-20"></i>
            <h3 className="text-xl font-medium">{t('finance.cashflowTitle')}</h3>
            <p className="mt-2 text-sm max-w-md">{t('finance.cashflowDesc')}</p>
            <button className="mt-8 px-6 py-2 bg-[#f9f9f8] rounded-xl text-sm hover:text-[#191918] transition-colors border border-[#e0ddd5]">
              {t('finance.cashflowSync')}
            </button>
          </div>
        )}
      </div>
    </div>
  );
};

// ─── US Schedule C Renderer ───
const USScheduleC: React.FC<{ data: any; fmt: (v: number) => string }> = ({ data, fmt }) => {
  const lines = [
    { label: 'Line 1 — Gross Receipts', key: 'line1_grossReceipts', bold: true },
    { label: 'Line 2 — Returns & Allowances', key: 'line2_returns', indent: true },
    { label: 'Line 6 — Other Income', key: 'line6_otherIncome', indent: true },
    { label: 'Line 7 — Gross Income', key: 'line7_grossIncome', bold: true, primary: true },
    { label: '', key: '_sep1', separator: true },
    { label: 'Line 8 — Advertising', key: 'line8_advertising', indent: true },
    { label: 'Line 9 — Car & Truck', key: 'line9_car', indent: true },
    { label: 'Line 10 — Commissions', key: 'line10_commissions', indent: true },
    { label: 'Line 11 — Contract Labor', key: 'line11_contract', indent: true },
    { label: 'Line 13 — Depreciation', key: 'line13_depreciation', indent: true },
    { label: 'Line 15 — Insurance', key: 'line15_insurance', indent: true },
    { label: 'Line 16b — Interest', key: 'line16b_interest', indent: true },
    { label: 'Line 17 — Legal & Professional', key: 'line17_legal', indent: true },
    { label: 'Line 18 — Office Expense', key: 'line18_office', indent: true },
    { label: 'Line 20 — Rent', key: 'line20_rent', indent: true },
    { label: 'Line 21 — Repairs', key: 'line21_repairs', indent: true },
    { label: 'Line 22 — Supplies', key: 'line22_supplies', indent: true },
    { label: 'Line 23 — Taxes & Licenses', key: 'line23_taxes', indent: true },
    { label: 'Line 24a — Travel', key: 'line24a_travel', indent: true },
    { label: 'Line 24b — Meals (50%)', key: 'line24b_meals', indent: true },
    { label: 'Line 25 — Utilities', key: 'line25_utilities', indent: true },
    { label: 'Line 26 — Wages', key: 'line26_wages', indent: true },
    { label: 'Line 27a — Other', key: 'line27a_other', indent: true },
    { label: 'Line 30 — Home Office', key: 'line30_homeOffice', indent: true },
    { label: '', key: '_sep2', separator: true },
    { label: 'Line 28 — Total Expenses', key: 'line28_totalExpenses', bold: true },
    { label: 'Line 31 — Net Profit (or Loss)', key: 'line31_netProfit', bold: true, success: true },
  ];

  return (
    <div className="space-y-1">
      {lines.map((l) => {
        if (l.separator) return <div key={l.key} className="border-t border-[#e0ddd5] my-3"></div>;
        const val = data[l.key] || 0;
        if (!l.bold && val === 0) return null; // Hide zero expense lines
        return <LineItem key={l.key} label={l.label} value={val} bold={l.bold} indent={l.indent} primary={l.primary} success={l.success} />;
      })}
    </div>
  );
};

// ─── Generic P&L Renderer (CN/JP/EU/KR/TW) ───
const GenericPL: React.FC<{
  is: any; fs: any; fallbackPL: any; fmt: (v: number) => string;
  t: (key: string) => string; locale: string;
  vatSummary?: any; taxIncSummary?: any;
}> = ({ is, fs, fallbackPL, fmt, t, locale, vatSummary, taxIncSummary }) => {
  const pl = is || {
    salesRevenue: fs.salesRevenue,
    costOfSales: fs.costOfSales,
    grossProfit: fallbackPL.grossProfit,
    grossMargin: fallbackPL.grossMargin,
    taxSurcharge: fs.taxSurcharge,
    shippingFee: fs.shippingFee,
    adminExpense: fs.adminExpense,
    incomeTax: fs.incomeTax,
    netProfit: fallbackPL.netProfit,
    netMargin: fallbackPL.netMargin,
  };

  return (
    <div className="space-y-8">
      {/* P&L */}
      <div className="space-y-1">
        <LineItem label={t('finance.plRevenue')} value={pl.salesRevenue || pl.revenue || 0} bold primary />
        <LineItem label={t('finance.plCost')} value={pl.costOfSales || pl.costOfSales || 0} indent />
        <LineItem label={t('finance.plGrossProfit')} value={pl.grossProfit || 0} bold primary />
        {pl.taxSurcharge != null && <LineItem label={t('finance.plTaxSurcharge')} value={pl.taxSurcharge} indent />}
        {pl.shippingFee != null && <LineItem label={t('finance.plShipping')} value={pl.shippingFee} indent />}
        <LineItem label={t('finance.plAdmin')} value={pl.adminExpense || pl.operatingProfit != null ? (pl.adminExpense || 0) : 0} indent />
        <LineItem label={t('finance.plIncomeTax')} value={pl.incomeTax || 0} indent />
        <LineItem label={t('finance.plNetProfit')} value={pl.netProfit || 0} bold success />
        <LineItem label={t('finance.plNetMargin')} value={`${(pl.netMargin || 0).toFixed(2)}%`} indent />
      </div>

      {/* VAT / Consumption Tax / Business Tax */}
      {vatSummary && (
        <div className="border-t border-[#e0ddd5] pt-6 space-y-1">
          <h3 className="text-lg font-bold text-[#191918] mb-4 flex items-center">
            <i className="fas fa-calculator mr-3 text-[#4a4a48]"></i>
            {t('dashboard.vatTitle')}
          </h3>
          <LineItem label={t('dashboard.vatInputTotal')} value={vatSummary.cumulativeInput || vatSummary.paid || vatSummary.inputVAT || 0} />
          <LineItem label={t('dashboard.vatOutputTotal')} value={vatSummary.cumulativeOutput || vatSummary.collected || vatSummary.outputVAT || 0} />
          <LineItem label={t('dashboard.vatEstimated')} value={vatSummary.estimatedPayable || vatSummary.payable || vatSummary.vatPayable || 0} bold primary />
        </div>
      )}

      {/* Tax-inclusive summary */}
      {taxIncSummary && (
        <div className="border-t border-[#e0ddd5] pt-6 space-y-1">
          <h3 className="text-lg font-bold text-[#191918] mb-4 flex items-center">
            <i className="fas fa-balance-scale mr-3 text-emerald-400"></i>
            {t('dashboard.taxSummaryTitle')}
          </h3>
          <LineItem label={t('dashboard.taxSummaryPurchase')} value={taxIncSummary.purchaseTotal || 0} />
          <LineItem label={t('dashboard.taxSummarySales')} value={taxIncSummary.salesTotal || 0} />
          <LineItem label={t('dashboard.taxSummaryDiff')} value={taxIncSummary.difference || 0} bold success />
        </div>
      )}
    </div>
  );
};

// ─── Shared LineItem ───
interface LineItemProps {
  label: string;
  value: number | string;
  bold?: boolean;
  indent?: boolean;
  primary?: boolean;
  success?: boolean;
}

const LineItem: React.FC<LineItemProps> = ({ label, value, bold, indent, primary, success }) => (
  <div className={`flex justify-between items-center py-3 px-4 rounded-xl transition-colors hover:bg-[#f0eeeb]/50 ${bold ? 'font-bold' : ''} ${primary ? 'bg-[#d97757]/5' : ''} ${success ? 'bg-emerald-500/5' : ''}`}>
    <span className={`text-sm ${indent ? 'pl-8 text-[#4a4a48]' : 'text-[#191918]'}`}>{label}</span>
    <span className={`text-base font-mono ${primary ? 'text-[#d97757]' : success ? 'text-emerald-600' : 'text-[#4a4a48]'}`}>
      {typeof value === 'number' ? value.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 }) : value}
    </span>
  </div>
);

export default FinancePage;
