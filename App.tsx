import React, { useState, useEffect, useCallback, useRef, lazy, Suspense } from 'react';
import { useTranslation } from 'react-i18next';
import { MOCK_BUSINESS_DATA } from './constants';
import { fetchAIAnalysis } from './services/aiBriefingService';
import { AIAnalysis, BusinessData } from './types';
import { fetchDashboardData, fetchPurchases, fetchSettings, listProviders } from './services/api';
import { parseAiErrorCode, aiErrorMessage } from './services/aiErrors';
import MetricCard from './components/MetricCard';
import AIInsights from './components/AIInsights';
import FinancialStatementTable from './components/FinancialStatementTable';
import ProfitMarginIndicators from './components/ProfitMarginIndicators';
import VATStatistics from './components/VATStatistics';
import TaxInclusiveSummary from './components/TaxInclusiveSummary';
// Route-level code splitting: each page is loaded on demand (its own chunk) so the main
// index chunk only carries the app shell + the (eager) default dashboard. Pages render
// behind the <Suspense> boundary below; chunks are local files under dist/assets — no
// network, works fully offline (same mechanism as the existing xlsx / pdfjs lazy imports).
const SalesAndOutputPage = lazy(() => import('./components/SalesAndOutputPage'));
const PurchaseAndInputPage = lazy(() => import('./components/PurchaseAndInputPage'));
const DataAnalysisPage = lazy(() => import('./components/DataAnalysisPage'));
const InventoryPage = lazy(() => import('./components/InventoryPage'));
const FinancePage = lazy(() => import('./components/FinancePage'));
const SettingsPage = lazy(() => import('./components/SettingsPage'));
const AccountsPage = lazy(() => import('./components/AccountsPage'));
const TransactionsPage = lazy(() => import('./components/TransactionsPage'));
const DocumentsPage = lazy(() => import('./components/DocumentsPage'));
const USTaxToolsPage = lazy(() => import('./components/USTaxToolsPage'));
import USDashboardCards from './components/USDashboardCards';
import { formatMoney, getTaxLabel, getDashboardSections, getCurrencySymbol, buildAIFinanceContext, getInventoryUnitLabel, getProductUnitLabel } from './components/accountingHelpers';
import AlertCenter from './components/AlertCenter';
import OnboardingWizard from './components/OnboardingWizard';
import { AssistantProvider } from './components/assistant/AssistantProvider';
import AssistantWidget from './components/assistant/AssistantWidget';
const AssistantPage = lazy(() => import('./components/assistant/AssistantPage'));

// Suspense fallback while a lazy page chunk loads. Icon-only (no text) on purpose: chunks
// load from local disk in ~tens of ms, and a textless flash never trips the locale audit.
const PageFallback: React.FC = () => (
  <div className="flex items-center justify-center py-24 text-[#5c5c5a]">
    <i className="fas fa-spinner fa-spin text-2xl"></i>
  </div>
);

type PageId = 'dashboard' | 'sales' | 'purchase' | 'analysis' | 'inventory' | 'documents' | 'finance' | 'accounts' | 'transactions' | 'assistant' | 'ustax' | 'settings';

// Display names for the "switch provider" hint shown when Gemini hits its quota (429).
const AI_PROVIDER_LABELS: Record<string, string> = { openai: 'ChatGPT (OpenAI)', anthropic: 'Claude (Anthropic)', gemini: 'Gemini' };

const YEARS = ['2026', '2025', '2024'];
const QUARTERS = ['全年', 'Q1', 'Q2', 'Q3', 'Q4'];
const MONTHS = ['全部', '01月', '02月', '03月', '04月', '05月', '06月', '07月', '08月', '09月', '10月', '11月', '12月'];
const DATA_VERSION = 'cleared-2026-02-11';
const FILTER_SUPPORTED_PAGES: PageId[] = ['dashboard', 'sales', 'purchase', 'analysis', 'inventory', 'finance'];

