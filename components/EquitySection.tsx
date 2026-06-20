// 设置页 → 权益/资本登记台账（PR-7D-4，管道层）
// 权益/资本事项手工登记台账。POLICY-NEUTRAL：仅录入/保存/读取/编辑/删除·停用。
// 不做权益合计、不做留存收益/利润结转、不做资产负债表/平衡，不碰 P&L/cashflow/reports，
// 不联动 accounts/transactions。equity_type 仅中性分类无科目映射；amount 允许负、系统不解释方向。
// 纯 UI 语言驱动（i18n），不读 accountingLocale。
import React, { useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import {
  listEquity, createEquity, updateEquity, deleteEquity,
  type EquityEntry, type EquityType,
} from '../services/api';
import { getSystemErrorText } from '../services/systemErrors';

const EQUITY_TYPES: EquityType[] = ['capital_contribution', 'owner_draw', 'adjustment', 'other'];

const EquitySection: React.FC = () => {
  const { t } = useTranslation();
  const [items, setItems] = useState<EquityEntry[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [showForm, setShowForm] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [confirmDelete, setConfirmDelete] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  const [fName, setFName] = useState('');
  const [fOwner, setFOwner] = useState('');
  const [fType, setFType] = useState<EquityType>('capital_contribution');
  const [fAmount, setFAmount] = useState<string>('0');
  const [fCurrency, setFCurrency] = useState('');
  const [fEventDate, setFEventDate] = useState('');
  const [fNote, setFNote] = useState('');

  useEffect(() => { reload(); }, []);

  const reload = async () => {
    setLoading(true);
    setError(null);
    try {
      setItems(await listEquity());
    } catch (e: any) {
      console.error(e);
      setError(t('common.operationFailed'));
    } finally {
      setLoading(false);
    }
  };

  const resetForm = () => {
    setFName(''); setFOwner(''); setFType('capital_contribution'); setFAmount('0'); setFCurrency(''); setFEventDate(''); setFNote('');
  };

  const openAdd = () => { resetForm(); setEditingId(null); setShowForm(true); };

  const openEdit = (e: EquityEntry) => {
    setFName(e.name);
    setFOwner(e.owner || '');
    setFType(e.equity_type);
    setFAmount(String(e.amount ?? 0));
    setFCurrency(e.currency || '');
    setFEventDate(e.event_date || '');
    setFNote(e.note || '');
    setEditingId(e.id);
    setShowForm(true);
  };

  const closeForm = () => { setShowForm(false); setEditingId(null); resetForm(); };

  const typeLabel = (ty: EquityType) =>
    ty === 'owner_draw' ? t('equity.typeOwnerDraw')
      : ty === 'adjustment' ? t('equity.typeAdjustment')
      : ty === 'other' ? t('equity.typeOther')
      : t('equity.typeCapitalContribution');

  const handleSubmit = async () => {
    if (!fName.trim()) return;
    setSaving(true);
    try {
      const payload = {
        name: fName.trim(),
        owner: fOwner.trim() || null,
        equity_type: fType,
        amount: Number(fAmount) || 0,
        currency: fCurrency.trim() || null,
        event_date: fEventDate || null,
        note: fNote.trim() || null,
      };
      if (editingId) await updateEquity(editingId, payload);
      else await createEquity(payload);
      closeForm();
      reload();
    } catch (e: any) {
      console.error(e);
      setError(getSystemErrorText(e, t) || t('common.operationFailed'));
    } finally {
      setSaving(false);
    }
  };

  const handleToggleActive = async (e: EquityEntry) => {
    try { await updateEquity(e.id, { is_active: !e.is_active }); reload(); }
    catch (err: any) { console.error(err); setError(getSystemErrorText(err, t) || t('common.operationFailed')); }
  };

  const handleDelete = async (id: string) => {
    try { await deleteEquity(id); setConfirmDelete(null); reload(); }
    catch (e: any) { console.error(e); setError(getSystemErrorText(e, t) || t('common.operationFailed')); setConfirmDelete(null); }
  };

  return (
    <section className="space-y-6">
      <div>
        <h3 className="text-xl font-bold text-[#191918]">{t('equity.title')}</h3>
        <p className="text-xs text-[#6b6b69] mt-1">{t('equity.subtitle')}</p>
      </div>

      {/* Boundary notes: NOT a balance sheet; registration only — no totals / carry-forward / balancing. */}
      <div className="text-xs text-amber-700 bg-amber-50 border border-amber-200 rounded-lg px-3 py-2 space-y-1">
        <p><i className="fas fa-info-circle mr-1.5"></i>{t('equity.notBalanceSheetNote')}</p>
        <p><i className="fas fa-circle-exclamation mr-1.5"></i>{t('equity.notRollupNote')}</p>
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
                <th className="text-left px-4 py-2.5">{t('equity.name')}</th>
                <th className="text-left px-4 py-2.5">{t('equity.owner')}</th>
                <th className="text-left px-4 py-2.5">{t('equity.type')}</th>
                <th className="text-right px-4 py-2.5">{t('equity.amount')}</th>
                <th className="text-left px-4 py-2.5">{t('equity.currency')}</th>
                <th className="text-left px-4 py-2.5">{t('equity.eventDate')}</th>
                <th className="text-left px-4 py-2.5">{t('equity.status')}</th>
                <th className="text-right px-4 py-2.5 w-28"></th>
              </tr>
            </thead>
            <tbody>
              {items.length === 0 && (
                <tr><td colSpan={8} className="text-center text-[#5c5c5a] py-6 text-xs">{t('equity.empty')}</td></tr>
              )}
              {items.map(e => (
                <tr key={e.id} className="border-t border-[#e0ddd5]/70 hover:bg-[#f9f9f8]/40">
                  <td className="px-4 py-2 text-[#191918] col-name">{e.name}</td>
                  <td className="px-4 py-2 text-[11px] text-[#5c5c5a]">{e.owner || '—'}</td>
                  <td className="px-4 py-2 text-[11px]">
                    <span className="text-[10px] bg-indigo-100 text-indigo-700 px-1.5 py-0.5 rounded">{typeLabel(e.equity_type)}</span>
                  </td>
                  <td className="px-4 py-2 text-right text-[11px] font-mono text-[#191918]">{e.amount}</td>
                  <td className="px-4 py-2 text-[11px] text-[#5c5c5a]">{e.currency || '—'}</td>
                  <td className="px-4 py-2 text-[11px] text-[#5c5c5a]">{e.event_date || '—'}</td>
                  <td className="px-4 py-2 text-[11px]">
                    <button onClick={() => handleToggleActive(e)} className={e.is_active ? 'text-emerald-600' : 'text-[#a8a8a6]'}>
                      <i className={`fas ${e.is_active ? 'fa-toggle-on' : 'fa-toggle-off'} mr-1`}></i>{e.is_active ? t('equity.active') : t('equity.inactive')}
                    </button>
                  </td>
                  <td className="px-4 py-2 text-right whitespace-nowrap">
                    {confirmDelete === e.id ? (
                      <div className="inline-flex items-center space-x-1">
                        <button onClick={() => handleDelete(e.id)} className="text-[10px] px-2 py-0.5 bg-rose-600 text-white rounded">{t('common.delete')}</button>
                        <button onClick={() => setConfirmDelete(null)} className="text-[10px] px-2 py-0.5 border border-rose-300 text-rose-600 rounded">{t('common.cancel')}</button>
                      </div>
                    ) : (
                      <div className="inline-flex items-center space-x-3">
                        <button onClick={() => openEdit(e)} className="text-[10px] text-primary hover:text-primary-hover">
                          <i className="fas fa-pen mr-1"></i>{t('common.edit')}
                        </button>
                        <button onClick={() => setConfirmDelete(e.id)} className="text-[10px] text-rose-600 hover:text-rose-700">
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
          <div className="text-sm font-semibold text-[#191918]">{editingId ? t('equity.editTitle') : t('equity.addTitle')}</div>
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('equity.name')}</label>
              <input value={fName} onChange={e => setFName(e.target.value)} placeholder={t('equity.namePlaceholder')}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('equity.owner')}</label>
              <input value={fOwner} onChange={e => setFOwner(e.target.value)} placeholder={t('equity.ownerPlaceholder')}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('equity.type')}</label>
              <select value={fType} onChange={e => setFType(e.target.value as EquityType)}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white">
                {EQUITY_TYPES.map(k => (<option key={k} value={k}>{typeLabel(k)}</option>))}
              </select>
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('equity.amount')}</label>
              <input type="number" step="0.01" value={fAmount} onChange={e => setFAmount(e.target.value)}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('equity.currency')}</label>
              <input value={fCurrency} onChange={e => setFCurrency(e.target.value)} placeholder={t('equity.currencyPlaceholder')}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('equity.eventDate')}</label>
              <input type="date" value={fEventDate} onChange={e => setFEventDate(e.target.value)}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
            <div className="col-span-2">
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('equity.note')}</label>
              <input value={fNote} onChange={e => setFNote(e.target.value)} placeholder={t('equity.notePlaceholder')}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
          </div>
          <p className="text-[10px] text-[#8a8a88]"><i className="fas fa-circle-info mr-1"></i>{t('equity.amountHint')}</p>
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
          <i className="fas fa-plus mr-1.5"></i>{t('equity.addButton')}
        </button>
      )}
    </section>
  );
};

export default EquitySection;
