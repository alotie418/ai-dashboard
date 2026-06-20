// 设置页 → 固定资产登记台账（PR-7D-3，管道层）
// 固定资产手工登记台账。POLICY-NEUTRAL：仅录入/保存/读取/编辑/删除·停用。
// 不折旧、不出净值、不接资产负债表、不生成折旧费用，不碰 P&L/cashflow/reports。
// 无折旧方法/年限/残值字段（留 PR-7B）；category 自由文本；status='disposed' 仅登记标签。
// 纯 UI 语言驱动（i18n），不读 accountingLocale。
import React, { useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import {
  listFixedAssets, createFixedAsset, updateFixedAsset, deleteFixedAsset,
  type FixedAsset, type AssetStatus,
} from '../services/api';
import { getSystemErrorText } from '../services/systemErrors';

const ASSET_STATUSES: AssetStatus[] = ['in_use', 'idle', 'disposed'];

const FixedAssetsSection: React.FC = () => {
  const { t } = useTranslation();
  const [items, setItems] = useState<FixedAsset[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [showForm, setShowForm] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [confirmDelete, setConfirmDelete] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  const [fName, setFName] = useState('');
  const [fCategory, setFCategory] = useState('');
  const [fAcqDate, setFAcqDate] = useState('');
  const [fOriginal, setFOriginal] = useState<string>('0');
  const [fCurrency, setFCurrency] = useState('');
  const [fSupplier, setFSupplier] = useState('');
  const [fSerial, setFSerial] = useState('');
  const [fStatus, setFStatus] = useState<AssetStatus>('in_use');
  const [fNote, setFNote] = useState('');

  useEffect(() => { reload(); }, []);

  const reload = async () => {
    setLoading(true);
    setError(null);
    try {
      setItems(await listFixedAssets());
    } catch (e: any) {
      console.error(e);
      setError(t('common.operationFailed'));
    } finally {
      setLoading(false);
    }
  };

  const resetForm = () => {
    setFName(''); setFCategory(''); setFAcqDate(''); setFOriginal('0'); setFCurrency('');
    setFSupplier(''); setFSerial(''); setFStatus('in_use'); setFNote('');
  };

  const openAdd = () => { resetForm(); setEditingId(null); setShowForm(true); };

  const openEdit = (a: FixedAsset) => {
    setFName(a.name);
    setFCategory(a.category || '');
    setFAcqDate(a.acquisition_date || '');
    setFOriginal(String(a.original_value ?? 0));
    setFCurrency(a.currency || '');
    setFSupplier(a.supplier || '');
    setFSerial(a.serial_no || '');
    setFStatus(a.status);
    setFNote(a.note || '');
    setEditingId(a.id);
    setShowForm(true);
  };

  const closeForm = () => { setShowForm(false); setEditingId(null); resetForm(); };

  const statusLabel = (s: AssetStatus) =>
    s === 'idle' ? t('fixedAssets.statusIdle') : s === 'disposed' ? t('fixedAssets.statusDisposed') : t('fixedAssets.statusInUse');

  const handleSubmit = async () => {
    if (!fName.trim()) return;
    setSaving(true);
    try {
      const payload = {
        name: fName.trim(),
        category: fCategory.trim() || null,
        acquisition_date: fAcqDate || null,
        original_value: Number(fOriginal) || 0,
        currency: fCurrency.trim() || null,
        supplier: fSupplier.trim() || null,
        serial_no: fSerial.trim() || null,
        status: fStatus,
        note: fNote.trim() || null,
      };
      if (editingId) await updateFixedAsset(editingId, payload);
      else await createFixedAsset(payload);
      closeForm();
      reload();
    } catch (e: any) {
      console.error(e);
      setError(getSystemErrorText(e, t) || t('common.operationFailed'));
    } finally {
      setSaving(false);
    }
  };

  const handleToggleActive = async (a: FixedAsset) => {
    try { await updateFixedAsset(a.id, { is_active: !a.is_active }); reload(); }
    catch (e: any) { console.error(e); setError(getSystemErrorText(e, t) || t('common.operationFailed')); }
  };

  const handleDelete = async (id: string) => {
    try { await deleteFixedAsset(id); setConfirmDelete(null); reload(); }
    catch (e: any) { console.error(e); setError(getSystemErrorText(e, t) || t('common.operationFailed')); setConfirmDelete(null); }
  };

  return (
    <section className="space-y-6">
      <div>
        <h3 className="text-xl font-bold text-[#191918]">{t('fixedAssets.title')}</h3>
        <p className="text-xs text-[#6b6b69] mt-1">{t('fixedAssets.subtitle')}</p>
      </div>

      {/* Boundary notes: NOT a balance sheet; registration only — no depreciation / net book value. */}
      <div className="text-xs text-amber-700 bg-amber-50 border border-amber-200 rounded-lg px-3 py-2 space-y-1">
        <p><i className="fas fa-info-circle mr-1.5"></i>{t('fixedAssets.notBalanceSheetNote')}</p>
        <p><i className="fas fa-circle-exclamation mr-1.5"></i>{t('fixedAssets.notDepreciationNote')}</p>
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
                <th className="text-left px-4 py-2.5">{t('fixedAssets.name')}</th>
                <th className="text-left px-4 py-2.5">{t('fixedAssets.category')}</th>
                <th className="text-left px-4 py-2.5">{t('fixedAssets.acquisitionDate')}</th>
                <th className="text-right px-4 py-2.5">{t('fixedAssets.originalValue')}</th>
                <th className="text-left px-4 py-2.5">{t('fixedAssets.currency')}</th>
                <th className="text-left px-4 py-2.5">{t('fixedAssets.status')}</th>
                <th className="text-left px-4 py-2.5">{t('fixedAssets.recordStatus')}</th>
                <th className="text-right px-4 py-2.5 w-28"></th>
              </tr>
            </thead>
            <tbody>
              {items.length === 0 && (
                <tr><td colSpan={8} className="text-center text-[#5c5c5a] py-6 text-xs">{t('fixedAssets.empty')}</td></tr>
              )}
              {items.map(a => (
                <tr key={a.id} className="border-t border-[#e0ddd5]/70 hover:bg-[#f9f9f8]/40">
                  <td className="px-4 py-2 text-[#191918] col-name">{a.name}</td>
                  <td className="px-4 py-2 text-[11px] text-[#5c5c5a]">{a.category || '—'}</td>
                  <td className="px-4 py-2 text-[11px] text-[#5c5c5a]">{a.acquisition_date || '—'}</td>
                  <td className="px-4 py-2 text-right text-[11px] font-mono text-[#191918]">{a.original_value}</td>
                  <td className="px-4 py-2 text-[11px] text-[#5c5c5a]">{a.currency || '—'}</td>
                  <td className="px-4 py-2 text-[11px]">
                    {a.status === 'in_use'
                      ? <span className="text-[10px] bg-emerald-100 text-emerald-700 px-1.5 py-0.5 rounded">{t('fixedAssets.statusInUse')}</span>
                      : a.status === 'idle'
                        ? <span className="text-[10px] bg-amber-100 text-amber-700 px-1.5 py-0.5 rounded">{t('fixedAssets.statusIdle')}</span>
                        : <span className="text-[10px] bg-[#f0eeeb] text-[#5c5c5a] px-1.5 py-0.5 rounded">{t('fixedAssets.statusDisposed')}</span>}
                  </td>
                  <td className="px-4 py-2 text-[11px]">
                    <button onClick={() => handleToggleActive(a)} className={a.is_active ? 'text-emerald-600' : 'text-[#a8a8a6]'}>
                      <i className={`fas ${a.is_active ? 'fa-toggle-on' : 'fa-toggle-off'} mr-1`}></i>{a.is_active ? t('fixedAssets.active') : t('fixedAssets.inactive')}
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
          <div className="text-sm font-semibold text-[#191918]">{editingId ? t('fixedAssets.editTitle') : t('fixedAssets.addTitle')}</div>
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('fixedAssets.name')}</label>
              <input value={fName} onChange={e => setFName(e.target.value)} placeholder={t('fixedAssets.namePlaceholder')}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('fixedAssets.category')}</label>
              <input value={fCategory} onChange={e => setFCategory(e.target.value)} placeholder={t('fixedAssets.categoryPlaceholder')}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('fixedAssets.acquisitionDate')}</label>
              <input type="date" value={fAcqDate} onChange={e => setFAcqDate(e.target.value)}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('fixedAssets.originalValue')}</label>
              <input type="number" step="0.01" value={fOriginal} onChange={e => setFOriginal(e.target.value)}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('fixedAssets.currency')}</label>
              <input value={fCurrency} onChange={e => setFCurrency(e.target.value)} placeholder={t('fixedAssets.currencyPlaceholder')}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('fixedAssets.status')}</label>
              <select value={fStatus} onChange={e => setFStatus(e.target.value as AssetStatus)}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white">
                {ASSET_STATUSES.map(s => (<option key={s} value={s}>{statusLabel(s)}</option>))}
              </select>
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('fixedAssets.supplier')}</label>
              <input value={fSupplier} onChange={e => setFSupplier(e.target.value)} placeholder={t('fixedAssets.supplierPlaceholder')}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('fixedAssets.serialNo')}</label>
              <input value={fSerial} onChange={e => setFSerial(e.target.value)} placeholder={t('common.optional')}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
            <div className="col-span-2">
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('fixedAssets.note')}</label>
              <input value={fNote} onChange={e => setFNote(e.target.value)} placeholder={t('fixedAssets.notePlaceholder')}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
          </div>
          <p className="text-[10px] text-[#8a8a88]"><i className="fas fa-circle-info mr-1"></i>{t('fixedAssets.originalValueHint')}</p>
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
          <i className="fas fa-plus mr-1.5"></i>{t('fixedAssets.addButton')}
        </button>
      )}
    </section>
  );
};

export default FixedAssetsSection;
