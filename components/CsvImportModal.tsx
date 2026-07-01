import React, { useState, useRef, useCallback, useEffect, useMemo } from 'react';
import { useTranslation } from 'react-i18next';
import Papa from 'papaparse';
import { batchCreateSales, batchCreatePurchases, fetchSettings, listProducts, type Product } from '../services/api';
import { getCurrencySymbol } from './accountingHelpers';

interface Props {
  type: 'sales' | 'purchases';
  onClose: () => void;
  onSuccess: () => void;
}

type Field = { key: string; labelKey: string; required: boolean; multiline?: boolean };

// Legacy single-row fields + P5d-3 multi-line columns (multiline:true). The multi-line columns are
// optional and only used when a row carries a docNo: rows sharing a docNo are merged into ONE
// document with items[]; rows without a docNo stay one-row-one-record (legacy, unchanged).
const SALES_FIELDS: Field[] = [
  { key: 'id', labelKey: 'csvImport.id', required: false },
  { key: 'date', labelKey: 'csvImport.date', required: true },
  { key: 'customer', labelKey: 'csvImport.customer', required: true },
  { key: 'tons', labelKey: 'csvImport.quantity', required: true },
  { key: 'pricePerTon', labelKey: 'csvImport.unitPrice', required: false },
  { key: 'totalAmount', labelKey: 'csvImport.totalAmount', required: true },
  { key: 'taxRate', labelKey: 'csvImport.taxRate', required: false },
  { key: 'shippingCost', labelKey: 'csvImport.shipping', required: false },
  { key: 'invoiceNumber', labelKey: 'csvImport.invoiceNumber', required: false },
  { key: 'invoiceStatus', labelKey: 'csvImport.invoiceStatus', required: false },
  { key: 'due_date', labelKey: 'csvImport.dueDate', required: false },
  { key: 'docNo', labelKey: 'csvImport.docNo', required: false, multiline: true },
  { key: 'lineNo', labelKey: 'csvImport.lineNo', required: false, multiline: true },
  { key: 'product', labelKey: 'csvImport.product', required: false, multiline: true },
  { key: 'description', labelKey: 'csvImport.description', required: false, multiline: true },
  { key: 'unit', labelKey: 'csvImport.unit', required: false, multiline: true },
  { key: 'unitPriceNet', labelKey: 'csvImport.unitPriceNet', required: false, multiline: true },
  { key: 'taxAmount', labelKey: 'csvImport.taxAmount', required: false, multiline: true },
  { key: 'totalWithTax', labelKey: 'csvImport.totalWithTax', required: false, multiline: true },
];

const PURCHASE_FIELDS: Field[] = [
  { key: 'id', labelKey: 'csvImport.id', required: false },
  { key: 'date', labelKey: 'csvImport.date', required: true },
  { key: 'supplier', labelKey: 'csvImport.supplier', required: true },
  { key: 'tons', labelKey: 'csvImport.quantity', required: true },
  { key: 'pricePerTon', labelKey: 'csvImport.unitPrice', required: false },
  { key: 'totalAmount', labelKey: 'csvImport.totalAmount', required: true },
  { key: 'taxRate', labelKey: 'csvImport.taxRate', required: false },
  { key: 'invoiceNumber', labelKey: 'csvImport.invoiceNumber', required: false },
  { key: 'invoiceStatus', labelKey: 'csvImport.invoiceStatus', required: false },
  { key: 'due_date', labelKey: 'csvImport.dueDate', required: false },
  { key: 'docNo', labelKey: 'csvImport.docNo', required: false, multiline: true },
  { key: 'lineNo', labelKey: 'csvImport.lineNo', required: false, multiline: true },
  { key: 'product', labelKey: 'csvImport.product', required: false, multiline: true },
  { key: 'description', labelKey: 'csvImport.description', required: false, multiline: true },
  { key: 'unit', labelKey: 'csvImport.unit', required: false, multiline: true },
  { key: 'unitPriceNet', labelKey: 'csvImport.unitPriceNet', required: false, multiline: true },
  { key: 'taxAmount', labelKey: 'csvImport.taxAmount', required: false, multiline: true },
  { key: 'totalWithTax', labelKey: 'csvImport.totalWithTax', required: false, multiline: true },
];

const NUMERIC_FIELDS = ['tons', 'pricePerTon', 'totalAmount', 'taxRate', 'shippingCost', 'lineNo', 'quantity', 'unitPriceNet', 'taxAmount', 'totalWithTax'];

const round2 = (n: number) => Math.round((Number(n) || 0) * 100) / 100;
const has = (v: any) => v != null && String(v).trim() !== '';
const cleanNum = (v: any): number => {
  const cleaned = String(v ?? '').replace(/[,，]/g, '');
  const m = cleaned.match(/-?[\d.]+/);
  return m ? parseFloat(m[0]) : 0;
};