// Dashboard KPI titles carry a parenthetical tax-basis suffix (e.g. "（不含税）",
// "(excl. tax)", "(HT)"). Split it off so MetricCard can render the title and the
// suffix as two stable lines — consistent at any card width — instead of relying on
// CSS to wrap the combined string (which only happens when the card is narrow).
// Locale-agnostic: matches a trailing full-width （）or half-width () group. No
// match (e.g. US "Total Expenses") → subtitle undefined → single line, unchanged.
const splitTaxBasis = (full: string): { label: string; subtitle?: string } => {
  const m = full.match(/^(.*?)\s*([（(][^（）()]*[）)])\s*$/);
  return m ? { label: m[1], subtitle: m[2] } : { label: full };
};

const AppContent: React.FC = () => {
  const { t, i18n } = useTranslation();
  const [data, setData] = useState<BusinessData>(MOCK_BUSINESS_DATA);
  const [analysis, setAnalysis] = useState<AIAnalysis | null>(null);
  const [loadingAI, setLoadingAI] = useState(false);
  const [aiError, setAiError] = useState<string | null>(null);
  // AI 简报额度冷却：一次 Gemini 429/额度耗尽后，5 分钟内不再向供应商发请求，
  // 避免控制台反复刷 api:request 错误。时间戳(ms)，0 表示无冷却。
  const aiQuotaCooldownRef = useRef(0);
  const [sidebarOpen, setSidebarOpen] = useState(true);
  const [currentPage, setCurrentPage] = useState<PageId>('dashboard');

  const [selectedYear, setSelectedYear] = useState('2026');
  const [selectedQuarter, setSelectedQuarter] = useState('全年');
  const [selectedMonth, setSelectedMonth] = useState('全部');

  // Ref to always hold latest data for AI analysis (avoids stale closure / infinite loop)
  const dataRef = useRef<BusinessData>(MOCK_BUSINESS_DATA);


  // Load real dashboard data from API (returns data directly to avoid ref race condition)
  const loadDashboardData = useCallback(async (): Promise<BusinessData | null> => {
    try {
      const dashboard = await fetchDashboardData(selectedYear);
      const m = dashboard.metrics;

      // PR-T2: trust the backend's locale-aware financial statement verbatim.
      // No client-side tax-rate math — taxSurcharge / incomeTax / grossProfit /
      // netProfit / margins (and shippingFee / adminExpense) are all computed
      // server-side (electron reports/*) using the configured per-locale
      // rates. We only pass the fields through, falling back to 0 if a field is
      // missing; we never re-derive a formula on the client (which previously
      // hardcoded a 12% surcharge and a 25% income tax regardless of locale).
      const fs = dashboard.financialStatement;
      const enrichedFS = {
        salesRevenue: fs.salesRevenue ?? 0,
        costOfSales: fs.costOfSales ?? 0,
        costOfGoodsSold: fs.costOfGoodsSold ?? 0,
        operatingExpenses: fs.operatingExpenses ?? 0,
        operatingProfit: fs.operatingProfit ?? 0,
        taxSurcharge: fs.taxSurcharge ?? 0,
        shippingFee: fs.shippingFee ?? 0,
        adminExpense: fs.adminExpense ?? 0,
        incomeTax: fs.incomeTax ?? 0,
        grossProfit: fs.grossProfit ?? 0,
        grossMargin: fs.grossMargin ?? 0,
        netProfit: fs.netProfit ?? 0,
        netMargin: fs.netMargin ?? 0,
      };

      // accountingLocale from dashboard response (or fallback to CN)
      const accLocale = dashboard.locale || 'CN';
      const sym = getCurrencySymbol(accLocale);

      // Quantity unit suffix — empty unless a real business unit is configured
      // (legacy 'ton'/unset → pure numbers). Display-only; no calc impact.
      let productUnit = '';
      try { const us = await fetchSettings(); productUnit = (us as any).product_unit || ''; } catch { /* default: no unit */ }
      const qtyUnit = getInventoryUnitLabel(productUnit, i18n.language);
      const qtySuffix = qtyUnit ? ` ${qtyUnit}` : '';
      const perUnit = qtyUnit ? `/${qtyUnit}` : '';
      // Phase 3: per-product inventory overview from the dashboard payload
      const inv = (dashboard as any).inventory || { inStockCount: 0, totalInventoryCost: 0, details: [] };

      const next: BusinessData = {
        ...dataRef.current,
        locale: accLocale, // pass through for dashboard rendering
        metrics: [
          {
            label: t('inventory.inStockCount'),
            value: String(inv.inStockCount),
            subValue: '—',
            icon: 'fa-boxes',
            color: 'bg-blue-500',
          },
          {
            ...splitTaxBasis(t('inventory.totalCost')),
            value: inv.totalInventoryCost > 0 ? formatMoney(inv.totalInventoryCost, accLocale) : `${sym}0`,
            subValue: '—',
            icon: 'fa-coins',
            color: 'bg-cyan-500',
          },
          {
            // PR fix: dashboard money KPI = report-engine canonical (matches the P&L),
            // not legacy tax-inclusive metrics. US has no COGS line — its
            // financialStatement.costOfSales maps to Schedule C Line 28 total expenses,
            // so US shows a "Total Expenses" label, not "Cost of Sales". subValue is
            // '—': legacy tons are a different (quantity) source and would mislead
            // next to a report-engine net amount.
            ...splitTaxBasis(`${t('header.yearLabel', { year: selectedYear })} ${accLocale === 'US' ? t('dashboard.totalExpenses') : t('dashboard.cogsNoTax')}`),
            // A zero cost of sales is a real figure (e.g. a service business with no COGS),
            // so render it as ¥0 rather than '—', which would read as "no data".
            value: formatMoney(enrichedFS.costOfSales, accLocale),
            subValue: '—',
            icon: 'fa-truck-loading',
            color: 'bg-purple-500',
          },
          {
            // PR fix: operating revenue (net) from the report engine — same source as
            // the P&L's salesRevenue. US salesRevenue = Schedule C Line 7 gross income
            // (not a VAT "excl. tax" figure), so US uses its kpiGrossIncome label.
            // subValue '—' (see above).
            ...splitTaxBasis(`${t('header.yearLabel', { year: selectedYear })} ${accLocale === 'US' ? getTaxLabel(accLocale, i18n.language, 'kpiGrossIncome') : t('dashboard.revenueNoTax')}`),
            value: enrichedFS.salesRevenue > 0 ? formatMoney(enrichedFS.salesRevenue, accLocale) : '—',
            subValue: '—',
            icon: 'fa-chart-line',
            color: 'bg-green-500',
          },
          {
            label: t('dashboard.avgCost'),
            value: m.avgCostPerTon > 0 ? `${sym}${m.avgCostPerTon.toLocaleString()}${perUnit}` : '—',
            // Label-first so the number reads as a labeled quantity ("采购总量: 269.6 吨")
            // instead of a bare "269.6 采购", whose meaning was unclear.
            subValue: m.purchaseTotalTons > 0 ? `${t('dashboard.purchasesLabel')}: ${m.purchaseTotalTons}${qtySuffix}` : '—',
            icon: 'fa-tags',
            color: 'bg-orange-500',
          },
        ],
        rawMetrics: {
          inventoryTons: m.inventoryTons,
          purchaseTotalTons: m.purchaseTotalTons,
          salesTotalTons: m.salesTotalTons,
        },
        monthlyPerformance: dashboard.monthlyPerformance,
        financialStatement: enrichedFS,
        vatStatistics: dashboard.vatStatistics,
        taxInclusiveSummary: dashboard.taxInclusiveSummary,
        inventory: inv,
      };
      dataRef.current = next;
      setData(next);
      return next;
    } catch (err) {
      console.error('Failed to load dashboard data:', err);
      return null;
    }
  }, [selectedYear]);

  useEffect(() => {
    loadDashboardData();
  }, [loadDashboardData]);

  // Stable accounting locale for the AI assistant — sourced from settings,
  // Tracks the user's current accountingLocale (drives sidebar nav labels, AI &
  // OCR context). Re-fetched on every page navigation so switching the
  // accounting locale in Settings is reflected in the sidebar once the user
  // navigates (not only at app start).
  const [assistantAccLocale, setAssistantAccLocale] = useState<string>('CN');
  useEffect(() => {
    fetchSettings().then((s: any) => {
      if (s?.accounting_locale) setAssistantAccLocale(s.accounting_locale);
    }).catch(() => {});
  }, [currentPage]);

  const performAnalysis = useCallback(async () => {
    // 额度冷却中（上次 Gemini 429 后 5 分钟内）：直接显示友好提示，不再发请求，
    // 避免连点刷新或任何残留路径反复刷 429。
    if (Date.now() < aiQuotaCooldownRef.current) {
      setLoadingAI(false);
      setAiError(t('aiInsights.quotaExceeded'));
      return;
    }
    setLoadingAI(true);
    setAiError(null);
    try {
      const freshData = await loadDashboardData();
      // Inject both accountingLocale (tax/currency/regime context) and
      // uiLanguage (response language) into the system prompt, so the AI
      // briefing follows the same separation rules as the chat assistant.
      const localeForAI = (freshData as any)?.locale || assistantAccLocale || 'CN';
      // PR-E1: append the management-boundary directive so the briefing avoids
      // stating statutory tax/accounting conclusions.
      const systemPrompt = `${t('ai.analyzeSystemPrompt')}\n\n${buildAIFinanceContext(localeForAI, i18n.language)}\n\n${t('ai.boundaryDirective')}`;
      const result = await fetchAIAnalysis(freshData || dataRef.current, undefined, t('ai.languageHint'), systemPrompt);
      setAnalysis(result);
    } catch (err: any) {
      // 区分「额度/限流(429)」与一般错误。429 时进入 5 分钟冷却 + 友好提示，
      // 并在有其他可用 provider 时提示切换（不自动切换），避免控制台刷屏。
      // R3c：错误分类改用稳定 code（parseAiErrorCode），其余按 code 映射 i18n（随 uiLanguage）。
      const code = parseAiErrorCode(err);
      if (code === 'quota') {
        aiQuotaCooldownRef.current = Date.now() + 5 * 60 * 1000;
        let friendly = t('aiInsights.quotaExceeded');
        try {
          const provs = await listProviders();
          const alt = (provs || []).filter((p: any) => p.provider !== 'gemini' && p.hasKey && p.enabled);
          if (alt.length) {
            const names = alt.map((p: any) => AI_PROVIDER_LABELS[p.provider] || p.provider).join(' / ');
            friendly = `${friendly} ${t('aiInsights.quotaSwitchHint', { providers: names })}`;
          }
        } catch { /* 获取 provider 列表失败时仅显示基础提示 */ }
        setAiError(friendly);
        console.warn('[AI] Gemini quota/429 — paused 5 min, no auto-retry');
      } else {
        console.error("AI Analysis Failed", err);
        setAiError(aiErrorMessage(err, t));
      }
    } finally {
      setLoadingAI(false);
    }
  }, [loadDashboardData, assistantAccLocale, i18n.language]);

  // AI 经营简报不再在挂载 / 切页 / 热更新时自动调用 —— performAnalysis 依赖
  // assistantAccLocale(每次导航刷新)与 i18n.language，若自动触发会对默认 provider
  // 反复请求，Gemini 额度耗尽即不断刷 429。改为用户在 AIInsights 卡片点「刷新」
  // (onRefresh=performAnalysis) 时才触发；默认 provider 可在 设置→AI 服务商 切换
  // (Claude Sonnet 4.6 / ChatGPT)。AI 请求必须由用户主动触发。
  const renderPage = () => {
    switch (currentPage) {
      case 'dashboard': {
        const accLocale = (data as any).locale || 'CN';
        const uiLang = i18n.language;
        const sections = getDashboardSections(accLocale);
        // sections determine which cards to show — driven by accountingLocale
        // labels on those cards are in uiLanguage via getTaxLabel()
        return (
          <div className="grid grid-cols-1 xl:grid-cols-4 gap-8">
            <div className="xl:col-span-3 space-y-8">
              <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-6">
                {data.metrics.map((m, i) => <MetricCard key={i} metric={m} />)}
              </div>
              {/* Phase 2: gentle data-source notice — business records and 收支记录 are
                  separate ledgers; reconcile when both are used in the same period. */}
              <p className="text-[11px] text-[#5c5c5a] leading-snug px-1">
                <i className="fas fa-circle-info mr-1.5"></i>{t('common.dataSourceNote')}
              </p>
              {/* Phase 3: per-product inventory detail (each line keeps its own unit) */}
              {data.inventory && data.inventory.details.length > 0 && (
                <div className="bg-white border border-[#e0ddd5] rounded-2xl overflow-hidden" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.06)' }}>
                  <div className="px-6 py-4 border-b border-[#e0ddd5] flex items-center space-x-2">
                    <i className="fas fa-boxes-stacked text-primary"></i>
                    <h3 className="text-sm font-bold text-[#191918]">{t('inventory.detailTitle')}</h3>
                  </div>
                  <table className="w-full text-sm">
                    <thead className="bg-[#f9f9f8] text-[10px] uppercase tracking-wider text-[#4a4a48]">
                      <tr>
                        <th className="text-left px-6 py-2.5">{t('inventory.colProduct')}</th>
                        <th className="text-right px-6 py-2.5">{t('inventory.colQty')}</th>
                        <th className="text-right px-6 py-2.5">{t('inventory.colCost')}</th>
                      </tr>
                    </thead>
                    <tbody>
                      {data.inventory.details.map(d => (
                        <tr key={d.product_id} className="border-t border-[#e0ddd5]/70">
                          <td className="px-6 py-2 text-[#191918]">{d.name}</td>
                          <td className="px-6 py-2 text-right text-[#5c5c5a]">{`${d.qtyOnHand} ${getProductUnitLabel(d.unit, i18n.language)}`}</td>
                          <td className="px-6 py-2 text-right text-[#5c5c5a]">{formatMoney(d.lineCost, data.locale || 'CN')}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
              <div className="grid grid-cols-1 lg:grid-cols-2 gap-8 items-stretch [grid-auto-rows:1fr]">
                {/* US: Schedule C + Deductions + SE Tax + Margins */}
                {sections.includes('schedule_c_summary') ? (
                  <USDashboardCards
                    report={(data as any).report}
                    mileageSummary={(data as any).mileageSummary}
                    homeOffice={(data as any).homeOffice}
                    accountingLocale={accLocale}
                    uiLanguage={uiLang}
                  />
                ) : (
                  <>
                    {/* P&L + Profit Margins — all non-US locales, locale-aware */}
                    {sections.includes('profit_loss') && <FinancialStatementTable data={data.financialStatement} accountingLocale={accLocale} />}
                    {sections.includes('profit_margins') && <ProfitMarginIndicators data={data.financialStatement} accountingLocale={accLocale} />}
                    {/* Tax summary — locale-aware labels + currency */}
                    {(sections.includes('vat_summary') || sections.includes('consumption_tax_summary') || sections.includes('business_tax_summary')) && (
                      <VATStatistics data={data.vatStatistics} accountingLocale={accLocale} />
                    )}
                    {sections.includes('tax_inclusive_summary') && <TaxInclusiveSummary data={data.taxInclusiveSummary} accountingLocale={accLocale} />}
                  </>
                )}
              </div>
            </div>
            <div className="xl:col-span-1 h-full min-h-[600px] xl:sticky xl:top-0 xl:h-[calc(100vh-120px)]">
              <AIInsights analysis={analysis} loading={loadingAI} error={aiError} onRefresh={performAnalysis} />
            </div>
          </div>
        );
      }
      case 'sales': return <SalesAndOutputPage data={data} selectedYear={selectedYear} selectedQuarter={selectedQuarter} selectedMonth={selectedMonth} />;
      case 'purchase': return <PurchaseAndInputPage data={data} selectedYear={selectedYear} selectedQuarter={selectedQuarter} selectedMonth={selectedMonth} />;
      case 'analysis': return <DataAnalysisPage data={data} selectedYear={selectedYear} selectedQuarter={selectedQuarter} selectedMonth={selectedMonth} />;
      case 'inventory': return <InventoryPage data={data} selectedYear={selectedYear} selectedQuarter={selectedQuarter} selectedMonth={selectedMonth} />;
      case 'finance': return <FinancePage data={data} selectedYear={selectedYear} selectedQuarter={selectedQuarter} selectedMonth={selectedMonth} />;
      case 'accounts': return <AccountsPage />;
      case 'documents': return <DocumentsPage />;
      case 'assistant': return <AssistantPage />;
      case 'transactions': return <TransactionsPage />;
      case 'ustax': return <USTaxToolsPage selectedYear={selectedYear} />;
      case 'settings': return <SettingsPage />;
      default: return null;
    }
  };

  return (
    <AssistantProvider
      accountingLocale={assistantAccLocale}
      uiLanguage={i18n.language}
      selectedYear={selectedYear}
      fallbackStatement={data.financialStatement}
    >
    <div className="flex h-screen overflow-hidden bg-transparent text-[#191918] font-sans relative">
      {/* Sidebar */}
      <aside className={`${sidebarOpen ? 'w-64' : 'w-20'} glass-bar border-r border-[#e0ddd5] transition-all duration-300 flex flex-col hidden md:flex z-20`}>
        {/* macOS 红绿灯避让区 + 可拖动 + 可双击最大化（仅 Electron 桌面版生效）*/}
        {isElectronEnv && (
          <div
            className="h-7 shrink-0"
            style={{ WebkitAppRegion: 'drag' } as React.CSSProperties}
          />
        )}
        <div
          className={`p-6 flex items-center justify-center mb-8 shrink-0 ${isElectronEnv ? 'pt-2' : ''}`}
          style={isElectronEnv ? ({ WebkitAppRegion: 'drag' } as React.CSSProperties) : undefined}
        >
          {sidebarOpen && <span className="font-bold text-xl tracking-tight text-[#191918]">SoloLedger</span>}
        </div>
        <nav className="flex-1 px-4 space-y-1 overflow-y-auto custom-scrollbar">
          <NavItem icon="fa-th-large" label={t('nav.dashboard')} active={currentPage === 'dashboard'} expanded={sidebarOpen} onClick={() => setCurrentPage('dashboard')} />

          {/* 业务记录 — business records */}
          <NavSection label={t('nav.sectionBusiness')} expanded={sidebarOpen} />
          <NavItem icon="fa-file-import" label={assistantAccLocale !== 'CN' ? getTaxLabel(assistantAccLocale, i18n.language, 'navPurchase') : t('nav.purchase')} active={currentPage === 'purchase'} expanded={sidebarOpen} onClick={() => setCurrentPage('purchase')} />
          <NavItem icon="fa-file-export" label={assistantAccLocale !== 'CN' ? getTaxLabel(assistantAccLocale, i18n.language, 'navSales') : t('nav.sales')} active={currentPage === 'sales'} expanded={sidebarOpen} onClick={() => setCurrentPage('sales')} />
          <NavItem icon="fa-file-contract" label={t('nav.documents')} active={currentPage === 'documents'} expanded={sidebarOpen} onClick={() => setCurrentPage('documents')} />

          {/* 账务核对 — accounting reconciliation */}
          <NavSection label={t('nav.sectionAccounting')} expanded={sidebarOpen} />
          <NavItem icon="fa-search-dollar" label={assistantAccLocale !== 'CN' ? getTaxLabel(assistantAccLocale, i18n.language, 'invQueryTitle') : t('nav.inventory')} active={currentPage === 'inventory'} expanded={sidebarOpen} onClick={() => setCurrentPage('inventory')} />
          <NavItem icon="fa-handshake" label={t('nav.accounts')} active={currentPage === 'accounts'} expanded={sidebarOpen} onClick={() => setCurrentPage('accounts')} />
          <NavItem icon="fa-exchange-alt" label={t('nav.transactions')} active={currentPage === 'transactions'} expanded={sidebarOpen} onClick={() => setCurrentPage('transactions')} />
          <NavItem icon="fa-wallet" label={t('nav.finance')} active={currentPage === 'finance'} expanded={sidebarOpen} onClick={() => setCurrentPage('finance')} />

          <NavItem icon="fa-chart-pie" label={t('nav.analysis')} active={currentPage === 'analysis'} expanded={sidebarOpen} onClick={() => setCurrentPage('analysis')} />
          <NavItem icon="fa-comments" label={t('nav.assistant')} active={currentPage === 'assistant'} expanded={sidebarOpen} onClick={() => setCurrentPage('assistant')} />
          {assistantAccLocale === 'US' && (
            <NavItem icon="fa-flag-usa" label={t('nav.usTax')} active={currentPage === 'ustax'} expanded={sidebarOpen} onClick={() => setCurrentPage('ustax')} />
          )}
          <NavItem icon="fa-cog" label={t('nav.settings')} active={currentPage === 'settings'} expanded={sidebarOpen} onClick={() => setCurrentPage('settings')} />
        </nav>
        <div className="p-4 mt-auto border-t border-[#e0ddd5] space-y-2">
          <button onClick={() => setSidebarOpen(!sidebarOpen)} className="w-full flex items-center justify-center p-2 rounded-lg bg-[#f0eeeb] hover:bg-[#e0ddd5] transition-colors text-[#6b6b69]">
            <i className={`fas ${sidebarOpen ? 'fa-angle-double-left' : 'fa-angle-double-right'}`}></i>
          </button>
        </div>
      </aside>

      {/* Main */}
      <main className="flex-1 flex flex-col overflow-hidden relative z-10">
        {(
          <header
            className="h-16 glass-bar border-b border-[#e0ddd5] flex items-center justify-between px-8 z-10 shrink-0"
            style={isElectronEnv ? ({ WebkitAppRegion: 'drag' } as React.CSSProperties) : undefined}
          >
            <div
              className="flex items-center space-x-6 min-w-0"
              style={isElectronEnv ? ({ WebkitAppRegion: 'no-drag' } as React.CSSProperties) : undefined}
            >
              <h2 className="text-xl font-semibold text-[#191918] truncate min-w-0">
                {assistantAccLocale !== 'CN' && currentPage === 'inventory'
                  ? getTaxLabel(assistantAccLocale, i18n.language, 'invQueryTitle')
                  : assistantAccLocale !== 'CN' && currentPage === 'purchase'
                  ? getTaxLabel(assistantAccLocale, i18n.language, 'navPurchase')
                  : assistantAccLocale !== 'CN' && currentPage === 'sales'
                  ? getTaxLabel(assistantAccLocale, i18n.language, 'navSales')
                  : t(`headerTitle.${currentPage}`)}
              </h2>
              <div className="hidden lg:flex items-center space-x-4 pl-4 border-l border-[#e0ddd5] shrink-0">
                <div className="flex items-center space-x-2 bg-white rounded-lg p-1 border border-[#e0ddd5]">
                  <select value={selectedYear} onChange={(e) => setSelectedYear(e.target.value)} className="bg-transparent text-xs font-medium text-[#6b6b69] outline-none px-2 py-1.5 cursor-pointer hover:text-primary">
                    {YEARS.map(y => <option key={y} value={y} className="bg-white">{t('header.yearLabel', { year: y })}</option>)}
                  </select>
                  {FILTER_SUPPORTED_PAGES.includes(currentPage) && (
                    <>
                      <div className="w-px h-3 bg-[#e0ddd5]"></div>
                      <select value={selectedQuarter} onChange={(e) => { setSelectedQuarter(e.target.value); if (e.target.value !== '全年') setSelectedMonth('全部'); }} className="bg-transparent text-xs font-medium text-[#6b6b69] outline-none px-2 py-1.5 cursor-pointer hover:text-primary">
                        {QUARTERS.map(q => <option key={q} value={q} className="bg-white">{q === '全年' ? t('header.allYear') : t('header.quarterLabel', { n: q.replace('Q', '') })}</option>)}
                      </select>
                    </>
                  )}
                  <div className="w-px h-3 bg-[#e0ddd5]"></div>
                  <select value={selectedMonth} onChange={(e) => { setSelectedMonth(e.target.value); if (e.target.value !== '全部') setSelectedQuarter('全年'); }} className="bg-transparent text-xs font-medium text-[#6b6b69] outline-none px-2 py-1.5 cursor-pointer hover:text-primary">
                    {MONTHS.map((m, i) => <option key={m} value={m} className="bg-white">{i === 0 ? t('header.monthAll') : t(`header.month${m.replace('月', '').padStart(2, '0')}`)}</option>)}
                  </select>
                </div>
                <button onClick={performAnalysis} className="p-2 text-primary hover:text-primary-hover transition-colors" title={t('header.refreshData')}>
                  <i className={`fas fa-sync-alt ${loadingAI ? 'animate-spin' : ''}`}></i>
                </button>
              </div>
            </div>
            <div
              className="flex items-center space-x-4"
              style={isElectronEnv ? ({ WebkitAppRegion: 'no-drag' } as React.CSSProperties) : undefined}
            >
              <AlertCenter />
            </div>
          </header>
        )}
        <div className="flex-1 overflow-y-auto p-8 custom-scrollbar">
          <Suspense fallback={<PageFallback />}>
            {renderPage()}
          </Suspense>
        </div>
      </main>

      {/* AI Assistant 浮窗（R1 抽离），与各页共享同一 AssistantProvider 会话。独立「AI 助手」页
          （R2a）本身已是全屏聊天，且右下角浮窗圆钮会遮挡该页输入框的发送按钮，故在该页隐藏浮窗；
          其余页面保留右下角快捷入口。会话状态在 Provider 中，隐藏/重挂浮窗不丢消息。 */}
      {currentPage !== 'assistant' && <AssistantWidget />}

      <style>{`
        .no-scrollbar::-webkit-scrollbar { display: none; }
        .no-scrollbar { -ms-overflow-style: none; scrollbar-width: none; }
      `}</style>
    </div>
    </AssistantProvider>
  );
};

// Auth wrapper — 桌面版默认无需登录；启动时检测 BYOK 是否已配置 API Key，未配置则进入 Onboarding
const isElectronEnv = typeof window !== 'undefined' && !!(window as any).electronAPI?.isElectron;

const AuthWrapper: React.FC = () => {
  const { t } = useTranslation();
  // 桌面版需要 BYOK：启动时检测是否已配置 API Key，未配置时显示 Onboarding
  const [onboardingState, setOnboardingState] = useState<'checking' | 'needed' | 'done'>(
    isElectronEnv ? 'checking' : 'done'
  );

  useEffect(() => {
    const electronAPI = (window as any).electronAPI;
    electronAPI.invoke('providers:hasAny')
      .then((has: boolean) => setOnboardingState(has ? 'done' : 'needed'))
      .catch(() => setOnboardingState('needed'));
  }, []);

  if (onboardingState === 'checking') {
    return (
      <div className="min-h-screen flex items-center justify-center bg-[#f9f9f8]">
        <div className="flex items-center space-x-3 text-[#6b6b69]">
          <i className="fas fa-spinner fa-spin text-primary"></i>
          <span className="text-sm">{t('common.loading')}</span>
        </div>
      </div>
    );
  }

  if (onboardingState === 'needed') {
    return <OnboardingWizard onComplete={() => setOnboardingState('done')} />;
  }

  return <AppContent />;
};

const NavItem: React.FC<{ icon: string; label: string; active?: boolean; expanded?: boolean; onClick?: () => void; }> = ({ icon, label, active = false, expanded = true, onClick }) => (
  <div onClick={onClick} className={`flex items-center p-3 rounded-lg transition-all duration-200 cursor-pointer group ${active ? 'bg-primary text-white' : 'text-[#4a4a48] hover:bg-[#f0eeeb] hover:text-[#191918]'}`} style={active ? { boxShadow: '0 4px 24px rgba(39,76,146,0.15)' } : {}}>
    <i className={`fas ${icon} text-base ${expanded ? 'mr-4' : 'mx-auto'} w-5 text-center group-hover:scale-110 transition-transform`}></i>
    {expanded && <span className="text-sm font-medium truncate min-w-0">{label}</span>}
  </div>
);

// Sidebar section header (业务记录 / 账务核对). Visual grouping only — no routing change.
// Both states render in the SAME fixed-height slot (h-9, bottom-aligned) so toggling
// expand/collapse never shifts the items below: expanded shows the readable label,
// collapsed shows a divider at the same vertical position.
const NavSection: React.FC<{ label: string; expanded?: boolean }> = ({ label, expanded = true }) => (
  <div className="h-9 flex items-end px-3 pb-1 select-none">
    {expanded
      ? <span className="text-xs font-semibold text-[#5c5c5a] tracking-wide">{label}</span>
      : <span className="block w-full border-t border-[#e0ddd5]" aria-hidden="true" />}
  </div>
);

export default AuthWrapper;
