// 业务单据 新建/编辑 弹窗（Phase A）
// 内部业务单据：非税务发票开具；单据编号为内部编号（自动建议、可编辑），
// 永不自动生成正式发票号码。明细行手动录入，行金额 = 数量 × 单价 自动计算，
// 表头合计 = 明细求和。税种标签（税率/税额/价税合计）按单据「冻结的会计制度」
// docLocale 经 getTaxLabel/CN-gate 渲染——不随设置里的制度切换漂移；
// 计算只有乘加求和，零税务口径逻辑。

import React, { useEffect, useMemo, useRef, useState } from 'react';
import { useTranslation } from 'react-i18next';
import {
  createDocument, updateDocument, fetchNextDocNumber, isDesktop,
  type BusinessDocument, type BusinessDocType, type Product,
} from '../services/api';
import { formatMoney, getTaxLabel, getProductUnitLabel, PRODUCT_UNIT_KEYS } from './accountingHelpers';

interface ItemRow {
  productId: string;
  description: string;
  quantity: string;
  unit: string;
  unitPrice: string;
  taxRatePct: string;
}

interface Props {
  editing: BusinessDocument | null; // null = 新建
  accLocale: string;                // 当前会计制度（新建时冻结进单据）
  products: Product[];
  onClose: () => void;
  onSaved: () => void;
}

const DOC_TYPES: BusinessDocType[] = ['quotation', 'sales_order', 'proforma_invoice', 'commercial_invoice', 'statement'];

const TYPE_LABEL_KEYS: Record<BusinessDocType, string> = {
  quotation: 'documents.typeQuotation',
  sales_order: 'documents.typeSalesOrder',
  proforma_invoice: 'documents.typeProforma',
  commercial_invoice: 'documents.typeCommercial',
  statement: 'documents.typeStatement',
};

const round2 = (v: number) => Math.round((v || 0) * 100) / 100;

const emptyRow = (): ItemRow => ({ productId: '', description: '', quantity: '', unit: '', unitPrice: '', taxRatePct: '' });

const toRow = (it: NonNullable<BusinessDocument['items']>[number]): ItemRow => ({
  productId: it.productId || '',
  description: it.description || '',
  quantity: it.quantity === null || it.quantity === undefined ? '' : String(it.quantity),
  unit: it.unit || '',
  unitPrice: it.unitPrice === null || it.unitPrice === undefined ? '' : String(it.unitPrice),
  // 显式 0% 与「未填」要区分：'0%' → '0'，null/'' → ''（编辑回写不丢零税率）
  taxRatePct: (() => {
    if (!it.taxRate) return '';
    const n = parseFloat(it.taxRate.replace('%', ''));
    return Number.isFinite(n) ? String(n) : '';
  })(),
});

