import React, { useState, useRef, useCallback, useEffect, useMemo } from 'react';
import { useTranslation } from 'react-i18next';
import Papa from 'papaparse';
import { batchCreateSales, batchCreatePurchases, fetchSettings } from '../services/api';
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
function buildItem(r: any, idx: number, t: any): { skip?: boolean; error?: string; item?: any } {
  const hasProduct = has(r.product);
  const hasDesc = has(r.description);
  // P5d-3 fix: the line quantity and net unit price come from the dedicated multi-line columns
  // when mapped, else fall back to the legacy 数量(tons) / 单价(pricePerTon) columns — those are
  // what a plain CSV's "数量"/"单价" headers actually map to. Without this the line qty/price were 0.
  const qtyRaw = has(r.quantity) ? r.quantity : r.tons;
  const unitRaw = has(r.unitPriceNet) ? r.unitPriceNet : r.pricePerTon;
  const hasAnyAmount = has(qtyRaw) || has(unitRaw) || has(r.totalWithTax);
  if (!hasProduct && !hasDesc && !hasAnyAmount) return { skip: true }; // blank line
  if (!hasProduct && !hasDesc) return { error: tr(t, 'csvImport.errLineNeedsProductOrDesc') };

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
  return {
    item: {
      line_no: has(r.lineNo) ? cleanNum(r.lineNo) : idx,
      product_id: hasProduct ? String(r.product).trim() : null,
      description: hasDesc ? String(r.description) : null,
      unit_snapshot: has(r.unit) ? String(r.unit).slice(0, 50) : null,
      quantity: qty,
      unit_price: unit,
      amount_net: net,
      tax_rate: has(r.taxRate) ? rate : null,
      tax_amount: tax,
      amount_gross: gross,
    },
  };
}