// Auto-detect CSV header to app field
function autoMapHeaders(headers: string[], fields: Field[]): Record<string, string> {
  const mapping: Record<string, string> = {};
  const aliases: Record<string, string[]> = {
    date: ['日期', 'date', '时间'],
    customer: ['客户', 'customer', '客户名', '买方'],
    supplier: ['供应商', 'supplier', '卖方', '供货商'],
    tons: ['吨数', 'tons', '数量', '重量', 'quantity', 'weight'],
    pricePerTon: ['单价', 'price_per_ton', '吨价', 'unit_price'],
    totalAmount: ['总金额', 'total', 'amount', '金额', '总额', 'total_amount'],
    taxRate: ['税率', 'tax_rate', 'tax'],
    shippingCost: ['运费', 'shipping', 'freight'],
    invoiceNumber: ['发票号', 'invoice_no', 'invoice', '发票编号'],
    invoiceStatus: ['发票状态', 'invoice_status', '状态'],
    due_date: ['到期日', 'due_date', '应收日期', '应付日期', '账期'],
    id: ['id', 'ID', '编号'],
    // P5d-3 multi-line columns
    docNo: ['单据号', 'docno', 'doc_no', 'document_no', '单号', '单据编号'],
    lineNo: ['行号', 'lineno', 'line_no', '明细行号'],
    product: ['商品id', 'product_id', 'productid', '商品编号', 'sku'],
    description: ['品名', '说明', 'description', 'desc', '品名/说明', '名称'],
    unit: ['单位', 'uom'],
    unitPriceNet: ['不含税单价', 'unit_price_net', 'net_unit_price', '净单价', '未税单价'],
    taxAmount: ['税额', 'tax_amount', 'taxamount'],
    totalWithTax: ['价税合计', 'total_with_tax', 'gross', 'amount_gross', '含税合计'],
  };

  // Normalise so camelCase / snake_case / spaced headers compare uniformly:
  //   "unitPriceNet" == "unit_price_net" == "unit price net" → "unitpricenet".
  const norm = (s: string) => String(s).toLowerCase().replace(/[\s_\-/]/g, '').trim();
  // Each field's candidates ALWAYS include its own key, so an English header equal to the field key
  // (e.g. "unitPriceNet", "invoiceStatus", "docNo", "totalWithTax") maps exactly — and exact match
  // runs first, so e.g. "invoiceStatus" hits invoiceStatus before invoiceNumber's "invoice" substring.
  const candidates = (f: Field) => [f.key, ...(aliases[f.key] || [])].map(norm).filter(Boolean);

  for (const header of headers) {
    const h = norm(header);
    if (!h) continue;
    let key = '';
    for (const field of fields) { // pass 1 — exact (key or alias)
      if (candidates(field).some(a => a === h)) { key = field.key; break; }
    }
    if (!key) {
      for (const field of fields) { // pass 2 — substring fallback for fuzzy headers
        if (candidates(field).some(a => a.length >= 2 && h.includes(a))) { key = field.key; break; }
      }
    }
    if (key) mapping[header] = key;
  }
  return mapping;
}

// ── Payload builder (P5d-3) ──────────────────────────────────────────────────────────────────
// Rows are partitioned by docNo: a non-empty docNo groups rows into ONE multi-line document
// (record.items[]); rows without a docNo become legacy one-row-one-record (unchanged semantics —
// the CSV totalAmount column is treated as NET, with tax added on top). buildPayload validates
// everything up front and returns { records, errors, summary }; the modal only submits when
// errors is empty, so the backend's all-or-nothing import is never handed a partial file.

const tr = (t: any, k: string, opts?: any) => t(k, opts) as string;

function validateLegacy(rec: any, type: string, t: any): string[] {
  const e: string[] = [];
  if (!rec.date || !/^\d{4}-\d{2}-\d{2}$/.test(String(rec.date))) e.push(tr(t, 'csvImport.errDateFormat'));
  if (type === 'sales' && !rec.customer) e.push(tr(t, 'csvImport.errMissingCustomer'));
  if (type === 'purchases' && !rec.supplier) e.push(tr(t, 'csvImport.errMissingSupplier'));
  if (!rec.totalAmount || rec.totalAmount <= 0) e.push(tr(t, 'csvImport.errAmountPositive'));
  return e;
}

function buildLegacyRecord(r: any, type: string): any {
  const rec: any = {};
  if (has(r.id)) rec.id = String(r.id);
  rec.date = r.date;
  if (type === 'sales') rec.customer = r.customer; else rec.supplier = r.supplier;
  rec.tons = cleanNum(r.tons);
  rec.pricePerTon = cleanNum(r.pricePerTon);
  rec.totalAmount = cleanNum(r.totalAmount);
  rec.taxRate = cleanNum(r.taxRate) || 13;
  if (type === 'sales') rec.shippingCost = cleanNum(r.shippingCost);
  if (has(r.invoiceNumber)) rec.invoiceNumber = String(r.invoiceNumber);
  if (has(r.invoiceStatus)) rec.invoiceStatus = String(r.invoiceStatus);
  if (has(r.due_date)) rec.due_date = r.due_date;
  if (!rec.id) rec.id = `${type === 'sales' ? 'sale' : 'purchase'}-import-${Date.now()}-${r._row}`;
  // legacy derivation (preserve existing semantics): the CSV totalAmount column is the NET amount,
  // tax is added on top → header totalAmount = net + tax. UNCHANGED from before P5d-3.
  if (!rec.pricePerTon && rec.totalAmount && rec.tons) rec.pricePerTon = round2(rec.totalAmount / rec.tons);
  rec.amountWithoutTax = rec.totalAmount;
  rec.taxAmount = round2(rec.totalAmount * (rec.taxRate / 100));
  rec.totalAmount = round2(rec.amountWithoutTax + rec.taxAmount);
  return rec;
}

