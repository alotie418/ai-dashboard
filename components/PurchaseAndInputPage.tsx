
import React, { useState, useRef, useEffect } from 'react';
import { useTranslation } from 'react-i18next';
import { BusinessData } from '../types';
import { analyzeInvoice, extractedToPurchaseForm, type ExtractedInvoice } from '../services/ocrService';
import { rasterizePdfFirstPage } from '../services/pdfRaster';
import { fetchPurchases, getPurchase, createPurchase, updatePurchase, deletePurchase, fetchSettings, listProducts, listProviders, type Product, type LineItem, PurchaseRecord } from '../services/api';
import { getSystemErrorText } from '../services/systemErrors';
import { formatMoney, getCurrencySymbol, getTaxLabel, formatLegacyQuantity, getProductUnitLabel } from './accountingHelpers';
import { classifyInvoiceStatus, INVOICE_STATUS_BADGE_CLASS } from './invoiceStatusDisplay';
import CsvImportModal from './CsvImportModal';
import OcrPreviewModal from './OcrPreviewModal';
import { TAX_RATE_OPTIONS } from './taxRateOptions';

interface Props {
  data: BusinessData;
  selectedYear: string;
  selectedQuarter: string;
  selectedMonth: string;
}

let purchaseIdCounter = 0;
const nextPurchaseId = () => `purchase-${++purchaseIdCounter}-${Date.now()}`;

// P4b: one product/service line in the multi-line editor (all inputs are strings).
interface ItemRow {
  productId: string;
  description: string;
  unit: string;
  quantity: string;
  unitPrice: string;
  taxRatePct: string;
  // Tax-inclusive amount typed directly (P4b problem-2 fix): a non-empty grossInput drives the
  // line in reverse (net = gross/(1+rate), tax = gross−net, unitPrice = net/qty); typing the
  // net unit price clears it and the line goes back to forward (net = qty × unitPrice).
  grossInput: string;
  // Locked original amount (from an edited record's stored values); cleared when the user
  // changes quantity/unitPrice/taxRate/gross so the line switches back to recompute. Prevents a
  // no-op edit from drifting a stored amount by a rounding cent (mirrors DocumentModal).
  locked: { net: number; tax: number } | null;
}
const round2 = (v: number) => Math.round((v || 0) * 100) / 100;

