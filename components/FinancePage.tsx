
import React, { useState, useEffect, useCallback, useRef } from 'react';
import { useTranslation } from 'react-i18next';
import { BusinessData } from '../types';
import { generateReport, fetchSettings, exportReportPdf, isDesktop, type ReportResult } from '../services/api';
import { formatMoney, getTaxLabel, getCurrencySymbol, shouldShowTaxModule, shouldShowTaxInclusiveSummary } from './accountingHelpers';

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
  // Initialize locale from parent BusinessData if available, so first render
  // uses the correct currency symbol instead of defaulting to CN.
  const [locale, setLocale] = useState<string>((data as any)?.locale || 'CN');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // PDF export (desktop-only) — company name for the PDF header + export status
  const [companyName, setCompanyName] = useState('');
  const [pdfBusy, setPdfBusy] = useState(false);
  const [pdfMsg, setPdfMsg] = useState<{ type: 'success' | 'error' | 'info'; text: string } | null>(null);
  const reportRef = useRef<HTMLDivElement>(null);

  // Eagerly hydrate locale from settings on mount, independent of report fetch.
  // This guarantees the KPI cards render with the correct currency even if
  // generateReport() later fails.
  useEffect(() => {
    fetchSettings().then((s: any) => {
      if (s?.accounting_locale) setLocale(s.accounting_locale);
      setCompanyName(s?.company_info?.name || s?.company_name || '');
    }).catch(() => {});
  }, []);

  // Keep locale in sync with parent data when it changes (e.g. after onboarding)
  useEffect(() => {
    const parentLocale = (data as any)?.locale;
    if (parentLocale && parentLocale !== locale) setLocale(parentLocale);
  }, [data]);

  const loadReport = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const settings = await fetchSettings();
      const loc = (settings as any).accounting_locale || 'CN';
      setLocale(loc);
      setCompanyName((settings as any)?.company_info?.name || (settings as any)?.company_name || '');
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
    const cost = fs.costOfSales; // PR-T5-2A: now COGS-only
    const operating = fs.operatingExpenses ?? 0; // 0 for US / pre-split payloads
    const grossProfit = revenue - cost;
    const netProfit = revenue - cost - operating - fs.taxSurcharge - fs.shippingFee - fs.adminExpense - fs.incomeTax;
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
  // Balance Sheet / Cash Flow show a "not enabled yet" empty state (PR-T1):
  // full calculation isn't implemented, so we no longer render a zero-filled
  // statement that could read as a real report. P&L / Schedule C stay fully
  // computed and locale-aware via getTaxLabel below.

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

  // ─── PDF export (desktop-only · Electron printToPDF) ───
  const escapeHtml = (s: string) =>
    String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');

  // Extract the on-screen statement rows from the rendered report DOM. This guarantees
  // the PDF matches the screen and reuses the already-localized labels (getTaxLabel /
  // t / formatMoney) — no duplication of accounting-regime logic.
  const extractRows = (): Array<{ kind: 'header' | 'row'; label: string; value?: string; indent?: boolean }> => {
    const root = reportRef.current;
    if (!root) return [];
    const out: Array<{ kind: 'header' | 'row'; label: string; value?: string; indent?: boolean }> = [];
    root.querySelectorAll('h3, h4, div.justify-between').forEach((el) => {
      const tag = el.tagName.toLowerCase();
      if (tag === 'h3' || tag === 'h4') {
        const label = (el.textContent || '').trim();
        if (label) out.push({ kind: 'header', label });
      } else {
        const spans = el.querySelectorAll(':scope > span');
        if (spans.length >= 2) {
          const label = (spans[0].textContent || '').trim();
          const value = (spans[1].textContent || '').trim();
          const indent = (spans[0].getAttribute('class') || '').includes('pl-8');
          if (label) out.push({ kind: 'row', label, value, indent });
        }
      }
    });
    return out;
  };

  // Build a self-contained print HTML document (inline CSS, no Tailwind / FontAwesome;
  // all user-supplied text escaped). Chromium renders all 6 UI languages natively.
  const buildPrintHtml = (reportName: string): string => {
    const rows = extractRows();
    const currency = getCurrencySymbol(locale);
    const generatedAt = new Date().toLocaleString(i18n.language);
    const body = rows.map((r) =>
      r.kind === 'header'
        ? `<tr class="section"><td colspan="2">${escapeHtml(r.label)}</td></tr>`
        : `<tr><td class="${r.indent ? 'indent' : ''}">${escapeHtml(r.label)}</td><td class="val">${escapeHtml(r.value || '')}</td></tr>`
    ).join('');
    return `<!DOCTYPE html><html lang="${escapeHtml(i18n.language)}"><head><meta charset="utf-8"><style>
*{box-sizing:border-box;}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Hiragino Sans","Hiragino Kaku Gothic ProN","Apple SD Gothic Neo","Microsoft YaHei","Noto Sans CJK SC",sans-serif;color:#191918;margin:0;padding:32px;font-size:13px;line-height:1.5;}
.hdr{border-bottom:2px solid #274C92;padding-bottom:14px;margin-bottom:18px;}
.company{font-size:20px;font-weight:700;}
.rname{font-size:15px;margin-top:4px;color:#333;}
.meta{margin-top:10px;font-size:11px;color:#5c5c5a;}
.meta span{margin-right:20px;}
table{width:100%;border-collapse:collapse;margin-top:4px;}
td{padding:7px 10px;border-bottom:1px solid #eee;}
td.val{text-align:right;white-space:nowrap;font-variant-numeric:tabular-nums;}
td.indent{padding-left:30px;color:#555;}
tr.section td{font-weight:700;padding-top:16px;border-bottom:2px solid #e0ddd5;}
.footer{margin-top:24px;font-size:10px;color:#8a8a88;border-top:1px solid #eee;padding-top:10px;}
</style></head><body>
<div class="hdr">
<div class="company">${escapeHtml(companyName || '—')}</div>
<div class="rname">${escapeHtml(reportName)}</div>
<div class="meta"><span>${escapeHtml(t('finance.pdfRegime'))}: ${escapeHtml(locale)}</span><span>${escapeHtml(t('finance.pdfPeriod'))}: ${escapeHtml(periodDisplay)}</span><span>${escapeHtml(t('finance.pdfCurrency'))}: ${escapeHtml(currency)}</span></div>
</div>
<table>${body}</table>
<div class="footer">${escapeHtml(t('disclaimer.report'))}<br>${escapeHtml(t('finance.pdfGeneratedAt'))}: ${escapeHtml(generatedAt)}</div>
</body></html>`;
  };

  const handleExportPdf = async () => {
    setPdfMsg(null);
    if (!isDesktop()) { setPdfMsg({ type: 'info', text: t('finance.pdfDesktopOnly') }); return; }
    setPdfBusy(true);
    try {
      const reportName = activeTab === 'pl'
        ? getTaxLabel(locale, i18n.language, 'plTitle')
        : activeTab === 'balance'
          ? t('finance.tabBalance')
          : t('finance.tabCashflow');
      const html = buildPrintHtml(reportName);
      const r = await exportReportPdf(html, `SoloLedger-${locale}-${activeTab}-${selectedYear}.pdf`);
      if (r.ok && r.path) setPdfMsg({ type: 'success', text: t('finance.pdfExported', { path: r.path }) });
      else if (r.error) setPdfMsg({ type: 'error', text: t('finance.pdfFailed') });
      // r.ok===false 且无 error = 用户取消保存框 → 静默
    } catch {
      setPdfMsg({ type: 'error', text: t('finance.pdfFailed') });
    } finally {
      setPdfBusy(false);
    }
  };

  // Tab labels driven by accountingLocale + uiLanguage
  const plTabLabel = getTaxLabel(locale, i18n.language, 'tabPlLabel');

  return (
    <div className="max-w-7xl mx-auto space-y-6 animate-in fade-in slide-in-from-bottom-4 duration-500">
      {/* Header */}
      <div className="flex justify-end space-x-3">
        <button onClick={exportCSV} className="flex items-center px-4 py-2 bg-white border border-[#e0ddd5] rounded-xl text-sm font-medium text-[#4a4a48] hover:text-[#191918] transition-all">
          <i className="fas fa-file-export mr-2 text-primary"></i> {t('finance.export')}
        </button>
        <button onClick={handleExportPdf} disabled={pdfBusy} className="flex items-center px-4 py-2 bg-white border border-[#e0ddd5] rounded-xl text-sm font-medium text-[#4a4a48] hover:text-[#191918] transition-all disabled:opacity-50">
          {pdfBusy ? <span className="mr-2 inline-block w-3 h-3 border-2 border-primary/30 border-t-primary rounded-full animate-spin"></span> : <i className="fas fa-file-pdf mr-2 text-primary"></i>} {t('finance.exportPdf')}
        </button>
        <button className="flex items-center px-4 py-2 bg-primary hover:bg-primary-hover text-white rounded-xl text-sm font-medium transition-all" style={{ boxShadow: '0 4px 16px rgba(39,76,146,0.15)' }}>
          <i className="fas fa-print mr-2"></i> {t('finance.print')}
        </button>
      </div>

      {pdfMsg && (
        <div className={`text-sm rounded-lg px-4 py-2 flex items-center justify-between ${pdfMsg.type === 'success' ? 'text-emerald-700 bg-emerald-50 border border-emerald-200' : pdfMsg.type === 'error' ? 'text-rose-600 bg-rose-50 border border-rose-200' : 'text-amber-700 bg-amber-50 border border-amber-200'}`}>
          <span className="break-all"><i className={`fas ${pdfMsg.type === 'success' ? 'fa-check-circle' : pdfMsg.type === 'error' ? 'fa-exclamation-circle' : 'fa-circle-info'} mr-2`}></i>{pdfMsg.text}</span>
          <button onClick={() => setPdfMsg(null)} className="ml-3 opacity-50 hover:opacity-100"><i className="fas fa-times"></i></button>
        </div>
      )}

      {/* Quick KPIs */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
        <div className="bg-white/80 border border-[#e0ddd5] p-6 rounded-xl">
          <p className="text-[#5c5c5a] text-[10px] uppercase font-bold tracking-widest mb-1">{t('finance.kpiNetAssets')}</p>
          <h4 className="text-2xl font-bold text-[#191918] tracking-tight">{fmt(report?.incomeStatement?.netProfit || report?.profitLoss?.netProfit || report?.scheduleC?.line31_netProfit || 0)}</h4>
        </div>
        <div className="bg-white/80 border border-[#e0ddd5] p-6 rounded-xl">
          <p className="text-[#5c5c5a] text-[10px] uppercase font-bold tracking-widest mb-1">{locale === 'US' ? getTaxLabel(locale, i18n.language, 'kpiGrossIncome') : t('finance.kpiDebtRatio')}</p>
          <h4 className="text-2xl font-bold text-[#191918] tracking-tight">
            {locale === 'US' ? fmt(report?.scheduleC?.line7_grossIncome || 0) : `${getIncomeStatement()?.grossMargin || 0}%`}
          </h4>
        </div>
        <div className="bg-white/80 border border-[#e0ddd5] p-6 rounded-xl">
          <p className="text-[#5c5c5a] text-[10px] uppercase font-bold tracking-widest mb-1">
            {locale === 'US' ? getTaxLabel(locale, i18n.language, 'kpiQuarterlyTax') : t('finance.kpiCurrentRatio')}
          </p>
          <h4 className="text-2xl font-bold text-[#191918] tracking-tight">
            {locale === 'US' ? fmt(report?.estimatedTax?.quarterlyPayment || 0) : '0.0'}
          </h4>
        </div>
      </div>

      {/* Tabs */}
      <div className="flex bg-white/80 p-1.5 rounded-xl border border-[#e0ddd5] w-fit">
        <button onClick={() => setActiveTab('pl')} className={`px-6 py-2 rounded-lg text-sm font-medium transition-all ${activeTab === 'pl' ? 'bg-primary text-white' : 'text-[#4a4a48] hover:text-[#191918]'}`} style={activeTab === 'pl' ? { boxShadow: '0 4px 16px rgba(39,76,146,0.15)' } : {}}>
          {plTabLabel}
        </button>
        <button onClick={() => setActiveTab('balance')} className={`px-6 py-2 rounded-lg text-sm font-medium transition-all ${activeTab === 'balance' ? 'bg-primary text-white' : 'text-[#4a4a48] hover:text-[#191918]'}`} style={activeTab === 'balance' ? { boxShadow: '0 4px 16px rgba(39,76,146,0.15)' } : {}}>
          {t('finance.tabBalance')}
        </button>
        <button onClick={() => setActiveTab('cashflow')} className={`px-6 py-2 rounded-lg text-sm font-medium transition-all ${activeTab === 'cashflow' ? 'bg-primary text-white' : 'text-[#4a4a48] hover:text-[#191918]'}`} style={activeTab === 'cashflow' ? { boxShadow: '0 4px 16px rgba(39,76,146,0.15)' } : {}}>
          {t('finance.tabCashflow')}
        </button>
      </div>

      {/* Loading / Error */}
      {loading && (
        <div className="text-center py-8 text-sm text-[#7a7a78]">
          <i className="fas fa-spinner fa-spin mr-2 text-primary"></i>{t('common.loading')}
        </div>
      )}
      {error && (
        <div className="text-sm text-amber-700 bg-amber-50 border border-amber-200 rounded-lg px-4 py-2">
          <i className="fas fa-exclamation-triangle mr-2"></i>{error}
        </div>
      )}

      {/* Statement Content */}
      <div ref={reportRef} className="bg-white/80 border border-[#e0ddd5] rounded-xl overflow-hidden" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.05)' }}>

        {/* === P&L / Schedule C tab === */}
        {activeTab === 'pl' && !loading && (
          <div className="p-10">
            <div className="max-w-4xl mx-auto space-y-6">
              <div className="text-center mb-10">
                <h2 className="text-2xl font-bold text-[#191918]">
                  {getTaxLabel(locale, i18n.language, 'plTitle')}
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
                <USScheduleC data={report.scheduleC} fmt={fmt} t={t} />
              ) : (
                <GenericPL
                  is={getIncomeStatement()}
                  fs={data.financialStatement}
                  fallbackPL={fallbackPL}
                  fmt={fmt}
                  t={t}
                  i18n={i18n}
                  locale={locale}
                  vatSummary={shouldShowTaxModule(locale) ? (report?.vatSummary || report?.consumptionTax || report?.vatReturn || report?.businessTax) : null}
                  taxIncSummary={shouldShowTaxInclusiveSummary(locale) ? report?.taxInclusiveSummary : null}
                />
              )}
            </div>
          </div>
        )}

        {/* === Balance Sheet — full calculation not enabled yet (PR-T1) === */}
        {activeTab === 'balance' && (
          <div className="p-20 text-center text-[#5c5c5a] flex flex-col items-center">
            <i className="fas fa-scale-balanced text-6xl mb-6 opacity-20"></i>
            <h3 className="text-xl font-medium">{t('finance.balanceComingSoonTitle')}</h3>
            <p className="mt-2 text-sm max-w-md">{t('finance.balanceComingSoonDesc')}</p>
            <span className="mt-6 inline-flex items-center px-3 py-1 rounded-full text-[11px] bg-[#f0eeeb] text-[#7a7a78] border border-[#e0ddd5]">
              <i className="fas fa-clock mr-1.5"></i>{t('finance.comingSoonBadge')}
            </span>
          </div>
        )}

        {/* === Cash Flow — full calculation not enabled yet (PR-T1) === */}
        {activeTab === 'cashflow' && (
          <div className="p-20 text-center text-[#5c5c5a] flex flex-col items-center">
            <i className="fas fa-faucet-drip text-6xl mb-6 opacity-20"></i>
            <h3 className="text-xl font-medium">{t('finance.cashflowTitle')}</h3>
            <p className="mt-2 text-sm max-w-md">{t('finance.cashflowDesc')}</p>
            <span className="mt-6 inline-flex items-center px-3 py-1 rounded-full text-[11px] bg-[#f0eeeb] text-[#7a7a78] border border-[#e0ddd5]">
              <i className="fas fa-clock mr-1.5"></i>{t('finance.comingSoonBadge')}
            </span>
          </div>
        )}
      </div>

      {/* PR-E1: the report is a management estimate, not a statutory financial statement. */}
      <p className="text-[11px] text-[#7a7a78] leading-snug px-2">
        <i className="fas fa-circle-info mr-1.5"></i>{t('disclaimer.report')}
      </p>
    </div>
  );
};

