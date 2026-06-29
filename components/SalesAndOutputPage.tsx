
import React, { useState, useRef, useEffect } from 'react';
import { useTranslation } from 'react-i18next';
import { BusinessData } from '../types';
import { analyzeInvoice, extractedToSalesForm, salesCounterparty, type ExtractedInvoice } from '../services/ocrService';
import { rasterizePdfFirstPage } from '../services/pdfRaster';
import { fetchSales, getSale, createSale, updateSale, deleteSale, fetchSettings, listProducts, listProviders, isDesktop, type Product, type BusinessDocument, type LineItem, SalesRecord } from '../services/api';
import { getSystemErrorText } from '../services/systemErrors';
import { formatMoney, getCurrencySymbol, formatQuantity, formatLegacyQuantity, getTaxLabel, getProductUnitLabel } from './accountingHelpers';
import { classifyInvoiceStatus, INVOICE_STATUS_BADGE_CLASS } from './invoiceStatusDisplay';
import CsvImportModal from './CsvImportModal';
import DocumentModal from './DocumentModal';
import OcrPreviewModal from './OcrPreviewModal';
import { TAX_RATE_OPTIONS } from './taxRateOptions';

interface Props {
  data: BusinessData;
  selectedYear: string;
  selectedQuarter: string;
  selectedMonth: string;
}

let salesIdCounter = 0;
const nextSalesId = () => `sale-${++salesIdCounter}-${Date.now()}`;

// P4c: one product/service line in the multi-line editor (all inputs are strings). Mirrors the
// purchase editor's ItemRow (P4b).
interface ItemRow {
  productId: string;
  description: string;
  unit: string;
  quantity: string;
  unitPrice: string;
  taxRatePct: string;
  // Tax-inclusive amount typed directly: a non-empty grossInput drives the line in reverse
  // (net = gross/(1+rate), tax = gross−net, unitPrice = net/qty); typing the net unit price
  // clears it and the line goes back to forward (net = qty × unitPrice).
  grossInput: string;
  // Locked original amount (from an edited record's stored values); cleared on any driver edit
  // so a no-op edit never drifts a stored amount by a rounding cent.
  locked: { net: number; tax: number } | null;
}
const round2 = (v: number) => Math.round((v || 0) * 100) / 100;