function buildPayload(rows: any[], type: string, t: any): { records: any[]; errors: { row: number; errors: string[] }[]; summary: { docs: number; lines: number } } {
  const party = type === 'sales' ? 'customer' : 'supplier';
  const records: any[] = [];
  const errors: { row: number; errors: string[] }[] = [];
  let docs = 0;
  let lines = 0;

  const groups = new Map<string, any[]>();
  const legacy: any[] = [];
  for (const r of rows) {
    if (has(r.docNo)) {
      const key = String(r.docNo).trim();
      if (!groups.has(key)) groups.set(key, []);
      (groups.get(key) as any[]).push(r);
    } else if (Object.keys(r).some(k => k !== '_row' && has(r[k]))) {
      legacy.push(r); // skip fully-blank rows
    }
  }

  // legacy rows → one record each
  for (const r of legacy) {
    const rec = buildLegacyRecord(r, type);
    const e = validateLegacy(rec, type, t);
    if (e.length) errors.push({ row: r._row, errors: e });
    else { records.push(rec); docs++; }
  }

  // doc groups → one items[] record each
  for (const [docNo, grp] of groups) {
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
    sorted.forEach(({ r }, i) => {
      const res = buildItem(r, i, t);
      if (res.skip) return;
      if (res.error) { e.push(tr(t, 'csvImport.rowError', { row: r._row, errors: res.error })); return; }
      items.push(res.item);
    });
    if (items.length === 0) e.push(tr(t, 'csvImport.errGroupNoLines', { docNo }));

    if (e.length) { errors.push({ row: head._row, errors: [...new Set(e)] }); continue; }
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

  return { records, errors, summary: { docs, lines } };
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

  const fields = type === 'sales' ? SALES_FIELDS : PURCHASE_FIELDS;

  const reset = useCallback(() => {
    setStep(1);
    setCsvData([]);
    setHeaders([]);
    setMapping({});
    setFileName('');
    setImporting(false);
    setResult(null);
  }, []);

  const handleClose = () => {
    reset();
    onClose();
  };

  const processFile = (file: File) => {
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

  const payload = useMemo(() => buildPayload(mappedRows, type, t), [mappedRows, type, t]);
  const errorRows = useMemo(() => new Set(payload.errors.map(e => e.row)), [payload]);

  const handleImport = async () => {
    if (payload.errors.length > 0) return; // all-or-nothing: never submit a file with known errors
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
                      onChange={(e) => setMapping({ ...mapping, [h]: e.target.value })}
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
            <div>
              <p className="text-sm text-[#191918] font-medium mb-2">{t('csvImport.groupSummary', { docs: payload.summary.docs, lines: payload.summary.lines })}</p>
              <div className="text-xs text-amber-700 bg-amber-50 border border-amber-200 rounded-lg px-3 py-2 mb-3">
                <i className="fas fa-circle-info mr-1.5"></i>{t('csvImport.allOrNothingNotice')}
              </div>
              {payload.errors.length > 0 && (
                <div className="text-xs bg-red-50 border border-red-200 rounded-lg px-3 py-2 mb-3 max-h-32 overflow-y-auto">
                  {payload.errors.slice(0, 10).map((e, i) => (
                    <p key={i} className="text-red-600">{t('csvImport.rowError', { row: e.row, errors: e.errors.join(', ') })}</p>
                  ))}
                  {payload.errors.length > 10 && <p className="text-red-500">{t('csvImport.moreRows', { count: payload.errors.length - 10 })}</p>}
                </div>
              )}
              <div className="overflow-x-auto">
                <table className="w-full text-xs border-collapse data-table">
                  <thead>
                    <tr className="bg-[#f0eeeb]">
                      <th className="px-2 py-1.5 text-left">#</th>
                      <th className="px-2 py-1.5 text-left">{t('csvImport.docNo')}</th>
                      <th className="px-2 py-1.5 text-left">{t('csvImport.date')}</th>
                      <th className="px-2 py-1.5 text-left">{type === 'sales' ? t('csvImport.customer') : t('csvImport.supplier')}</th>
                      <th className="px-2 py-1.5 text-right">{t('csvImport.quantity')}</th>
                      <th className="px-2 py-1.5 text-right">{t('csvImport.totalAmount')}</th>
                      <th className="px-2 py-1.5 text-center">{t('csvImport.invoiceStatus')}</th>
                    </tr>
                  </thead>
                  <tbody>
                    {mappedRows.slice(0, 10).map((r, i) => {
                      const isErr = errorRows.has(r._row);
                      const amount = cleanNum(has(r.totalWithTax) ? r.totalWithTax : r.totalAmount);
                      return (
                        <tr key={i} className={`border-t border-[#f0eeeb] ${isErr ? 'bg-red-50' : ''}`}>
                          <td className="px-2 py-1.5">{r._row}</td>
                          <td className="px-2 py-1.5">{has(r.docNo) ? String(r.docNo) : '—'}</td>
                          <td className="px-2 py-1.5">{r.date}</td>
                          <td className="px-2 py-1.5">{type === 'sales' ? r.customer : r.supplier}</td>
                          <td className="px-2 py-1.5 text-right">{has(r.quantity) ? r.quantity : (r.tons ?? '')}</td>
                          <td className="px-2 py-1.5 text-right">{currSym}{amount.toLocaleString()}</td>
                          <td className="px-2 py-1.5 text-center">
                            {isErr
                              ? <span className="text-red-500"><i className="fas fa-exclamation-circle"></i></span>
                              : <span className="text-green-600"><i className="fas fa-check-circle"></i></span>
                            }
                          </td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
              {mappedRows.length > 10 && <p className="text-xs text-[#5c5c5a] mt-2">{t('csvImport.moreRows', { count: mappedRows.length - 10 })}</p>}
            </div>
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
              <button onClick={handleImport} disabled={importing || payload.errors.length > 0} className="px-4 py-2 text-sm bg-primary text-white rounded-lg hover:bg-primary-hover disabled:opacity-50 disabled:cursor-not-allowed">
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