// Build one snake_case line item from a CSV row. Mirrors the editor's per-line calc:
//   totalWithTax given → reverse (net = gross/(1+rate), tax = gross − net);
//   unitPriceNet + quantity (+ taxRate) given → forward (net = qty×price, tax = net×rate);
//   description-only with no amount → a zero-amount line (allowed).
// Returns { skip } for a fully-blank row, { error } for an invalid one, else { item }.
type MatchStatus = 'none' | 'byId' | 'byName' | 'unmatched' | 'ambiguous' | 'manual';

// P5d-4 conservative product resolution: an explicit product_id wins (active or not, the user typed
// the id on purpose); otherwise an EXACT name match against ACTIVE products only — a single hit
// resolves, multiple hits are ambiguous (error, never silently pick), zero hits stay unmatched
// (imported as a description-only line, not counted in inventory). No fuzzy matching.
function resolveProduct(value: string, products: Product[]): { product_id: string | null; status: MatchStatus; name: string | null; unit: string | null } {
  const v = String(value ?? '').trim();
  if (!v) return { product_id: null, status: 'none', name: null, unit: null };
  const byId = products.find(p => p.id === v);
  if (byId) return { product_id: byId.id, status: 'byId', name: byId.name, unit: byId.unit };
  const lc = v.toLowerCase();
  const byName = products.filter(p => p.is_active && String(p.name).trim().toLowerCase() === lc);
  if (byName.length === 1) return { product_id: byName[0].id, status: 'byName', name: byName[0].name, unit: byName[0].unit };
  if (byName.length > 1) return { product_id: null, status: 'ambiguous', name: v, unit: null };
  return { product_id: null, status: 'unmatched', name: v, unit: null };
}

function buildItem(r: any, idx: number, t: any, products: Product[], override?: string): { skip?: boolean; error?: string; item?: any; match?: MatchStatus } {
  const productVal = has(r.product) ? String(r.product).trim() : '';
  const hasProduct = !!productVal;
  const hasDesc = has(r.description);
  // P5d-3 fix: the line quantity and net unit price come from the dedicated multi-line columns
  // when mapped, else fall back to the legacy 数量(tons) / 单价(pricePerTon) columns — those are
  // what a plain CSV's "数量"/"单价" headers actually map to. Without this the line qty/price were 0.
  const qtyRaw = has(r.quantity) ? r.quantity : r.tons;
  const unitRaw = has(r.unitPriceNet) ? r.unitPriceNet : r.pricePerTon;
  const hasAnyAmount = has(qtyRaw) || has(unitRaw) || has(r.totalWithTax);
  if (!hasProduct && !hasDesc && !hasAnyAmount) return { skip: true }; // blank line
  if (!hasProduct && !hasDesc) return { error: tr(t, 'csvImport.errLineNeedsProductOrDesc') };

  // P6: a manual override (an active product the user picked in the preview) wins over name
  // resolution. A stale override (product since removed) falls back to normal resolution.
  const ov = override != null && String(override).trim() !== '' ? String(override).trim() : '';
  let resolved: { product_id: string | null; status: MatchStatus; name: string | null; unit: string | null };
  if (ov) {
    const picked = products.find(p => p.id === ov);
    resolved = picked
      ? { product_id: picked.id, status: 'manual', name: picked.name, unit: picked.unit }
      : resolveProduct(productVal, products);
  } else {
    resolved = resolveProduct(productVal, products);
  }
  // P6 (method B): an ambiguous name no longer short-circuits to an error here — the line is still
  // built (product_id=null, match='ambiguous') so the preview can offer a product selector.
  // buildPayload turns an un-resolved ambiguous line into a blocking group error, so all-or-nothing
  // holds: the record is never submitted while any line stays ambiguous.

  const qty = cleanNum(qtyRaw);
  const rate = has(r.taxRate) ? cleanNum(r.taxRate) : 0;
  const hasGross = has(r.totalWithTax);
  const hasUnit = has(unitRaw);
  let net = 0, tax = 0, gross = 0, unit = 0;
  if (hasGross) {
    gross = cleanNum(r.totalWithTax);
    net = round2(gross / (1 + rate / 100));
    tax = round2(gross - net);
    unit = qty > 0 ? round2(net / qty) : 0;
    if (hasUnit) {
      const u = cleanNum(unitRaw);
      const altNet = round2(qty * u);
      const altGross = round2(altNet + round2(altNet * rate / 100));
      if (Math.abs(altGross - gross) > 0.02) return { error: tr(t, 'csvImport.errAmountConflict') };
    }
  } else if (hasUnit) {
    unit = cleanNum(unitRaw);
    net = round2(qty * unit);
    tax = has(r.taxAmount) ? round2(cleanNum(r.taxAmount)) : round2(net * rate / 100);
    gross = round2(net + tax);
  }
  // description = CSV description, else the matched product name or the raw product cell (so an
  // unmatched product still imports as a labelled description-only line). unit_snapshot = CSV unit,
  // else the matched product's unit. The persisted item shape is unchanged from P5d-3.
  const description = hasDesc ? String(r.description) : (resolved.name || (productVal || null));
  const unit_snapshot = has(r.unit) ? String(r.unit).slice(0, 50) : (resolved.unit || null);
  return {
    match: resolved.status,
    item: {
      line_no: has(r.lineNo) ? cleanNum(r.lineNo) : idx,
      product_id: resolved.product_id,
      description,
      unit_snapshot,
      quantity: qty,
      unit_price: unit,
      amount_net: net,
      tax_rate: has(r.taxRate) ? rate : null,
      tax_amount: tax,
      amount_gross: gross,
    },
  };
}

