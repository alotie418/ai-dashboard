
import React, { useState, useEffect, useCallback, useRef } from 'react';
import { useTranslation } from 'react-i18next';
import { BusinessData } from '../types';
import { generateReport, fetchSettings, exportReportPdf, isDesktop, fetchBalanceOverview, type ReportResult, type BalanceOverview } from '../services/api';
import { formatMoney, getTaxLabel, getCurrencySymbol, shouldShowTaxModule, shouldShowTaxInclusiveSummary } from './accountingHelpers';
import { BALANCE_CLASSIFICATION } from './accountingClassification';

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
  // PR-7B P1-4: 管理口径资产负债概览（只读，来自 GET /api/balance-overview）。非法定 B/S。
  const [balanceOverview, setBalanceOverview] = useState<BalanceOverview | null>(null);
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
      // 管理口径资产负债概览（只读·非阻断：失败不影响 P&L）。年度口径，与 P&L 一致。
      try { setBalanceOverview(await fetchBalanceOverview({ year: selectedYear })); }
      catch { setBalanceOverview(null); }
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
    // Match the report engine's rounding (Math.round(x*10000)/100, half-up) so the
    // no-report fallback path agrees with the engine-sourced KPI cards / P&L table.
    const grossMargin = revenue === 0 ? 0 : Math.round(grossProfit / revenue * 10000) / 100;
    const netMargin = revenue === 0 ? 0 : Math.round(netProfit / revenue * 10000) / 100;
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
          <button onClick={() => setPdfMsg(null)} aria-label={t('common.close')} className="ml-3 opacity-50 hover:opacity-100"><i className="fas fa-times"></i></button>
        </div>
      )}

      {/* Quick KPIs.
          US keeps its 3 legitimate cards (net profit / Schedule C gross income / quarterly tax).
          Non-US shows real, already-computed P&L figures: net profit / gross margin / net margin.
          The previous non-US cards were misleading — "debt ratio" actually rendered the gross
          margin under a balance-sheet label, and "current ratio" was a hardcoded 0.0. Neither is
          computed (the Balance Sheet stays a "not enabled yet" tab), so they are removed. This is
          display-only: grossMargin / netMargin come from the report engine (with the existing
          fallbackPL), no new accounting calculation. */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
        <div className="bg-white/80 border border-[#e0ddd5] p-6 rounded-xl">
          <p className="text-[#5c5c5a] text-[10px] uppercase font-bold tracking-widest mb-1">{locale === 'US' ? t('finance.kpiNetAssets') : t('finance.kpiNetProfit')}</p>
          <h4 className="text-2xl font-bold text-[#191918] tracking-tight">{fmt(report?.incomeStatement?.netProfit || report?.profitLoss?.netProfit || report?.scheduleC?.line31_netProfit || 0)}</h4>
        </div>
        <div className="bg-white/80 border border-[#e0ddd5] p-6 rounded-xl">
          <p className="text-[#5c5c5a] text-[10px] uppercase font-bold tracking-widest mb-1">{locale === 'US' ? getTaxLabel(locale, i18n.language, 'kpiGrossIncome') : t('finance.kpiGrossMargin')}</p>
          <h4 className="text-2xl font-bold text-[#191918] tracking-tight">
            {locale === 'US' ? fmt(report?.scheduleC?.line7_grossIncome || 0) : `${((getIncomeStatement()?.grossMargin ?? fallbackPL.grossMargin) || 0).toFixed(2)}%`}
          </h4>
        </div>
        <div className="bg-white/80 border border-[#e0ddd5] p-6 rounded-xl">
          <p className="text-[#5c5c5a] text-[10px] uppercase font-bold tracking-widest mb-1">
            {locale === 'US' ? getTaxLabel(locale, i18n.language, 'kpiQuarterlyTax') : t('finance.kpiNetMargin')}
          </p>
          <h4 className="text-2xl font-bold text-[#191918] tracking-tight">
            {locale === 'US' ? fmt(report?.estimatedTax?.quarterlyPayment || 0) : `${((getIncomeStatement()?.netMargin ?? fallbackPL.netMargin) || 0).toFixed(2)}%`}
          </h4>
        </div>
      </div>

      {/* Tabs */}
      <div className="flex bg-white/80 p-1.5 rounded-xl border border-[#e0ddd5] w-fit">
        <button onClick={() => setActiveTab('pl')} className={`px-6 py-2 rounded-lg text-sm font-medium transition-all ${activeTab === 'pl' ? 'bg-primary text-white' : 'text-[#4a4a48] hover:text-[#191918]'}`} style={activeTab === 'pl' ? { boxShadow: '0 4px 16px rgba(39,76,146,0.15)' } : {}}>
          {plTabLabel}
        </button>
        <button data-testid="finance-tab-balance" onClick={() => setActiveTab('balance')} className={`px-6 py-2 rounded-lg text-sm font-medium transition-all ${activeTab === 'balance' ? 'bg-primary text-white' : 'text-[#4a4a48] hover:text-[#191918]'}`} style={activeTab === 'balance' ? { boxShadow: '0 4px 16px rgba(39,76,146,0.15)' } : {}}>
          {t('finance.tabBalance')}
        </button>
        <button onClick={() => setActiveTab('cashflow')} className={`px-6 py-2 rounded-lg text-sm font-medium transition-all ${activeTab === 'cashflow' ? 'bg-primary text-white' : 'text-[#4a4a48] hover:text-[#191918]'}`} style={activeTab === 'cashflow' ? { boxShadow: '0 4px 16px rgba(39,76,146,0.15)' } : {}}>
          {t('finance.tabCashflow')}
        </button>
      </div>

      {/* Loading / Error */}
      {loading && (
        <div className="text-center py-8 text-sm text-[#5c5c5a]">
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

        {/* === 管理口径资产负债概览（PR-7B P1-4）—— 非法定资产负债表 ===
            按币种展示 资产/负债/权益 + 显式「平衡差额／待调整」(始终显示·不可隐藏) + 免责。
            金额按「币种代码 + 千分位」展示，不折算、不用 locale 货币符号。数据来自只读 /api/balance-overview。
            无数据时回退到「需先录入账户/交易数据」的空态（功能已就绪，非未实现）。 */}
        {activeTab === 'balance' && !loading && (
          balanceOverview?.byCurrency?.length ? (
            <div className="p-6 md:p-10">
              <div className="max-w-6xl mx-auto space-y-6">
                {/* 顶部标题左对齐：标题 + 期间 + 估算徽标 */}
                <div className="flex flex-wrap items-center gap-x-4 gap-y-2">
                  <h2 className="text-2xl font-bold text-[#191918]">{t('finance.balanceOverviewTitle')}</h2>
                  <span className="text-[#5c5c5a] text-sm">{periodDisplay}</span>
                  <span className="inline-flex items-center px-3 py-1 rounded-full text-[11px] bg-[#f0eeeb] text-[#5c5c5a] border border-[#e0ddd5]">
                    <i className="fas fa-circle-info mr-1.5"></i>{t('finance.balanceEstimateBadge')}
                  </span>
                </div>
                {/* 免责：管理口径估算 / 非法定 / 未做严格平衡（更轻的 notice·降低视觉重心·保留全文） */}
                <div className="text-[11px] text-[#5c5c5a] bg-[#f9f9f8]/70 border border-[#e0ddd5] rounded-lg px-4 py-2 leading-relaxed">
                  <p><i className="fas fa-circle-info mr-1.5 text-[#8a8a88]"></i>{t('finance.balanceOverviewDisclaimer')}</p>
                  <p className="mt-0.5 text-[#8a8a88]">{t('disclaimer.report')}</p>
                </div>

                {balanceOverview.byCurrency.map((blk) => {
                  const ccyAmt = (v: number) => {
                    const num = (Number(v) || 0).toLocaleString(i18n.language, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
                    return blk.currency ? `${blk.currency} ${num}` : num;
                  };
                  const lineLabel = (key: string) => {
                    // P2-3：固定资产行显示「固定资产（净值）」。
                    if (key === 'fixedAssets') return t('finance.balanceFixedNet');
                    // P2-4b：权益两行特判（不进 BALANCE_CLASSIFICATION，避开 check-balance-classify 红线）。
                    if (key === 'contributedCapital') return t('finance.balanceCapital');      // 公司=实收资本
                    if (key === 'ownerCapital') return t('finance.balanceOwnerCapital');        // 个体=业主资本
                    if (key === 'retainedEarnings') return t('finance.balanceRetained');        // 未分配利润
                    // P3-4：所得税应交/预缴特判（仅所得税·估算·本位币；同 P2-4b 不进 BALANCE_CLASSIFICATION）。
                    if (key === 'incomeTaxPayable') return t('finance.balanceIncomeTaxPayable');  // 应交税费（所得税·估算）
                    if (key === 'incomeTaxPrepaid') return t('finance.balanceIncomeTaxPrepaid');  // 预缴税款（所得税·估算）
                    const e = (BALANCE_CLASSIFICATION as Record<string, { labelKey: string }>)[key];
                    return e ? t(e.labelKey) : key;
                  };
                  type Meta = { originalValue: number; accumulatedDepreciation: number };
                  // 明细行（栏内）：左 label 可换行，右金额 monospace 右对齐、不换行，避免重叠 / 横向滚动。
                  const lineRow = (l: { key: string; amount: number; meta?: Meta }, pfx: string, i: number) => (
                    <div key={`${pfx}${i}`} className="px-1 py-1.5">
                      <div className="flex items-baseline justify-between gap-3">
                        <span className="text-sm text-[#4a4a48] min-w-0 break-words">{lineLabel(l.key)}</span>
                        <span className="text-sm font-mono text-[#191918] shrink-0 whitespace-nowrap tabular-nums">{ccyAmt(l.amount)}</span>
                      </div>
                      {/* 辅助说明（低视觉权重·保留全文）：固定资产原值 / 累计折旧（直线法估算，非法定/税务折旧）。 */}
                      {l.key === 'fixedAssets' && l.meta && (
                        <div className="mt-0.5 text-[10px] text-[#a3a3a1] leading-snug">
                          {t('finance.balanceOriginalValue')} {ccyAmt(l.meta.originalValue)} · {t('finance.balanceAccumulatedDepreciation')} {ccyAmt(l.meta.accumulatedDepreciation)}
                          <span className="ml-1">· {t('finance.balanceFixedNetHint')}</span>
                        </div>
                      )}
                      {/* P2-4b 未分配利润：本位币口径 · 管理估算（未做年结）。 */}
                      {l.key === 'retainedEarnings' && (
                        <div className="mt-0.5 text-[10px] text-[#a3a3a1] leading-snug">{t('finance.balanceRetainedHint')}</div>
                      )}
                      {/* P3-4 所得税应交/预缴：本位币 · 同税种同期间对冲 · 管理估算。 */}
                      {(l.key === 'incomeTaxPayable' || l.key === 'incomeTaxPrepaid') && (
                        <div className="mt-0.5 text-[10px] text-[#a3a3a1] leading-snug">{t('finance.balanceIncomeTaxHint')}</div>
                      )}
                    </div>
                  );
                  // 分区内小标题（流动 / 非流动）：结构性标签，加黑加粗保证清晰。
                  const subHdr = (label: string) => (
                    <div className="px-1 pt-2 pb-0.5 text-[11px] font-bold tracking-wide text-[#191918]">{label}</div>
                  );
                  // 顶部 KPI 小卡（每个数字只出现一次；差额=主题色卡·始终显示·不可隐藏）。
                  // 标签不 truncate（保留完整文案：长标签换行·flex 底对齐使各卡数字对齐）。
                  const kpi = (label: string, v: number, accent?: boolean) => (
                    <div className={`flex flex-col justify-between rounded-lg border px-3.5 py-3 overflow-hidden ${accent ? 'bg-primary/5 border-primary/25' : 'bg-[#f6f6f4] border-[#eceae6]'}`}>
                      <p className="text-xs font-bold tracking-wide text-[#191918] leading-tight">{label}</p>
                      <p className={`mt-1.5 font-mono text-base md:text-lg font-bold whitespace-nowrap tabular-nums ${accent ? 'text-primary' : 'text-[#191918]'}`}>{ccyAmt(v)}</p>
                    </div>
                  );
                  // 分区卡（资产 / 负债 / 所有者权益）：独立卡片·高度自适应·空分区显示占位「—」
                  const section = (title: string, empty: boolean, body: React.ReactNode) => (
                    <div className="rounded-lg border border-[#e0ddd5] bg-white/70 overflow-hidden">
                      <div className="px-4 py-2 text-xs font-bold text-[#191918] bg-[#f9f9f8]/70 border-b border-[#e0ddd5]/70">{title}</div>
                      <div className="px-3 py-2">
                        {empty ? <div className="py-4 text-center text-sm text-[#c4c4c2]">—</div> : body}
                      </div>
                    </div>
                  );
                  const assetsEmpty = blk.assets.current.length + blk.assets.nonCurrent.length === 0;
                  const liabEmpty = blk.liabilities.current.length + blk.liabilities.nonCurrent.length === 0;
                  const equityEmpty = blk.equity.length === 0;
                  return (
                    <div key={blk.currency ?? 'null'} className="rounded-xl border border-[#e8e6e1] bg-white/40 overflow-hidden">
                      {/* 卡头：币种 */}
                      <div className="flex items-center px-5 py-3 border-b border-[#e8e6e1] bg-[#f9f9f8]/60">
                        <span className="text-sm font-bold text-[#191918]"><i className="fas fa-coins mr-2 text-[#8a8a88]"></i>{blk.currency ?? t('finance.balanceCurrencyUnspecified')}</span>
                      </div>
                      <div className="p-4 md:p-5 space-y-4">
                        {/* 顶部 4 个 KPI 小卡：资产总计 / 负债合计 / 所有者权益 / 平衡差额（差额=主题色卡·始终显示） */}
                        <div className="grid grid-cols-2 lg:grid-cols-4 gap-2.5">
                          {kpi(t('finance.balanceTotalAssets'), blk.totals.assets)}
                          {kpi(t('finance.balanceTotalLiabilities'), blk.totals.liabilities)}
                          {kpi(t('finance.balanceEquity'), blk.totals.equity)}
                          {kpi(t('finance.balanceDifference'), blk.balanceDifference, true)}
                        </div>
                        {/* 明细：桌面 3 张独立分区卡·高度自适应（消除空栏留白），移动端堆叠 */}
                        <div className="grid grid-cols-1 lg:grid-cols-3 gap-3 items-start">
                          {section(t('finance.balanceAssets'), assetsEmpty, (
                            <>
                              {blk.assets.current.length > 0 && subHdr(t('finance.balanceCurrentAssets'))}
                              {blk.assets.current.map((l, i) => lineRow(l, 'ac', i))}
                              {blk.assets.nonCurrent.length > 0 && subHdr(t('finance.balanceNonCurrentAssets'))}
                              {blk.assets.nonCurrent.map((l, i) => lineRow(l, 'anc', i))}
                            </>
                          ))}
                          {section(t('finance.balanceLiabilities'), liabEmpty, (
                            <>
                              {blk.liabilities.current.length > 0 && subHdr(t('finance.balanceCurrentLiabilities'))}
                              {blk.liabilities.current.map((l, i) => lineRow(l, 'lc', i))}
                              {blk.liabilities.nonCurrent.length > 0 && subHdr(t('finance.balanceNonCurrentLiabilities'))}
                              {blk.liabilities.nonCurrent.map((l, i) => lineRow(l, 'lnc', i))}
                            </>
                          ))}
                          {section(t('finance.balanceEquity'), equityEmpty, (
                            <>
                              {blk.equity.map((l, i) => lineRow(l, 'eq', i))}
                            </>
                          ))}
                        </div>
                      </div>
                      {/* warnings（保留在卡底） */}
                      {blk.warnings?.includes('borrowingsNullMaturityDefaultCurrent') && (
                        <div className="px-5 py-2 text-[11px] text-amber-600 border-t border-[#e8e6e1]">
                          <i className="fas fa-info-circle mr-1"></i>{t('finance.balanceBorrowingsNullMaturity')}
                        </div>
                      )}
                      {/* P3-4 亏损期所得税估算 caveat：预缴行不代表真实预缴 */}
                      {blk.warnings?.includes('incomeTaxLossPeriodCaveat') && (
                        <div className="px-5 py-2 text-[11px] text-amber-600 border-t border-[#e8e6e1]">
                          <i className="fas fa-info-circle mr-1"></i>{t('finance.balanceIncomeTaxLossCaveat')}
                        </div>
                      )}
                    </div>
                  );
                })}
              </div>
            </div>
          ) : (
            <div className="p-20 text-center text-[#5c5c5a] flex flex-col items-center">
              <i className="fas fa-scale-balanced text-6xl mb-6 opacity-20"></i>
              <h3 className="text-xl font-medium">{t('finance.balanceComingSoonTitle')}</h3>
              <p className="mt-2 text-sm max-w-md">{t('finance.balanceComingSoonDesc')}</p>
              <span className="mt-6 inline-flex items-center px-3 py-1 rounded-full text-[11px] bg-[#f0eeeb] text-[#5c5c5a] border border-[#e0ddd5]">
                <i className="fas fa-circle-info mr-1.5"></i>{t('finance.comingSoonBadge')}
              </span>
            </div>
          )
        )}

        {/* === Cash Flow — operating activities MVP (management / cash basis, PR-7C) ===
            Real operating figures from recorded payments; investing / financing /
            beginning / ending cash render as "not configured" (never 0). Falls back to
            a "needs data" empty state (feature is ready, not unimplemented) if the engine did not attach a cashflowStatement. */}
        {activeTab === 'cashflow' && !loading && (
          report?.cashflowStatement ? (
            <div className="p-10">
              <div className="max-w-3xl mx-auto space-y-6">
                <div className="text-center mb-2">
                  <h2 className="text-2xl font-bold text-[#191918]">{t('finance.cashflowOperatingTitle')}</h2>
                  <p className="text-[#5c5c5a] text-sm">{periodDisplay}</p>
                </div>
                {/* Basis notice: management / cash basis / NOT statutory; differs from the accrual P&L. */}
                <div className="text-xs text-amber-700 bg-amber-50 border border-amber-200 rounded-lg px-4 py-2.5 space-y-1">
                  <p><i className="fas fa-info-circle mr-1.5"></i>{t('finance.cashflowBasisNote')}</p>
                  <p>{t('finance.cashflowVsPlNote')}</p>
                </div>
                {/* Operating activities — real figures */}
                <div className="border border-[#e0ddd5] rounded-xl overflow-hidden">
                  <div className="bg-[#f9f9f8]/60 px-6 py-3 text-sm font-bold text-[#191918]">{t('finance.cashflowOperatingTitle')}</div>
                  <div className="divide-y divide-[#e0ddd5]">
                    <div className="flex justify-between px-6 py-3 text-sm"><span className="text-[#4a4a48]">{t('finance.cashflowInflow')}</span><span className="font-mono text-[#191918]">{fmt(report.cashflowStatement.operating.inflow)}</span></div>
                    <div className="flex justify-between px-6 py-3 text-sm"><span className="text-[#4a4a48]">{t('finance.cashflowOutflow')}</span><span className="font-mono text-[#191918]">{fmt(report.cashflowStatement.operating.outflow)}</span></div>
                    <div className="flex justify-between px-6 py-3 text-sm font-bold bg-[#f9f9f8]/40"><span className="text-[#191918]">{t('finance.cashflowNet')}</span><span className="font-mono text-[#191918]">{fmt(report.cashflowStatement.operating.net)}</span></div>
                  </div>
                </div>
                {/* Investing / Financing / Beginning / Ending cash — not configured (never 0) */}
                <div className="border border-[#e0ddd5] rounded-xl overflow-hidden divide-y divide-[#e0ddd5]">
                  {[t('finance.cashflowInvesting'), t('finance.cashflowFinancing'), t('finance.cashflowBeginning'), t('finance.cashflowEnding')].map((label, i) => (
                    <div key={i} className="flex justify-between px-6 py-3 text-sm"><span className="text-[#4a4a48]">{label}</span><span className="text-[#5c5c5a] italic">{t('finance.cashflowNotConfigured')}</span></div>
                  ))}
                </div>
              </div>
            </div>
          ) : (
            <div className="p-20 text-center text-[#5c5c5a] flex flex-col items-center">
              <i className="fas fa-faucet-drip text-6xl mb-6 opacity-20"></i>
              <h3 className="text-xl font-medium">{t('finance.cashflowTitle')}</h3>
              <p className="mt-2 text-sm max-w-md">{t('finance.cashflowDesc')}</p>
              <span className="mt-6 inline-flex items-center px-3 py-1 rounded-full text-[11px] bg-[#f0eeeb] text-[#5c5c5a] border border-[#e0ddd5]">
                <i className="fas fa-circle-info mr-1.5"></i>{t('finance.comingSoonBadge')}
              </span>
            </div>
          )
        )}
      </div>

      {/* PR-E1: the report is a management estimate, not a statutory financial statement. */}
      <p className="text-[11px] text-[#5c5c5a] leading-snug px-2">
        <i className="fas fa-circle-info mr-1.5"></i>{t('disclaimer.report')}
      </p>
      {/* Phase 2: gentle data-source notice — business records and 收支记录 are separate
          ledgers; reconcile when both are used in the same period. */}
      <p className="text-[11px] text-[#5c5c5a] leading-snug px-2">
        <i className="fas fa-circle-info mr-1.5"></i>{t('common.dataSourceNote')}
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
        <LineItem label={t('finance.kpiGrossMargin')} value={`${(pl.grossMargin || 0).toFixed(2)}%`} indent />
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
          <p className="px-4 pt-1 text-[10px] text-[#5c5c5a] leading-snug">{t('disclaimer.tax')}</p>
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
