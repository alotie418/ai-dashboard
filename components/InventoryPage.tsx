
import React, { useState, useMemo, useEffect } from 'react';
import { useTranslation } from 'react-i18next';
import { BusinessData } from '../types';
import { fetchSales, fetchPurchases, fetchSettings, SalesRecord, PurchaseRecord } from '../services/api';
import { formatMoney, getTaxLabel, formatQuantity, getInventoryUnitLabel } from './accountingHelpers';

interface Props {
  data: BusinessData;
  selectedYear: string;
  selectedQuarter: string;
  selectedMonth: string;
}


type InvoiceType = 'all' | 'input' | 'output';

const parseTons = (qty: string) => { const m = qty.match(/[\d.]+/); return m ? parseFloat(m[0]) : 0; };
const parseTaxRate = (s: string) => { const m = s.match(/[\d.]+/); return m ? parseFloat(m[0]) / 100 : 0.13; };


const InventoryPage: React.FC<Props> = ({ data, selectedYear, selectedQuarter, selectedMonth }) => {
  const { t, i18n } = useTranslation();
  const [accLocale, setAccLocale] = useState('CN');
  const [productUnit, setProductUnit] = useState<string>('ton');
  useEffect(() => {
    fetchSettings().then((s: any) => {
      if (s.accounting_locale) setAccLocale(s.accounting_locale);
      if (s.product_unit) setProductUnit(s.product_unit);
    }).catch(() => {});
  }, []);
  const uiLang = i18n.language;
  const taxLabel = (key: string) => getTaxLabel(accLocale, uiLang, key);
  const fmtMoney = (val: number) => formatMoney(val, accLocale, uiLang);
  const unitLabel = getInventoryUnitLabel(productUnit, uiLang);
  // Every non-CN accountingLocale (US/JP/KR/TW/EU) uses the generic document
  // wording from the accounting-locale taxConcepts (receipt/document context, no
  // CN-VAT 进项/销项/认证/抵扣/发票号 terminology); only CN keeps the invoices.*
  // i18n values. genLabelCount substitutes the literal {count} token (getTaxLabel
  // returns a plain string, no i18next interpolation) for non-CN.
  const genLabel = (taxKey: string, i18nKey: string) => accLocale !== 'CN' ? taxLabel(taxKey) : t(i18nKey);
  const genLabelCount = (taxKey: string, i18nKey: string, count: number) =>
    accLocale !== 'CN'
      ? taxLabel(taxKey).replace(/\{count\}/g, String(count))
      : t(i18nKey, { count });

  const [searchTerm, setSearchTerm] = useState('');
  const [filterType, setFilterType] = useState<InvoiceType>('all');
  const [showAdvanced, setShowAdvanced] = useState(false);
  const [isLoadingData, setIsLoadingData] = useState(true);
  const [salesRecords, setSalesRecords] = useState<SalesRecord[]>([]);
  const [purchaseRecords, setPurchaseRecords] = useState<PurchaseRecord[]>([]);

  // Advanced filter state
  const [dateFrom, setDateFrom] = useState('');
  const [dateTo, setDateTo] = useState('');
  const [amountMin, setAmountMin] = useState('');
  const [amountMax, setAmountMax] = useState('');
  const [weightMin, setWeightMin] = useState('');
  const [weightMax, setWeightMax] = useState('');
  const [statusFilter, setStatusFilter] = useState<string>('all');

  useEffect(() => {
    Promise.all([fetchSales(), fetchPurchases()])
      .then(([sales, purchases]) => {
        setSalesRecords(sales);
        setPurchaseRecords(purchases);
      })
      .catch((err) => console.error('Failed to load invoice data:', err))
      .finally(() => setIsLoadingData(false));
  }, []);

  const clearAdvancedFilters = () => {
    setDateFrom(''); setDateTo('');
    setAmountMin(''); setAmountMax('');
    setWeightMin(''); setWeightMax('');
    setStatusFilter('all');
  };

  const hasAdvancedFilters = dateFrom || dateTo || amountMin || amountMax || weightMin || weightMax || statusFilter !== 'all';

  const allInvoices = useMemo(() => {
    const output = salesRecords.map(r => {
      const taxRate = 0.13;
      const amountNoTax = Math.round(r.price / (1 + taxRate) * 100) / 100;
      const taxAmt = Math.round((r.price - amountNoTax) * 100) / 100;
      return {
        date: r.date, typeKey: 'output' as const, partner: r.customer,
        weight: `${parseTons(r.quantity)} ${unitLabel}`, amount: amountNoTax, tax: taxAmt,
        invoiceNo: r.invoiceNo, statusKey: r.status === '已开' ? 'issued' : 'pendingIssue',
      };
    });
    const input = purchaseRecords.map(r => {
      const rate = parseTaxRate(r.taxRate);
      const amountNoTax = Math.round(r.price / (1 + rate) * 100) / 100;
      const taxAmt = Math.round((r.price - amountNoTax) * 100) / 100;
      return {
        date: r.date, typeKey: 'input' as const, partner: r.supplier,
        weight: `${parseTons(r.quantity)} ${unitLabel}`, amount: amountNoTax, tax: taxAmt,
        invoiceNo: r.invoiceNo, statusKey: r.status === '已收' ? 'certified' : 'pendingCert',
      };
    });
    return [...output, ...input].sort((a, b) => b.date.localeCompare(a.date));
  }, [salesRecords, purchaseRecords]);


  const filteredInvoices = useMemo(() => {
    return allInvoices.filter(inv => {
      const matchesSearch = inv.partner.toLowerCase().includes(searchTerm.toLowerCase()) ||
        inv.invoiceNo.includes(searchTerm);
      const matchesType = filterType === 'all' || filterType === inv.typeKey;

      // Advanced filters
      const matchesDateFrom = !dateFrom || inv.date >= dateFrom;
      const matchesDateTo = !dateTo || inv.date <= dateTo;
      const matchesAmountMin = !amountMin || inv.amount >= parseFloat(amountMin);
      const matchesAmountMax = !amountMax || inv.amount <= parseFloat(amountMax);
      const invWeight = parseFloat(String(inv.weight).replace(/[^0-9.]/g, '')) || 0;
      const matchesWeightMin = !weightMin || invWeight >= parseFloat(weightMin);
      const matchesWeightMax = !weightMax || invWeight <= parseFloat(weightMax);
      const matchesStatus = statusFilter === 'all' || inv.statusKey === statusFilter;

      return matchesSearch && matchesType &&
        matchesDateFrom && matchesDateTo &&
        matchesAmountMin && matchesAmountMax &&
        matchesWeightMin && matchesWeightMax &&
        matchesStatus;
    });
  }, [allInvoices, searchTerm, filterType, dateFrom, dateTo, amountMin, amountMax, weightMin, weightMax, statusFilter]);

  const stats = useMemo(() => {
    const totalInputTons = purchaseRecords.reduce((s, r) => s + parseTons(r.quantity), 0);
    const totalOutputTons = salesRecords.reduce((s, r) => s + parseTons(r.quantity), 0);
    const inventoryTons = totalInputTons - totalOutputTons;
    const pendingTax = purchaseRecords
      .filter(r => r.status !== '已收')
      .reduce((s, r) => {
        const rate = parseTaxRate(r.taxRate);
        return s + Math.round(r.price / (1 + rate) * rate * 100) / 100;
      }, 0);
    return {
      currentStock: formatQuantity(inventoryTons, productUnit, uiLang, 2),
      currentStockSub: t('invoices.stockNormal'),
      totalInputWeight: formatQuantity(totalInputTons, productUnit, uiLang, 1),
      totalInputSub: purchaseRecords.length > 0 ? genLabelCount('invInputRecordCount', 'invoices.inputRecordCount', purchaseRecords.length) : genLabel('invNoInput', 'invoices.noInput'),
      totalOutputWeight: formatQuantity(totalOutputTons, productUnit, uiLang, 1),
      totalOutputSub: salesRecords.length > 0 ? genLabelCount('invOutputRecordCount', 'invoices.outputRecordCount', salesRecords.length) : genLabel('invNoOutput', 'invoices.noOutput'),
      pendingCertification: fmtMoney(pendingTax),
    };
  }, [salesRecords, purchaseRecords, accLocale, uiLang]);

  return (
    <div className="space-y-8 animate-in fade-in duration-500">
      {/* Header Stats Grid */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
        <StatCard
          title={t('invoices.currentStock')}
          value={stats.currentStock}
          sub={stats.currentStockSub}
          icon="fa-warehouse"
          color="text-amber-500"
          bg="bg-amber-500/10"
        />
        <StatCard
          title={genLabel('invTotalInput', 'invoices.totalInput')}
          value={stats.totalInputWeight}
          sub={stats.totalInputSub}
          icon="fa-file-import"
          color="text-primary"
          bg="bg-primary/10"
        />
        <StatCard
          title={genLabel('invTotalOutput', 'invoices.totalOutput')}
          value={stats.totalOutputWeight}
          sub={stats.totalOutputSub}
          icon="fa-file-export"
          color="text-emerald-600"
          bg="bg-emerald-500/10"
        />
        <StatCard
          title={genLabel('invPendingTax', 'invoices.pendingTax')}
          value={stats.pendingCertification}
          sub={genLabel('invPendingTaxSub', 'invoices.deductible')}
          icon="fa-clock"
          color="text-primary"
          bg="bg-primary/10"
        />
      </div>

      {/* Search and Filters */}
      <div className="glass-card p-6 rounded-xl flex flex-col md:flex-row md:items-center justify-between gap-4" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.05)' }}>
        <div className="relative flex-1 max-w-md">
          <i className="fas fa-search absolute left-4 top-1/2 -translate-y-1/2 text-[#5c5c5a]"></i>
          <input
            type="text"
            placeholder={genLabel('invSearchPlaceholder', 'invoices.searchPlaceholder')}
            value={searchTerm}
            onChange={(e) => setSearchTerm(e.target.value)}
            className="w-full bg-white border border-[#e0ddd5] rounded-xl py-3 pl-12 pr-4 text-sm focus:outline-none focus:ring-2 focus:ring-primary transition-all"
          />
        </div>

        <div className="flex items-center space-x-2 glass-card p-1.5 rounded-xl shrink-0">
          <FilterTab active={filterType === 'all'} onClick={() => setFilterType('all')} label={genLabel('invFilterAll', 'invoices.filterAll')} />
          <FilterTab active={filterType === 'input'} onClick={() => setFilterType('input')} label={genLabel('invFilterInput', 'invoices.filterInput')} />
          <FilterTab active={filterType === 'output'} onClick={() => setFilterType('output')} label={genLabel('invFilterOutput', 'invoices.filterOutput')} />
        </div>
      </div>

      {/* Main Data Table */}
      <div className="bg-white/80 border border-[#e0ddd5] rounded-xl overflow-hidden" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.05)' }}>
        <div className="p-8 border-b border-[#e0ddd5] flex justify-between items-center bg-[#f9f9f8]/20">
          <div>
            <h3 className="text-xl font-bold text-[#191918]">{genLabel('invTableTitle', 'invoices.tableTitle')}</h3>
            <p className="text-sm text-[#5c5c5a] mt-1">{genLabel('invTableSubtitle', 'invoices.tableSubtitle')}</p>
          </div>
          <div className="flex space-x-3">
            <button
              onClick={() => setShowAdvanced(!showAdvanced)}
              className={`px-4 py-2 text-xs font-bold rounded-xl transition-all flex items-center ${showAdvanced || hasAdvancedFilters ? 'bg-primary/10 text-primary border border-primary/30' : 'text-[#4a4a48] hover:text-[#191918] hover:bg-[#f0eeeb] border border-transparent'}`}
            >
              <i className={`fas fa-filter mr-2 ${hasAdvancedFilters ? 'text-primary' : ''}`}></i>
              {t('invoices.advancedFilter')}
              {hasAdvancedFilters && <span className="ml-2 w-2 h-2 bg-primary rounded-full"></span>}
            </button>
            <button className="px-4 py-2 bg-primary text-white rounded-xl text-xs font-bold hover:bg-primary-hover transition-all" style={{ boxShadow: '0 4px 16px rgba(39,76,146,0.15)' }}>
              <i className="fas fa-download mr-2"></i> {t('invoices.export')}
            </button>
          </div>
        </div>

        {/* Advanced Filter Panel */}
        {showAdvanced && (
          <div className="px-8 py-6 border-b border-[#e0ddd5] bg-[#f9f9f8]/60 animate-in slide-in-from-top-2 duration-300">
            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
              {/* Date Range */}
              <div className="space-y-2">
                <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{genLabel('invDateRange', 'invoices.dateRange')}</label>
                <div className="flex items-center space-x-2">
                  <input type="date" lang={uiLang} value={dateFrom} onChange={e => setDateFrom(e.target.value)}
                    className="flex-1 bg-white border border-[#e0ddd5] rounded-lg px-3 py-2 text-xs text-[#191918] focus:outline-none focus:ring-2 focus:ring-primary/50 transition-all" />
                  <span className="text-[#5c5c5a] text-xs">—</span>
                  <input type="date" lang={uiLang} value={dateTo} onChange={e => setDateTo(e.target.value)}
                    className="flex-1 bg-white border border-[#e0ddd5] rounded-lg px-3 py-2 text-xs text-[#191918] focus:outline-none focus:ring-2 focus:ring-primary/50 transition-all" />
                </div>
              </div>

              {/* Amount Range */}
              <div className="space-y-2">
                <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{accLocale === 'JP' ? taxLabel('invAmountRange') : t('invoices.amountRange')}</label>
                <div className="flex items-center space-x-2">
                  <input type="number" placeholder={t('invoices.min')} value={amountMin} onChange={e => setAmountMin(e.target.value)}
                    className="flex-1 bg-white border border-[#e0ddd5] rounded-lg px-3 py-2 text-xs text-[#191918] focus:outline-none focus:ring-2 focus:ring-primary/50 transition-all" />
                  <span className="text-[#5c5c5a] text-xs">—</span>
                  <input type="number" placeholder={t('invoices.max')} value={amountMax} onChange={e => setAmountMax(e.target.value)}
                    className="flex-1 bg-white border border-[#e0ddd5] rounded-lg px-3 py-2 text-xs text-[#191918] focus:outline-none focus:ring-2 focus:ring-primary/50 transition-all" />
                </div>
              </div>

              {/* Weight Range */}
              <div className="space-y-2">
                <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{genLabel('invWeightRange', 'invoices.weightRange')}</label>
                <div className="flex items-center space-x-2">
                  <input type="number" placeholder={t('invoices.min')} value={weightMin} onChange={e => setWeightMin(e.target.value)}
                    className="flex-1 bg-white border border-[#e0ddd5] rounded-lg px-3 py-2 text-xs text-[#191918] focus:outline-none focus:ring-2 focus:ring-primary/50 transition-all" />
                  <span className="text-[#5c5c5a] text-xs">—</span>
                  <input type="number" placeholder={t('invoices.max')} value={weightMax} onChange={e => setWeightMax(e.target.value)}
                    className="flex-1 bg-white border border-[#e0ddd5] rounded-lg px-3 py-2 text-xs text-[#191918] focus:outline-none focus:ring-2 focus:ring-primary/50 transition-all" />
                </div>
              </div>

              {/* Status Filter */}
              <div className="space-y-2">
                <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{genLabel('invStatusFilter', 'invoices.statusFilter')}</label>
                <select value={statusFilter} onChange={e => setStatusFilter(e.target.value)}
                  className="w-full bg-white border border-[#e0ddd5] rounded-lg px-3 py-2 text-xs text-[#191918] focus:outline-none focus:ring-2 focus:ring-primary/50 transition-all appearance-none cursor-pointer"
                  style={{ backgroundImage: `url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' fill='none' viewBox='0 0 20 20'%3E%3Cpath stroke='%236b7280' stroke-linecap='round' stroke-linejoin='round' stroke-width='1.5' d='M6 8l4 4 4-4'/%3E%3C/svg%3E")`, backgroundPosition: 'right 0.5rem center', backgroundRepeat: 'no-repeat', backgroundSize: '1.5em 1.5em', paddingRight: '2.5rem' }}>
                  <option value="all">{genLabel('invStatusAll', 'invoices.allStatus')}</option>
                  <option value="verified">{genLabel('invStatusVerified', 'invoices.statusVerified')}</option>
                  <option value="certified">{genLabel('invStatusCertified', 'invoices.statusCertified')}</option>
                  <option value="deducted">{genLabel('invStatusDeducted', 'invoices.statusDeducted')}</option>
                  <option value="pendingCert">{genLabel('invStatusPendingCert', 'invoices.statusPendingCert')}</option>
                  <option value="pendingIssue">{genLabel('invStatusPendingIssue', 'invoices.statusPendingInvoice')}</option>
                  <option value="issued">{genLabel('invStatusIssued', 'invoices.statusIssued')}</option>
                </select>
              </div>
            </div>

            {/* Filter Actions */}
            <div className="mt-5 flex items-center justify-between">
              <div className="text-xs text-[#5c5c5a]">
                {hasAdvancedFilters && (
                  <span className="flex items-center">
                    <i className="fas fa-info-circle mr-1.5 text-primary"></i>
                    {genLabelCount('invAdvFilterActive', 'invoices.advancedFilterActive', filteredInvoices.length)}
                  </span>
                )}
              </div>
              <button
                onClick={clearAdvancedFilters}
                disabled={!hasAdvancedFilters}
                className="px-4 py-2 text-xs font-bold text-[#5c5c5a] hover:text-primary disabled:opacity-30 disabled:cursor-not-allowed transition-all flex items-center"
              >
                <i className="fas fa-times mr-1.5"></i> {t('invoices.clearAll')}
              </button>
            </div>
          </div>
        )}

        <div className="overflow-x-auto">
          <table className="w-full text-left border-collapse min-w-[1000px]">
            <thead>
              <tr className="bg-[#f9f9f8]/30 text-[#5c5c5a] text-[10px] uppercase font-bold tracking-widest">
                <th className="px-8 py-5">{genLabel('invHeaderDate', 'invoices.headerDate')}</th>
                <th className="px-8 py-5">{t('invoices.headerType')}</th>
                <th className="px-8 py-5">{t('invoices.headerPartner')}</th>
                <th className="px-8 py-5">{genLabel('invHeaderWeight', 'invoices.headerWeight')}</th>
                <th className="px-8 py-5 text-right">{genLabel('invHeaderAmount', 'invoices.headerAmount')}</th>
                <th className="px-8 py-5 text-right">{t('invoices.headerTax')}</th>
                <th className="px-8 py-5">{genLabel('invHeaderInvoiceNo', 'invoices.headerInvoiceNo')}</th>
                <th className="px-8 py-5 text-center">{t('invoices.headerStatus')}</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-[#e0ddd5]">
              {filteredInvoices.map((inv) => (
                <tr key={inv.invoiceNo || inv.date + inv.partner} className="group hover:bg-[#f9f9f8]/40 transition-all">
                  <td className="px-8 py-5 text-sm text-[#4a4a48] whitespace-nowrap min-w-[7rem]">{inv.date}</td>
                  <td className="px-8 py-5 whitespace-nowrap min-w-[5rem]">
                    <span className={`inline-block whitespace-nowrap px-2 py-1 rounded text-[10px] font-bold ${inv.typeKey === 'output' ? 'bg-primary/10 text-primary' : 'bg-amber-500/10 text-amber-400'}`}>
                      {taxLabel(inv.typeKey === 'output' ? 'invoiceTypeOutput' : 'invoiceTypeInput')}
                    </span>
                  </td>
                  <td className="px-8 py-5 text-sm font-bold text-[#191918] group-hover:text-[#191918] transition-colors">{inv.partner}</td>
                  <td className="px-8 py-5 text-sm font-mono text-[#5c5c5a]">{inv.weight}</td>
                  <td className="px-8 py-5 text-sm text-right font-bold text-[#191918]">{fmtMoney(inv.amount)}</td>
                  <td className="px-8 py-5 text-sm text-right text-[#4a4a48]">{fmtMoney(inv.tax)}</td>
                  <td className="px-8 py-5 text-sm font-mono text-[#5c5c5a] tracking-tighter">{inv.invoiceNo}</td>
                  <td className="px-8 py-5 text-center">
                    <StatusBadge statusKey={inv.statusKey} accLocale={accLocale} uiLang={uiLang} />
                  </td>
                </tr>
              ))}
              {filteredInvoices.length === 0 && (
                <tr>
                  <td colSpan={8} className="px-8 py-20 text-center text-[#5c5c5a] italic">
                    <div className="flex flex-col items-center">
                      <i className="fas fa-search text-4xl mb-4 opacity-20"></i>
                      <p>{genLabel('invEmpty', 'invoices.empty')}</p>
                      {hasAdvancedFilters && (
                        <button onClick={clearAdvancedFilters} className="mt-3 text-primary text-xs font-bold hover:underline">
                          <i className="fas fa-times mr-1"></i> {t('invoices.clearRetry')}
                        </button>
                      )}
                    </div>
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
};

const StatCard: React.FC<{ title: string, value: string, sub: string, icon: string, color: string, bg: string }> = ({ title, value, sub, icon, color, bg }) => (
  <div className="glass-card p-6 rounded-xl group hover:border-primary/30 transition-all duration-300" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.05)' }}>
    <div className="flex items-center justify-between mb-4">
      <div className={`w-12 h-12 ${bg} rounded-xl flex items-center justify-center ${color} group-hover:scale-110 transition-transform`}>
        <i className={`fas ${icon} text-xl`}></i>
      </div>
      <div className="text-right">
        <p className="text-[#5c5c5a] text-[10px] uppercase font-bold tracking-widest">{title}</p>
        <p className={`text-2xl font-bold ${color} tracking-tighter`}>{value}</p>
      </div>
    </div>
    <p className="text-[#5c5c5a] text-xs italic">{sub}</p>
  </div>
);

const FilterTab: React.FC<{ active: boolean, onClick: () => void, label: string }> = ({ active, onClick, label }) => (
  <button
    onClick={onClick}
    className={`px-5 py-2 rounded-xl text-xs font-bold whitespace-nowrap transition-all duration-300 ${active ? 'bg-primary text-white' : 'text-[#5c5c5a] hover:text-[#4a4a48]'}`}
    style={active ? { boxShadow: '0 4px 16px rgba(39,76,146,0.15)' } : {}}
  >
    {label}
  </button>
);

const statusI18nMap: Record<string, string> = {
  verified: 'invoices.statusVerified',
  certified: 'invoices.statusCertified',
  deducted: 'invoices.statusDeducted',
  pendingCert: 'invoices.statusPendingCert',
  pendingIssue: 'invoices.statusPendingInvoice',
  issued: 'invoices.statusIssued',
};

// Every non-CN accountingLocale maps each status to a generic document-status
// taxConcept (no CN-VAT 认证/抵扣 wording). Used by both the filter dropdown and
// the table StatusBadge so non-CN never renders the CN invoices.status* wording.
const usStatusTaxKey: Record<string, string> = {
  all: 'invStatusAll',
  verified: 'invStatusVerified',
  certified: 'invStatusCertified',
  deducted: 'invStatusDeducted',
  pendingCert: 'invStatusPendingCert',
  pendingIssue: 'invStatusPendingIssue',
  issued: 'invStatusIssued',
};

const StatusBadge: React.FC<{ statusKey: string, accLocale: string, uiLang: string }> = ({ statusKey, accLocale, uiLang }) => {
  const { t } = useTranslation();
  const colors: Record<string, string> = {
    verified: 'bg-primary/10 text-primary border-primary/20',
    certified: 'bg-emerald-500/10 text-emerald-600 border-emerald-500/20',
    deducted: 'bg-purple-500/10 text-purple-400 border-purple-500/20',
    issued: 'bg-blue-500/10 text-blue-600 border-blue-500/20',
  };
  // Non-CN (US/JP/KR/TW/EU): resolve via the generic document-status taxConcept
  // (no raw key, no CN-VAT 认证/抵扣 wording). CN: unchanged invoices.status* i18n.
  const label = accLocale !== 'CN' && usStatusTaxKey[statusKey]
    ? getTaxLabel(accLocale, uiLang, usStatusTaxKey[statusKey])
    : (statusI18nMap[statusKey] ? t(statusI18nMap[statusKey]) : statusKey);
  return (
    <span className={`inline-block min-w-[3.5rem] text-center whitespace-nowrap px-2 py-0.5 rounded border text-[10px] font-bold ${colors[statusKey] || 'bg-[#f0eeeb]/10 text-[#4a4a48] border-[#e0ddd5]/20'}`}>
      {label}
    </span>
  );
};

export default InventoryPage;