type PreviewItem = { row: number; lineNo: number; name: string | null; unit: string | null; qty: number; unitNet: number; rate: number | null; net: number; tax: number; gross: number; match: MatchStatus };
type PreviewGroup = { kind: 'doc' | 'legacy'; docNo: string; row: number; date: string; party: string; invoiceNumber: string; lineCount: number; totals: { net: number; tax: number; gross: number }; items: PreviewItem[]; errors: string[]; warning: string | null };
type Payload = { records: any[]; errors: { row: number; errors: string[] }[]; summary: { docs: number; lines: number }; groups: PreviewGroup[] };

function buildPayload(rows: any[], type: string, t: any, products: Product[], overrides: Record<number, string>): Payload {
  const party = type === 'sales' ? 'customer' : 'supplier';
  const records: any[] = [];
  const errors: { row: number; errors: string[] }[] = [];
  const groups: PreviewGroup[] = [];
  let docs = 0;
  let lines = 0;

  const groupsMap = new Map<string, any[]>();
  const legacy: any[] = [];
  for (const r of rows) {
    if (has(r.docNo)) {
      const key = String(r.docNo).trim();
      if (!groupsMap.has(key)) groupsMap.set(key, []);
      (groupsMap.get(key) as any[]).push(r);
    } else if (Object.keys(r).some(k => k !== '_row' && has(r[k]))) {
      legacy.push(r); // skip fully-blank rows
    }
  }

  // legacy rows → one record + one compact display group
  for (const r of legacy) {
    docs++;
    const rec = buildLegacyRecord(r, type);
    const e = validateLegacy(rec, type, t);
    groups.push({ kind: 'legacy', docNo: '', row: r._row, date: rec.date, party: rec[party], invoiceNumber: rec.invoiceNumber || '', lineCount: 1, totals: { net: rec.amountWithoutTax, tax: rec.taxAmount, gross: rec.totalAmount }, items: [], errors: e, warning: null });
    if (e.length) errors.push({ row: r._row, errors: e });
    else records.push(rec);
  }

  // doc groups → one items[] record + one per-document display group
  for (const [docNo, grp] of groupsMap) {
    docs++;
    const head = grp[0];
    const e: string[] = [];
    const hDate = String(head.date ?? '').trim();
    const hParty = String(head[party] ?? '').trim();
    if (grp.some(r => String(r.date ?? '').trim() !== hDate) || grp.some(r => String(r[party] ?? '').trim() !== hParty)) {
      e.push(tr(t, 'csvImport.errGroupConflict', { docNo }));
    }
    if (!hDate || !/^\d{4}-\d{2}-\d{2}$/.test(hDate)) e.push(tr(t, 'csvImport.errDateFormat'));
    if (!hParty) e.push(type === 'sales' ? tr(t, 'csvImport.errMissingCustomer') : tr(t, 'csvImport.errMissingSupplier'));

    const sorted = grp
      .map((r, i) => ({ r, i }))
      .sort((a, b) => (has(a.r.lineNo) ? cleanNum(a.r.lineNo) : a.i) - (has(b.r.lineNo) ? cleanNum(b.r.lineNo) : b.i));
    const items: any[] = [];
    const previewItems: PreviewItem[] = [];
    const seenLineNos = new Set<number>();
    let dupLine = false;
    sorted.forEach(({ r }, i) => {
      const ln = has(r.lineNo) ? cleanNum(r.lineNo) : null;
      if (ln != null) { if (seenLineNos.has(ln)) dupLine = true; else seenLineNos.add(ln); }
      const res = buildItem(r, i, t, products, overrides[r._row]);
      if (res.skip) return;
      const lineNo = has(r.lineNo) ? cleanNum(r.lineNo) : i;
      if (res.error) { e.push(tr(t, 'csvImport.rowErrorCtx', { row: r._row, docNo, lineNo, errors: res.error })); return; }
      // P6 (method B): a still-ambiguous line (no valid manual pick) blocks the whole file — the row
      // is shown with a selector, but the import stays disabled until the user resolves it.
      if (res.match === 'ambiguous') {
        e.push(tr(t, 'csvImport.rowErrorCtx', { row: r._row, docNo, lineNo, errors: tr(t, 'csvImport.errProductAmbiguous', { name: res.item.description }) }));
      }
      items.push(res.item);
      previewItems.push({ row: r._row, lineNo: res.item.line_no, name: res.item.description, unit: res.item.unit_snapshot, qty: res.item.quantity, unitNet: res.item.unit_price, rate: res.item.tax_rate, net: res.item.amount_net, tax: res.item.tax_amount, gross: res.item.amount_gross, match: res.match || 'none' });
    });
    if (items.length === 0) e.push(tr(t, 'csvImport.errGroupNoLines', { docNo }));

    const totals = {
      net: round2(items.reduce((s, it) => s + it.amount_net, 0)),
      tax: round2(items.reduce((s, it) => s + it.tax_amount, 0)),
      gross: round2(items.reduce((s, it) => s + it.amount_gross, 0)),
    };
    const dedup = [...new Set(e)];
    groups.push({ kind: 'doc', docNo, row: head._row, date: head.date, party: head[party], invoiceNumber: has(head.invoiceNumber) ? String(head.invoiceNumber) : '', lineCount: previewItems.length, totals, items: previewItems, errors: dedup, warning: dupLine ? tr(t, 'csvImport.errDupLineNo', { docNo }) : null });
    if (dedup.length) { errors.push({ row: head._row, errors: dedup }); continue; }
    lines += items.length;
    const rec: any = {
      id: has(head.id) ? String(head.id) : `${type === 'sales' ? 'sale' : 'purchase'}-import-${Date.now()}-${String(docNo).replace(/[^a-zA-Z0-9_-]/g, '').slice(0, 40)}`,
      date: head.date,
      [party]: head[party],
      invoiceNumber: has(head.invoiceNumber) ? String(head.invoiceNumber) : '',
      invoiceStatus: has(head.invoiceStatus) ? String(head.invoiceStatus) : '',
      due_date: has(head.due_date) ? head.due_date : null,
      items,
    };
    if (type === 'sales') rec.shippingCost = cleanNum(head.shippingCost); // header-level, never in items sum
    records.push(rec);
  }

  return { records, errors, summary: { docs, lines }, groups };
}

