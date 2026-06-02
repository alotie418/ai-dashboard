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
import { getTaxLabel } from './accountingHelpers';

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
      setError(e?.message || 'Failed to load');
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
      category_id: categories.length > 0 ? categories[0].id : undefined,
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
      setError(e?.message || 'Save failed');
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
      setError(e?.message || 'Delete failed');
    }
  };

  const fmt = (v: number) => v.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  // US accountingLocale labels the report-line column as 账户 (the Schedule C
  // line is effectively the expense account); other locales keep the existing
  // transactions.scheduleLine value via the default fallback.
  const usLabel = (taxKey: string, i18nKey: string, fallback: string) =>
    locale === 'US' ? getTaxLabel(locale, lang, taxKey) : t(i18nKey, fallback);

  return (
    <div className="max-w-7xl mx-auto space-y-6 animate-in fade-in slide-in-from-bottom-4 duration-500">
      {/* Header */}
      <div className="flex items-center justify-between">
        <h2 className="text-2xl font-bold text-[#191918]">{t('transactions.title', 'Transactions')}</h2>
        <button onClick={openNew} className="flex items-center px-5 py-2.5 bg-[#d97757] hover:bg-[#c56a4a] text-white rounded-xl text-sm font-medium transition-all" style={{ boxShadow: '0 4px 16px rgba(217,119,87,0.15)' }}>
          <i className="fas fa-plus mr-2"></i> {t('transactions.add', 'New Transaction')}
        </button>
      </div>

      {/* Summary Cards */}
      {summary && (
        <div className="grid grid-cols-3 gap-4">
          <div className="bg-white/80 border border-[#e0ddd5] p-5 rounded-xl">
            <p className="text-[10px] uppercase tracking-widest text-[#5c5c5a] font-bold">{t('transactions.totalIncome', 'Total Income')}</p>
            <p className="text-xl font-bold text-emerald-600 mt-1">{fmt(summary.income.total)}</p>
            <p className="text-[11px] text-[#7a7a78]">{summary.income.count} {t('transactions.items', 'items')}</p>
          </div>
          <div className="bg-white/80 border border-[#e0ddd5] p-5 rounded-xl">
            <p className="text-[10px] uppercase tracking-widest text-[#5c5c5a] font-bold">{t('transactions.totalExpense', 'Total Expense')}</p>
            <p className="text-xl font-bold text-rose-500 mt-1">{fmt(summary.expense.total)}</p>
            <p className="text-[11px] text-[#7a7a78]">{summary.expense.count} {t('transactions.items', 'items')}</p>
          </div>
          <div className="bg-white/80 border border-[#e0ddd5] p-5 rounded-xl">
            <p className="text-[10px] uppercase tracking-widest text-[#5c5c5a] font-bold">{t('transactions.netIncome', 'Net Income')}</p>
            <p className={`text-xl font-bold mt-1 ${summary.net >= 0 ? 'text-emerald-600' : 'text-rose-500'}`}>{fmt(summary.net)}</p>
          </div>
        </div>
      )}

      {/* Income / Expense Tab */}
      <div className="flex border-b border-[#e0ddd5]">
        {(['expense', 'income'] as TransactionType[]).map(tp => (
          <button key={tp} onClick={() => setActiveType(tp)}
            className={`px-6 py-2.5 text-sm font-medium border-b-2 transition-colors ${activeType === tp ? 'border-[#d97757] text-[#d97757]' : 'border-transparent text-[#7a7a78] hover:text-[#4a4a48]'}`}>
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
        <div className="text-center py-10 text-sm text-[#7a7a78]"><i className="fas fa-spinner fa-spin mr-2 text-[#d97757]"></i>{t('common.loading')}</div>
      ) : (
        <div className="border border-[#e0ddd5] rounded-xl overflow-hidden bg-white/80">
          {/* overflow-x-auto: small screens scroll horizontally instead of squeezing columns */}
          <div className="overflow-x-auto">
          {/* table-fixed + colgroup: columns keep their defined widths (no even-spread in
              empty/sparse state); min-w guarantees a horizontal scroll rather than collapse */}
          <table className="w-full text-sm table-fixed min-w-[1060px]">
            <colgroup>
              <col className="w-[120px]" />{/* date */}
              <col className="w-[180px]" />{/* counterparty (supplier/customer) */}
              <col className="w-[160px]" />{/* category */}
              <col className="w-[180px]" />{/* report line / account */}
              <col className="w-[160px]" />{/* amount */}
              <col className="w-[140px]" />{/* status */}
              <col className="w-[120px]" />{/* action (≥100 to fit en/fr confirm·cancel) */}
            </colgroup>
            <thead className="bg-[#f9f9f8] text-[10px] uppercase tracking-wider text-[#4a4a48]">
              <tr>
                <th className="text-left px-4 py-2.5 whitespace-nowrap">{t('tableHeaders.date')}</th>
                <th className="text-left px-4 py-2.5 whitespace-nowrap">{activeType === 'income' ? t('tableHeaders.customer') : t('tableHeaders.supplier')}</th>
                <th className="text-left px-4 py-2.5 whitespace-nowrap">{t('transactions.category', 'Category')}</th>
                <th className="text-left px-4 py-2.5 whitespace-nowrap">{usLabel('txnAccountHeader', 'transactions.scheduleLine', 'Report Line')}</th>
                <th className="text-right px-4 py-2.5 whitespace-nowrap">{t('transactions.amount', 'Amount')}</th>
                <th className="text-left px-4 py-2.5 whitespace-nowrap">{t('tableHeaders.status')}</th>
                <th className="text-right px-4 py-2.5 whitespace-nowrap">{t('tableHeaders.action')}</th>
              </tr>
            </thead>
            <tbody>
              {transactions.length === 0 ? (
                <tr><td colSpan={7} className="text-center py-10 text-[#7a7a78]">{t('transactions.empty', 'No transactions yet. Click "New Transaction" to add one.')}</td></tr>
              ) : transactions.map(txn => (
                <tr key={txn.id} className="border-t border-[#e0ddd5]/70 hover:bg-[#f9f9f8]/40">
                  <td className="px-4 py-2.5 text-[#191918] whitespace-nowrap">{txn.date}</td>
                  <td className="px-4 py-2.5 text-[#4a4a48] truncate" title={txn.counterparty || ''}>{txn.counterparty || '—'}</td>
                  <td className="px-4 py-2.5 truncate">
                    <span className="inline-block max-w-full truncate align-middle text-xs bg-[#f0eeeb] px-2 py-0.5 rounded" title={getCategoryLabel(txn.category_id)}>{getCategoryLabel(txn.category_id)}</span>
                  </td>
                  <td className="px-4 py-2.5 text-[11px] text-[#7a7a78] font-mono truncate" title={getCategoryScheduleLine(txn.category_id) || ''}>{getCategoryScheduleLine(txn.category_id) || '—'}</td>
                  <td className="px-4 py-2.5 text-right font-mono font-medium whitespace-nowrap">{fmt(txn.amount)}</td>
                  <td className="px-4 py-2.5 whitespace-nowrap">
                    <span className={`text-[10px] font-bold uppercase px-2 py-0.5 rounded ${txn.payment_status === 'paid' ? 'bg-emerald-50 text-emerald-600' : txn.payment_status === 'partial' ? 'bg-amber-50 text-amber-600' : 'bg-rose-50 text-rose-600'}`}>
                      {txn.payment_status}
                    </span>
                  </td>
                  <td className="px-4 py-2.5 text-right space-x-2 whitespace-nowrap">
                    <button onClick={() => openEdit(txn)} className="text-xs text-[#d97757] hover:text-[#c56a4a]">{t('common2.edit')}</button>
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
                {t('transactions.category', 'Category')}
                <span className="text-[#7a7a78] font-normal ml-2">→ {t('transactions.mapsToLine', 'Maps to report line')}</span>
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
              <button onClick={handleSave} disabled={saving} className="px-5 py-2 bg-[#d97757] text-white rounded-lg text-sm font-medium hover:bg-[#c56a4a] disabled:opacity-50">
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