const PurchaseAndInputPage: React.FC<Props> = ({ data, selectedYear, selectedQuarter, selectedMonth }) => {
  const { t, i18n } = useTranslation();
  const [accLocale, setAccLocale] = useState('CN');
  const [productUnit, setProductUnit] = useState<string>('ton');
  useEffect(() => {
    fetchSettings().then((s: any) => {
      if (s?.accounting_locale) setAccLocale(s.accounting_locale);
      if (s?.product_unit) setProductUnit(s.product_unit);
    }).catch(() => {});
  }, []);
  const uiLang = i18n.language;
  const currSym = getCurrencySymbol(accLocale);
  // Left padding for money inputs whose currency prefix is absolutely positioned.
  // A multi-char symbol (e.g. NT$) is wider than the default pl-8 and would overlap
  // the placeholder/value, so widen the padding when the symbol is longer than 1 char.
  // Generic across NT$ / $ / ¥ / € / ₩ — no per-currency hardcoding.
  const moneyPad = currSym.length > 1 ? 'pl-12' : 'pl-8';
  const fmtMoney = (val: number) => formatMoney(val, accLocale, uiLang);
  const taxLabel = (key: string) => getTaxLabel(accLocale, uiLang, key);
  // US 采购与费用 page: payee/expense wording only under zh UI (en/ja/ko/fr keep their i18n labels).
  const usZh = accLocale === 'US' && (uiLang === 'zh-CN' || uiLang === 'zh-TW');
  const taxRateOptions = TAX_RATE_OPTIONS[accLocale] || TAX_RATE_OPTIONS.CN;
  const defaultTaxRate = taxRateOptions[0]?.value || '13%';

  const [recognitionMode, setRecognitionMode] = useState<'ai' | 'ocr'>('ai');
  const [isScanning, setIsScanning] = useState(false);
  const [showAddModal, setShowAddModal] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [records, setRecords] = useState<PurchaseRecord[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [showCsvImport, setShowCsvImport] = useState(false);
  const [ocrPreview, setOcrPreview] = useState<ExtractedInvoice | null>(null);

  // Load records from API on mount
  useEffect(() => {
    fetchPurchases()
      .then(setRecords)
      .catch((err) => console.error('Failed to load purchases:', err))
      .finally(() => setIsLoading(false));
  }, []);

  // Phase 2: product/service list for the modal picker (display only; no calc impact).
  const [products, setProducts] = useState<Product[]>([]);
  useEffect(() => { listProducts().then(setProducts).catch(() => {}); }, []);

  // Form State
  const [newPurchase, setNewPurchase] = useState<Omit<PurchaseRecord, 'status' | 'id'>>({
    date: new Date().toISOString().split('T')[0],
    supplier: '',
    quantity: '',
    price: 0,
    taxRate: defaultTaxRate,
    invoiceNo: '',
    dueDate: '',
    totalWithTax: 0,
    unitPriceWithoutTax: 0,
    taxAmount: 0
  });

  // Invoice status selector. Maps to the existing invoiceStatus column via
  // PurchaseRecord.status. Default '未收' — a record only counts as having an
  // invoice once the user explicitly marks 已收 (PR-1; no schema change).
  const [purchaseInvoiceStatus, setPurchaseInvoiceStatus] = useState('未收');

  // ── P4b: multi-line items editor ──────────────────────────────────────────
  // The header (date/supplier/invoiceNo/dueDate/status) stays in newPurchase; the product
  // lines live here. Save rule: exactly 1 valid line → legacy single-item payload (header
  // tons/product_id preserved, no regression); >1 valid line → items[] (backend P2 sums the
  // header from the lines and neutralises the legacy columns).
  const defaultRatePct = String(parseFloat(defaultTaxRate.replace('%', '')) || 0);
  const emptyRow = (): ItemRow => ({ productId: '', description: '', unit: '', quantity: '', unitPrice: '', taxRatePct: defaultRatePct, grossInput: '', locked: null });
  const initialHeader = () => ({ date: new Date().toISOString().split('T')[0], supplier: '', quantity: '', price: 0, taxRate: defaultTaxRate, invoiceNo: '', dueDate: '', totalWithTax: 0, unitPriceWithoutTax: 0, taxAmount: 0 });
  const [lines, setLines] = useState<ItemRow[]>([emptyRow()]);

  // Per-line amounts, by driver precedence: gross-typed (reverse) > stored/locked > unit-price
  // (forward). Reverse: net = gross/(1+rate), tax = gross−net. Forward: net = qty × unitPrice,
  // tax = net × rate, gross = net + tax. All round2.
  const lineAmounts = (r: ItemRow) => {
    const pct = parseFloat(r.taxRatePct) || 0;
    if (r.grossInput !== '') {
      const amountGross = round2(parseFloat(r.grossInput) || 0);
      const amountNet = round2(amountGross / (1 + pct / 100));
      return { amountNet, taxAmount: round2(amountGross - amountNet), amountGross, pct };
    }
    if (r.locked) return { amountNet: round2(r.locked.net), taxAmount: round2(r.locked.tax), amountGross: round2(r.locked.net + r.locked.tax), pct };
    const amountNet = round2((parseFloat(r.quantity) || 0) * (parseFloat(r.unitPrice) || 0));
    const taxAmount = round2(amountNet * pct / 100);
    return { amountNet, taxAmount, amountGross: round2(amountNet + taxAmount), pct };
  };
  // Effective net unit price (derived when the line is gross-driven; raw otherwise).
  const lineUnitPrice = (r: ItemRow) => {
    const qty = parseFloat(r.quantity) || 0;
    if (r.grossInput !== '' || r.locked) return qty > 0 ? round2(lineAmounts(r).amountNet / qty) : (parseFloat(r.unitPrice) || 0);
    return parseFloat(r.unitPrice) || 0;
  };
  const computed = lines.map(lineAmounts);
  const totalNet = round2(computed.reduce((s, l) => s + l.amountNet, 0));
  const totalTax = round2(computed.reduce((s, l) => s + l.taxAmount, 0));
  const totalGross = round2(computed.reduce((s, l) => s + l.amountGross, 0));

  // Editing any driver (qty/unitPrice/taxRate/gross) unlocks a stored amount. Typing the net
  // unit price additionally clears the gross driver (switches the line back to forward mode).
  const setLine = (i: number, patch: Partial<ItemRow>) => {
    setLines((prev) => prev.map((r, idx) => {
      if (idx !== i) return r;
      const next: ItemRow = { ...r, ...patch };
      if (patch.quantity !== undefined || patch.unitPrice !== undefined || patch.taxRatePct !== undefined || patch.grossInput !== undefined) next.locked = null;
      if (patch.unitPrice !== undefined) next.grossInput = '';
      return next;
    }));
  };
  const addLine = () => setLines((prev) => [...prev, emptyRow()]);
  const removeLine = (i: number) => setLines((prev) => prev.filter((_, idx) => idx !== i));
  const onPickProduct = (i: number, productId: string) => {
    const p = products.find((x) => x.id === productId);
    if (!p) { setLine(i, { productId: '' }); return; }
    setLine(i, {
      productId,
      description: lines[i].description || p.name,
      unit: p.unit || '',
      unitPrice: p.default_unit_cost && p.default_unit_cost > 0 ? String(p.default_unit_cost) : lines[i].unitPrice,
      quantity: lines[i].quantity || '1',
    });
  };
  const itemToRow = (it: LineItem): ItemRow => ({
    productId: it.productId || '',
    description: it.description || '',
    unit: it.unitSnapshot || '',
    quantity: it.quantity == null ? '' : String(it.quantity),
    unitPrice: it.unitPrice == null ? '' : String(it.unitPrice),
    taxRatePct: it.taxRate == null ? '' : String(it.taxRate),
    grossInput: '',
    locked: { net: it.amountNet || 0, tax: it.taxAmount || 0 },
  });
  const resetLines = () => setLines([emptyRow()]);
  const openNewPurchase = () => { setEditingId(null); setNewPurchase(initialHeader()); setPurchaseInvoiceStatus('未收'); resetLines(); setShowAddModal(true); };
  const closeAddModal = () => { setShowAddModal(false); setEditingId(null); setNewPurchase(initialHeader()); setPurchaseInvoiceStatus('未收'); resetLines(); };
  // ──────────────────────────────────────────────────────────────────────────

  const fileInputRef = useRef<HTMLInputElement>(null);

  // P4b: per-line amounts are computed by lineAmounts() above; the old single-field
  // total→amount auto-calc effect is removed (each line now carries its own qty/price/rate).

  const formatCurrency = (val: number) => fmtMoney(val);

  const handleFileChange = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (file) {
      await processFile(file);
    }
  };

  const OCR_IMAGE_TYPES = ['image/jpeg', 'image/png', 'image/webp'];
  const OCR_MAX_BYTES = 8 * 1024 * 1024;

  const readImageBase64 = (file: File) => new Promise<string>((resolve, reject) => {
    const reader = new FileReader();
    const timeout = setTimeout(() => reject(new Error(t('purchases.errorFileTimeout'))), 30000);
    reader.onload = () => {
      clearTimeout(timeout);
      const result = reader.result as string;
      const parts = result.split(',');
      if (parts.length < 2) { reject(new Error(t('purchases.errorFileFormat'))); return; }
      resolve(parts[1]);
    };
    reader.onerror = () => { clearTimeout(timeout); reject(new Error(t('purchases.errorFileRead'))); };
    reader.readAsDataURL(file);
  });

  const processFile = async (file: File) => {
    // OCR follows a configured OCR-capable provider (its own key); if none, guide the user.
    try {
      const providers = await listProviders();
      if (!providers.some(p => p.hasKey && p.supportsOCR)) { alert(t('ocr.noProviderConfigured')); return; }
    } catch { /* fall through — backend getOcrRecord still guards */ }

    const isPdf = file.type === 'application/pdf';
    if (!isPdf && !OCR_IMAGE_TYPES.includes(file.type)) { alert(t('ocr.errorUnsupportedFormat')); return; }

    setIsScanning(true);
    try {
      let base64: string;
      let mimeType: string;
      if (isPdf) {
        // Vision image_url can't take PDF → rasterize the FIRST PAGE to PNG before OCR.
        try {
          const png = await rasterizePdfFirstPage(file);
          base64 = png.base64; mimeType = png.mimeType;
        } catch (e) { console.error(e); alert(t('ocr.errorPdfRender')); return; }
        if (base64.length * 0.75 > OCR_MAX_BYTES) { alert(t('ocr.errorImageTooLarge')); return; }
      } else {
        if (file.size > OCR_MAX_BYTES) { alert(t('ocr.errorImageTooLarge')); return; }
        base64 = await readImageBase64(file); mimeType = file.type;
      }

      const extracted = await analyzeInvoice(base64, mimeType, accLocale, uiLang);
      if (!extracted.isInvoiceLike) {
        const docType = extracted.documentType || 'unknown';
        alert(t('purchases.notInvoiceWarning', { type: docType }));
        return;
      }
      // Show a preview; the user confirms before anything is filled (PR-3c).
      setOcrPreview(extracted);
    } catch (err) {
      console.error(err);
      alert(t('purchases.errorFailed'));
    } finally {
      setIsScanning(false);
      if (fileInputRef.current) fileInputRef.current.value = '';
    }
  };

  // PR-3c: "use these values" → fill the add-form state and open the modal. NO createPurchase / NO DB
  // write — the user reviews the pre-filled form and clicks save (handleAddSubmit) to actually record.
  const confirmOcrFill = () => {
    if (!ocrPreview) return;
    const filled = extractedToPurchaseForm(ocrPreview, defaultTaxRate);
    setNewPurchase(prev => ({ ...filled, date: filled.date || prev.date }));
    setPurchaseInvoiceStatus('未收');
    // OCR is single-invoice → land the recognised values in line 1 (P4b keeps OCR single-line;
    // multi-line OCR is a later task). Amount is locked to the recognised value.
    const pct = String(parseFloat((filled.taxRate || defaultTaxRate).replace('%', '')) || 0);
    const net = filled.amountWithoutTax || filled.price || 0;
    setLines([{
      productId: filled.productId || '',
      description: '',
      unit: '',
      quantity: filled.quantity || '',
      unitPrice: String(filled.unitPriceWithoutTax || ''),
      taxRatePct: pct,
      grossInput: '',
      locked: net ? { net, tax: filled.taxAmount || 0 } : null,
    }]);
    setOcrPreview(null);
    setShowAddModal(true);
  };

  const handleAddSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!newPurchase.supplier) {
      alert(t('purchases.errorRequiredFields'));
      return;
    }
    // Auto-ignore fully blank rows; a row is valid if it has a product OR a description.
    const valid = lines.filter((r) => r.productId || r.description.trim());
    if (valid.length === 0) {
      alert(t('purchases.errorRequiredFields'));
      return;
    }
    const header = {
      date: newPurchase.date,
      supplier: newPurchase.supplier,
      invoiceNo: newPurchase.invoiceNo,
      dueDate: newPurchase.dueDate,
      status: purchaseInvoiceStatus,
    };
    try {
      if (valid.length === 1) {
        // Single line → legacy single-item payload (header tons/product_id preserved, no items).
        const r = valid[0];
        const a = lineAmounts(r);
        const legacy: PurchaseRecord = {
          id: editingId || nextPurchaseId(),
          ...header,
          productId: r.productId || '',
          quantity: r.quantity || '',
          price: a.amountNet,
          taxRate: `${a.pct}%`,
          amountWithoutTax: a.amountNet,
          taxAmount: a.taxAmount,
          totalWithTax: a.amountGross,
          unitPriceWithoutTax: lineUnitPrice(r),
        };
        if (editingId) await updatePurchase(editingId, legacy);
        else await createPurchase(legacy);
      } else {
        // Multiple lines → items[] payload (backend P2 sums the header + neutralises legacy cols).
        const items: LineItem[] = valid.map((r, idx) => {
          const a = lineAmounts(r);
          const up = lineUnitPrice(r);
          return {
            productId: r.productId || null,
            description: r.description.trim() || null,
            unitSnapshot: r.unit || null,
            quantity: r.quantity === '' ? null : (parseFloat(r.quantity) || 0),
            unitPrice: (r.unitPrice !== '' || r.grossInput !== '' || r.locked) ? up : null,
            amountNet: a.amountNet,
            taxRate: r.taxRatePct === '' ? null : (parseFloat(r.taxRatePct) || 0),
            taxAmount: a.taxAmount,
            amountGross: a.amountGross,
            lineNo: idx,
          };
        });
        const record: PurchaseRecord = {
          id: editingId || nextPurchaseId(),
          ...header,
          productId: '',
          quantity: '',
          price: 0,
          taxRate: defaultTaxRate,
          items,
        };
        if (editingId) await updatePurchase(editingId, record);
        else await createPurchase(record);
      }
      // Refresh from the backend instead of optimistic patching: a multi-line save neutralises
      // the header (tons=0, total=Σ items) so the stored row differs from the form values.
      setRecords(await fetchPurchases());
      closeAddModal();
    } catch (err) {
      console.error(err);
      alert(getSystemErrorText(err, t) || t('purchases.errorSaveFailed'));
    }
  };

  const triggerUpload = () => {
    fileInputRef.current?.click();
  };

  return (
    <div className="space-y-6 animate-in fade-in duration-500 max-w-[1600px] mx-auto relative">
      <input
        type="file"
        ref={fileInputRef}
        onChange={handleFileChange}
        className="hidden"
        accept="image/jpeg,image/png,image/webp,application/pdf"
      />

      {/* Header Section */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-[#191918]">{(accLocale !== 'CN') ? taxLabel('pageTitlePurchase') : t('purchases.title')}</h1>
          <p className="text-sm text-[#5c5c5a] mt-1">{t('purchases.pageSubtitle')}</p>
        </div>
        <div className="flex space-x-3">
          <button
            onClick={() => setShowCsvImport(true)}
            className="flex items-center px-4 py-2 bg-emerald-600 hover:bg-emerald-500 text-white rounded-lg transition-colors text-sm font-medium" style={{ boxShadow: '0 4px 16px rgba(16,185,129,0.15)' }}
          >
            <i className="fas fa-file-csv mr-2"></i> {t('purchases.batchImport')}
          </button>
          <button
            onClick={triggerUpload}
            disabled={isScanning}
            className="flex items-center px-4 py-2 bg-purple-600 hover:bg-purple-500 text-white rounded-lg transition-colors text-sm font-medium disabled:opacity-50" style={{ boxShadow: '0 4px 16px rgba(147,51,234,0.15)' }}
          >
            <i className={`fas ${isScanning ? 'fa-spinner animate-spin' : 'fa-camera'} mr-2`}></i>
            {isScanning ? t('purchases.scanning') : (accLocale === 'KR' ? taxLabel('scanDocButton') : t('purchases.scanInvoice'))}
          </button>
          <button
            onClick={openNewPurchase}
            className="flex items-center px-4 py-2 bg-primary hover:bg-primary-hover text-white rounded-lg transition-colors text-sm font-medium" style={{ boxShadow: '0 4px 16px rgba(39,76,146,0.15)' }}
          >
            <i className="fas fa-plus mr-2"></i> {accLocale !== 'CN' ? taxLabel('newPurchaseButton') : t('purchases.newPurchase')}
          </button>
        </div>
      </div>

      {/* Recognition Mode Selector */}
      <div className="flex items-center justify-between py-2">
        <div className="flex items-center space-x-4">
          <span className="text-[#4a4a48] text-sm">{t('purchases.recognitionMode')}:</span>
          <div className="flex bg-[#f9f9f8] rounded-lg p-1 border border-[#e0ddd5]">
            <button
              onClick={() => setRecognitionMode('ai')}
              className={`flex items-center px-3 py-1.5 rounded-md text-xs transition-all ${recognitionMode === 'ai' ? 'bg-primary text-white shadow-sm' : 'text-[#4a4a48] hover:text-[#191918]'}`}
            >
              <i className="fas fa-robot mr-2"></i> {t('purchases.modeAi')}
            </button>
            <button
              onClick={() => setRecognitionMode('ocr')}
              className={`flex items-center px-3 py-1.5 rounded-md text-xs transition-all ${recognitionMode === 'ocr' ? 'bg-[#f0eeeb] text-[#191918]' : 'text-[#4a4a48] hover:text-[#191918]'}`}
            >
              <i className="fas fa-file-invoice mr-2"></i> {t('purchases.modeOcr')}
            </button>
          </div>
        </div>
        <div className="flex items-center space-x-2 text-xs text-[#5c5c5a]">
          <span className="w-2 h-2 rounded-full bg-amber-500 animate-pulse"></span>
          <span>{t('purchases.aiStatus')}</span>
        </div>
      </div>

      {/* Upload Dropzone */}
      <div
        onClick={triggerUpload}
        onDragOver={(e) => e.preventDefault()}
        onDrop={async (e) => {
          e.preventDefault();
          const file = e.dataTransfer.files[0];
          if (file) await processFile(file);
        }}
        className={`border-2 border-dashed rounded-xl py-12 flex flex-col items-center justify-center transition-all cursor-pointer group
          ${isScanning ? 'border-primary/50 bg-primary/10' : 'border-primary/30 bg-primary/5 hover:bg-primary/10 hover:border-primary/50'}
        `}
      >
        <div className="mb-4 transform group-hover:scale-110 transition-transform duration-300">
          {isScanning ? (
            <div className="w-12 h-12 border-4 border-primary/30 border-t-primary rounded-full animate-spin"></div>
          ) : (
            <div className="text-4xl">🤖</div>
          )}
        </div>
        <h3 className="text-[#4a4a48] font-medium text-base mb-1">
          {isScanning ? ((accLocale !== 'CN') ? taxLabel('scanningTitle') : t('purchases.uploadScanning')) : ((accLocale !== 'CN') ? taxLabel('uploadTitle') : t('purchases.uploadTitle'))}
        </h3>
        <p className="text-[#5c5c5a] text-xs">
          {isScanning ? ((accLocale !== 'CN') ? taxLabel('scanningSubtitle') : t('purchases.uploadAnalyzing')) : ((accLocale !== 'CN') ? taxLabel('uploadSubtitle') : t('purchases.uploadSubtitle'))}
        </p>
      </div>

      {/* Data Table */}
      <div className="bg-white/80 border border-[#e0ddd5] rounded-xl overflow-hidden" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.05)' }}>
        <div className="overflow-x-auto">
          <table className="w-full text-left border-collapse data-table">
            <thead>
              <tr className="border-b border-[#e0ddd5] text-[#5c5c5a] text-xs">
                <th className="px-5 py-4 font-medium">{t('tableHeaders.date')}</th>
                <th className="px-5 py-4 font-medium">{usZh ? taxLabel('setHeaderPayee') : t('tableHeaders.supplier')}</th>
                <th className="px-5 py-4 font-medium">{t('tableHeaders.product')}</th>
                <th className="px-5 py-4 font-medium">{t('tableHeaders.quantity')}</th>
                <th className="px-5 py-4 font-medium whitespace-nowrap">{(accLocale !== 'CN') ? taxLabel('headerUnitPrice') : t('tableHeaders.unitPriceWithoutTax')}</th>
                <th className="px-5 py-4 font-medium whitespace-nowrap">{(accLocale !== 'CN') ? taxLabel('headerAmount') : t('tableHeaders.totalAmountWithoutTax')}</th>
                <th className="px-5 py-4 font-medium whitespace-nowrap">{accLocale !== 'CN' ? taxLabel('headerTaxAmount') : t('tableHeaders.totalTax')}</th>
                <th className="px-5 py-4 font-medium whitespace-nowrap">{accLocale !== 'CN' ? taxLabel('headerTotalWithTax') : t('tableHeaders.totalWithTax')}</th>
                <th className="px-5 py-4 font-medium">{t('tableHeaders.taxRate')}</th>
                <th className="px-5 py-4 font-medium">{(accLocale !== 'CN') ? taxLabel('headerInvoiceNo') : t('tableHeaders.invoiceNo')}</th>
                <th className="px-5 py-4 font-medium">{t('tableHeaders.status')}</th>
                <th className="px-5 py-4 font-medium">{t('tableHeaders.actions')}</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-[#e0ddd5]/50">
              {records.flatMap((rec) => {
                // P4b-2: expand a multi-line record into one display row per line item; a legacy
                // single-item record stays one row. All rows of a record share rec.id, so editing
                // any row opens the same multi-line modal and deleting any row removes the whole
                // purchase. Per-row amounts are the LINE's net/tax/gross (not the order total).
                const lineRows = (rec.items && rec.items.length > 0)
                  ? rec.items.map((it, idx) => ({ item: it as LineItem | null, key: `${rec.id}::${it.lineNo ?? idx}::${idx}` }))
                  : [{ item: null as LineItem | null, key: rec.id }];
                return lineRows.map(({ item, key }) => {
                  const productName = item
                    ? ((item.productId && products.find(p => p.id === item.productId)?.name) || (item.description || '').trim() || (item.unitSnapshot ? getProductUnitLabel(item.unitSnapshot, uiLang) : '—'))
                    : (rec.productName || (rec.productId && products.find(p => p.id === rec.productId)?.name) || '—');
                  const qtyCell = item
                    ? (item.quantity != null ? `${item.quantity}${item.unitSnapshot ? ' ' + getProductUnitLabel(item.unitSnapshot, uiLang) : ''}` : '—')
                    : (rec.unit ? `${rec.quantity} ${getProductUnitLabel(rec.unit, uiLang)}` : formatLegacyQuantity(rec.quantity, productUnit, uiLang));
                  const unitPriceCell = item ? (item.unitPrice != null ? formatCurrency(item.unitPrice) : '—') : formatCurrency(rec.unitPriceWithoutTax || rec.pricePerTon || 0);
                  const net = item ? item.amountNet : (rec.amountWithoutTax || rec.price);
                  const tax = item ? item.taxAmount : (rec.taxAmount || 0);
                  const gross = item ? item.amountGross : (rec.totalWithTax || (net + tax));
                  const rateCell = item ? (item.taxRate != null ? `${item.taxRate}%` : '—') : rec.taxRate;
                  return (
                  <tr key={key} className="hover:bg-[#f9f9f8]/30 transition-colors">
                    <td className="px-5 py-5 text-sm text-[#4a4a48] whitespace-nowrap">{rec.date}</td>
                    <td className="px-5 py-5 text-sm text-[#191918] font-medium col-name">{rec.supplier}</td>
                    <td className="px-5 py-5 text-sm text-[#4a4a48] col-name">{productName}</td>
                    <td className="px-5 py-5 text-sm text-[#4a4a48]">{qtyCell}</td>
                    <td className="px-5 py-5 text-sm text-[#191918] font-medium whitespace-nowrap">{unitPriceCell}</td>
                    <td className="px-5 py-5 text-sm text-[#191918] font-medium whitespace-nowrap">{formatCurrency(net)}</td>
                    <td className="px-5 py-5 text-sm text-rose-600 font-medium whitespace-nowrap">{formatCurrency(tax)}</td>
                    <td className="px-5 py-5 text-sm text-[#191918] font-bold whitespace-nowrap">{formatCurrency(gross)}</td>
                    <td className="px-5 py-5 text-sm text-[#4a4a48]">{rateCell}</td>
                    <td className="px-5 py-5 text-sm font-mono text-[#4a4a48] tracking-tight">{rec.invoiceNo}</td>
                    <td className="px-5 py-5">
                      {(() => {
                        const tone = classifyInvoiceStatus(rec.status);
                        const label = tone === 'unknown'
                          ? (String(rec.status ?? '').trim() || '—')
                          : tone === 'done'
                            ? (accLocale !== 'CN' ? taxLabel('invStatusCertified') : t('purchases.invoiceStatusReceived'))
                            : (accLocale !== 'CN' ? taxLabel('invStatusPendingCert') : t('purchases.invoiceStatusPending'));
                        return (
                          <span className={`px-2 py-0.5 border rounded-md text-[10px] font-bold ${INVOICE_STATUS_BADGE_CLASS[tone]}`}>
                            {label}
                          </span>
                        );
                      })()}
                    </td>
                    <td className="px-5 py-5 text-xs font-medium space-x-3">
                      <button
                        onClick={async () => {
                          try {
                            // Always fetch the detail so a multi-line record's items are never lost.
                            const detail = await getPurchase(rec.id);
                            setEditingId(rec.id);
                            setNewPurchase({ date: detail.date, supplier: detail.supplier, productId: detail.productId || '', quantity: '', price: 0, taxRate: detail.taxRate || defaultTaxRate, invoiceNo: detail.invoiceNo, dueDate: detail.dueDate || '', totalWithTax: 0, unitPriceWithoutTax: 0, taxAmount: 0 });
                            setPurchaseInvoiceStatus(rec.status || '未收');
                            if (detail.items && detail.items.length > 0) {
                              setLines(detail.items.map(itemToRow));
                            } else {
                              // Legacy single-item record → one row rehydrated from the header
                              // (amount locked to the stored value so a no-op edit never drifts it).
                              const pct = String(parseFloat((detail.taxRate || '').replace('%', '')) || parseFloat(defaultRatePct) || 0);
                              setLines([{
                                productId: detail.productId || '',
                                description: detail.productName || '',
                                unit: detail.unit || '',
                                quantity: detail.quantity || '',
                                unitPrice: String(detail.unitPriceWithoutTax || detail.pricePerTon || ''),
                                taxRatePct: pct,
                                grossInput: '',
                                locked: { net: detail.amountWithoutTax || detail.price || 0, tax: detail.taxAmount || 0 },
                              }]);
                            }
                            setShowAddModal(true);
                          } catch (err) {
                            console.error(err);
                            alert(getSystemErrorText(err, t) || t('purchases.errorSaveFailed'));
                          }
                        }}
                        className="text-primary hover:text-primary-hover transition-colors"
                      >{t('common2.edit')}</button>
                      <button
                        onClick={async () => {
                          try {
                            await deletePurchase(rec.id);
                            setRecords(prev => prev.filter(r => r.id !== rec.id));
                          } catch (err) {
                            console.error(err);
                            alert(getSystemErrorText(err, t) || t('purchases.errorDeleteFailed'));
                          }
                        }}
                        className="text-rose-500 hover:text-rose-400 transition-colors"
                      >
                        {t('common2.delete')}
                      </button>
                    </td>
                  </tr>
                  );
                });
              })}
              {isLoading && (
                <tr>
                  <td colSpan={12} className="px-6 py-12 text-center text-[#5c5c5a] text-sm">
                    <i className="fas fa-spinner animate-spin mr-2"></i>{t('purchases.loading')}
                  </td>
                </tr>
              )}
              {!isLoading && records.length === 0 && (
                <tr>
                  <td colSpan={12} className="px-6 py-12 text-center text-[#5c5c5a] text-sm italic">
                    {accLocale !== 'CN' ? taxLabel('emptyPurchase') : t('purchases.empty')}
                  </td>
                </tr>
              )}
              {/* Summary row */}
              {!isLoading && records.length > 0 && (
                <tr className="bg-[#f9f9f8] border-t-2 border-[#e0ddd5] font-semibold">
                  <td className="px-5 py-4 text-sm text-[#191918]" colSpan={2}>{t('purchases.summary')}</td>
                  <td className="px-5 py-4 text-sm text-[#4a4a48]">—</td>
                  <td className="px-5 py-4 text-sm text-[#191918]">
                    {(() => {
                      const total = records.reduce((sum, r) => {
                        const match = r.quantity.match(/[\d.]+/);
                        return sum + (match ? parseFloat(match[0]) : 0);
                      }, 0);
                      const unit = records[0]?.quantity.replace(/[\d.\s]+/g, '') || '';
                      return `${total}${unit}`;
                    })()}
                  </td>
                  <td className="px-5 py-4 text-sm text-[#4a4a48]">—</td>
                  <td className="px-5 py-4 text-sm text-[#191918] whitespace-nowrap">
                    {formatCurrency(records.reduce((s, r) => s + (r.amountWithoutTax || r.price), 0))}
                  </td>
                  <td className="px-5 py-4 text-sm text-rose-600 whitespace-nowrap">
                    {formatCurrency(records.reduce((s, r) => s + (r.taxAmount || 0), 0))}
                  </td>
                  <td className="px-5 py-4 text-sm text-[#191918] font-bold whitespace-nowrap">
                    {formatCurrency(records.reduce((s, r) => {
                      const amt = r.amountWithoutTax || r.price;
                      const tax = r.taxAmount || 0;
                      return s + (r.totalWithTax || (amt + tax));
                    }, 0))}
                  </td>
                  <td colSpan={4}></td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </div>

      {/* CSV Import Modal */}
      {showCsvImport && (
        <CsvImportModal
          type="purchases"
          onClose={() => setShowCsvImport(false)}
          onSuccess={() => {
            setShowCsvImport(false);
            fetchPurchases().then(setRecords).catch(console.error);
          }}
        />
      )}

      {/* Add Purchase Modal */}
      {showAddModal && (
        <div className="fixed inset-0 z-[10001] flex items-center justify-center px-4">
          <div className="absolute inset-0 bg-black/40 backdrop-blur-sm" onClick={closeAddModal}></div>
          <div className="relative w-full max-w-2xl bg-white border border-[#e0ddd5] rounded-xl overflow-hidden flex flex-col max-h-[calc(100vh-2rem)] animate-in zoom-in-95 duration-200" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.05)' }}>
            <div className="p-8 border-b border-[#e0ddd5] flex justify-between items-center gap-4 shrink-0">
              <div className="flex-shrink-0">
                <h2 className="text-xl font-bold text-[#191918] whitespace-nowrap">{editingId ? t('purchases.modalTitleEdit') : ((accLocale !== 'CN') ? taxLabel('modalTitlePurchase') : t('purchases.modalTitle'))}</h2>
                <p className="text-xs text-[#5c5c5a] mt-1">{(accLocale !== 'CN') ? taxLabel('modalSubtitlePurchase') : t('purchases.modalSubtitle')}</p>
              </div>
              <button onClick={closeAddModal} aria-label={t('common.close')} className="flex-shrink-0 text-[#5c5c5a] hover:text-[#191918] transition-colors">
                <i className="fas fa-times text-xl"></i>
              </button>
            </div>

            <form onSubmit={handleAddSubmit} className="p-8 space-y-5 flex-1 min-h-0 overflow-y-auto">
              <div className="grid grid-cols-2 gap-4">
                <div className="space-y-2">
                  <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{t('purchases.formDate')}</label>
                  <input
                    type="date"
                    required
                    value={newPurchase.date}
                    onChange={(e) => setNewPurchase({ ...newPurchase, date: e.target.value })}
                    className="w-full bg-white border border-[#e0ddd5] rounded-xl px-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary text-[#191918] transition-all"
                  />
                </div>
                <div className="space-y-2">
                  <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{accLocale !== 'CN' ? taxLabel('headerInvoiceNo') : t('purchases.formInvoiceNo')}</label>
                  <input
                    type="text"
                    placeholder={t('common2.optional')}
                    value={newPurchase.invoiceNo}
                    onChange={(e) => setNewPurchase({ ...newPurchase, invoiceNo: e.target.value })}
                    className="w-full bg-white border border-[#e0ddd5] rounded-xl px-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary text-[#191918] transition-all"
                  />
                </div>
              </div>

              <div className="space-y-2">
                <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{t('common2.dueDate')}</label>
                <input
                  type="date"
                  value={newPurchase.dueDate || ''}
                  onChange={(e) => setNewPurchase({ ...newPurchase, dueDate: e.target.value })}
                  className="w-full bg-white border border-[#e0ddd5] rounded-xl px-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary text-[#191918] transition-all"
                />
              </div>

              <div className="space-y-2">
                <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{accLocale !== 'CN' ? taxLabel('invStatusFilter') : t('purchases.formInvoiceStatus')}</label>
                <select
                  data-testid="purchase-invoice-status"
                  value={purchaseInvoiceStatus}
                  onChange={(e) => setPurchaseInvoiceStatus(e.target.value)}
                  className="w-full bg-white border border-[#e0ddd5] rounded-xl px-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary text-[#191918] transition-all"
                >
                  <option value="未收">{accLocale !== 'CN' ? taxLabel('invStatusPendingCert') : t('purchases.invoiceStatusPending')}</option>
                  <option value="已收">{accLocale !== 'CN' ? taxLabel('invStatusCertified') : t('purchases.invoiceStatusReceived')}</option>
                </select>
              </div>

              <div className="space-y-2">
                <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{usZh ? taxLabel('setFormPayeeLabel') : t('purchases.formSupplier')}</label>
                <input
                  type="text"
                  required
                  placeholder={usZh ? taxLabel('setFormPayeePh') : t('purchases.formSupplierPlaceholder')}
                  data-testid="ocr-fill-counterparty"
                  value={newPurchase.supplier}
                  onChange={(e) => setNewPurchase({ ...newPurchase, supplier: e.target.value })}
                  className="w-full bg-white border border-[#e0ddd5] rounded-xl px-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary text-[#191918] transition-all"
                />
              </div>

              {/* P4b: multi-line items editor. One product/service per row; the header above
                  keeps date/supplier/invoice/due/status. A row is valid (saved) when it has a
                  product OR a description; fully blank rows are ignored. */}
              <div className="space-y-3">
                <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{t('documents.itemsTitle')}</label>
                {lines.map((row, i) => {
                  const amt = computed[i];
                  return (
                  <div key={i} className="border border-[#e0ddd5] rounded-xl p-4 space-y-3 bg-[#f9f9f8]/50">
                    <div className="flex items-center justify-between gap-3">
                      <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{t('products.selectLabel')}</label>
                      {lines.length > 1 && (
                        <button type="button" onClick={() => removeLine(i)} className="flex-shrink-0 text-rose-500 hover:text-rose-400 text-xs font-medium">
                          {t('documents.removeItem')}
                        </button>
                      )}
                    </div>
                    <select
                      value={row.productId}
                      onChange={(e) => onPickProduct(i, e.target.value)}
                      className="w-full bg-white border border-[#e0ddd5] rounded-xl px-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary text-[#191918] transition-all"
                    >
                      <option value="">{t('products.unassigned')}</option>
                      {products.filter(p => p.is_active).map(p => (
                        <option key={p.id} value={p.id}>{p.name}（{getProductUnitLabel(p.unit, uiLang)}）</option>
                      ))}
                    </select>
                    <div className="space-y-2">
                      <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{t('documents.itemDescription')}</label>
                      <input
                        type="text"
                        data-testid={`purchase-line-desc-${i}`}
                        placeholder={t('common2.optional')}
                        value={row.description}
                        onChange={(e) => setLine(i, { description: e.target.value })}
                        className="w-full bg-white border border-[#e0ddd5] rounded-xl px-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary text-[#191918] transition-all"
                      />
                    </div>
                    <div className="grid grid-cols-4 gap-3">
                      <div className="space-y-2">
                        <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{usZh ? taxLabel('setFormQtyLabel') : t('purchases.formQuantity')}</label>
                        <input
                          type="number"
                          step="0.01"
                          min="0"
                          data-testid={`purchase-line-qty-${i}`}
                          placeholder={usZh ? taxLabel('setFormQtyPh') : t('purchases.formQuantityPlaceholder')}
                          value={row.quantity}
                          onChange={(e) => setLine(i, { quantity: e.target.value })}
                          className="w-full bg-white border border-[#e0ddd5] rounded-xl px-3 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary text-[#191918] transition-all"
                        />
                      </div>
                      <div className="space-y-2">
                        <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{accLocale !== 'CN' ? taxLabel('headerUnitPrice') : t('purchases.formUnitPrice')}</label>
                        <input
                          type="number"
                          step="0.01"
                          min="0"
                          data-testid={`purchase-line-price-${i}`}
                          value={row.grossInput !== '' ? String(lineUnitPrice(row) || '') : row.unitPrice}
                          onChange={(e) => setLine(i, { unitPrice: e.target.value })}
                          className="w-full bg-white border border-[#e0ddd5] rounded-xl px-3 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary text-[#191918] transition-all"
                        />
                      </div>
                      <div className="space-y-2">
                        <label className="text-[10px] font-bold text-[#5c5c5a] tracking-widest">{taxLabel('formTaxRate')} %</label>
                        <input
                          type="number"
                          step="0.01"
                          min="0"
                          max="100"
                          value={row.taxRatePct}
                          onChange={(e) => setLine(i, { taxRatePct: e.target.value })}
                          className="w-full bg-white border border-[#e0ddd5] rounded-xl px-3 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary text-[#191918] transition-all"
                        />
                      </div>
                      <div className="space-y-2">
                        {/* P4b problem-2 fix: type the tax-inclusive total here → net/tax/unit-price
                            are back-calculated; typing the unit price instead drives it forward. */}
                        <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{accLocale !== 'CN' ? taxLabel('headerTotalWithTax') : t('purchases.formTotalWithTax')}</label>
                        <input
                          type="number"
                          step="0.01"
                          min="0"
                          data-testid={`purchase-line-gross-${i}`}
                          placeholder={t('common2.optional')}
                          value={row.grossInput !== '' ? row.grossInput : (amt.amountGross ? String(amt.amountGross) : '')}
                          onChange={(e) => setLine(i, { grossInput: e.target.value })}
                          className="w-full bg-white border border-[#e0ddd5] rounded-xl px-3 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary text-[#191918] transition-all"
                        />
                      </div>
                    </div>
                    <div className="flex justify-end gap-5 text-xs text-[#4a4a48]">
                      <span>{accLocale !== 'CN' ? taxLabel('headerAmount') : t('tableHeaders.totalAmountWithoutTax')}: <span className="font-medium text-[#191918]">{fmtMoney(amt.amountNet)}</span></span>
                      <span>{t('purchases.formTaxAmount')}: <span className="font-medium text-rose-600">{fmtMoney(amt.taxAmount)}</span></span>
                    </div>
                  </div>
                  );
                })}
                <button type="button" onClick={addLine} className="w-full border-2 border-dashed border-[#e0ddd5] hover:border-primary/50 hover:bg-primary/5 rounded-xl py-2.5 text-xs text-[#5c5c5a] hover:text-primary transition-all">
                  <i className="fas fa-plus mr-2"></i>{t('documents.addItem')}
                </button>
              </div>

              {/* 表头合计（明细求和；只读展示，后端 P2 再权威重算） */}
              <div className="border-t border-[#e0ddd5] pt-4 space-y-1.5 text-sm">
                <div className="flex justify-between text-[#4a4a48]">
                  <span>{accLocale !== 'CN' ? taxLabel('headerAmount') : t('tableHeaders.totalAmountWithoutTax')}</span>
                  <span className="font-medium text-[#191918]">{fmtMoney(totalNet)}</span>
                </div>
                <div className="flex justify-between text-[#4a4a48]">
                  <span>{accLocale !== 'CN' ? taxLabel('headerTaxAmount') : t('tableHeaders.totalTax')}</span>
                  <span className="font-medium text-rose-600">{fmtMoney(totalTax)}</span>
                </div>
                <div className="flex justify-between text-base font-bold text-[#191918]">
                  <span>{accLocale !== 'CN' ? taxLabel('headerTotalWithTax') : t('tableHeaders.totalWithTax')}</span>
                  <span data-testid="purchase-total-gross">{fmtMoney(totalGross)}</span>
                </div>
              </div>

              <div className="pt-4 flex space-x-3">
                <button
                  type="button"
                  onClick={closeAddModal}
                  className="flex-1 py-4 bg-[#f0eeeb] hover:bg-[#e0ddd5] text-[#4a4a48] font-bold rounded-xl transition-all"
                >
                  {t('purchases.formCancel')}
                </button>
                <button
                  type="submit"
                  className="flex-2 px-10 py-4 bg-primary hover:bg-primary-hover text-white font-bold rounded-xl transition-all active:scale-95" style={{ boxShadow: '0 4px 16px rgba(39,76,146,0.15)' }}
                >
                  {editingId ? t('purchases.formSubmitEdit') : t('purchases.formSubmit')}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {ocrPreview && (
        <OcrPreviewModal
          extracted={ocrPreview}
          counterpartyLabel={usZh ? taxLabel('setHeaderPayee') : t('tableHeaders.supplier')}
          fmtMoney={fmtMoney}
          onClose={() => setOcrPreview(null)}
          onConfirm={confirmOcrFill}
        />
      )}
    </div>
  );
};

export default PurchaseAndInputPage;
