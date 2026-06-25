// 业务单据 新建/编辑 弹窗（Phase A CRUD + Phase C 预填/对账单）
// 内部业务单据：非税务发票开具；单据编号为内部编号（自动建议、可编辑），
// 永不自动生成正式发票号码。明细行手动录入时 行金额 = 数量 × 单价 自动计算；
// 由销售记录预填/对账单生成的行带「锁定金额」（复制销售记录已存金额、不重算，
// 避免单价写库时舍入造成的分差），用户改动数量/单价/税率才解锁转为重算。
// 表头合计 = 明细求和。税种标签（税率/税额/价税合计）按单据「冻结的会计制度」
// docLocale 经 getTaxLabel/CN-gate 渲染——不随设置里的制度切换漂移；
// 计算只有乘加求和，零税务口径逻辑。对账单生成器：客户名 trim 后精确匹配 +
// 期间 [起, 止] 闭区间过滤销售记录，纯读取、不改任何销售数据。

import React, { useEffect, useMemo, useRef, useState } from 'react';
import { useTranslation } from 'react-i18next';
import {
  createDocument, updateDocument, fetchNextDocNumber, fetchSales, isDesktop,
  type BusinessDocument, type BusinessDocType, type Product, type SalesRecord,
} from '../services/api';
import { formatMoney, getTaxLabel, getProductUnitLabel, PRODUCT_UNIT_KEYS } from './accountingHelpers';

interface ItemRow {
  productId: string;
  description: string;
  quantity: string;
  unit: string;
  unitPrice: string;
  taxRatePct: string;
  // 锁定金额（来自销售记录的已存值）；用户改 数量/单价/税率 即清空转为重算
  locked: { amount: number; tax: number } | null;
  refSalesId: string | null;
  refDate: string | null;
}

interface Props {
  editing: BusinessDocument | null;        // null = 新建
  initial?: Partial<BusinessDocument> | null; // Phase C：新建时的预填（由销售记录生成）
  accLocale: string;                       // 当前会计制度（新建时冻结进单据）
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

const emptyRow = (): ItemRow => ({ productId: '', description: '', quantity: '', unit: '', unitPrice: '', taxRatePct: '', locked: null, refSalesId: null, refDate: null });

// 已存明细 → 编辑行：金额默认「锁定」为已存值（不因重算产生分差），
// 用户改动 数量/单价/税率 时解锁（setRow 统一清 locked）。
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
  locked: { amount: it.amount || 0, tax: it.taxAmount || 0 },
  refSalesId: it.refSalesId ?? null,
  refDate: it.refDate ?? null,
});

