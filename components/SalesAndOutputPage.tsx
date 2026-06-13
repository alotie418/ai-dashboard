
import React, { useState, useRef, useEffect } from 'react';
import { useTranslation } from 'react-i18next';
import { BusinessData } from '../types';
import { analyzeInvoice, extractedToSalesForm, type ExtractedInvoice } from '../services/ocrService';
import { rasterizePdfFirstPage } from '../services/pdfRaster';
import { fetchSales, createSale, updateSale, deleteSale, fetchSettings, listProducts, listProviders, isDesktop, type Product, type BusinessDocument, SalesRecord } from '../services/api';
import { formatMoney, getCurrencySymbol, formatQuantity, formatLegacyQuantity, getTaxLabel, getProductUnitLabel } from './accountingHelpers';
import CsvImportModal from './CsvImportModal';
import DocumentModal from './DocumentModal';
import OcrPreviewModal from './OcrPreviewModal';

interface Props {
  data: BusinessData;
  selectedYear: string;
  selectedQuarter: string;
  selectedMonth: string;
}

let salesIdCounter = 0;
const nextSalesId = () => `sale-${++salesIdCounter}-${Date.now()}`;

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
    totalWithTax: 0,
    unitPriceWithoutTax: 0,
    taxAmount: 0
  });

  const fileInputRef = useRef<HTMLInputElement>(null);

  // Auto-calculate: when totalWithTax + quantity change, compute price/unitPrice/taxAmount
  useEffect(() => {
    const { totalWithTax, quantity, taxRate } = newSale;
    if (!totalWithTax || totalWithTax <= 0) return;

    const rateNum = parseFloat((taxRate || '13%').replace('%', '')) || 13;
    const amountWithoutTax = Math.round((totalWithTax / (1 + rateNum / 100)) * 100) / 100;
    const taxAmount = Math.round((totalWithTax - amountWithoutTax) * 100) / 100;

    const tonsMatch = quantity.match(/[\d.]+/);
    const tons = tonsMatch ? parseFloat(tonsMatch[0]) : 0;
    const unitPrice = tons > 0 ? Math.round((amountWithoutTax / tons) * 100) / 100 : 0;

    if (
      newSale.price !== amountWithoutTax ||
      newSale.unitPriceWithoutTax !== unitPrice ||
      newSale.taxAmount !== taxAmount
    ) {
      setNewSale(prev => ({
        ...prev,
        price: amountWithoutTax,
        unitPriceWithoutTax: unitPrice,
        taxAmount
      }));
    }
  }, [newSale.totalWithTax, newSale.quantity, newSale.taxRate]);

  const formatCurrency = (val: number) => fmtMoney(val);

  // Phase C：销售记录 → 业务单据预填。金额三项（不含税/税额）走「锁定行」复制
  // 已存值（pricePerTon 写库时已舍入，重算会差分）；一条记录 = 一行明细。
  const buildDocPrefill = (row: SalesRecord): Partial<BusinessDocument> => {
    const qtyMatch = (row.quantity || '').match(/[\d.]+/);
    // 旧记录可能无商品快照：回退「日期 + 票据号」描述（与对账单行同款），保证非空可保存
    const desc = row.productName
      || products.find((p) => p.id === row.productId)?.name
      || `${row.date} ${row.invoiceNo || ''}`.trim();
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
    const filled = extractedToSalesForm(ocrPreview, '13%');
    setNewSale(prev => ({ ...filled, date: filled.date || prev.date }));
    setOcrPreview(null);
    setShowAddModal(true);
  };

  const handleAddSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!newSale.customer || !newSale.quantity) {
      alert(t('sales.formValidation'));
      return;
    }
    try {
      if (editingId) {
        // Update existing record
        const recordToUpdate: SalesRecord = { id: editingId, ...newSale, status: '已开' };
        await updateSale(editingId, recordToUpdate);
        setRecords(prev => prev.map(r => r.id === editingId ? recordToUpdate : r));
      } else {
        // Create new record
        const recordToAdd: SalesRecord = { id: nextSalesId(), ...newSale, status: '已开' };
        await createSale(recordToAdd);
        setRecords(prev => [recordToAdd, ...prev]);
      }
      setShowAddModal(false);
      setEditingId(null);
      setNewSale({
        date: new Date().toISOString().split('T')[0],
        customer: '',
        quantity: '',
        price: 0,
        shipping: 0,
        invoiceNo: '',
        totalWithTax: 0,
        unitPriceWithoutTax: 0,
        taxAmount: 0
      });
    } catch (err) {
      console.error(err);
      alert(editingId ? t('sales.updateFailed') : t('sales.saveFailed'));
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
        <h1 className="text-2xl font-bold text-[#191918]">{accLocale !== 'CN' ? taxLabel('pageTitleSales') : t('sales.title')}</h1>
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
            onClick={() => { setEditingId(null); setShowAddModal(true); }}
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
          <span>{t('sales.aiStatus', { engine: recognitionMode === 'ai' ? 'Gemini 3 Flash' : 'Local OCR Engine' })}</span>
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
                <th className="px-5 py-4 font-medium">{t('tableHeaders.quantity')}</th>
                <th className="px-5 py-4 font-medium whitespace-nowrap">{accLocale !== 'CN' ? taxLabel('headerUnitPrice') : t('tableHeaders.unitPriceWithoutTax')}</th>
                <th className="px-5 py-4 font-medium whitespace-nowrap">{accLocale !== 'CN' ? taxLabel('headerAmount') : t('tableHeaders.amountWithoutTax')}</th>
                <th className="px-5 py-4 font-medium whitespace-nowrap">{accLocale !== 'CN' ? taxLabel('headerTaxAmount') : t('tableHeaders.taxAmount')}</th>
                <th className="px-5 py-4 font-medium whitespace-nowrap">{accLocale !== 'CN' ? taxLabel('headerTotalWithTax') : t('tableHeaders.totalWithTax')}</th>
                <th className="px-5 py-4 font-medium">{t('tableHeaders.shipping')}</th>
                <th className="px-5 py-4 font-medium">{accLocale !== 'CN' ? taxLabel('headerInvoiceNo') : t('tableHeaders.invoiceNo')}</th>
                <th className="px-5 py-4 font-medium">{t('tableHeaders.status')}</th>
                <th className="px-5 py-4 font-medium">{t('tableHeaders.actions')}</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-[#e0ddd5]/50">
              {records.map((row) => {
                const unitPrice = row.unitPriceWithoutTax || (row.pricePerTon || 0);
                const amtWithoutTax = row.amountWithoutTax || row.price;
                const taxAmt = row.taxAmount || 0;
                const totalWT = row.totalWithTax || (amtWithoutTax + taxAmt);
                return (
                <tr key={row.id} className="hover:bg-[#f9f9f8]/30 transition-colors">
                  <td className="px-5 py-5 text-sm text-[#4a4a48] whitespace-nowrap">{row.date}</td>
                  <td className="px-5 py-5 text-sm text-[#191918] font-medium col-name">{row.customer}</td>
                  <td className="px-5 py-5 text-sm text-[#4a4a48]">{row.unit ? `${row.quantity} ${getProductUnitLabel(row.unit, uiLang)}` : formatLegacyQuantity(row.quantity, productUnit, uiLang)}</td>
                  <td className="px-5 py-5 text-sm text-[#191918] font-medium whitespace-nowrap">{formatCurrency(unitPrice)}</td>
                  <td className="px-5 py-5 text-sm text-[#191918] font-medium whitespace-nowrap">{formatCurrency(amtWithoutTax)}</td>
                  <td className="px-5 py-5 text-sm text-rose-600 font-medium whitespace-nowrap">{formatCurrency(taxAmt)}</td>
                  <td className="px-5 py-5 text-sm text-[#191918] font-bold whitespace-nowrap">{formatCurrency(totalWT)}</td>
                  <td className="px-5 py-5 text-sm text-[#4a4a48]">{formatCurrency(row.shipping)}</td>
                  <td className="px-5 py-5 text-sm font-mono text-[#4a4a48] tracking-tight">{row.invoiceNo}</td>
                  <td className="px-5 py-5">
                    <span className="px-2 py-0.5 bg-emerald-500/10 text-emerald-500 border border-emerald-500/20 rounded-md text-[10px] font-bold">
                      {row.status}
                    </span>
                  </td>
                  <td className="px-5 py-5 text-xs font-medium space-x-3">
                    <button
                      onClick={() => {
                        setEditingId(row.id);
                        setNewSale({ date: row.date, customer: row.customer, productId: row.productId || '', quantity: row.quantity, price: row.price, shipping: row.shipping, invoiceNo: row.invoiceNo, totalWithTax: row.totalWithTax || 0, unitPriceWithoutTax: row.unitPriceWithoutTax || 0, taxAmount: row.taxAmount || 0 });
                        setShowAddModal(true);
                      }}
                      className="text-primary hover:text-primary-hover transition-colors"
                    >{t('common2.edit')}</button>
                    <button
                      onClick={async () => {
                        try {
                          await deleteSale(row.id);
                          setRecords(prev => prev.filter(r => r.id !== row.id));
                        } catch (err) {
                          console.error(err);
                          alert(t('sales.deleteFailed'));
                        }
                      }}
                      className="text-rose-500 hover:text-rose-400 transition-colors"
                    >
                      {t('common2.delete')}
                    </button>
                    {docDesktop && (
                      <button
                        onClick={() => { setDocGenOk(false); setDocPrefill(buildDocPrefill(row)); }}
                        className="text-[#5c5c5a] hover:text-[#191918] transition-colors"
                      >
                        {t('documents.generateFromSale')}
                      </button>
                    )}
                  </td>
                </tr>
                );
              })}
              {isLoading && (
                <tr>
                  <td colSpan={11} className="px-6 py-12 text-center text-[#5c5c5a] text-sm">
                    <i className="fas fa-spinner animate-spin mr-2"></i>{t('sales.loading')}
                  </td>
                </tr>
              )}
              {!isLoading && records.length === 0 && (
                <tr>
                  <td colSpan={11} className="px-6 py-12 text-center text-[#5c5c5a] text-sm italic">
                    {accLocale !== 'CN' ? taxLabel('emptySales') : t('sales.empty')}
                  </td>
                </tr>
              )}
              {/* Summary row */}
              {!isLoading && records.length > 0 && (
                <tr className="bg-[#f9f9f8] border-t-2 border-[#e0ddd5] font-semibold">
                  <td className="px-5 py-4 text-sm text-[#191918]" colSpan={2}>{t('sales.summary')}</td>
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
          <div className="absolute inset-0 bg-black/40 backdrop-blur-sm" onClick={() => { setShowAddModal(false); setEditingId(null); }}></div>
          <div className="relative w-full max-w-xl bg-white border border-[#e0ddd5] rounded-xl overflow-hidden animate-in zoom-in-95 duration-200" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.05)' }}>
            <div className="p-8 border-b border-[#e0ddd5] flex justify-between items-center gap-4">
              <div className="flex-shrink-0">
                <h2 className="text-xl font-bold text-[#191918] whitespace-nowrap">{editingId ? t('sales.modalTitleEdit') : (accLocale !== 'CN' ? taxLabel('modalTitleSales') : t('sales.modalTitle'))}</h2>
                <p className="text-xs text-[#5c5c5a] mt-1">{editingId ? t('sales.modalSubtitleEdit') : (accLocale !== 'CN' ? taxLabel('modalSubtitleSales') : t('sales.modalSubtitle'))}</p>
              </div>
              <button onClick={() => setShowAddModal(false)} className="flex-shrink-0 text-[#5c5c5a] hover:text-[#191918] transition-colors">
                <i className="fas fa-times text-xl"></i>
              </button>
            </div>

            <form onSubmit={handleAddSubmit} className="p-8 space-y-5">
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

              <div className="space-y-2">
                <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{t('products.selectLabel')}</label>
                <select
                  value={newSale.productId || ''}
                  onChange={(e) => setNewSale({ ...newSale, productId: e.target.value })}
                  className="w-full bg-white border border-[#e0ddd5] rounded-xl px-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary text-[#191918] transition-all"
                >
                  <option value="">{t('products.unassigned')}</option>
                  {products.filter(p => p.is_active).map(p => (
                    <option key={p.id} value={p.id}>{p.name}（{getProductUnitLabel(p.unit, uiLang)}）</option>
                  ))}
                </select>
              </div>

              <div className="space-y-2">
                <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{usZh ? taxLabel('setFormQtyLabel') : t('sales.formQuantity')}</label>
                <input
                  type="text"
                  required
                  placeholder={usZh ? taxLabel('setFormQtyPh') : t('sales.formQuantityPlaceholder')}
                  value={newSale.quantity}
                  onChange={(e) => setNewSale({ ...newSale, quantity: e.target.value })}
                  className="w-full bg-white border border-[#e0ddd5] rounded-xl px-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary text-[#191918] transition-all"
                />
              </div>

              <div className="grid grid-cols-2 gap-4">
                <div className="space-y-2">
                  <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{accLocale !== 'CN' ? taxLabel('headerAmount') : t('sales.formPrice')}</label>
                  <div className="relative">
                    <span className="absolute left-4 top-1/2 -translate-y-1/2 text-[#5c5c5a] text-sm">{currSym}</span>
                    <input
                      type="number"
                      required
                      step="0.01"
                      value={newSale.price || ''}
                      onChange={(e) => setNewSale({ ...newSale, price: parseFloat(e.target.value) || 0 })}
                      className={`w-full bg-white border border-[#e0ddd5] rounded-xl ${moneyPad} pr-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary text-[#191918] transition-all`}
                    />
                  </div>
                </div>
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
              </div>

              <div className="grid grid-cols-3 gap-4">
                <div className="space-y-2">
                  <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{accLocale !== 'CN' ? taxLabel('headerUnitPrice') : t('sales.formUnitPrice')}</label>
                  <div className="relative">
                    <span className="absolute left-4 top-1/2 -translate-y-1/2 text-[#5c5c5a] text-sm">{currSym}</span>
                    <input
                      type="number"
                      step="0.01"
                      value={newSale.unitPriceWithoutTax || ''}
                      onChange={(e) => setNewSale({ ...newSale, unitPriceWithoutTax: parseFloat(e.target.value) || 0 })}
                      className={`w-full bg-white border border-[#e0ddd5] rounded-xl ${moneyPad} pr-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary text-[#191918] transition-all`}
                      placeholder={t('common2.optional')}
                    />
                  </div>
                </div>
                <div className="space-y-2">
                  <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{t('sales.formTaxAmount')}</label>
                  <div className="relative">
                    <span className="absolute left-4 top-1/2 -translate-y-1/2 text-[#5c5c5a] text-sm">{currSym}</span>
                    <input
                      type="number"
                      step="0.01"
                      value={newSale.taxAmount || ''}
                      onChange={(e) => setNewSale({ ...newSale, taxAmount: parseFloat(e.target.value) || 0 })}
                      className={`w-full bg-white border border-[#e0ddd5] rounded-xl ${moneyPad} pr-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary text-[#191918] transition-all`}
                      placeholder={t('common2.optional')}
                    />
                  </div>
                </div>
                <div className="space-y-2">
                  <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{t('sales.formTotalWithTax')}</label>
                  <div className="relative">
                    <span className="absolute left-4 top-1/2 -translate-y-1/2 text-[#5c5c5a] text-sm">{currSym}</span>
                    <input
                      type="number"
                      step="0.01"
                      data-testid="ocr-fill-total"
                      value={newSale.totalWithTax || ''}
                      onChange={(e) => setNewSale({ ...newSale, totalWithTax: parseFloat(e.target.value) || 0 })}
                      className={`w-full bg-white border border-[#e0ddd5] rounded-xl ${moneyPad} pr-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary text-[#191918] transition-all`}
                      placeholder={t('common2.optional')}
                    />
                  </div>
                </div>
              </div>


              <div className="pt-4 flex space-x-3">
                <button
                  type="button"
                  onClick={() => setShowAddModal(false)}
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
          fmtMoney={fmtMoney}
          onClose={() => setOcrPreview(null)}
          onConfirm={confirmOcrFill}
        />
      )}
    </div>
  );
};

export default SalesAndOutputPage;
