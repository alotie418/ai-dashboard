// 设置页 → 账户与期初余额（建账）管理（PR-7D-1，管道层）
// 现金/银行账户主数据 + 期初余额。POLICY-NEUTRAL：仅录入/保存/读取/编辑/删除·停用。
// 不展示资产负债表、不做合计/平衡断言、不与流水联动（属 PR-7B，须会计确认）。
// 纯 UI 语言驱动（i18n），不读 accountingLocale。
import React, { useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import {
  listAccounts, createAccount, updateAccount, deleteAccount,
  type Account, type AccountType,
} from '../services/api';
import { getSystemErrorText } from '../services/systemErrors';

const ACCOUNT_TYPES: AccountType[] = ['cash', 'bank'];

const AccountsSection: React.FC = () => {
  const { t } = useTranslation();
  const [items, setItems] = useState<Account[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [showForm, setShowForm] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [confirmDelete, setConfirmDelete] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  const [fName, setFName] = useState('');
  const [fType, setFType] = useState<AccountType>('cash');
  const [fCurrency, setFCurrency] = useState('');
  const [fOpening, setFOpening] = useState<string>('0');
  const [fOpeningDate, setFOpeningDate] = useState('');
  const [fNote, setFNote] = useState('');

  useEffect(() => { reload(); }, []);

  const reload = async () => {
    setLoading(true);
    setError(null);
    try {
      setItems(await listAccounts());
    } catch (e: any) {
      console.error(e);
      setError(t('common.operationFailed'));
    } finally {
      setLoading(false);
    }
  };

  const resetForm = () => {
    setFName(''); setFType('cash'); setFCurrency(''); setFOpening('0'); setFOpeningDate(''); setFNote('');
  };

  const openAdd = () => { resetForm(); setEditingId(null); setShowForm(true); };

  const openEdit = (a: Account) => {
    setFName(a.name);
    setFType(a.type);
    setFCurrency(a.currency || '');
    setFOpening(String(a.opening_balance ?? 0));
    setFOpeningDate(a.opening_date || '');
    setFNote(a.note || '');
    setEditingId(a.id);
    setShowForm(true);
  };

  const closeForm = () => { setShowForm(false); setEditingId(null); resetForm(); };

  const handleSubmit = async () => {
    if (!fName.trim()) return;
    setSaving(true);
    try {
      const payload = {
        name: fName.trim(),
        type: fType,
        currency: fCurrency.trim() || null,
        opening_balance: Number(fOpening) || 0,
        opening_date: fOpeningDate || null,
        note: fNote.trim() || null,
      };
      if (editingId) await updateAccount(editingId, payload);
      else await createAccount(payload);
      closeForm();
      reload();
    } catch (e: any) {
      console.error(e);
      setError(getSystemErrorText(e, t) || t('common.operationFailed'));
    } finally {
      setSaving(false);
    }
  };

  const handleToggleActive = async (a: Account) => {
    try { await updateAccount(a.id, { is_active: !a.is_active }); reload(); }
    catch (e: any) { console.error(e); setError(getSystemErrorText(e, t) || t('common.operationFailed')); }
  };

  const handleDelete = async (id: string) => {
    try { await deleteAccount(id); setConfirmDelete(null); reload(); }
    catch (e: any) { console.error(e); setError(getSystemErrorText(e, t) || t('common.operationFailed')); setConfirmDelete(null); }
  };

  return (
    <section className="space-y-6">
      <div>
        <h3 className="text-xl font-bold text-[#191918]">{t('cashAccounts.title')}</h3>
        <p className="text-xs text-[#6b6b69] mt-1">{t('cashAccounts.subtitle')}</p>
      </div>

      {/* Boundary note: this is account / opening-balance bookkeeping, NOT a balance sheet. */}
      <div className="text-xs text-amber-700 bg-amber-50 border border-amber-200 rounded-lg px-3 py-2">
        <i className="fas fa-info-circle mr-1.5"></i>{t('cashAccounts.notBalanceSheetNote')}
      </div>

      {error && (
        <div className="text-sm text-rose-600 bg-rose-50 border border-rose-200 rounded-lg px-3 py-2">
          <i className="fas fa-exclamation-circle mr-2"></i>{error}
        </div>
      )}

      {loading ? (
        <div className="text-sm text-[#5c5c5a] py-6 text-center">
          <i className="fas fa-spinner fa-spin mr-2"></i>{t('common.loading')}
        </div>
      ) : (
        <div className="border border-[#e0ddd5] rounded-xl overflow-hidden">
          <div className="overflow-x-auto">
          <table className="w-full text-sm data-table">
            <thead className="bg-[#f9f9f8] text-[10px] uppercase tracking-wider text-[#4a4a48]">
              <tr>
                <th className="text-left px-4 py-2.5">{t('cashAccounts.name')}</th>
                <th className="text-left px-4 py-2.5">{t('cashAccounts.type')}</th>
                <th className="text-left px-4 py-2.5">{t('cashAccounts.currency')}</th>
                <th className="text-right px-4 py-2.5">{t('cashAccounts.openingBalance')}</th>
                <th className="text-left px-4 py-2.5">{t('cashAccounts.openingDate')}</th>
                <th className="text-left px-4 py-2.5">{t('cashAccounts.status')}</th>
                <th className="text-right px-4 py-2.5 w-28"></th>
              </tr>
            </thead>
            <tbody>
              {items.length === 0 && (
                <tr><td colSpan={7} className="text-center text-[#5c5c5a] py-6 text-xs">{t('cashAccounts.empty')}</td></tr>
              )}
              {items.map(a => (
                <tr key={a.id} className="border-t border-[#e0ddd5]/70 hover:bg-[#f9f9f8]/40">
                  <td className="px-4 py-2 text-[#191918] col-name">{a.name}</td>
                  <td className="px-4 py-2 text-[11px]">
                    {a.type === 'bank'
                      ? <span className="text-[10px] bg-blue-100 text-blue-700 px-1.5 py-0.5 rounded">{t('cashAccounts.typeBank')}</span>
                      : <span className="text-[10px] bg-emerald-100 text-emerald-700 px-1.5 py-0.5 rounded">{t('cashAccounts.typeCash')}</span>}
                  </td>
                  <td className="px-4 py-2 text-[11px] text-[#5c5c5a]">{a.currency || '—'}</td>
                  <td className="px-4 py-2 text-right text-[11px] font-mono text-[#191918]">{a.opening_balance}</td>
                  <td className="px-4 py-2 text-[11px] text-[#5c5c5a]">{a.opening_date || '—'}</td>
                  <td className="px-4 py-2 text-[11px]">
                    <button onClick={() => handleToggleActive(a)} className={a.is_active ? 'text-emerald-600' : 'text-[#a8a8a6]'}>
                      <i className={`fas ${a.is_active ? 'fa-toggle-on' : 'fa-toggle-off'} mr-1`}></i>{a.is_active ? t('cashAccounts.active') : t('cashAccounts.inactive')}
                    </button>
                  </td>
                  <td className="px-4 py-2 text-right whitespace-nowrap">
                    {confirmDelete === a.id ? (
                      <div className="inline-flex items-center space-x-1">
                        <button onClick={() => handleDelete(a.id)} className="text-[10px] px-2 py-0.5 bg-rose-600 text-white rounded">{t('common.delete')}</button>
                        <button onClick={() => setConfirmDelete(null)} className="text-[10px] px-2 py-0.5 border border-rose-300 text-rose-600 rounded">{t('common.cancel')}</button>
                      </div>
                    ) : (
                      <div className="inline-flex items-center space-x-3">
                        <button onClick={() => openEdit(a)} className="text-[10px] text-primary hover:text-primary-hover">
                          <i className="fas fa-pen mr-1"></i>{t('common.edit')}
                        </button>
                        <button onClick={() => setConfirmDelete(a.id)} className="text-[10px] text-rose-600 hover:text-rose-700">
                          <i className="fas fa-trash mr-1"></i>{t('common.delete')}
                        </button>
                      </div>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          </div>
        </div>
      )}

      {showForm ? (
        <div className="border border-primary/30 bg-primary/5 rounded-xl p-4 space-y-3">
          <div className="text-sm font-semibold text-[#191918]">{editingId ? t('cashAccounts.editTitle') : t('cashAccounts.addTitle')}</div>
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('cashAccounts.name')}</label>
              <input value={fName} onChange={e => setFName(e.target.value)} placeholder={t('cashAccounts.namePlaceholder')}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('cashAccounts.type')}</label>
              <select value={fType} onChange={e => setFType(e.target.value as AccountType)}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white">
                {ACCOUNT_TYPES.map(k => (<option key={k} value={k}>{k === 'bank' ? t('cashAccounts.typeBank') : t('cashAccounts.typeCash')}</option>))}
              </select>
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('cashAccounts.currency')}</label>
              <input value={fCurrency} onChange={e => setFCurrency(e.target.value)} placeholder={t('cashAccounts.currencyPlaceholder')}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('cashAccounts.openingBalance')}</label>
              <input type="number" step="0.01" value={fOpening} onChange={e => setFOpening(e.target.value)}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('cashAccounts.openingDate')}</label>
              <input type="date" value={fOpeningDate} onChange={e => setFOpeningDate(e.target.value)}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('cashAccounts.note')}</label>
              <input value={fNote} onChange={e => setFNote(e.target.value)} placeholder={t('cashAccounts.notePlaceholder')}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
          </div>
          <p className="text-[10px] text-[#8a8a88]"><i className="fas fa-circle-info mr-1"></i>{t('cashAccounts.openingHint')}</p>
          <div className="flex space-x-2">
            <button onClick={closeForm} className="text-xs px-4 py-1.5 border border-[#e0ddd5] text-[#4a4a48] rounded-lg hover:bg-[#f0eeeb]">
              {t('common.cancel')}
            </button>
            <button onClick={handleSubmit} disabled={!fName.trim() || saving}
              className="text-xs px-4 py-1.5 bg-primary text-white rounded-lg hover:bg-primary-hover disabled:opacity-50">
              {t('common.save')}
            </button>
          </div>
        </div>
      ) : (
        <button onClick={openAdd} className="w-full border-2 border-dashed border-[#e0ddd5] text-sm text-[#5c5c5a] hover:text-primary hover:border-primary/50 rounded-xl py-3 transition-colors">
          <i className="fas fa-plus mr-1.5"></i>{t('cashAccounts.addButton')}
        </button>
      )}
    </section>
  );
};

export default AccountsSection;
