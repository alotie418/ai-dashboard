// TransactionsPage — 国际化数据模型核心页面（E+G 阶段）
// 替代旧的 SalesAndOutputPage + PurchaseAndInputPage
// 统一 income/expense 视图，内置 category 选择器（映射到报表行）

import React, { useState, useEffect, useCallback } from 'react';
import { useTranslation } from 'react-i18next';
import {
  listTransactions, createTransaction, updateTransaction, deleteTransaction,
  fetchTransactionSummary, listCategories, fetchSettings,
  type Transaction, type TransactionUpsert, type TransactionSummary, type Category,
  type AccountingLocale, type TransactionType,
} from '../services/api';
import { getTaxLabel, formatMoney } from './accountingHelpers';
import { getSystemErrorText } from '../services/systemErrors';
import { useEscapeToClose } from '../hooks/useEscapeToClose';

const TransactionsPage: React.FC = () => {
  const { t, i18n } = useTranslation();
  const lang = i18n.language;

  const [activeType, setActiveType] = useState<TransactionType>('expense');
  const [transactions, setTransactions] = useState<Transaction[]>([]);
  const [categories, setCategories] = useState<Category[]>([]);
  const [summary, setSummary] = useState<TransactionSummary | null>(null);
  const [locale, setLocale] = useState<AccountingLocale>('CN');
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  // Form state
  const [showForm, setShowForm] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [form, setForm] = useState<Partial<TransactionUpsert>>({});
  const [saving, setSaving] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState<string | null>(null);

  // C6-2: close the form modal on Escape (ignores IME composition; suppressed while saving).
  useEscapeToClose(showForm && !saving, () => setShowForm(false));

  const reload = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const settings = await fetchSettings();
      const loc = ((settings as any).accounting_locale || 'CN') as AccountingLocale;
      setLocale(loc);

      const [txns, cats, sum] = await Promise.all([
        listTransactions({ type: activeType, limit: 500 }),
        listCategories({ locale: loc, type: activeType, lang }),
        fetchTransactionSummary({}),
      ]);
      setTransactions(txns);
      setCategories(cats);
      setSummary(sum);
    } catch (e: any) {
      console.error(e);
      setError(t('common.operationFailed'));
    } finally {
      setLoading(false);
    }
  }, [activeType, lang]);

  useEffect(() => { reload(); }, [reload]);

  const getCategoryLabel = (catId: string | null) => {
    if (!catId) return '—';
    const cat = categories.find(c => c.id === catId);
    return cat ? cat.displayLabel : catId;
  };

  const getCategoryScheduleLine = (catId: string | null) => {
    if (!catId) return null;
    const cat = categories.find(c => c.id === catId);
    return cat?.schedule_line || null;
  };

  const openNew = () => {
    setEditingId(null);
    setForm({
      id: `txn-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`,
      type: activeType,
      date: new Date().toISOString().split('T')[0],
      amount: 0,
      currency: locale === 'US' ? 'USD' : locale === 'JP' ? 'JPY' : locale === 'EU' ? 'EUR' : locale === 'KR' ? 'KRW' : locale === 'TW' ? 'TWD' : 'CNY',
      // PR-T5-2B-2: default expense entries to the first operating (non-COGS)
      // category so manual costs don't silently land in COGS; income unchanged.
      category_id: activeType === 'expense'
        ? (categories.find(c => !c.is_cogs)?.id ?? categories[0]?.id)
        : categories[0]?.id,
      counterparty: '',
      description: '',
      payment_status: 'paid',
    });
    setShowForm(true);
  };

  const openEdit = (txn: Transaction) => {
    setEditingId(txn.id);
    setForm({ ...txn });
    setShowForm(true);
  };

  const handleSave = async () => {
    if (!form.date || !form.amount) { setError(t('common2.noData')); return; }
    setSaving(true);
    setError(null);
    try {
      if (editingId) {
        await updateTransaction(editingId, form as any);
      } else {
        await createTransaction(form as TransactionUpsert);
      }
      setShowForm(false);
      setForm({});
      await reload();
    } catch (e: any) {
      console.error(e);
      setError(getSystemErrorText(e, t) || t('common.operationFailed'));
    } finally {
      setSaving(false);
    }
  };

  const handleDelete = async (id: string) => {
    try {
      await deleteTransaction(id);
      setConfirmDelete(null);
      await reload();
    } catch (e: any) {
      console.error(e);
      setError(getSystemErrorText(e, t) || t('common.operationFailed'));
    }
  };

  const fmt = (v: number) => v.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  // Summary totals follow the accountingLocale currency (TW → NT$0.00, JP/KR → no
  // decimals) instead of a bare number.
  const money = (v: number) => formatMoney(v || 0, locale, lang);
  // Dates display as YYYY/MM/DD (台湾/中文常用格式, e.g. 2026/06/07) rather than the
  // stored ISO YYYY-MM-DD; never MM/DD/YYYY. The stored value (form/input) stays ISO.
  const fmtDate = (d: string) => (d || '').replace(/-/g, '/');
  // TW + zh-CN/zh-TW formal table headers: 类别 / 会计科目 / 付款状态·收款状态 (by tab).
  // US keeps 账户 for the schedule column; other locales keep the shared i18n
  // (transactions.category / transactions.scheduleLine / tableHeaders.status).
  // UI language stays Simplified Chinese; only the accounting wording is Taiwan-style.
  const twZh = locale === 'TW' && (lang === 'zh-CN' || lang === 'zh-TW');
  const catHeaderLabel = twZh
    ? getTaxLabel(locale, lang, 'txnCategoryHeader')
    : t('transactions.category', 'Category');
  const scheduleHeaderLabel = locale === 'US'
    ? getTaxLabel(locale, lang, 'txnAccountHeader')
    : twZh
    ? getTaxLabel(locale, lang, 'txnScheduleHeader')
    : t('transactions.scheduleLine', 'Report Line');
  const statusHeaderLabel = twZh
    ? getTaxLabel(locale, lang, activeType === 'income' ? 'txnReceiptStatusHeader' : 'txnPaymentStatusHeader')
    : t('tableHeaders.status');
  const mapsToLabel = twZh
    ? getTaxLabel(locale, lang, 'txnScheduleHeader')
    : t('transactions.mapsToLine', 'Maps to report line');

  return (
    <div className="max-w-7xl mx-auto space-y-6 animate-in fade-in slide-in-from-bottom-4 duration-500">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-2xl font-bold text-[#191918]">{t('transactions.title', 'Transactions')}</h2>
          <p className="text-sm text-[#5c5c5a] mt-1">{t('transactions.pageSubtitle')}</p>
        </div>
        <button onClick={openNew} className="flex items-center px-5 py-2.5 bg-primary hover:bg-primary-hover text-white rounded-xl text-sm font-medium transition-all" style={{ boxShadow: '0 4px 16px rgba(39,76,146,0.15)' }}>
          <i className="fas fa-plus mr-2"></i> {t('transactions.add', 'New Transaction')}
        </button>
      </div>

      {/* Summary Cards */}
      {summary && (
        <div className="grid grid-cols-3 gap-4">
          <div className="bg-white/80 border border-[#e0ddd5] p-5 rounded-xl">
            <p className="text-[10px] uppercase tracking-widest text-[#5c5c5a] font-bold">{t('transactions.totalIncome', 'Total Income')}</p>
            <p className="text-xl font-bold text-emerald-600 mt-1">{money(summary.income.total)}</p>
            <p className="text-[11px] text-[#5c5c5a]">{summary.income.count} {t('transactions.items', 'items')}</p>
          </div>
          <div className="bg-white/80 border border-[#e0ddd5] p-5 rounded-xl">
            <p className="text-[10px] uppercase tracking-widest text-[#5c5c5a] font-bold">{t('transactions.totalExpense', 'Total Expense')}</p>
            <p className="text-xl font-bold text-rose-500 mt-1">{money(summary.expense.total)}</p>
            <p className="text-[11px] text-[#5c5c5a]">{summary.expense.count} {t('transactions.items', 'items')}</p>
          </div>
          <div className="bg-white/80 border border-[#e0ddd5] p-5 rounded-xl">
            <p className="text-[10px] uppercase tracking-widest text-[#5c5c5a] font-bold">{t('transactions.netIncome', 'Net Income')}</p>
            <p className={`text-xl font-bold mt-1 ${summary.net >= 0 ? 'text-emerald-600' : 'text-rose-500'}`}>{money(summary.net)}</p>
            {/* Net income shows a formula hint, never a record count (it is income − expense, not a list) */}
            <p className="text-[11px] text-[#5c5c5a]">{t('transactions.netIncomeFormula', 'Income - Expense')}</p>
          </div>
        </div>
      )}
      {/* PR-B: tax-basis note for the income/expense totals (kept off the tight 10px card titles) */}
      {summary && <p className="text-[11px] text-[#5c5c5a] px-1">{t('transactions.amountBasisNote')}</p>}

      {/* Income / Expense Tab */}
      <div className="flex border-b border-[#e0ddd5]">
        {(['expense', 'income'] as TransactionType[]).map(tp => (
          <button key={tp} onClick={() => setActiveType(tp)}
            className={`px-6 py-2.5 text-sm font-medium border-b-2 transition-colors ${activeType === tp ? 'border-primary text-primary' : 'border-transparent text-[#5c5c5a] hover:text-[#4a4a48]'}`}>
            {tp === 'expense' ? t('transactions.expense', 'Expenses') : t('transactions.income', 'Income')}
          </button>
        ))}
      </div>

      {error && (
        <div className="text-sm text-rose-600 bg-rose-50 border border-rose-200 rounded-lg px-4 py-2">
          <i className="fas fa-exclamation-circle mr-2"></i>{error}
        </div>
      )}

      {/* Table */}
      {loading ? (
        <div className="text-center py-10 text-sm text-[#5c5c5a]"><i className="fas fa-spinner fa-spin mr-2 text-primary"></i>{t('common.loading')}</div>
      ) : (
        <div className="border border-[#e0ddd5] rounded-xl overflow-hidden bg-white/80">
          {/* overflow-x-auto: small screens scroll horizontally instead of squeezing columns */}
          <div className="overflow-x-auto">
          {/* table-fixed gives the colgroup widths authority (the earlier even-spread came
              from auto layout). Six columns are fixed px; counterparty is the single
              flexible column (no width) so the table fills the card via w-full WITHOUT
              diluting the fixed columns — amount/status render at exactly 170/150 instead
              of being proportionally stretched. min-w-[1080px] is the floor (counterparty
              ≥180px there); the overflow-x-auto wrapper scrolls on narrower screens. */}
          <table className="w-full text-sm table-fixed min-w-[1080px]">
            <colgroup>
              <col className="w-[120px]" />{/* date */}
              <col />{/* counterparty (supplier/customer) — flexible, absorbs extra width */}
              <col className="w-[160px]" />{/* category */}
              <col className="w-[180px]" />{/* report line / account */}
              <col className="w-[170px]" />{/* amount */}
              <col className="w-[150px]" />{/* status */}
              <col className="w-[120px]" />{/* action (≥100 to fit en/fr confirm·cancel) */}
            </colgroup>
            <thead className="bg-[#f9f9f8] text-[10px] uppercase tracking-wider text-[#4a4a48]">
              <tr>
                <th className="text-left px-4 py-2.5 whitespace-nowrap">{t('tableHeaders.date')}</th>
                <th className="text-left px-4 py-2.5 whitespace-nowrap">{activeType === 'income' ? t('tableHeaders.customer') : t('tableHeaders.supplier')}</th>
                <th className="text-left px-4 py-2.5 whitespace-nowrap">{catHeaderLabel}</th>
                <th className="text-left px-4 py-2.5 whitespace-nowrap">{scheduleHeaderLabel}</th>
                <th className="text-right px-4 py-2.5 whitespace-nowrap">{t('transactions.amount', 'Amount')}</th>
                <th className="text-center px-4 py-2.5 whitespace-nowrap">{statusHeaderLabel}</th>
                <th className="text-right px-4 py-2.5 whitespace-nowrap">{t('tableHeaders.action')}</th>
              </tr>
            </thead>
            <tbody>
              {transactions.length === 0 ? (
                <tr><td colSpan={7} className="text-center py-10 text-[#5c5c5a]">{t('transactions.empty', 'No transactions yet. Click "New Transaction" to add one.')}</td></tr>
              ) : transactions.map(txn => (
                <tr key={txn.id} className="border-t border-[#e0ddd5]/70 hover:bg-[#f9f9f8]/40">
                  <td className="px-4 py-2.5 text-[#191918] whitespace-nowrap">{fmtDate(txn.date)}</td>
                  <td className="px-4 py-2.5 text-[#4a4a48] truncate" title={txn.counterparty || ''}>{txn.counterparty || '—'}</td>
                  <td className="px-4 py-2.5 truncate">
                    <span className="inline-block max-w-full truncate align-middle text-xs bg-[#f0eeeb] px-2 py-0.5 rounded" title={getCategoryLabel(txn.category_id)}>{getCategoryLabel(txn.category_id)}</span>
                  </td>
                  <td className="px-4 py-2.5 text-[11px] text-[#5c5c5a] font-mono truncate" title={getCategoryScheduleLine(txn.category_id) || ''}>{getCategoryScheduleLine(txn.category_id) || '—'}</td>
                  <td className="px-4 py-2.5 text-right font-mono font-medium whitespace-nowrap">{fmt(txn.amount)}</td>
                  <td className="px-4 py-2.5 text-center whitespace-nowrap">
                    <span className={`text-[10px] font-bold uppercase px-2 py-0.5 rounded ${txn.payment_status === 'paid' ? 'bg-emerald-50 text-emerald-600' : txn.payment_status === 'partial' ? 'bg-amber-50 text-amber-600' : 'bg-rose-50 text-rose-600'}`}>
                      {txn.payment_status === 'paid' ? t('transactions.paid') : txn.payment_status === 'partial' ? t('transactions.partial') : t('transactions.unpaid')}
                    </span>
                  </td>
                  <td className="px-4 py-2.5 text-right space-x-2 whitespace-nowrap">
                    <button onClick={() => openEdit(txn)} className="text-xs text-primary hover:text-primary-hover">{t('common2.edit')}</button>
                    {confirmDelete === txn.id ? (
                      <span className="inline-flex space-x-1">
                        <button onClick={() => handleDelete(txn.id)} className="text-[10px] px-2 py-0.5 bg-rose-600 text-white rounded">{t('common.confirm')}</button>
                        <button onClick={() => setConfirmDelete(null)} className="text-[10px] px-2 py-0.5 border border-rose-300 text-rose-600 rounded">{t('common.cancel')}</button>
                      </span>
                    ) : (
                      <button onClick={() => setConfirmDelete(txn.id)} className="text-xs text-rose-500 hover:text-rose-700">{t('common2.delete')}</button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          </div>
        </div>
      )}

      {/* Add/Edit Form Modal */}
      {showForm && (
        <div className="fixed inset-0 bg-black/30 z-50 flex items-center justify-center p-6" onClick={() => setShowForm(false)}>
          <div className="bg-white rounded-2xl w-full max-w-lg p-8 shadow-2xl space-y-5" onClick={e => e.stopPropagation()}>
            <h3 className="text-lg font-bold text-[#191918]">
              {editingId ? t('transactions.editTitle', 'Edit Transaction') : t('transactions.addTitle', 'New Transaction')}
            </h3>

            <div className="grid grid-cols-2 gap-4">
              <div>
                <label className="block text-xs font-medium text-[#4a4a48] mb-1">{t('tableHeaders.date')}</label>
                <input type="date" value={form.date || ''} onChange={e => setForm(f => ({ ...f, date: e.target.value }))}
                  className="w-full px-3 py-2 border border-[#e0ddd5] rounded-lg text-sm" />
              </div>
              <div>
                <label className="block text-xs font-medium text-[#4a4a48] mb-1">{t('transactions.amount', 'Amount')}</label>
                <input type="number" step="0.01" value={form.amount || ''} onChange={e => setForm(f => ({ ...f, amount: Number(e.target.value) }))}
                  className="w-full px-3 py-2 border border-[#e0ddd5] rounded-lg text-sm" />
              </div>
            </div>

            <div>
              <label className="block text-xs font-medium text-[#4a4a48] mb-1">{activeType === 'income' ? t('tableHeaders.customer') : t('tableHeaders.supplier')}</label>
              <input type="text" value={form.counterparty || ''} onChange={e => setForm(f => ({ ...f, counterparty: e.target.value }))}
                className="w-full px-3 py-2 border border-[#e0ddd5] rounded-lg text-sm" />
            </div>

            {/* Category selector with report line mapping */}
            <div>
              <label className="block text-xs font-medium text-[#4a4a48] mb-1">
                {catHeaderLabel}
                <span className="text-[#5c5c5a] font-normal ml-2">→ {mapsToLabel}</span>
              </label>
              <select value={form.category_id || ''} onChange={e => setForm(f => ({ ...f, category_id: e.target.value || undefined }))}
                className="w-full px-3 py-2 border border-[#e0ddd5] rounded-lg text-sm bg-white">
                <option value="">— {t('transactions.noCategory', 'No category')} —</option>
                {categories.map(cat => (
                  <option key={cat.id} value={cat.id}>
                    {cat.displayLabel}{cat.schedule_line ? ` → ${cat.schedule_line}` : ''}
                  </option>
                ))}
              </select>
            </div>

            <div>
              <label className="block text-xs font-medium text-[#4a4a48] mb-1">{t('transactions.description', 'Description')}</label>
              <input type="text" value={form.description || ''} onChange={e => setForm(f => ({ ...f, description: e.target.value }))}
                placeholder={t('transactions.descPlaceholder', 'Optional notes...')}
                className="w-full px-3 py-2 border border-[#e0ddd5] rounded-lg text-sm" />
            </div>

            <div className="grid grid-cols-2 gap-4">
              <div>
                <label className="block text-xs font-medium text-[#4a4a48] mb-1">{t('tableHeaders.invoiceNo')}</label>
                <input type="text" value={form.invoice_no || ''} onChange={e => setForm(f => ({ ...f, invoice_no: e.target.value }))}
                  className="w-full px-3 py-2 border border-[#e0ddd5] rounded-lg text-sm" />
              </div>
              <div>
                <label className="block text-xs font-medium text-[#4a4a48] mb-1">{t('tableHeaders.status')}</label>
                <select value={form.payment_status || 'paid'} onChange={e => setForm(f => ({ ...f, payment_status: e.target.value as any }))}
                  className="w-full px-3 py-2 border border-[#e0ddd5] rounded-lg text-sm bg-white">
                  <option value="paid">{t('transactions.paid', 'Paid')}</option>
                  <option value="partial">{t('transactions.partial', 'Partial')}</option>
                  <option value="unpaid">{t('transactions.unpaid', 'Unpaid')}</option>
                </select>
              </div>
            </div>

            <div className="flex justify-end space-x-3 pt-2">
              <button onClick={() => setShowForm(false)} className="px-5 py-2 border border-[#e0ddd5] text-[#4a4a48] rounded-lg text-sm font-medium hover:bg-[#f0eeeb]">
                {t('common.cancel')}
              </button>
              <button onClick={handleSave} disabled={saving} className="px-5 py-2 bg-primary text-white rounded-lg text-sm font-medium hover:bg-primary-hover disabled:opacity-50">
                {saving ? <><i className="fas fa-spinner fa-spin mr-2"></i>{t('common.saving')}</> : t('common.save')}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
};

export default TransactionsPage;