const SalesAndOutputPage: React.FC<Props> = ({ data, selectedYear, selectedQuarter, selectedMonth }) => {
  const { t, i18n } = useTranslation();
  const [accLocale, setAccLocale] = useState('CN');
  const [productUnit, setProductUnit] = useState<string>('ton');
  useEffect(() => {
    fetchSettings().then((s: any) => {
      if (s.accounting_locale) setAccLocale(s.accounting_locale);
      if (s.product_unit) setProductUnit(s.product_unit);
    }).catch(() => {});
  }, []);
  const uiLang = i18n.language;
  // US 销售与收入 page: income wording only under zh UI (en/ja/ko/fr keep their i18n labels).
  const usZh = accLocale === 'US' && (uiLang === 'zh-CN' || uiLang === 'zh-TW');
  const currSym = getCurrencySymbol(accLocale);
  // Left padding for money inputs whose currency prefix is absolutely positioned.
  // A multi-char symbol (e.g. NT$) is wider than the default pl-8 and would overlap
  // the placeholder/value, so widen the padding when the symbol is longer than 1 char.
  // Generic across NT$ / $ / ¥ / € / ₩ — no per-currency hardcoding.
  const moneyPad = currSym.length > 1 ? 'pl-12' : 'pl-8';
  const fmtMoney = (val: number) => formatMoney(val, accLocale, uiLang);
  const fmtQty = (val: number, decimals = 2) => formatQuantity(val, productUnit, uiLang, decimals);
  const taxLabel = (key: string) => getTaxLabel(accLocale, uiLang, key);
  // Locale-aware default tax rate (CN 13% / US 0% / JP 10% / EU 20% / KR 10% / TW 5%),
  // shared with the purchase page. Used as the fallback for manual entry + OCR auto-fill
  // so a non-CN sale no longer silently defaults to China's 13%.
  const defaultTaxRate = (TAX_RATE_OPTIONS[accLocale] || TAX_RATE_OPTIONS.CN)[0]?.value || '13%';
  const [recognitionMode, setRecognitionMode] = useState<'ai' | 'ocr'>('ai');
  const [isScanning, setIsScanning] = useState(false);
  const [showAddModal, setShowAddModal] = useState(false);
  const [records, setRecords] = useState<SalesRecord[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [showCsvImport, setShowCsvImport] = useState(false);
  const [ocrPreview, setOcrPreview] = useState<ExtractedInvoice | null>(null);
  const [editingId, setEditingId] = useState<string | null>(null);
  // Phase C：从销售记录生成业务单据（仅桌面版；共享 DocumentModal 预填，
  // 金额复制记录已存值、不重算——见 DocumentModal 的锁定行机制）
  const docDesktop = isDesktop();
  const [docPrefill, setDocPrefill] = useState<Partial<BusinessDocument> | null>(null);
  const [docGenOk, setDocGenOk] = useState(false);

  // Load records from API on mount
  useEffect(() => {
    fetchSales()
      .then(setRecords)
      .catch((err) => console.error('Failed to load sales:', err))
      .finally(() => setIsLoading(false));
  }, []);

  // Phase 2: product/service list for the modal picker (display only; no calc impact).
  const [products, setProducts] = useState<Product[]>([]);
  useEffect(() => { listProducts().then(setProducts).catch(() => {}); }, []);

  // Form State for manual entry
  const [newSale, setNewSale] = useState<Omit<SalesRecord, 'status' | 'id'>>({
    date: new Date().toISOString().split('T')[0],
    customer: '',
    quantity: '',
    price: 0,
    shipping: 0,
    invoiceNo: '',
    dueDate: '',
    totalWithTax: 0,
    unitPriceWithoutTax: 0,
    taxAmount: 0
  });

  // Invoice status selector. Maps to the existing invoiceStatus column via
  // SalesRecord.status. Default '待开' — a record only counts as having an invoice
  // once the user explicitly marks 已开 (PR-1; no schema change).
  const [saleInvoiceStatus, setSaleInvoiceStatus] = useState<'已开' | '待开'>('待开');

  // ── P4c: multi-line items editor (mirrors the purchase editor) ───────────────
  // The header (date/customer/invoice/due/status/shipping) stays in newSale; the product lines
  // live here. Save rule: exactly 1 valid line → legacy single-item payload (header
  // tons/product_id preserved); >1 valid line → items[] (backend P2 sums the header from the
  // lines). shippingCost is header-level and is NEVER part of the items sum.
  const defaultRatePct = String(parseFloat(defaultTaxRate.replace('%', '')) || 0);
  const emptyRow = (): ItemRow => ({ productId: '', description: '', unit: '', quantity: '', unitPrice: '', taxRatePct: defaultRatePct, grossInput: '', locked: null });
  const initialHeader = (): Omit<SalesRecord, 'status' | 'id'> => ({ date: new Date().toISOString().split('T')[0], customer: '', quantity: '', price: 0, shipping: 0, invoiceNo: '', dueDate: '', totalWithTax: 0, unitPriceWithoutTax: 0, taxAmount: 0 });
  const [lines, setLines] = useState<ItemRow[]>([emptyRow()]);

  // Per-line amounts, by driver precedence: gross-typed (reverse) > stored/locked > unit-price
  // (forward). All round2.
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
  const openNewSale = () => { setEditingId(null); setNewSale(initialHeader()); setSaleInvoiceStatus('待开'); resetLines(); setShowAddModal(true); };
  const closeAddModal = () => { setShowAddModal(false); setEditingId(null); setNewSale(initialHeader()); setSaleInvoiceStatus('待开'); resetLines(); };
  // ──────────────────────────────────────────────────────────────────────────

  const fileInputRef = useRef<HTMLInputElement>(null);

  // P4c: per-line amounts are computed by lineAmounts() above; the old single-field
  // total→amount auto-calc effect is removed (each line now carries its own qty/price/rate).

  const formatCurrency = (val: number) => fmtMoney(val);

  // Phase C：销售记录 → 业务单据预填。金额三项（不含税/税额）走「锁定行」复制
  // 已存值（pricePerTon 写库时已舍入，重算会差分）；一条记录 = 一行明细。
  const buildDocPrefill = (row: SalesRecord): Partial<BusinessDocument> => {
    const fallbackDesc = `${row.date} ${row.invoiceNo || ''}`.trim();
    // P4c: a multi-line sale → one doc line per item (so generated documents keep the breakdown);
    // a legacy single-item sale → one line from the header (unchanged). DocumentModal is not
    // touched — it already renders multi-item docs; amounts are copied (its toRow locks them).
    if (row.items && row.items.length > 0) {
      return {
        customerName: row.customer,
        sourceSalesId: row.id,
        items: row.items.map((it) => ({
          productId: it.productId || null,
          description: (it.description || '').trim() || (it.productId ? products.find((p) => p.id === it.productId)?.name : '') || fallbackDesc,
          quantity: it.quantity ?? null,
          unit: it.unitSnapshot || null,
          unitPrice: it.unitPrice ?? null,
          taxRate: it.taxRate != null ? `${it.taxRate}%` : null,
          amount: it.amountNet,
          taxAmount: it.taxAmount,
          refSalesId: row.id,
          refDate: row.date,
        })),
      };
    }
    const qtyMatch = (row.quantity || '').match(/[\d.]+/);
    // 旧记录可能无商品快照：回退「日期 + 票据号」描述（与对账单行同款），保证非空可保存
    const desc = row.productName
      || products.find((p) => p.id === row.productId)?.name
      || fallbackDesc;
    return {
      customerName: row.customer,
      sourceSalesId: row.id,
      items: [{
        productId: row.productId || null,
        description: desc,
        quantity: qtyMatch ? parseFloat(qtyMatch[0]) : null,
        unit: row.unit || null,
        unitPrice: row.unitPriceWithoutTax || row.pricePerTon || null,
        taxRate: row.taxRate || null,
        // 已存金额（与列表显示同款 || 回退）：DocumentModal 的 toRow 锁定显示、不重算
        amount: row.amountWithoutTax || row.price,
        taxAmount: row.taxAmount || 0,
        refSalesId: row.id,
        refDate: row.date,
      }],
    };
  };

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
    const timeout = setTimeout(() => reject(new Error(t('sales.fileReadTimeout'))), 30000);
    reader.onload = () => {
      clearTimeout(timeout);
      const result = reader.result as string;
      const parts = result.split(',');
      if (parts.length < 2) { reject(new Error(t('sales.fileFormatUnsupported'))); return; }
      resolve(parts[1]);
    };
    reader.onerror = () => { clearTimeout(timeout); reject(new Error(t('sales.fileReadFailed'))); };
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
        alert(t('sales.notInvoiceWarning', { type: docType }));
        return;
      }
      // Show a preview; the user confirms before anything is filled (PR-3c).
      setOcrPreview(extracted);
    } catch (err) {
      console.error(err);
      alert(t('sales.recognizeFailed'));
    } finally {
      setIsScanning(false);
      if (fileInputRef.current) fileInputRef.current.value = '';
    }
  };

  // PR-3c: "use these values" → fill the add-form state and open the modal. NO createSale / NO DB
  // write — the user reviews the pre-filled form and clicks save (handleAddSubmit) to actually record.
  const confirmOcrFill = () => {
    if (!ocrPreview) return;
    const filled = extractedToSalesForm(ocrPreview, defaultTaxRate);
    setNewSale(prev => ({ ...filled, date: filled.date || prev.date }));
    setSaleInvoiceStatus('待开');
    // OCR is single-invoice → land the recognised values in line 1 (P4c keeps OCR single-line;
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
    if (!newSale.customer) {
      alert(t('sales.formValidation'));
      return;
    }
    // Auto-ignore fully blank rows; a row is valid if it has a product OR a description.
    const valid = lines.filter((r) => r.productId || r.description.trim());
    if (valid.length === 0) {
      alert(t('sales.formValidation'));
      return;
    }
    // shippingCost stays header-level — it is NEVER part of the items sum.
    const header = {
      date: newSale.date,
      customer: newSale.customer,
      shipping: newSale.shipping,
      invoiceNo: newSale.invoiceNo,
      dueDate: newSale.dueDate,
      status: saleInvoiceStatus,
    };
    try {
      if (valid.length === 1) {
        // Single line → legacy single-item payload (header tons/product_id preserved, no items).
        const r = valid[0];
        const a = lineAmounts(r);
        const legacy: SalesRecord = {
          id: editingId || nextSalesId(),
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
        if (editingId) await updateSale(editingId, legacy);
        else await createSale(legacy);
      } else {
        // Multiple lines → items[] payload (backend P2 sums the header + neutralises legacy cols;
        // shippingCost above is carried as a header field, not summed into items).
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
        const record: SalesRecord = {
          id: editingId || nextSalesId(),
          ...header,
          productId: '',
          quantity: '',
          price: 0,
          taxRate: defaultTaxRate,
          items,
        };
        if (editingId) await updateSale(editingId, record);
        else await createSale(record);
      }
      // Refresh from the backend instead of optimistic patching: a multi-line save neutralises
      // the header (tons=0, total=Σ items) so the stored row differs from the form values.
      setRecords(await fetchSales());
      closeAddModal();
    } catch (err) {
      console.error(err);
      alert(getSystemErrorText(err, t) || (editingId ? t('sales.updateFailed') : t('sales.saveFailed')));
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
          <h1 className="text-2xl font-bold text-[#191918]">{accLocale !== 'CN' ? taxLabel('pageTitleSales') : t('sales.title')}</h1>
          <p className="text-sm text-[#5c5c5a] mt-1">{t('sales.pageSubtitle')}</p>
        </div>
        <div className="flex space-x-3">
          <button
            onClick={() => setShowCsvImport(true)}
            className="flex items-center px-4 py-2 bg-emerald-600 hover:bg-emerald-500 text-white rounded-lg transition-colors text-sm font-medium" style={{ boxShadow: '0 4px 16px rgba(16,185,129,0.15)' }}
          >
            <i className="fas fa-file-csv mr-2"></i> {t('sales.batchImport')}
          </button>
          <button
            onClick={triggerUpload}
            disabled={isScanning}
            className="flex items-center px-4 py-2 bg-purple-600 hover:bg-purple-500 text-white rounded-lg transition-colors text-sm font-medium disabled:opacity-50" style={{ boxShadow: '0 4px 16px rgba(147,51,234,0.15)' }}
          >
            <i className={`fas ${isScanning ? 'fa-spinner animate-spin' : 'fa-camera'} mr-2`}></i>
            {isScanning ? t('sales.scanning') : (accLocale === 'KR' ? taxLabel('scanDocButton') : t('sales.scanInvoice'))}
          </button>
          <button
            onClick={openNewSale}
            className="flex items-center px-4 py-2 bg-primary hover:bg-primary-hover text-white rounded-lg transition-colors text-sm font-medium" style={{ boxShadow: '0 4px 16px rgba(39,76,146,0.15)' }}
          >
            <i className="fas fa-plus mr-2"></i> {accLocale !== 'CN' ? taxLabel('newSaleButton') : t('sales.newSale')}
          </button>
        </div>
      </div>

      {/* Inventory Banner */}
      {(() => {
        const purchaseQty = data.rawMetrics?.purchaseTotalTons ?? 0;
        const salesQty = data.rawMetrics?.salesTotalTons ?? 0;
        const inventoryQty = purchaseQty - salesQty;
        const isLow = inventoryQty <= 0;
        return (
          <div className={`${isLow ? 'bg-rose-500/10 border-rose-500/20' : 'bg-blue-500/10 border-blue-500/20'} border rounded-xl p-4 flex items-center justify-between`}>
            <div className="flex items-center space-x-3">
              <div className={`${isLow ? 'text-rose-500 bg-rose-500/20' : 'text-blue-500 bg-blue-500/20'} w-8 h-8 rounded-full flex items-center justify-center`}>
                <i className={`fas ${isLow ? 'fa-exclamation-triangle' : 'fa-boxes'}`}></i>
              </div>
              <div>
                <p className={`${isLow ? 'text-rose-500' : 'text-blue-500'} font-bold text-sm`}>
                  {t('sales.inventoryCurrent')}: {fmtQty(inventoryQty)}
                </p>
                <p className={`${isLow ? 'text-rose-400' : 'text-blue-400'} text-xs`}>
                  {isLow ? t('sales.inventoryLow') : t('sales.inventorySufficient')}
                </p>
              </div>
            </div>
            <div className="text-right text-[#5c5c5a] text-xs space-y-0.5">
              {/* US shows quantity stats instead of the CN 总采购/总销售 inventory wording */}
              <p>{accLocale === 'US' ? taxLabel('salesBannerPurchaseQty') : t('sales.inventoryTotalPurchase')}: {fmtQty(purchaseQty)}</p>
              <p>{accLocale === 'US' ? taxLabel('salesBannerSalesQty') : t('sales.inventoryTotalSales')}: {fmtQty(salesQty)}</p>
            </div>
          </div>
        );
      })()}

      {/* Recognition Mode Selector */}
      <div className="flex items-center justify-between py-2">
        <div className="flex items-center space-x-4">
          <span className="text-[#4a4a48] text-sm">{t('sales.recognitionMode')}:</span>
          <div className="flex bg-[#f9f9f8] rounded-lg p-1 border border-[#e0ddd5]">
            <button
              onClick={() => setRecognitionMode('ai')}
              className={`flex items-center px-3 py-1.5 rounded-md text-xs transition-all ${recognitionMode === 'ai' ? 'bg-primary text-white shadow-sm' : 'text-[#4a4a48] hover:text-[#191918]'}`}
            >
              <i className="fas fa-robot mr-2"></i> {t('sales.modeAi')}
            </button>
            <button
              onClick={() => setRecognitionMode('ocr')}
              className={`flex items-center px-3 py-1.5 rounded-md text-xs transition-all ${recognitionMode === 'ocr' ? 'bg-[#f0eeeb] text-[#191918]' : 'text-[#4a4a48] hover:text-[#191918]'}`}
            >
              <i className="fas fa-file-invoice mr-2"></i> {t('sales.modeOcr')}
            </button>
          </div>
        </div>
        <div className="flex items-center space-x-2 text-xs text-[#5c5c5a]">
          <span className="w-2 h-2 rounded-full bg-emerald-500 animate-pulse"></span>
          <span>{t('sales.aiStatus')}</span>
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
          {isScanning ? (accLocale !== 'CN' ? taxLabel('scanningTitle') : t('sales.uploadAnalyzing')) : (accLocale !== 'CN' ? taxLabel('uploadTitleSales') : t('sales.uploadTitle'))}
        </h3>
        <p className="text-[#5c5c5a] text-xs">
          {isScanning ? (accLocale !== 'CN' ? taxLabel('scanningSubtitle') : t('sales.uploadExtracting')) : (accLocale !== 'CN' ? taxLabel('uploadSubtitleSales') : t('sales.uploadSubtitle'))}
        </p>
      </div>

      {/* Phase C：业务单据生成成功提示 */}
      {docGenOk && (
        <div className="text-sm text-emerald-700 bg-emerald-50 border border-emerald-200 rounded-lg px-3 py-2">
          <i className="fas fa-check-circle mr-2"></i>{t('documents.generatedOk')}
        </div>
      )}

      {/* Data Table */}
      <div className="bg-white/80 border border-[#e0ddd5] rounded-xl overflow-hidden" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.05)' }}>
        <div className="overflow-x-auto">
          <table className="w-full text-left border-collapse data-table">
            <thead>
              <tr className="border-b border-[#e0ddd5] text-[#5c5c5a] text-xs">
                <th className="px-5 py-4 font-medium">{t('tableHeaders.date')}</th>
                <th className="px-5 py-4 font-medium">{t('tableHeaders.customer')}</th>
                <th className="px-5 py-4 font-medium">{t('tableHeaders.product')}</th>
                <th className="px-5 py-4 font-medium">{t('tableHeaders.quantity')}</th>
                <th className="px-5 py-4 font-medium whitespace-nowrap">{accLocale !== 'CN' ? taxLabel('headerUnitPrice') : t('tableHeaders.unitPriceWithoutTax')}</th>
                <th className="px-5 py-4 font-medium whitespace-nowrap">{accLocale !== 'CN' ? taxLabel('headerAmount') : t('tableHeaders.amountWithoutTax')}</th>
                <th className="px-5 py-4 font-medium whitespace-nowrap">{accLocale !== 'CN' ? taxLabel('headerTaxAmount') : t('tableHeaders.taxAmount')}</th>
                <th className="px-5 py-4 font-medium whitespace-nowrap">{accLocale !== 'CN' ? taxLabel('headerTotalWithTax') : t('tableHeaders.totalWithTax')}</th>
                <th className="px-5 py-4 font-medium">{t('tableHeaders.taxRate')}</th>
                <th className="px-5 py-4 font-medium">{t('tableHeaders.shipping')}</th>
                <th className="px-5 py-4 font-medium">{accLocale !== 'CN' ? taxLabel('headerInvoiceNo') : t('tableHeaders.invoiceNo')}</th>
                <th className="px-5 py-4 font-medium">{t('tableHeaders.status')}</th>
                <th className="px-5 py-4 font-medium">{t('tableHeaders.actions')}</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-[#e0ddd5]/50">
              {records.flatMap((rec) => {
                // P4c: expand a multi-line sale into one display row per line item; a legacy
                // single-item sale stays one row. All rows share rec.id, so editing any row opens
                // the same multi-line modal and deleting any row removes the whole sale. Per-row
                // amounts are the LINE's net/tax/gross. shippingCost is header-level: shown on the
                // first row only, never per item, never summed into items.
                const lineRows = (rec.items && rec.items.length > 0)
                  ? rec.items.map((it, idx) => ({ item: it as LineItem | null, key: `${rec.id}::${it.lineNo ?? idx}::${idx}`, first: idx === 0 }))
                  : [{ item: null as LineItem | null, key: rec.id, first: true }];
                return lineRows.map(({ item, key, first }) => {
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
                  const rateCell = item ? (item.taxRate != null ? `${item.taxRate}%` : '—') : (rec.taxRate || '—');
                  return (
                  <tr key={key} className="hover:bg-[#f9f9f8]/30 transition-colors">
                    <td className="px-5 py-5 text-sm text-[#4a4a48] whitespace-nowrap">{rec.date}</td>
                    <td className="px-5 py-5 text-sm text-[#191918] font-medium col-name">{rec.customer}</td>
                    <td className="px-5 py-5 text-sm text-[#4a4a48] col-name">{productName}</td>
                    <td className="px-5 py-5 text-sm text-[#4a4a48]">{qtyCell}</td>
                    <td className="px-5 py-5 text-sm text-[#191918] font-medium whitespace-nowrap">{unitPriceCell}</td>
                    <td className="px-5 py-5 text-sm text-[#191918] font-medium whitespace-nowrap">{formatCurrency(net)}</td>
                    <td className="px-5 py-5 text-sm text-rose-600 font-medium whitespace-nowrap">{formatCurrency(tax)}</td>
                    <td className="px-5 py-5 text-sm text-[#191918] font-bold whitespace-nowrap">{formatCurrency(gross)}</td>
                    <td className="px-5 py-5 text-sm text-[#4a4a48]">{rateCell}</td>
                    <td className="px-5 py-5 text-sm text-[#4a4a48]">{first ? formatCurrency(rec.shipping) : '—'}</td>
                    <td className="px-5 py-5 text-sm font-mono text-[#4a4a48] tracking-tight">{rec.invoiceNo}</td>
                    <td className="px-5 py-5">
                      {(() => {
                        const tone = classifyInvoiceStatus(rec.status);
                        const label = tone === 'unknown'
                          ? (String(rec.status ?? '').trim() || '—')
                          : tone === 'done'
                            ? (accLocale !== 'CN' ? taxLabel('invStatusIssued') : t('sales.invoiceStatusIssued'))
                            : (accLocale !== 'CN' ? taxLabel('invStatusPendingIssue') : t('sales.invoiceStatusPending'));
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
                            // Always fetch the detail so a multi-line sale's items are never lost.
                            const detail = await getSale(rec.id);
                            setEditingId(rec.id);
                            setNewSale({ date: detail.date, customer: detail.customer, productId: detail.productId || '', quantity: '', price: 0, shipping: detail.shipping, invoiceNo: detail.invoiceNo, dueDate: detail.dueDate || '', totalWithTax: 0, unitPriceWithoutTax: 0, taxAmount: 0 });
                            setSaleInvoiceStatus(rec.status || '待开');
                            if (detail.items && detail.items.length > 0) {
                              setLines(detail.items.map(itemToRow));
                            } else {
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
                            alert(getSystemErrorText(err, t) || t('sales.updateFailed'));
                          }
                        }}
                        className="text-primary hover:text-primary-hover transition-colors"
                      >{t('common2.edit')}</button>
                      <button
                        onClick={async () => {
                          try {
                            await deleteSale(rec.id);
                            setRecords(prev => prev.filter(r => r.id !== rec.id));
                          } catch (err) {
                            console.error(err);
                            alert(getSystemErrorText(err, t) || t('sales.deleteFailed'));
                          }
                        }}
                        className="text-rose-500 hover:text-rose-400 transition-colors"
                      >
                        {t('common2.delete')}
                      </button>
                      {docDesktop && (
                        <button
                          onClick={() => { setDocGenOk(false); setDocPrefill(buildDocPrefill(rec)); }}
                          className="text-[#5c5c5a] hover:text-[#191918] transition-colors"
                        >
                          {t('documents.generateFromSale')}
                        </button>
                      )}
                    </td>
                  </tr>
                  );
                });
              })}
              {isLoading && (
                <tr>
                  <td colSpan={13} className="px-6 py-12 text-center text-[#5c5c5a] text-sm">
                    <i className="fas fa-spinner animate-spin mr-2"></i>{t('sales.loading')}
                  </td>
                </tr>
              )}
              {!isLoading && records.length === 0 && (
                <tr>
                  <td colSpan={13} className="px-6 py-12 text-center text-[#5c5c5a] text-sm italic">
                    {accLocale !== 'CN' ? taxLabel('emptySales') : t('sales.empty')}
                  </td>
                </tr>
              )}
              {/* Summary row */}
              {!isLoading && records.length > 0 && (
                <tr className="bg-[#f9f9f8] border-t-2 border-[#e0ddd5] font-semibold">
                  <td className="px-5 py-4 text-sm text-[#191918]" colSpan={2}>{t('sales.summary')}</td>
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
                  <td className="px-5 py-4 text-sm text-[#4a4a48]">—</td>
                  <td className="px-5 py-4 text-sm text-[#4a4a48] whitespace-nowrap">
                    {formatCurrency(records.reduce((s, r) => s + (r.shipping || 0), 0))}
                  </td>
                  <td colSpan={3}></td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </div>

      {/* CSV Import Modal */}
      {showCsvImport && (
        <CsvImportModal
          type="sales"
          onClose={() => setShowCsvImport(false)}
          onSuccess={() => {
            setShowCsvImport(false);
            fetchSales().then(setRecords).catch(console.error);
          }}
        />
      )}

      {/* Phase C：从销售记录生成业务单据（共享 DocumentModal，预填 + 锁定金额） */}
      {docPrefill && (
        <DocumentModal
          editing={null}
          initial={docPrefill}
          accLocale={accLocale}
          products={products}
          onClose={() => setDocPrefill(null)}
          onSaved={() => { setDocPrefill(null); setDocGenOk(true); }}
        />
      )}

      {/* Add Sales Modal */}
      {showAddModal && (
        <div className="fixed inset-0 z-[10001] flex items-center justify-center px-4">
          <div className="absolute inset-0 bg-black/40 backdrop-blur-sm" onClick={closeAddModal}></div>
          <div className="relative w-full max-w-2xl bg-white border border-[#e0ddd5] rounded-xl overflow-hidden flex flex-col max-h-[calc(100vh-2rem)] animate-in zoom-in-95 duration-200" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.05)' }}>
            <div className="p-8 border-b border-[#e0ddd5] flex justify-between items-center gap-4 shrink-0">
              <div className="flex-shrink-0">
                <h2 className="text-xl font-bold text-[#191918] whitespace-nowrap">{editingId ? t('sales.modalTitleEdit') : (accLocale !== 'CN' ? taxLabel('modalTitleSales') : t('sales.modalTitle'))}</h2>
                <p className="text-xs text-[#5c5c5a] mt-1">{editingId ? t('sales.modalSubtitleEdit') : (accLocale !== 'CN' ? taxLabel('modalSubtitleSales') : t('sales.modalSubtitle'))}</p>
              </div>
              <button onClick={closeAddModal} aria-label={t('common.close')} className="flex-shrink-0 text-[#5c5c5a] hover:text-[#191918] transition-colors">
                <i className="fas fa-times text-xl"></i>
              </button>
            </div>

            <form onSubmit={handleAddSubmit} className="p-8 space-y-5 flex-1 min-h-0 overflow-y-auto">
              <div className="grid grid-cols-2 gap-4">
                <div className="space-y-2">
                  <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{t('sales.formDate')}</label>
                  <input
                    type="date"
                    required
                    value={newSale.date}
                    onChange={(e) => setNewSale({ ...newSale, date: e.target.value })}
                    className="w-full bg-white border border-[#e0ddd5] rounded-xl px-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary text-[#191918] transition-all"
                  />
                </div>
                <div className="space-y-2">
                  <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{accLocale !== 'CN' ? taxLabel('headerInvoiceNo') : t('sales.formInvoiceNo')}</label>
                  <input
                    type="text"
                    placeholder={t('common2.optional')}
                    value={newSale.invoiceNo}
                    onChange={(e) => setNewSale({ ...newSale, invoiceNo: e.target.value })}
                    className="w-full bg-white border border-[#e0ddd5] rounded-xl px-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary text-[#191918] transition-all"
                  />
                </div>
              </div>

              <div className="space-y-2">
                <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{t('common2.dueDate')}</label>
                <input
                  type="date"
                  value={newSale.dueDate || ''}
                  onChange={(e) => setNewSale({ ...newSale, dueDate: e.target.value })}
                  className="w-full bg-white border border-[#e0ddd5] rounded-xl px-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary text-[#191918] transition-all"
                />
              </div>

              <div className="space-y-2">
                <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{accLocale !== 'CN' ? taxLabel('invStatusFilter') : t('sales.formInvoiceStatus')}</label>
                <select
                  data-testid="sale-invoice-status"
                  value={saleInvoiceStatus}
                  onChange={(e) => setSaleInvoiceStatus(e.target.value as '已开' | '待开')}
                  className="w-full bg-white border border-[#e0ddd5] rounded-xl px-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary text-[#191918] transition-all"
                >
                  <option value="待开">{accLocale !== 'CN' ? taxLabel('invStatusPendingIssue') : t('sales.invoiceStatusPending')}</option>
                  <option value="已开">{accLocale !== 'CN' ? taxLabel('invStatusIssued') : t('sales.invoiceStatusIssued')}</option>
                </select>
              </div>

              <div className="space-y-2">
                <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{t('sales.formCustomer')}</label>
                <input
                  type="text"
                  required
                  placeholder={usZh ? taxLabel('setFormCustomerPh') : t('sales.formCustomerPlaceholder')}
                  data-testid="ocr-fill-counterparty"
                  value={newSale.customer}
                  onChange={(e) => setNewSale({ ...newSale, customer: e.target.value })}
                  className="w-full bg-white border border-[#e0ddd5] rounded-xl px-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary text-[#191918] transition-all"
                />
              </div>

              {/* P4c: multi-line items editor (mirrors the purchase page). One product/service per
                  row; a row is valid (saved) when it has a product OR a description. */}
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
                        data-testid={`sale-line-desc-${i}`}
                        placeholder={t('common2.optional')}
                        value={row.description}
                        onChange={(e) => setLine(i, { description: e.target.value })}
                        className="w-full bg-white border border-[#e0ddd5] rounded-xl px-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary text-[#191918] transition-all"
                      />
                    </div>
                    <div className="grid grid-cols-5 gap-3">
                      <div className="space-y-2">
                        <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{usZh ? taxLabel('setFormQtyLabel') : t('sales.formQuantity')}</label>
                        <input
                          type="number"
                          step="0.01"
                          min="0"
                          data-testid={`sale-line-qty-${i}`}
                          placeholder={usZh ? taxLabel('setFormQtyPh') : t('sales.formQuantityPlaceholder')}
                          value={row.quantity}
                          onChange={(e) => setLine(i, { quantity: e.target.value })}
                          className="w-full bg-white border border-[#e0ddd5] rounded-xl px-3 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary text-[#191918] transition-all"
                        />
                      </div>
                      <div className="space-y-2">
                        <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{accLocale !== 'CN' ? taxLabel('headerUnitPrice') : t('sales.formUnitPrice')}</label>
                        <input
                          type="number"
                          step="0.01"
                          min="0"
                          data-testid={`sale-line-price-${i}`}
                          value={row.grossInput !== '' ? String(lineUnitPrice(row) || '') : row.unitPrice}
                          onChange={(e) => setLine(i, { unitPrice: e.target.value })}
                          className="w-full bg-white border border-[#e0ddd5] rounded-xl px-3 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary text-[#191918] transition-all"
                        />
                      </div>
                      <div className="space-y-2">
                        <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{t('tableHeaders.taxRate')} %</label>
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
                        {/* Per-line tax amount — read-only display, shown inline in the row so the user
                            sees THIS item's tax beside its rate and gross total (not just a footer). */}
                        <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{t('common2.taxAmount')}</label>
                        <div className="w-full px-3 py-3 text-sm font-bold text-rose-600 whitespace-nowrap overflow-hidden text-ellipsis" title={fmtMoney(amt.taxAmount)}>{fmtMoney(amt.taxAmount)}</div>
                      </div>
                      <div className="space-y-2">
                        <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{accLocale !== 'CN' ? taxLabel('headerTotalWithTax') : t('sales.formTotalWithTax')}</label>
                        <input
                          type="number"
                          step="0.01"
                          min="0"
                          data-testid={`sale-line-gross-${i}`}
                          placeholder={t('common2.optional')}
                          value={row.grossInput !== '' ? row.grossInput : (amt.amountGross ? String(amt.amountGross) : '')}
                          onChange={(e) => setLine(i, { grossInput: e.target.value })}
                          className="w-full bg-white border border-[#e0ddd5] rounded-xl px-3 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary text-[#191918] transition-all"
                        />
                      </div>
                    </div>
                    {/* THIS line's own net amount (该行不含税金额) — the line's tax now sits inline in the
                        grid above; this keeps the net (the COGS basis) visible, never the order total. */}
                    <div className="flex flex-wrap items-center justify-end gap-x-6 gap-y-1 border-t border-[#e0ddd5]/70 mt-1 pt-2 text-sm">
                      <span className="font-semibold text-[#3c3c3a]">{t('common2.lineNetAmount')}: <span className="font-bold text-[#191918]">{fmtMoney(amt.amountNet)}</span></span>
                    </div>
                  </div>
                  );
                })}
                <button type="button" onClick={addLine} className="w-full border-2 border-dashed border-[#e0ddd5] hover:border-primary/50 hover:bg-primary/5 rounded-xl py-2.5 text-xs text-[#5c5c5a] hover:text-primary transition-all">
                  <i className="fas fa-plus mr-2"></i>{t('documents.addItem')}
                </button>
              </div>

              {/* 运费（表头级·不进 items 汇总） */}
              <div className="space-y-2">
                <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{t('sales.formShipping')}</label>
                <div className="relative">
                  <span className="absolute left-4 top-1/2 -translate-y-1/2 text-[#5c5c5a] text-sm">{currSym}</span>
                  <input
                    type="number"
                    step="0.01"
                    value={newSale.shipping || ''}
                    onChange={(e) => setNewSale({ ...newSale, shipping: parseFloat(e.target.value) || 0 })}
                    className={`w-full bg-white border border-[#e0ddd5] rounded-xl ${moneyPad} pr-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary text-[#191918] transition-all`}
                  />
                </div>
              </div>

              {/* 表头合计（明细求和；运费不计入） */}
              <div className="border-t border-[#e0ddd5] pt-4 space-y-1.5 text-sm">
                <div className="flex justify-between text-[#4a4a48]">
                  <span>{accLocale !== 'CN' ? taxLabel('headerAmount') : t('tableHeaders.amountWithoutTax')}</span>
                  <span className="font-medium text-[#191918]">{fmtMoney(totalNet)}</span>
                </div>
                <div className="flex justify-between text-[#4a4a48]">
                  <span>{accLocale !== 'CN' ? taxLabel('headerTaxAmount') : t('tableHeaders.taxAmount')}</span>
                  <span className="font-medium text-rose-600">{fmtMoney(totalTax)}</span>
                </div>
                <div className="flex justify-between text-base font-bold text-[#191918]">
                  <span>{accLocale !== 'CN' ? taxLabel('headerTotalWithTax') : t('tableHeaders.totalWithTax')}</span>
                  <span data-testid="sale-total-gross">{fmtMoney(totalGross)}</span>
                </div>
              </div>


              <div className="pt-4 flex space-x-3">
                <button
                  type="button"
                  onClick={closeAddModal}
                  className="flex-1 py-4 bg-[#f0eeeb] hover:bg-[#e0ddd5] text-[#4a4a48] font-bold rounded-xl transition-all"
                >
                  {t('sales.formCancel')}
                </button>
                <button
                  type="submit"
                  className="flex-2 px-10 py-4 bg-primary hover:bg-primary-hover text-white font-bold rounded-xl transition-all active:scale-95" style={{ boxShadow: '0 4px 16px rgba(39,76,146,0.15)' }}
                >
                  {editingId ? t('sales.formSubmitEdit') : t('sales.formSubmitNew')}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {ocrPreview && (
        <OcrPreviewModal
          extracted={ocrPreview}
          counterpartyLabel={t('tableHeaders.customer')}
          counterparty={salesCounterparty(ocrPreview)}
          fmtMoney={fmtMoney}
          onClose={() => setOcrPreview(null)}
          onConfirm={confirmOcrFill}
        />
      )}
    </div>
  );
};

export default SalesAndOutputPage;