const DocumentModal: React.FC<Props> = ({ editing, initial, accLocale, products, onClose, onSaved }) => {
  const { t, i18n } = useTranslation();
  const uiLang = i18n.language;
  // 编辑时用单据创建时冻结的制度，新建时冻结当前制度
  const docLocale = editing ? editing.accLocale : accLocale;
  const taxLabel = (key: string) => getTaxLabel(docLocale, uiLang, key);
  // CN 的 taxConcepts 没有 header* 键（miss 会返回裸 key），沿用销售页的 CN gate
  const taxAmountLabel = docLocale !== 'CN' ? taxLabel('headerTaxAmount') : t('tableHeaders.taxAmount');
  const totalLabel = docLocale !== 'CN' ? taxLabel('headerTotalWithTax') : t('tableHeaders.totalWithTax');

  // 新建预填（Phase C：由销售记录生成）只在 create 模式生效
  const seed = !editing ? initial || null : null;
  const seedItems = (editing?.items && editing.items.length > 0 ? editing.items : null)
    || (seed?.items && seed.items.length > 0 ? seed.items : null);

  const [docType, setDocType] = useState<BusinessDocType>(editing?.docType || seed?.docType || 'quotation');
  const [docNumber, setDocNumber] = useState(editing ? editing.docNumber : '');
  const [numberEdited, setNumberEdited] = useState(!!editing);
  // ref 守卫：用户敲第一个字符到 effect cleanup 之间，在途的建议请求不得覆盖手输值
  const numberEditedRef = useRef(!!editing);
  const [docDate, setDocDate] = useState(editing ? editing.docDate : new Date().toISOString().split('T')[0]);
  const [validUntil, setValidUntil] = useState(editing?.validUntil || '');
  const [customerName, setCustomerName] = useState(editing?.customerName || seed?.customerName || '');
  const [customerTaxId, setCustomerTaxId] = useState(editing?.customerTaxId || '');
  const [customerAddress, setCustomerAddress] = useState(editing?.customerAddress || '');
  const [customerContact, setCustomerContact] = useState(editing?.customerContact || '');
  const [notes, setNotes] = useState(editing?.notes || '');
  const [rows, setRows] = useState<ItemRow[]>(seedItems ? seedItems.map(toRow) : [emptyRow()]);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // Phase C：对账单期间 + 来源销售记录回链（信息性）
  const [periodStart, setPeriodStart] = useState(editing?.periodStart || '');
  const [periodEnd, setPeriodEnd] = useState(editing?.periodEnd || '');
  const sourceSalesId = seed?.sourceSalesId ?? editing?.sourceSalesId ?? null;
  // Phase C：对账单生成器（仅新建 + statement 类型；纯读取销售记录）
  const [salesRecs, setSalesRecs] = useState<SalesRecord[] | null>(null);
  const [stmtCustomer, setStmtCustomer] = useState('');
  const [stmtMsg, setStmtMsg] = useState<string | null>(null);

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
      // 锁定行（销售记录已存金额）原样求和；解锁后按 数量×单价 重算
      if (r.locked) return { amount: round2(r.locked.amount), tax: round2(r.locked.tax) };
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
    // 改动 数量/单价/税率 任意一项即解锁该行（转为重算）；其余字段不动锁
    const unlocks = patch.quantity !== undefined || patch.unitPrice !== undefined || patch.taxRatePct !== undefined;
    setRows((prev) => prev.map((r, idx) => (idx === i ? { ...r, ...patch, ...(unlocks ? { locked: null } : {}) } : r)));
  };

  // ─── Phase C：对账单生成器 ───
  // 客户清单来自销售记录的 distinct(trim(customer))；生成时 trim 后精确匹配 +
  // 期间闭区间过滤（ISO 日期字符串可直接比较），明细金额复制已存值（锁定行）。
  useEffect(() => {
    if (editing || docType !== 'statement' || salesRecs !== null || !isDesktop()) return;
    fetchSales().then(setSalesRecs).catch(() => setSalesRecs([]));
  }, [docType, editing, salesRecs]);

  const stmtCustomers = useMemo(() => {
    if (!salesRecs) return [];
    return Array.from(new Set(salesRecs.map((r) => r.customer.trim()).filter(Boolean))).sort();
  }, [salesRecs]);

  const salesToRow = (r: SalesRecord): ItemRow => {
    const qtyMatch = (r.quantity || '').match(/[\d.]+/);
    const pct = parseFloat((r.taxRate || '').replace('%', ''));
    return {
      productId: r.productId || '',
      description: `${r.date} ${r.productName || r.invoiceNo || ''}`.trim(),
      quantity: qtyMatch ? qtyMatch[0] : '',
      unit: r.unit || '',
      unitPrice: r.unitPriceWithoutTax || r.pricePerTon ? String(r.unitPriceWithoutTax || r.pricePerTon) : '',
      taxRatePct: Number.isFinite(pct) ? String(pct) : '',
      // 复制销售记录已存金额（与销售页列表显示同款 || 回退），不重算
      locked: { amount: round2(r.amountWithoutTax || r.price), tax: round2(r.taxAmount || 0) },
      refSalesId: r.id,
      refDate: r.date,
    };
  };

  const generateStatement = () => {
    setStmtMsg(null);
    if (!stmtCustomer || !periodStart || !periodEnd) { setStmtMsg(t('documents.stmtNeedInput')); return; }
    const matches = (salesRecs || [])
      .filter((r) => r.customer.trim() === stmtCustomer && r.date >= periodStart && r.date <= periodEnd)
      .sort((a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : 0));
    if (matches.length === 0) { setStmtMsg(t('documents.stmtNoRecords')); return; }
    setCustomerName(stmtCustomer);
    setRows(matches.map(salesToRow));
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
        // 来源回链/期间仅在新建时发送（update handler 的 EDITABLE 白名单不含它们，
        // 编辑时发送会被静默忽略——干脆不发，避免无声的契约错位）；
        // 切到对账单类型后来源回链不再成立，置空。
        ...(editing ? {} : {
          sourceSalesId: docType === 'statement' ? null : sourceSalesId,
          periodStart: docType === 'statement' && periodStart ? periodStart : null,
          periodEnd: docType === 'statement' && periodEnd ? periodEnd : null,
        }),
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
          refSalesId: r.refSalesId,
          refDate: r.refDate,
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

  const inputCls = 'w-full bg-white border border-[#e0ddd5] rounded-xl px-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary text-[#191918] transition-all';
  const labelCls = 'text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest';

  return (
    <div className="fixed inset-0 z-[10001] flex items-center justify-center px-4">
      <div className="absolute inset-0 bg-black/40 backdrop-blur-sm" onClick={onClose}></div>
      <div className="relative w-full max-w-3xl max-h-[90vh] overflow-y-auto glass-modal rounded-xl animate-in zoom-in-95 duration-200" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.05)' }}>
        <div className="p-8 border-b border-[#e0ddd5] flex justify-between items-center gap-4 sticky top-0 bg-white z-10">
          <h2 className="text-xl font-bold text-[#191918] whitespace-nowrap">{editing ? t('documents.formEditTitle') : t('documents.formTitle')}</h2>
          <button type="button" onClick={onClose} aria-label={t('common.close')} className="flex-shrink-0 text-[#5c5c5a] hover:text-[#191918] transition-colors">
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
              <select name="docType" value={docType} onChange={(e) => setDocType(e.target.value as BusinessDocType)} className={inputCls} disabled={!!editing}>
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

          {/* 编辑对账单：期间只读显示（创建后期间冻结，与生成的明细行保持一致） */}
          {editing && docType === 'statement' && (editing.periodStart || editing.periodEnd) && (
            <div className="text-xs text-[#5c5c5a] bg-[#f9f9f8] border border-[#e0ddd5] rounded-lg px-3 py-2">
              <i className="fas fa-calendar-days mr-2"></i>
              {t('documents.pdfPeriod')}: {editing.periodStart || '—'} ~ {editing.periodEnd || '—'}
            </div>
          )}

          {/* Phase C：对账单生成器（仅新建 + statement；客户 trim 精确匹配 + 期间闭区间） */}
          {!editing && docType === 'statement' && (
            <div className="border border-[#e0ddd5] rounded-xl p-4 space-y-3 bg-[#f9f9f8]/50">
              <div className="grid grid-cols-3 gap-3">
                <div className="space-y-2">
                  <label className={labelCls}>{t('documents.stmtCustomer')}</label>
                  <select name="stmtCustomer" value={stmtCustomer} onChange={(e) => setStmtCustomer(e.target.value)} className={inputCls}>
                    <option value=""></option>
                    {stmtCustomers.map((c) => (
                      <option key={c} value={c}>{c}</option>
                    ))}
                  </select>
                </div>
                <div className="space-y-2">
                  <label className={labelCls}>{t('documents.stmtPeriodStart')}</label>
                  <input type="date" name="stmtStart" value={periodStart} onChange={(e) => setPeriodStart(e.target.value)} className={inputCls} />
                </div>
                <div className="space-y-2">
                  <label className={labelCls}>{t('documents.stmtPeriodEnd')}</label>
                  <input type="date" name="stmtEnd" value={periodEnd} onChange={(e) => setPeriodEnd(e.target.value)} className={inputCls} />
                </div>
              </div>
              <button
                type="button"
                onClick={generateStatement}
                className="bg-[#191918] text-white px-4 py-2 rounded-lg text-xs font-medium hover:bg-black"
              >
                <i className="fas fa-list-check mr-2"></i>{t('documents.stmtGenerate')}
              </button>
              {stmtMsg && (
                <div className="text-xs text-amber-700 bg-amber-50 border border-amber-200 rounded-lg px-3 py-2">
                  <i className="fas fa-circle-info mr-2"></i>{stmtMsg}
                </div>
              )}
            </div>
          )}

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
              className="w-full border-2 border-dashed border-[#e0ddd5] hover:border-primary/50 hover:bg-primary/5 rounded-xl py-2.5 text-xs text-[#5c5c5a] hover:text-primary transition-all"
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
              className="bg-primary text-white px-5 py-2.5 rounded-lg text-sm font-medium hover:bg-primary-hover disabled:opacity-50"
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
