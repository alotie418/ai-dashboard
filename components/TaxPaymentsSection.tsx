// 设置页 → 已缴税款登记台账（PR-7D-5，管道层）
// 已缴税款手工登记台账（历史缴税流水）。POLICY-NEUTRAL：仅录入/保存/读取/编辑/删除·停用。
// 不算税额/税率、不抵扣 VAT、不对冲所得税/附加税、不确认税费费用、不进 cashflow、不联动
// accounts/transactions、不接资产负债表、不碰 reports，且不与系统的税额估算做任何勾稽/抵扣/对冲。
// tax_type 仅中性分类无科目映射；amount 允许负（退税/冲正），系统不解释方向。
// 纯 UI 语言驱动（i18n），不读 accountingLocale。
import React, { useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import {
  listTaxPayments, createTaxPayment, updateTaxPayment, deleteTaxPayment,
  type TaxPayment, type TaxType,
} from '../services/api';
import { getSystemErrorText } from '../services/systemErrors';

const TAX_TYPES: TaxType[] = ['vat', 'income_tax', 'surcharge', 'payroll_tax', 'sales_tax', 'other'];

const TaxPaymentsSection: React.FC = () => {
  const { t } = useTranslation();
  const [items, setItems] = useState<TaxPayment[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [showForm, setShowForm] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [confirmDelete, setConfirmDelete] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  const [fName, setFName] = useState('');
  const [fType, setFType] = useState<TaxType>('vat');
  const [fAmount, setFAmount] = useState<string>('0');
  const [fCurrency, setFCurrency] = useState('');
  const [fPaymentDate, setFPaymentDate] = useState('');
  const [fPeriodStart, setFPeriodStart] = useState('');
  const [fPeriodEnd, setFPeriodEnd] = useState('');
  const [fAuthority, setFAuthority] = useState('');
  const [fReference, setFReference] = useState('');
  const [fNote, setFNote] = useState('');

  useEffect(() => { reload(); }, []);

  const reload = async () => {
    setLoading(true);
    setError(null);
    try {
      setItems(await listTaxPayments());
    } catch (e: any) {
      console.error(e);
      setError(t('common.operationFailed'));
    } finally {
      setLoading(false);
    }
  };

  const resetForm = () => {
    setFName(''); setFType('vat'); setFAmount('0'); setFCurrency(''); setFPaymentDate('');
    setFPeriodStart(''); setFPeriodEnd(''); setFAuthority(''); setFReference(''); setFNote('');
  };

  const openAdd = () => { resetForm(); setEditingId(null); setShowForm(true); };

  const openEdit = (p: TaxPayment) => {
    setFName(p.name);
    setFType(p.tax_type);
    setFAmount(String(p.amount ?? 0));
    setFCurrency(p.currency || '');
    setFPaymentDate(p.payment_date || '');
    setFPeriodStart(p.period_start || '');
    setFPeriodEnd(p.period_end || '');
    setFAuthority(p.authority || '');
    setFReference(p.reference_no || '');
    setFNote(p.note || '');
    setEditingId(p.id);
    setShowForm(true);
  };

  const closeForm = () => { setShowForm(false); setEditingId(null); resetForm(); };

  const typeLabel = (ty: TaxType) => ({
    vat: t('taxPayments.typeVat'),
    income_tax: t('taxPayments.typeIncomeTax'),
    surcharge: t('taxPayments.typeSurcharge'),
    payroll_tax: t('taxPayments.typePayrollTax'),
    sales_tax: t('taxPayments.typeSalesTax'),
    other: t('taxPayments.typeOther'),
  }[ty]);

  const handleSubmit = async () => {
    if (!fName.trim()) return;
    setSaving(true);
    try {
      const payload = {
        name: fName.trim(),
        tax_type: fType,
        amount: Number(fAmount) || 0,
        currency: fCurrency.trim() || null,
        payment_date: fPaymentDate || null,
        period_start: fPeriodStart || null,
        period_end: fPeriodEnd || null,
        authority: fAuthority.trim() || null,
        reference_no: fReference.trim() || null,
        note: fNote.trim() || null,
      };
      if (editingId) await updateTaxPayment(editingId, payload);
      else await createTaxPayment(payload);
      closeForm();
      reload();
    } catch (e: any) {
      console.error(e);
      setError(getSystemErrorText(e, t) || t('common.operationFailed'));
    } finally {
      setSaving(false);
    }
  };

  const handleToggleActive = async (p: TaxPayment) => {
    try { await updateTaxPayment(p.id, { is_active: !p.is_active }); reload(); }
    catch (e: any) { console.error(e); setError(getSystemErrorText(e, t) || t('common.operationFailed')); }
  };

  const handleDelete = async (id: string) => {
    try { await deleteTaxPayment(id); setConfirmDelete(null); reload(); }
    catch (e: any) { console.error(e); setError(getSystemErrorText(e, t) || t('common.operationFailed')); setConfirmDelete(null); }
  };

  return (
    <section className="space-y-6">
      <div>
        <h3 className="text-xl font-bold text-[#191918]">{t('taxPayments.title')}</h3>
        <p className="text-xs text-[#6b6b69] mt-1">{t('taxPayments.subtitle')}</p>
      </div>

      {/* Boundary notes: NOT a balance sheet; registration only — no tax calc / deduction / offset / report. */}
      <div className="text-xs text-amber-700 bg-amber-50 border border-amber-200 rounded-lg px-3 py-2 space-y-1">
        <p><i className="fas fa-info-circle mr-1.5"></i>{t('taxPayments.notBalanceSheetNote')}</p>
        <p><i className="fas fa-circle-exclamation mr-1.5"></i>{t('taxPayments.notComputeNote')}</p>
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
                <th className="text-left px-4 py-2.5">{t('taxPayments.name')}</th>
                <th className="text-left px-4 py-2.5">{t('taxPayments.taxType')}</th>
                <th className="text-right px-4 py-2.5">{t('taxPayments.amount')}</th>
                <th className="text-left px-4 py-2.5">{t('taxPayments.currency')}</th>
                <th className="text-left px-4 py-2.5">{t('taxPayments.paymentDate')}</th>
                <th className="text-left px-4 py-2.5">{t('taxPayments.authority')}</th>
                <th className="text-left px-4 py-2.5">{t('taxPayments.status')}</th>
                <th className="text-right px-4 py-2.5 w-28"></th>
              </tr>
            </thead>
            <tbody>
              {items.length === 0 && (
                <tr><td colSpan={8} className="text-center text-[#5c5c5a] py-6 text-xs">{t('taxPayments.empty')}</td></tr>
              )}
              {items.map(p => (
                <tr key={p.id} className="border-t border-[#e0ddd5]/70 hover:bg-[#f9f9f8]/40">
                  <td className="px-4 py-2 text-[#191918] col-name">{p.name}</td>
                  <td className="px-4 py-2 text-[11px]">
                    <span className="text-[10px] bg-slate-100 text-slate-700 px-1.5 py-0.5 rounded">{typeLabel(p.tax_type)}</span>
                  </td>
                  <td className="px-4 py-2 text-right text-[11px] font-mono text-[#191918]">{p.amount}</td>
                  <td className="px-4 py-2 text-[11px] text-[#5c5c5a]">{p.currency || '—'}</td>
                  <td className="px-4 py-2 text-[11px] text-[#5c5c5a]">{p.payment_date || '—'}</td>
                  <td className="px-4 py-2 text-[11px] text-[#5c5c5a]">{p.authority || '—'}</td>
                  <td className="px-4 py-2 text-[11px]">
                    <button onClick={() => handleToggleActive(p)} className={p.is_active ? 'text-emerald-600' : 'text-[#a8a8a6]'}>
                      <i className={`fas ${p.is_active ? 'fa-toggle-on' : 'fa-toggle-off'} mr-1`}></i>{p.is_active ? t('taxPayments.active') : t('taxPayments.inactive')}
                    </button>
                  </td>
                  <td className="px-4 py-2 text-right whitespace-nowrap">
                    {confirmDelete === p.id ? (
                      <div className="inline-flex items-center space-x-1">
                        <button onClick={() => handleDelete(p.id)} className="text-[10px] px-2 py-0.5 bg-rose-600 text-white rounded">{t('common.delete')}</button>
                        <button onClick={() => setConfirmDelete(null)} className="text-[10px] px-2 py-0.5 border border-rose-300 text-rose-600 rounded">{t('common.cancel')}</button>
                      </div>
                    ) : (
                      <div className="inline-flex items-center space-x-3">
                        <button onClick={() => openEdit(p)} className="text-[10px] text-primary hover:text-primary-hover">
                          <i className="fas fa-pen mr-1"></i>{t('common.edit')}
                        </button>
                        <button onClick={() => setConfirmDelete(p.id)} className="text-[10px] text-rose-600 hover:text-rose-700">
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
          <div className="text-sm font-semibold text-[#191918]">{editingId ? t('taxPayments.editTitle') : t('taxPayments.addTitle')}</div>
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('taxPayments.name')}</label>
              <input value={fName} onChange={e => setFName(e.target.value)} placeholder={t('taxPayments.namePlaceholder')}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('taxPayments.taxType')}</label>
              <select value={fType} onChange={e => setFType(e.target.value as TaxType)}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white">
                {TAX_TYPES.map(k => (<option key={k} value={k}>{typeLabel(k)}</option>))}
              </select>
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('taxPayments.amount')}</label>
              <input type="number" step="0.01" value={fAmount} onChange={e => setFAmount(e.target.value)}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('taxPayments.currency')}</label>
              <input value={fCurrency} onChange={e => setFCurrency(e.target.value)} placeholder={t('taxPayments.currencyPlaceholder')}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('taxPayments.paymentDate')}</label>
              <input type="date" value={fPaymentDate} onChange={e => setFPaymentDate(e.target.value)}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('taxPayments.authority')}</label>
              <input value={fAuthority} onChange={e => setFAuthority(e.target.value)} placeholder={t('taxPayments.authorityPlaceholder')}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('taxPayments.periodStart')}</label>
              <input type="date" value={fPeriodStart} onChange={e => setFPeriodStart(e.target.value)}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('taxPayments.periodEnd')}</label>
              <input type="date" value={fPeriodEnd} onChange={e => setFPeriodEnd(e.target.value)}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('taxPayments.referenceNo')}</label>
              <input value={fReference} onChange={e => setFReference(e.target.value)} placeholder={t('common.optional')}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('taxPayments.note')}</label>
              <input value={fNote} onChange={e => setFNote(e.target.value)} placeholder={t('taxPayments.notePlaceholder')}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
          </div>
          <p className="text-[10px] text-[#8a8a88]"><i className="fas fa-circle-info mr-1"></i>{t('taxPayments.amountHint')}</p>
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
          <i className="fas fa-plus mr-1.5"></i>{t('taxPayments.addButton')}
        </button>
      )}
    </section>
  );
};

export default TaxPaymentsSection;