const CsvImportModal: React.FC<Props> = ({ type, onClose, onSuccess }) => {
  const { t } = useTranslation();
  const [accLocale, setAccLocale] = useState<string>('CN');
  useEffect(() => {
    fetchSettings().then((s: any) => {
      if (s?.accounting_locale) setAccLocale(s.accounting_locale);
    }).catch(() => {});
  }, []);
  const currSym = getCurrencySymbol(accLocale);
  const [step, setStep] = useState<1 | 2 | 3 | 4>(1);
  const [csvData, setCsvData] = useState<any[]>([]);
  const [headers, setHeaders] = useState<string[]>([]);
  const [mapping, setMapping] = useState<Record<string, string>>({});
  const [fileName, setFileName] = useState('');
  const [importing, setImporting] = useState(false);
  const [result, setResult] = useState<{ success: number; failed: number; errors: { row: number; errors: string[] }[] } | null>(null);
  const [dragActive, setDragActive] = useState(false);
  const fileInputRef = useRef<HTMLInputElement>(null);
  // P5d-4: products for name→id resolution, pre-loaded on open. productsReady gates the preview so
  // a slow load never makes every product look "unmatched".
  const [products, setProducts] = useState<Product[]>([]);
  const [productsReady, setProductsReady] = useState(false);
  useEffect(() => {
    listProducts().then((p) => { setProducts(p); setProductsReady(true); }).catch(() => setProductsReady(true));
  }, []);
  // P6: manual product picks keyed by source row (_row → product_id). Only active products are
  // offered — this does not narrow resolveProduct's existing semantics (an explicit id still wins,
  // active-service names still match); it just mirrors the same active-only rule for manual picks.
  const [overrides, setOverrides] = useState<Record<number, string>>({});
  const activeProducts = useMemo(() => products.filter(p => p.is_active), [products]);
  const setOverride = useCallback((row: number, productId: string) => {
    setOverrides(prev => {
      const next = { ...prev };
      if (productId) next[row] = productId; else delete next[row]; // clearing reverts to auto-resolution
      return next;
    });
  }, []);

  const fields = type === 'sales' ? SALES_FIELDS : PURCHASE_FIELDS;

  const reset = useCallback(() => {
    setStep(1);
    setCsvData([]);
    setHeaders([]);
    setMapping({});
    setFileName('');
    setImporting(false);
    setResult(null);
    setOverrides({});
  }, []);

  const handleClose = () => {
    reset();
    onClose();
  };

  const processFile = (file: File) => {
    setOverrides({}); // a new file re-numbers rows — old _row→product picks no longer apply
    setFileName(file.name);
    const isExcel = file.name.endsWith('.xlsx') || file.name.endsWith('.xls');

    if (isExcel) {
      // Dynamic import for xlsx
      import('xlsx').then((XLSX) => {
        const reader = new FileReader();
        reader.onload = (e) => {
          const data = new Uint8Array(e.target?.result as ArrayBuffer);
          const workbook = XLSX.read(data, { type: 'array' });
          const sheet = workbook.Sheets[workbook.SheetNames[0]];
          const json = XLSX.utils.sheet_to_json(sheet, { header: 1 }) as any[][];
          if (json.length < 2) return;
          const hdrs = json[0].map(String);
          setHeaders(hdrs);
          const rows = json.slice(1).map(row => {
            const obj: any = {};
            hdrs.forEach((h, i) => { obj[h] = row[i] ?? ''; });
            return obj;
          });
          setCsvData(rows);
          setMapping(autoMapHeaders(hdrs, fields));
          setStep(2);
        };
        reader.readAsArrayBuffer(file);
      }).catch(() => alert(t('csvImport.excelParseError')));
    } else {
      Papa.parse(file, {
        header: true,
        skipEmptyLines: true,
        complete: (results) => {
          if (results.data.length === 0) return;
          const hdrs = results.meta.fields || [];
          setHeaders(hdrs);
          setCsvData(results.data);
          setMapping(autoMapHeaders(hdrs, fields));
          setStep(2);
        },
        error: () => alert(t('csvImport.csvParseError')),
      });
    }
  };

  const handleDrop = (e: React.DragEvent) => {
    e.preventDefault();
    setDragActive(false);
    const file = e.dataTransfer.files[0];
    if (file) processFile(file);
  };

  // Raw per-source-row mapping (keeps line-level fields so docNo grouping can build items[]).
  const mappedRows = useMemo(() => csvData.map((row, idx) => {
    const r: any = { _row: idx + 1 };
    for (const [csvHeader, appField] of Object.entries(mapping)) {
      if (appField) r[appField] = row[csvHeader];
    }
    return r;
  }), [csvData, mapping]);

  const payload = useMemo(() => buildPayload(mappedRows, type, t, products, overrides), [mappedRows, type, t, products, overrides]);

  const handleImport = async () => {
    if (!productsReady || payload.errors.length > 0) return; // all-or-nothing: never submit a file with known errors
    setImporting(true);
    try {
      const batchFn = type === 'sales' ? batchCreateSales : batchCreatePurchases;
      const res = await batchFn(payload.records);
      setResult(res);
      setStep(4);
      if (res.success > 0) onSuccess();
    } catch (err: any) {
      setResult({ success: 0, failed: payload.records.length, errors: [{ row: 0, errors: [err.message || t('csvImport.importFailed')] }] });
      setStep(4);
    } finally {
      setImporting(false);
    }
  };

  const downloadTemplate = () => {
    // legacy (non-multiline) template stays byte-compatible with the existing example rows
    const templateFields = fields.filter(f => !f.multiline).map(f => t((f as any).labelKey));
    const exampleRow = type === 'sales'
      ? ['', '2026-03-01', t('csvImport.exampleCustomer'), '10', '3500', '35000', '13', '500', 'FP-001', t('csvImport.exampleIssued'), '2026-04-01']
      : ['', '2026-03-01', t('csvImport.exampleSupplier'), '10', '3000', '30000', '13', '', 'FP-001', t('csvImport.exampleReceived'), '2026-04-01'];
    const csv = [templateFields.join(','), exampleRow.join(',')].join('\n');
    const blob = new Blob(['﻿' + csv], { type: 'text/csv;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `${t(type === 'sales' ? 'csvImport.templateSales' : 'csvImport.templatePurchases')}.csv`;
    a.click();
    URL.revokeObjectURL(url);
  };

  return (
    <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50 p-4">
      <div className="glass-modal rounded-2xl w-full max-w-3xl max-h-[90vh] overflow-hidden">
        {/* Header */}
        <div className="flex items-center justify-between px-6 py-4 border-b border-[#e0ddd5]">
          <h3 className="text-lg font-bold text-[#191918]">
            <i className="fas fa-file-import mr-2 text-primary"></i>
            {type === 'sales' ? t('csvImport.titleSales') : t('csvImport.titlePurchases')}
          </h3>
          <button onClick={handleClose} aria-label={t('common.close')} className="text-[#5c5c5a] hover:text-[#191918]">
            <i className="fas fa-times text-lg"></i>
          </button>
        </div>

        {/* Steps indicator */}
        <div className="flex items-center px-6 py-3 bg-[#f9f9f8] border-b border-[#e0ddd5]">
          {[t('csvImport.step1Upload'), t('csvImport.step2Mapping'), t('csvImport.step3Preview'), t('csvImport.step4Result')].map((label, i) => (
            <div key={i} className="flex items-center">
              <div className={`w-7 h-7 rounded-full flex items-center justify-center text-xs font-bold ${
                step > i + 1 ? 'bg-green-500 text-white' : step === i + 1 ? 'bg-primary text-white' : 'bg-[#e0ddd5] text-[#5c5c5a]'
              }`}>{step > i + 1 ? '✓' : i + 1}</div>
              <span className={`ml-1.5 text-xs ${step === i + 1 ? 'text-[#191918] font-medium' : 'text-[#5c5c5a]'}`}>{label}</span>
              {i < 3 && <div className="w-8 h-px bg-[#e0ddd5] mx-2"></div>}
            </div>
          ))}
        </div>

        {/* Content */}
        <div className="p-6 overflow-y-auto max-h-[60vh]">
          {/* Step 1: Upload */}
          {step === 1 && (
            <div>
              <div
                onDrop={handleDrop}
                onDragOver={(e) => { e.preventDefault(); setDragActive(true); }}
                onDragLeave={() => setDragActive(false)}
                onClick={() => fileInputRef.current?.click()}
                className={`border-2 border-dashed rounded-xl p-12 text-center cursor-pointer transition-all ${
                  dragActive ? 'border-primary bg-primary/5' : 'border-[#e0ddd5] hover:border-primary/50'
                }`}
              >
                <i className="fas fa-cloud-upload-alt text-4xl text-primary mb-3"></i>
                <p className="text-[#191918] font-medium mb-1">{t('csvImport.dropHint')}</p>
                <p className="text-xs text-[#5c5c5a]">{t('csvImport.formatHint')}</p>
                <input ref={fileInputRef} type="file" accept=".csv,.xlsx,.xls" className="hidden"
                  onChange={(e) => { if (e.target.files?.[0]) processFile(e.target.files[0]); }} />
              </div>
              <button onClick={downloadTemplate} className="mt-4 text-sm text-primary hover:underline">
                <i className="fas fa-download mr-1"></i> {t('csvImport.downloadTemplate')}
              </button>
            </div>
          )}

          {/* Step 2: Field Mapping */}
          {step === 2 && (
            <div>
              <p className="text-sm text-[#5c5c5a] mb-2">{t('csvImport.mappingInstruction')}</p>
              <p className="text-xs text-[#5c5c5a] mb-4"><i className="fas fa-circle-info mr-1"></i>{t('csvImport.multiLineHint')}</p>
              <div className="space-y-2">
                {headers.map(h => (
                  <div key={h} className="flex items-center gap-3">
                    <span className="w-32 text-sm text-[#191918] truncate font-mono bg-[#f0eeeb] px-2 py-1 rounded">{h}</span>
                    <i className="fas fa-arrow-right text-[#5c5c5a] text-xs"></i>
                    <select
                      value={mapping[h] || ''}
                      onChange={(e) => { setMapping({ ...mapping, [h]: e.target.value }); setOverrides({}); }}
                      className="flex-1 text-sm border border-[#e0ddd5] rounded-lg px-3 py-1.5 bg-white"
                    >
                      <option value="">{t('csvImport.skipColumn')}</option>
                      {fields.map(f => (
                        <option key={f.key} value={f.key}>{t((f as any).labelKey)}{f.required ? ' *' : ''}</option>
                      ))}
                    </select>
                  </div>
                ))}
              </div>
            </div>
          )}

          {/* Step 3: Preview & Validate */}
          {step === 3 && (
            !productsReady ? (
              <div className="text-sm text-[#5c5c5a] py-10 text-center"><i className="fas fa-spinner fa-spin mr-2"></i>{t('csvImport.productsLoading')}</div>
            ) : (
            <div>
              <p className="text-sm text-[#191918] font-medium mb-2">{t('csvImport.groupSummary', { docs: payload.summary.docs, lines: payload.summary.lines })}</p>
              <div className={`text-xs border rounded-lg px-3 py-2 mb-3 ${payload.errors.length > 0 ? 'text-red-700 bg-red-50 border-red-200' : 'text-amber-700 bg-amber-50 border-amber-200'}`}>
                <i className="fas fa-circle-info mr-1.5"></i>
                {payload.errors.length > 0 ? t('csvImport.errorSummary', { count: payload.errors.length }) : t('csvImport.allOrNothingNotice')}
              </div>
              <div className="space-y-2">
                {payload.groups.slice(0, 30).map((g, gi) => {
                  const hasErr = g.errors.length > 0;
                  const cardHead = (
                    <div className="flex flex-wrap items-center justify-between gap-x-4 gap-y-1 px-3 py-2">
                      <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs min-w-0">
                        <i className={`fas ${hasErr ? 'fa-exclamation-circle text-red-500' : 'fa-check-circle text-green-600'}`}></i>
                        <span className="font-bold text-[#191918] truncate">{g.kind === 'doc' ? g.docNo : t('csvImport.legacyRow')}</span>
                        <span className="text-[#5c5c5a]">{g.date}</span>
                        <span className="text-[#5c5c5a] truncate">{g.party}</span>
                        {g.invoiceNumber && <span className="text-[#5c5c5a]">{g.invoiceNumber}</span>}
                        <span className="text-[#5c5c5a]">{t('csvImport.previewLineCount', { count: g.lineCount })}</span>
                      </div>
                      <div className="flex items-center gap-x-3 text-xs whitespace-nowrap">
                        <span className="text-[#5c5c5a]">{t('csvImport.previewNetTotal')} <span className="font-bold text-[#191918]">{currSym}{g.totals.net.toLocaleString()}</span></span>
                        <span className="text-[#5c5c5a]">{t('csvImport.previewTaxTotal')} <span className="font-bold text-[#191918]">{currSym}{g.totals.tax.toLocaleString()}</span></span>
                        <span className="text-[#5c5c5a]">{t('csvImport.totalWithTax')} <span className="font-bold text-rose-600">{currSym}{g.totals.gross.toLocaleString()}</span></span>
                      </div>
                    </div>
                  );
                  return (
                    <div key={gi} className={`border rounded-lg ${hasErr ? 'border-red-200 bg-red-50/40' : 'border-[#e0ddd5] bg-white'}`}>
                      {g.kind === 'doc' && g.items.length > 0 ? (
                        <details open={hasErr || undefined}>
                          <summary className="cursor-pointer list-none hover:bg-[#f9f9f8]/60 rounded-lg">{cardHead}</summary>
                          <div className="overflow-x-auto border-t border-[#e0ddd5]/70">
                            <table className="w-full text-[11px] border-collapse">
                              <thead><tr className="bg-[#f9f9f8] text-[#5c5c5a]">
                                <th className="px-2 py-1 text-left">{t('csvImport.lineNo')}</th>
                                <th className="px-2 py-1 text-left">{t('csvImport.description')}</th>
                                <th className="px-2 py-1 text-left">{t('csvImport.unit')}</th>
                                <th className="px-2 py-1 text-right">{t('csvImport.quantity')}</th>
                                <th className="px-2 py-1 text-right">{t('csvImport.unitPriceNet')}</th>
                                <th className="px-2 py-1 text-right">{t('csvImport.taxRate')}</th>
                                <th className="px-2 py-1 text-right">{t('csvImport.taxAmount')}</th>
                                <th className="px-2 py-1 text-right">{t('csvImport.totalWithTax')}</th>
                                <th className="px-2 py-1 text-center">{t('csvImport.matchStatus')}</th>
                              </tr></thead>
                              <tbody>
                                {g.items.map((it, ii) => (
                                  <tr key={ii} className="border-t border-[#f0eeeb]">
                                    <td className="px-2 py-1">{it.lineNo}</td>
                                    <td className="px-2 py-1">{it.name || '—'}</td>
                                    <td className="px-2 py-1">{it.unit || '—'}</td>
                                    <td className="px-2 py-1 text-right">{it.qty}</td>
                                    <td className="px-2 py-1 text-right">{currSym}{it.unitNet.toLocaleString()}</td>
                                    <td className="px-2 py-1 text-right">{it.rate != null ? `${it.rate}%` : '—'}</td>
                                    <td className="px-2 py-1 text-right">{currSym}{it.tax.toLocaleString()}</td>
                                    <td className="px-2 py-1 text-right font-medium">{currSym}{it.gross.toLocaleString()}</td>
                                    <td className="px-2 py-1 text-center whitespace-nowrap">
                                      {it.match === 'byId' || it.match === 'byName' ? (
                                        <span className="text-green-600">{t('csvImport.matchedBadge')}</span>
                                      ) : it.match === 'unmatched' || it.match === 'ambiguous' || it.match === 'manual' ? (
                                        // P6: let the user assign an active product to an unmatched / same-name-ambiguous
                                        // line; an empty pick keeps it description-only (unmatched) or blocking (ambiguous).
                                        <div className="flex items-center justify-center gap-1">
                                          <select
                                            aria-label={t('csvImport.matchStatus')}
                                            value={overrides[it.row] ?? ''}
                                            onChange={(e) => setOverride(it.row, e.target.value)}
                                            className="text-[11px] border border-[#e0ddd5] rounded px-1 py-0.5 bg-white max-w-[130px]"
                                          >
                                            <option value="">{t('csvImport.selectProduct')}</option>
                                            {activeProducts.map(p => (
                                              <option key={p.id} value={p.id}>{p.name}</option>
                                            ))}
                                          </select>
                                          {it.match === 'manual'
                                            ? <span className="text-green-600" title={t('csvImport.manualMatchBadge')}><i className="fas fa-check"></i></span>
                                            : it.match === 'ambiguous'
                                              ? <span className="text-red-500" title={t('csvImport.errProductAmbiguous', { name: it.name || '' })}><i className="fas fa-exclamation"></i></span>
                                              : <span className="text-amber-600" title={t('csvImport.unmatchedBadge')}>{t('csvImport.unmatchedShort')}</span>}
                                        </div>
                                      ) : (
                                        <span className="text-[#5c5c5a]">—</span>
                                      )}
                                    </td>
                                  </tr>
                                ))}
                              </tbody>
                            </table>
                            {g.warning && <p className="text-[10px] text-amber-600 px-2 py-1">{g.warning}</p>}
                          </div>
                        </details>
                      ) : cardHead}
                      {hasErr && <div className="border-t border-red-200 px-3 py-1.5 text-[11px] text-red-600">{g.errors.join('；')}</div>}
                    </div>
                  );
                })}
              </div>
              {payload.groups.length > 30 && <p className="text-xs text-[#5c5c5a] mt-2">{t('csvImport.previewMoreDocs', { count: payload.groups.length - 30 })}</p>}
            </div>
            )
          )}

          {/* Step 4: Result */}
          {step === 4 && result && (
            <div className="text-center py-6">
              {result.success > 0 ? (
                <div>
                  <i className="fas fa-check-circle text-5xl text-green-500 mb-4"></i>
                  <p className="text-lg font-bold text-[#191918]">{t('csvImport.importComplete')}</p>
                  <p className="text-sm text-[#5c5c5a] mt-2">
                    <span className="text-green-600 font-bold">{t('csvImport.successCount', { count: result.success })}</span>
                    {result.failed > 0 && <>{', '}<span className="text-red-500 font-bold">{t('csvImport.failedCount', { count: result.failed })}</span></>}
                  </p>
                </div>
              ) : (
                <div>
                  <i className="fas fa-exclamation-triangle text-5xl text-red-500 mb-4"></i>
                  <p className="text-lg font-bold text-[#191918]">{t('csvImport.importFailed')}</p>
                </div>
              )}
              {result.errors.length > 0 && (
                <div className="mt-4 text-left bg-red-50 rounded-lg p-3 max-h-40 overflow-y-auto">
                  {result.errors.slice(0, 10).map((e, i) => (
                    <p key={i} className="text-xs text-red-600">{t('csvImport.rowError', { row: e.row, errors: e.errors.join(', ') })}</p>
                  ))}
                </div>
              )}
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="flex items-center justify-between px-6 py-4 border-t border-[#e0ddd5] bg-[#f9f9f8]">
          <span className="text-xs text-[#5c5c5a]">{fileName && t('csvImport.fileInfo', { name: fileName, count: csvData.length })}</span>
          <div className="flex gap-2">
            {step > 1 && step < 4 && (
              <button onClick={() => setStep((step - 1) as any)} className="px-4 py-2 text-sm text-[#5c5c5a] hover:text-[#191918]">{t('csvImport.prev')}</button>
            )}
            {step === 2 && (
              <button onClick={() => setStep(3)} className="px-4 py-2 text-sm bg-primary text-white rounded-lg hover:bg-primary-hover">
                {t('csvImport.nextPreview')}
              </button>
            )}
            {step === 3 && (
              <button onClick={handleImport} disabled={importing || !productsReady || payload.errors.length > 0} className="px-4 py-2 text-sm bg-primary text-white rounded-lg hover:bg-primary-hover disabled:opacity-50 disabled:cursor-not-allowed">
                {importing ? <><i className="fas fa-spinner fa-spin mr-1"></i>{t('csvImport.importing')}</> : t('csvImport.confirmImport', { count: payload.records.length })}
              </button>
            )}
            {step === 4 && (
              <button onClick={handleClose} className="px-4 py-2 text-sm bg-primary text-white rounded-lg hover:bg-primary-hover">{t('csvImport.done')}</button>
            )}
          </div>
        </div>
      </div>
    </div>
  );
};

export default CsvImportModal;