// ─── US Schedule C Renderer ───
// Schedule C is the IRS form name; line numbers are official.
// Line descriptions follow uiLanguage via usSchedule.* i18n keys.
const USScheduleC: React.FC<{ data: any; fmt: (v: number) => string; t: (key: string) => string }> = ({ data, fmt, t }) => {
  const lines: Array<{ i18nKey?: string; key: string; bold?: boolean; indent?: boolean; primary?: boolean; success?: boolean; separator?: boolean }> = [
    { i18nKey: 'usSchedule.line1', key: 'line1_grossReceipts', bold: true },
    { i18nKey: 'usSchedule.line2', key: 'line2_returns', indent: true },
    { i18nKey: 'usSchedule.line6', key: 'line6_otherIncome', indent: true },
    { i18nKey: 'usSchedule.line7', key: 'line7_grossIncome', bold: true, primary: true },
    { key: '_sep1', separator: true },
    { i18nKey: 'usSchedule.line8', key: 'line8_advertising', indent: true },
    { i18nKey: 'usSchedule.line9', key: 'line9_car', indent: true },
    { i18nKey: 'usSchedule.line10', key: 'line10_commissions', indent: true },
    { i18nKey: 'usSchedule.line11', key: 'line11_contract', indent: true },
    { i18nKey: 'usSchedule.line13', key: 'line13_depreciation', indent: true },
    { i18nKey: 'usSchedule.line15', key: 'line15_insurance', indent: true },
    { i18nKey: 'usSchedule.line16b', key: 'line16b_interest', indent: true },
    { i18nKey: 'usSchedule.line17', key: 'line17_legal', indent: true },
    { i18nKey: 'usSchedule.line18', key: 'line18_office', indent: true },
    { i18nKey: 'usSchedule.line20', key: 'line20_rent', indent: true },
    { i18nKey: 'usSchedule.line21', key: 'line21_repairs', indent: true },
    { i18nKey: 'usSchedule.line22', key: 'line22_supplies', indent: true },
    { i18nKey: 'usSchedule.line23', key: 'line23_taxes', indent: true },
    { i18nKey: 'usSchedule.line24a', key: 'line24a_travel', indent: true },
    { i18nKey: 'usSchedule.line24b', key: 'line24b_meals', indent: true },
    { i18nKey: 'usSchedule.line25', key: 'line25_utilities', indent: true },
    { i18nKey: 'usSchedule.line26', key: 'line26_wages', indent: true },
    { i18nKey: 'usSchedule.line27a', key: 'line27a_other', indent: true },
    { i18nKey: 'usSchedule.line30', key: 'line30_homeOffice', indent: true },
    { key: '_sep2', separator: true },
    { i18nKey: 'usSchedule.line28', key: 'line28_totalExpenses', bold: true },
    { i18nKey: 'usSchedule.line31', key: 'line31_netProfit', bold: true, success: true },
  ];

  return (
    <div className="space-y-1">
      {lines.map((l) => {
        if (l.separator) return <div key={l.key} className="border-t border-[#e0ddd5] my-3"></div>;
        const val = data[l.key] || 0;
        if (!l.bold && val === 0) return null;
        return <LineItem key={l.key} label={l.i18nKey ? t(l.i18nKey) : l.key} value={fmt(val)} bold={l.bold} indent={l.indent} primary={l.primary} success={l.success} />;
      })}
    </div>
  );
};