const DocumentModal: React.FC<Props> = ({ editing, accLocale, products, onClose, onSaved }) => {
  const { t, i18n } = useTranslation();
  const uiLang = i18n.language;
  // 编辑时用单据创建时冻结的制度，新建时冻结当前制度
  const docLocale = editing ? editing.accLocale : accLocale;
  const taxLabel = (key: string) => getTaxLabel(docLocale, uiLang, key);
  // CN 的 taxConcepts 没有 header* 键（miss 会返回裸 key），沿用销售页的 CN gate
  const taxAmountLabel = docLocale !== 'CN' ? taxLabel('headerTaxAmount') : t('tableHeaders.taxAmount');
  const totalLabel = docLocale !== 'CN' ? taxLabel('headerTotalWithTax') : t('tableHeaders.totalWithTax');

  const [docType, setDocType] = useState<BusinessDocType>(editing ? editing.docType : 'quotation');
  const [docNumber, setDocNumber] = useState(editing ? editing.docNumber : '');
  const [numberEdited, setNumberEdited] = useState(!!editing);
  // ref 守卫：用户敲第一个字符到 effect cleanup 之间，在途的建议请求不得覆盖手输值
  const numberEditedRef = useRef(!!editing);
  const [docDate, setDocDate] = useState(editing ? editing.docDate : new Date().toISOString().split('T')[0]);
  const [validUntil, setValidUntil] = useState(editing?.validUntil || '');
  const [customerName, setCustomerName] = useState(editing?.customerName || '');
  const [customerTaxId, setCustomerTaxId] = useState(editing?.customerTaxId || '');
  const [customerAddress, setCustomerAddress] = useState(editing?.customerAddress || '');
  const [customerContact, setCustomerContact] = useState(editing?.customerContact || '');
  const [notes, setNotes] = useState(editing?.notes || '');
  const [rows, setRows] = useState<ItemRow[]>(
    editing?.items && editing.items.length > 0 ? editing.items.map(toRow) : [emptyRow()],
  );
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // 新建时按类型建议内部编号；用户手动改过就不再覆盖
  useEffect(() => {
    if (editing || numberEdited || !isDesktop()) return;
    let cancelled = false;
    fetchNextDocNumber(docType)
      .then((n) => { if (!cancelled && !numberEditedRef.current) setDocNumber(n); })
      .catch(() => {});
    return () => { cancelled = true; };
  }, [docType, editing, numberEdited]);

  const computed = useMemo(() => {
    const lines = rows.map((r) => {
      const qty = parseFloat(r.quantity) || 0;
      const price = parseFloat(r.unitPrice) || 0;
      const amount = round2(qty * price);
      const pct = parseFloat(r.taxRatePct) || 0;
      const tax = round2(amount * pct / 100);
      return { amount, tax };
    });
    const subtotal = round2(lines.reduce((s, l) => s + l.amount, 0));
    const taxTotal = round2(lines.reduce((s, l) => s + l.tax, 0));
    return { lines, subtotal, taxTotal, total: round2(subtotal + taxTotal) };
  }, [rows]);

  const setRow = (i: number, patch: Partial<ItemRow>) => {
    setRows((prev) => prev.map((r, idx) => (idx === i ? { ...r, ...patch } : r)));
  };

  const onPickProduct = (i: number, productId: string) => {
    const p = products.find((x) => x.id === productId);
    if (!p) { setRow(i, { productId: '' }); return; }
    setRow(i, {
      productId,
      description: p.name,
      unit: p.unit || '',
      unitPrice: p.default_unit_cost && p.default_unit_cost > 0 ? String(p.default_unit_cost) : rows[i].unitPrice,
      quantity: rows[i].quantity || '1',
    });
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    const validRows = rows
      .map((r, i) => ({ r, line: computed.lines[i], i }))
      .filter(({ r }) => r.description.trim());
    if (validRows.length === 0) { setError(t('documents.itemsRequired')); return; }
    setSaving(true);
    try {
      const payload: Partial<BusinessDocument> = {
        docType,
        docNumber: docNumber.trim(),
        docDate,
        validUntil: validUntil || null,
        customerName: customerName.trim(),
        customerTaxId: customerTaxId.trim() || null,
        customerAddress: customerAddress.trim() || null,
        customerContact: customerContact.trim() || null,
        notes: notes.trim() || null,
        // accLocale 不随 payload 发送：创建时由 handler 同步读取 settings 真值冻结
        // （前端的 accLocale prop 是异步加载的，竞态下可能还是默认 'CN'）；
        // 编辑时 handler 本就忽略 acc_locale，冻结值不可变。
        items: validRows.map(({ r, line }, idx) => ({
          productId: r.productId || null,
          description: r.description.trim(),
          quantity: r.quantity === '' ? null : parseFloat(r.quantity) || 0,
          unit: r.unit || null,
          unitPrice: r.unitPrice === '' ? null : parseFloat(r.unitPrice) || 0,
          taxRate: r.taxRatePct === '' ? null : `${parseFloat(r.taxRatePct) || 0}%`,
          taxAmount: line.tax,
          amount: line.amount,
          lineNo: idx,
        })),
      };
      if (editing) await updateDocument(editing.id, payload);
      else await createDocument(payload);
      onSaved();
    } catch (err: any) {
      const msg = String(err?.message || '');
      setError(msg.includes('DOC_NUMBER_EXISTS') ? t('documents.numberConflict') : t('documents.saveFailed'));
    } finally {
      setSaving(false);
    }
  };

  const inputCls = 'w-full bg-white border border-[#e0ddd5] rounded-xl px-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-[#d97757] text-[#191918] transition-all';
  const labelCls = 'text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest';

  return (
    <div className="fixed inset-0 z-[10001] flex items-center justify-center px-4">
      <div className="absolute inset-0 bg-black/40 backdrop-blur-sm" onClick={onClose}></div>
      <div className="relative w-full max-w-3xl max-h-[90vh] overflow-y-auto bg-white border border-[#e0ddd5] rounded-xl animate-in zoom-in-95 duration-200" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.05)' }}>
        <div className="p-8 border-b border-[#e0ddd5] flex justify-between items-center gap-4 sticky top-0 bg-white z-10">
          <h2 className="text-xl font-bold text-[#191918] whitespace-nowrap">{editing ? t('documents.formEditTitle') : t('documents.formTitle')}</h2>
          <button type="button" onClick={onClose} className="flex-shrink-0 text-[#5c5c5a] hover:text-[#191918] transition-colors">
            <i className="fas fa-times text-xl"></i>
          </button>
        </div>

        <form onSubmit={handleSubmit} className="p-8 space-y-5">
          {error && (
            <div className="text-sm text-rose-600 bg-rose-50 border border-rose-200 rounded-lg px-3 py-2">
              <i className="fas fa-exclamation-circle mr-2"></i>{error}
            </div>
          )}

          <div className="grid grid-cols-2 gap-4">
            <div className="space-y-2">
              <label className={labelCls}>{t('documents.formType')}</label>
              <select value={docType} onChange={(e) => setDocType(e.target.value as BusinessDocType)} className={inputCls} disabled={!!editing}>
                {DOC_TYPES.map((ty) => (
                  <option key={ty} value={ty}>{t(TYPE_LABEL_KEYS[ty])}</option>
                ))}
              </select>
            </div>
            <div className="space-y-2">
              <label className={labelCls}>{t('documents.formNumber')}</label>
              <input
                type="text"
                name="docNumber"
                required
                value={docNumber}
                onChange={(e) => { setDocNumber(e.target.value); numberEditedRef.current = true; setNumberEdited(true); }}
                className={inputCls}
              />
              <p className="text-[10px] text-[#5c5c5a]">{t('documents.formNumberHint')}</p>
            </div>
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div className="space-y-2">
              <label className={labelCls}>{t('documents.formDate')}</label>
              <input type="date" required value={docDate} onChange={(e) => setDocDate(e.target.value)} className={inputCls} />
            </div>
            <div className="space-y-2">
              <label className={labelCls}>{t('documents.formValidUntil')}</label>
              <input type="date" value={validUntil} onChange={(e) => setValidUntil(e.target.value)} className={inputCls} />
            </div>
          </div>

          <div className="space-y-2">
            <label className={labelCls}>{t('documents.formCustomer')}</label>
            <input
              type="text"
              name="customerName"
              required
              placeholder={t('documents.formCustomerPlaceholder')}
              value={customerName}
              onChange={(e) => setCustomerName(e.target.value)}
              className={inputCls}
            />
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div className="space-y-2">
              <label className={labelCls}>{t('documents.formCustomerTaxId')}</label>
              <input type="text" placeholder={t('common2.optional')} value={customerTaxId} onChange={(e) => setCustomerTaxId(e.target.value)} className={inputCls} />
            </div>
            <div className="space-y-2">
              <label className={labelCls}>{t('documents.formCustomerContact')}</label>
              <input type="text" placeholder={t('common2.optional')} value={customerContact} onChange={(e) => setCustomerContact(e.target.value)} className={inputCls} />
            </div>
          </div>

          <div className="space-y-2">
            <label className={labelCls}>{t('documents.formCustomerAddress')}</label>
            <input type="text" placeholder={t('common2.optional')} value={customerAddress} onChange={(e) => setCustomerAddress(e.target.value)} className={inputCls} />
          </div>

          {/* 明细行 */}
          <div className="space-y-3">
            <label className={labelCls}>{t('documents.itemsTitle')}</label>
            {rows.map((row, i) => (
              <div key={i} className="border border-[#e0ddd5] rounded-xl p-4 space-y-3 bg-[#f9f9f8]/50">
                <div className="flex items-center gap-3">
                  <select value={row.productId} onChange={(e) => onPickProduct(i, e.target.value)} className={`${inputCls} flex-1`}>
                    <option value="">{t('products.unassigned')}</option>
                    {products.filter((p) => p.is_active).map((p) => (
                      <option key={p.id} value={p.id}>{p.name}（{getProductUnitLabel(p.unit, uiLang)}）</option>
                    ))}
                  </select>
                  {rows.length > 1 && (
                    <button
                      type="button"
                      onClick={() => setRows((prev) => prev.filter((_, idx) => idx !== i))}
                      className="flex-shrink-0 text-rose-500 hover:text-rose-400 text-xs font-medium"
                    >
                      {t('documents.removeItem')}
                    </button>
                  )}
                </div>
                <div className="space-y-2">
                  <label className={labelCls}>{t('documents.itemDescription')}</label>
                  <input
                    type="text"
                    name={`itemDescription-${i}`}
                    value={row.description}
                    onChange={(e) => setRow(i, { description: e.target.value })}
                    className={inputCls}
                  />
                </div>
                <div className="grid grid-cols-4 gap-3">
                  <div className="space-y-2">
                    <label className={labelCls}>{t('documents.itemQty')}</label>
                    <input type="number" step="0.01" min="0" name={`itemQty-${i}`} value={row.quantity} onChange={(e) => setRow(i, { quantity: e.target.value })} className={inputCls} />
                  </div>
                  <div className="space-y-2">
                    <label className={labelCls}>{t('documents.itemUnit')}</label>
                    <select value={row.unit} onChange={(e) => setRow(i, { unit: e.target.value })} className={inputCls}>
                      <option value="">{t('documents.noUnit')}</option>
                      {PRODUCT_UNIT_KEYS.map((u) => (
                        <option key={u} value={u}>{getProductUnitLabel(u, uiLang)}</option>
                      ))}
                    </select>
                  </div>
                  <div className="space-y-2">
                    <label className={labelCls}>{t('documents.itemUnitPrice')}</label>
                    <input type="number" step="0.01" min="0" name={`itemUnitPrice-${i}`} value={row.unitPrice} onChange={(e) => setRow(i, { unitPrice: e.target.value })} className={inputCls} />
                  </div>
                  <div className="space-y-2">
                    <label className={labelCls}>{taxLabel('formTaxRate')} %</label>
                    <input type="number" step="0.01" min="0" max="100" value={row.taxRatePct} onChange={(e) => setRow(i, { taxRatePct: e.target.value })} className={inputCls} />
                  </div>
                </div>
                <div className="flex justify-end gap-5 text-xs text-[#4a4a48]">
                  <span>{t('documents.itemAmount')}: <span className="font-medium text-[#191918]">{formatMoney(computed.lines[i].amount, docLocale)}</span></span>
                  <span>{taxAmountLabel}: <span className="font-medium text-rose-600">{formatMoney(computed.lines[i].tax, docLocale)}</span></span>
                </div>
              </div>
            ))}
            <button
              type="button"
              onClick={() => setRows((prev) => [...prev, emptyRow()])}
              className="w-full border-2 border-dashed border-[#e0ddd5] hover:border-[#d97757]/50 hover:bg-[#d97757]/5 rounded-xl py-2.5 text-xs text-[#5c5c5a] hover:text-[#d97757] transition-all"
            >
              <i className="fas fa-plus mr-2"></i>{t('documents.addItem')}
            </button>
          </div>

          <div className="space-y-2">
            <label className={labelCls}>{t('documents.formNotes')}</label>
            <textarea rows={2} placeholder={t('common2.optional')} value={notes} onChange={(e) => setNotes(e.target.value)} className={inputCls} />
          </div>

          {/* 合计（明细求和；显示用冻结制度的币种符号） */}
          <div className="border-t border-[#e0ddd5] pt-4 space-y-1.5 text-sm">
            <div className="flex justify-between text-[#4a4a48]">
              <span>{t('documents.subtotal')}</span>
              <span className="font-medium text-[#191918]">{formatMoney(computed.subtotal, docLocale)}</span>
            </div>
            <div className="flex justify-between text-[#4a4a48]">
              <span>{taxAmountLabel}</span>
              <span className="font-medium text-rose-600">{formatMoney(computed.taxTotal, docLocale)}</span>
            </div>
            <div className="flex justify-between text-base font-bold text-[#191918]">
              <span>{totalLabel}</span>
              <span>{formatMoney(computed.total, docLocale)}</span>
            </div>
          </div>

          <div className="flex justify-end gap-3 pt-2">
            <button
              type="button"
              onClick={onClose}
              disabled={saving}
              className="px-5 py-2.5 border border-[#e0ddd5] text-[#4a4a48] rounded-lg text-sm font-medium hover:bg-[#f9f9f8] disabled:opacity-50"
            >
              {t('common.cancel')}
            </button>
            <button
              type="submit"
              disabled={saving}
              className="bg-[#d97757] text-white px-5 py-2.5 rounded-lg text-sm font-medium hover:bg-[#c56a4a] disabled:opacity-50"
            >
              {saving
                ? <><i className="fas fa-spinner fa-spin mr-2"></i>{t('common.loading')}</>
                : t('documents.saveButton')}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
};

export default DocumentModal;
