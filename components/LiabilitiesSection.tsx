// 设置页 → 负债 / 借款台账（PR-7D-2，管道层）
// 借款 / 其他负债手工台账 + 期初未偿余额。POLICY-NEUTRAL：仅录入/保存/读取/编辑/删除·结清。
// ≠ 采购应付账款（应付仍由 purchases 聚合）。不展示资产负债表、不 roll-up、不做还款计划、
// 不算利息、不碰 P&L/cashflow/reports。opening_balance 允许为负；interest_rate 仅备查不计算。
// 纯 UI 语言驱动（i18n），不读 accountingLocale。
import React, { useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import {
  listLiabilities, createLiability, updateLiability, deleteLiability,
  type Liability, type LiabilityType,
} from '../services/api';
import { getSystemErrorText } from '../services/systemErrors';

const LIABILITY_TYPES: LiabilityType[] = ['loan', 'other'];

const LiabilitiesSection: React.FC = () => {
  const { t } = useTranslation();
  const [items, setItems] = useState<Liability[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [showForm, setShowForm] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [confirmDelete, setConfirmDelete] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  const [fName, setFName] = useState('');
  const [fLender, setFLender] = useState('');
  const [fType, setFType] = useState<LiabilityType>('loan');
  const [fCurrency, setFCurrency] = useState('');
  const [fPrincipal, setFPrincipal] = useState<string>('');
  const [fOpening, setFOpening] = useState<string>('0');
  const [fOpeningDate, setFOpeningDate] = useState('');
  const [fRate, setFRate] = useState<string>('');
  const [fMaturity, setFMaturity] = useState('');
  const [fNote, setFNote] = useState('');

  useEffect(() => { reload(); }, []);

  const reload = async () => {
    setLoading(true);
    setError(null);
    try {
      setItems(await listLiabilities());
    } catch (e: any) {
      console.error(e);
      setError(t('common.operationFailed'));
    } finally {
      setLoading(false);
    }
  };

  const resetForm = () => {
    setFName(''); setFLender(''); setFType('loan'); setFCurrency('');
    setFPrincipal(''); setFOpening('0'); setFOpeningDate(''); setFRate(''); setFMaturity(''); setFNote('');
  };

  const openAdd = () => { resetForm(); setEditingId(null); setShowForm(true); };

  const openEdit = (l: Liability) => {
    setFName(l.name);
    setFLender(l.lender || '');
    setFType(l.liability_type);
    setFCurrency(l.currency || '');
    setFPrincipal(l.principal != null ? String(l.principal) : '');
    setFOpening(String(l.opening_balance ?? 0));
    setFOpeningDate(l.opening_date || '');
    setFRate(l.interest_rate != null ? String(l.interest_rate) : '');
    setFMaturity(l.maturity_date || '');
    setFNote(l.note || '');
    setEditingId(l.id);
    setShowForm(true);
  };

  const closeForm = () => { setShowForm(false); setEditingId(null); resetForm(); };

  const handleSubmit = async () => {
    if (!fName.trim()) return;
    setSaving(true);
    try {
      const payload = {
        name: fName.trim(),
        lender: fLender.trim() || null,
        liability_type: fType,
        currency: fCurrency.trim() || null,
        principal: fPrincipal.trim() === '' ? null : Number(fPrincipal),
        opening_balance: Number(fOpening) || 0,
        opening_date: fOpeningDate || null,
        interest_rate: fRate.trim() === '' ? null : Number(fRate),
        maturity_date: fMaturity || null,
        note: fNote.trim() || null,
      };
      if (editingId) await updateLiability(editingId, payload);
      else await createLiability(payload);
      closeForm();
      reload();
    } catch (e: any) {
      console.error(e);
      setError(getSystemErrorText(e, t) || t('common.operationFailed'));
    } finally {
      setSaving(false);
    }
  };

  const handleToggleActive = async (l: Liability) => {
    try { await updateLiability(l.id, { is_active: !l.is_active }); reload(); }
    catch (e: any) { console.error(e); setError(getSystemErrorText(e, t) || t('common.operationFailed')); }
  };

  const handleDelete = async (id: string) => {
    try { await deleteLiability(id); setConfirmDelete(null); reload(); }
    catch (e: any) { console.error(e); setError(getSystemErrorText(e, t) || t('common.operationFailed')); setConfirmDelete(null); }
  };

  return (
    <section className="space-y-6">
      <div>
        <h3 className="text-xl font-bold text-[#191918]">{t('liabilities.title')}</h3>
        <p className="text-xs text-[#6b6b69] mt-1">{t('liabilities.subtitle')}</p>
      </div>

      {/* Boundary notes: NOT a balance sheet; NOT trade payables. */}
      <div className="text-xs text-amber-700 bg-amber-50 border border-amber-200 rounded-lg px-3 py-2 space-y-1">
        <p><i className="fas fa-info-circle mr-1.5"></i>{t('liabilities.notBalanceSheetNote')}</p>
        <p><i className="fas fa-circle-exclamation mr-1.5"></i>{t('liabilities.notTradePayableNote')}</p>
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
                <th className="text-left px-4 py-2.5">{t('liabilities.name')}</th>
                <th className="text-left px-4 py-2.5">{t('liabilities.type')}</th>
                <th className="text-left px-4 py-2.5">{t('liabilities.lender')}</th>
                <th className="text-left px-4 py-2.5">{t('liabilities.currency')}</th>
                <th className="text-right px-4 py-2.5">{t('liabilities.openingBalance')}</th>
                <th className="text-right px-4 py-2.5">{t('liabilities.interestRate')}</th>
                <th className="text-left px-4 py-2.5">{t('liabilities.maturityDate')}</th>
                <th className="text-left px-4 py-2.5">{t('liabilities.status')}</th>
                <th className="text-right px-4 py-2.5 w-28"></th>
              </tr>
            </thead>
            <tbody>
              {items.length === 0 && (
                <tr><td colSpan={9} className="text-center text-[#5c5c5a] py-6 text-xs">{t('liabilities.empty')}</td></tr>
              )}
              {items.map(l => (
                <tr key={l.id} className="border-t border-[#e0ddd5]/70 hover:bg-[#f9f9f8]/40">
                  <td className="px-4 py-2 text-[#191918] col-name">{l.name}</td>
                  <td className="px-4 py-2 text-[11px]">
                    {l.liability_type === 'loan'
                      ? <span className="text-[10px] bg-amber-100 text-amber-700 px-1.5 py-0.5 rounded">{t('liabilities.typeLoan')}</span>
                      : <span className="text-[10px] bg-[#f0eeeb] text-[#5c5c5a] px-1.5 py-0.5 rounded">{t('liabilities.typeOther')}</span>}
                  </td>
                  <td className="px-4 py-2 text-[11px] text-[#5c5c5a]">{l.lender || '—'}</td>
                  <td className="px-4 py-2 text-[11px] text-[#5c5c5a]">{l.currency || '—'}</td>
                  <td className="px-4 py-2 text-right text-[11px] font-mono text-[#191918]">{l.opening_balance}</td>
                  <td className="px-4 py-2 text-right text-[11px] font-mono text-[#5c5c5a]">{l.interest_rate != null ? `${l.interest_rate}%` : '—'}</td>
                  <td className="px-4 py-2 text-[11px] text-[#5c5c5a]">{l.maturity_date || '—'}</td>
                  <td className="px-4 py-2 text-[11px]">
                    <button onClick={() => handleToggleActive(l)} className={l.is_active ? 'text-emerald-600' : 'text-[#a8a8a6]'}>
                      <i className={`fas ${l.is_active ? 'fa-toggle-on' : 'fa-toggle-off'} mr-1`}></i>{l.is_active ? t('liabilities.active') : t('liabilities.closed')}
                    </button>
                  </td>
                  <td className="px-4 py-2 text-right whitespace-nowrap">
                    {confirmDelete === l.id ? (
                      <div className="inline-flex items-center space-x-1">
                        <button onClick={() => handleDelete(l.id)} className="text-[10px] px-2 py-0.5 bg-rose-600 text-white rounded">{t('common.delete')}</button>
                        <button onClick={() => setConfirmDelete(null)} className="text-[10px] px-2 py-0.5 border border-rose-300 text-rose-600 rounded">{t('common.cancel')}</button>
                      </div>
                    ) : (
                      <div className="inline-flex items-center space-x-3">
                        <button onClick={() => openEdit(l)} className="text-[10px] text-primary hover:text-primary-hover">
                          <i className="fas fa-pen mr-1"></i>{t('common.edit')}
                        </button>
                        <button onClick={() => setConfirmDelete(l.id)} className="text-[10px] text-rose-600 hover:text-rose-700">
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
          <div className="text-sm font-semibold text-[#191918]">{editingId ? t('liabilities.editTitle') : t('liabilities.addTitle')}</div>
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('liabilities.name')}</label>
              <input value={fName} onChange={e => setFName(e.target.value)} placeholder={t('liabilities.namePlaceholder')}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('liabilities.type')}</label>
              <select value={fType} onChange={e => setFType(e.target.value as LiabilityType)}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white">
                {LIABILITY_TYPES.map(k => (<option key={k} value={k}>{k === 'loan' ? t('liabilities.typeLoan') : t('liabilities.typeOther')}</option>))}
              </select>
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('liabilities.lender')}</label>
              <input value={fLender} onChange={e => setFLender(e.target.value)} placeholder={t('liabilities.lenderPlaceholder')}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('liabilities.currency')}</label>
              <input value={fCurrency} onChange={e => setFCurrency(e.target.value)} placeholder={t('liabilities.currencyPlaceholder')}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('liabilities.principal')}</label>
              <input type="number" step="0.01" value={fPrincipal} onChange={e => setFPrincipal(e.target.value)} placeholder={t('common.optional')}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('liabilities.openingBalance')}</label>
              <input type="number" step="0.01" value={fOpening} onChange={e => setFOpening(e.target.value)}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('liabilities.openingDate')}</label>
              <input type="date" value={fOpeningDate} onChange={e => setFOpeningDate(e.target.value)}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('liabilities.interestRate')}</label>
              <input type="number" step="0.01" value={fRate} onChange={e => setFRate(e.target.value)} placeholder={t('common.optional')}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('liabilities.maturityDate')}</label>
              <input type="date" value={fMaturity} onChange={e => setFMaturity(e.target.value)}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('liabilities.note')}</label>
              <input value={fNote} onChange={e => setFNote(e.target.value)} placeholder={t('liabilities.notePlaceholder')}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
          </div>
          <p className="text-[10px] text-[#8a8a88]"><i className="fas fa-circle-info mr-1"></i>{t('liabilities.openingHint')}</p>
          <p className="text-[10px] text-[#8a8a88]"><i className="fas fa-circle-info mr-1"></i>{t('liabilities.interestRateHint')}</p>
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
          <i className="fas fa-plus mr-1.5"></i>{t('liabilities.addButton')}
        </button>
      )}
    </section>
  );
};

export default LiabilitiesSection;