// ─── Generic P&L Renderer (CN/JP/EU/KR/TW) ───
const GenericPL: React.FC<{
  is: any; fs: any; fallbackPL: any; fmt: (v: number) => string;
  t: (key: string) => string; i18n: any; locale: string;
  vatSummary?: any; taxIncSummary?: any;
}> = ({ is, fs, fallbackPL, fmt, t, i18n, locale, vatSummary, taxIncSummary }) => {
  const pl = is || {
    salesRevenue: fs.salesRevenue,
    costOfSales: fs.costOfSales,
    costOfGoodsSold: fs.costOfGoodsSold,
    operatingExpenses: fs.operatingExpenses,
    operatingProfit: fs.operatingProfit,
    grossProfit: fallbackPL.grossProfit,
    grossMargin: fallbackPL.grossMargin,
    taxSurcharge: fs.taxSurcharge,
    shippingFee: fs.shippingFee,
    adminExpense: fs.adminExpense,
    incomeTax: fs.incomeTax,
    netProfit: fallbackPL.netProfit,
    netMargin: fallbackPL.netMargin,
  };
  // Pull P&L line labels from the accounting locale (per-locale, per-language)
  const lbl = (key: string) => getTaxLabel(locale, i18n.language, key);

  return (
    <div className="space-y-8">
      {/* P&L — labels driven by accountingLocale.taxConcepts */}
      <div className="space-y-1">
        <LineItem label={lbl('plRevenue')} value={fmt(pl.salesRevenue || pl.revenue || 0)} bold primary />
        <LineItem label={lbl('plCost')} value={fmt(pl.costOfSales || 0)} indent />
        <LineItem label={lbl('plGrossProfit')} value={fmt(pl.grossProfit || 0)} bold primary />
        {(pl.operatingExpenses ?? 0) > 0 && <LineItem label={lbl('plOperatingExpenses')} value={fmt(pl.operatingExpenses)} indent />}
        {pl.taxSurcharge != null && <LineItem label={lbl('plTaxSurcharge')} value={fmt(pl.taxSurcharge)} indent />}
        {pl.shippingFee != null && <LineItem label={lbl('plShipping')} value={fmt(pl.shippingFee)} indent />}
        <LineItem label={lbl('plAdmin')} value={fmt(pl.adminExpense || pl.operatingProfit != null ? (pl.adminExpense || 0) : 0)} indent />
        {pl.operatingProfit != null && <LineItem label={lbl('plOperatingProfit')} value={fmt(pl.operatingProfit)} bold primary />}
        <LineItem label={lbl('plIncomeTax')} value={fmt(pl.incomeTax || 0)} indent />
        <LineItem label={lbl('plNetProfit')} value={fmt(pl.netProfit || 0)} bold success />
        <LineItem label={t('finance.plNetMargin')} value={`${(pl.netMargin || 0).toFixed(2)}%`} indent />
      </div>

      {/* VAT / Consumption Tax / Business Tax — labels per accountingLocale */}
      {vatSummary && (
        <div className="border-t border-[#e0ddd5] pt-6 space-y-1">
          <h3 className="text-lg font-bold text-[#191918] mb-4 flex items-center">
            <i className="fas fa-calculator mr-3 text-[#4a4a48]"></i>
            {locale === 'JP' ? lbl('taxReportTitle') : lbl('taxTitle')}
          </h3>
          <LineItem label={lbl('inputTax')} value={fmt(vatSummary.cumulativeInput || vatSummary.paid || vatSummary.inputVAT || 0)} />
          <LineItem label={lbl('outputTax')} value={fmt(vatSummary.cumulativeOutput || vatSummary.collected || vatSummary.outputVAT || 0)} />
          <LineItem label={lbl('estimatedTax')} value={fmt(vatSummary.estimatedPayable || vatSummary.payable || vatSummary.vatPayable || 0)} bold primary />
          {/* PR-E1: estimated tax for management reference, not a filing basis. */}
          <p className="px-4 pt-1 text-[10px] text-[#7a7a78] leading-snug">{t('disclaimer.tax')}</p>
        </div>
      )}

      {/* Tax-inclusive summary — labels per accountingLocale */}
      {taxIncSummary && (
        <div className="border-t border-[#e0ddd5] pt-6 space-y-1">
          <h3 className="text-lg font-bold text-[#191918] mb-4 flex items-center">
            <i className="fas fa-balance-scale mr-3 text-emerald-400"></i>
            <span className="whitespace-nowrap">{lbl('taxSummaryTitle')}</span>
          </h3>
          <LineItem label={lbl('purchaseTotal')} value={fmt(taxIncSummary.purchaseTotal || 0)} />
          <LineItem label={lbl('salesTotal')} value={fmt(taxIncSummary.salesTotal || 0)} />
          <LineItem label={lbl('taxDifference')} value={fmt(taxIncSummary.difference || 0)} bold success />
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
  <div className={`flex justify-between items-center py-3 px-4 rounded-xl transition-colors hover:bg-[#f0eeeb]/50 ${bold ? 'font-bold' : ''} ${primary ? 'bg-primary/5' : ''} ${success ? 'bg-emerald-500/5' : ''}`}>
    <span className={`text-sm ${indent ? 'pl-8 text-[#4a4a48]' : 'text-[#191918]'}`}>{label}</span>
    <span className={`text-base font-mono ${primary ? 'text-primary' : success ? 'text-emerald-600' : 'text-[#4a4a48]'}`}>
      {/* Callers pre-format numeric values via formatMoney(); plain numbers render with default locale */}
      {typeof value === 'number' ? value.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 }) : value}
    </span>
  </div>
);

export default FinancePage;
