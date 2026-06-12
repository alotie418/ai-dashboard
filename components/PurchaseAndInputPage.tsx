
import React, { useState, useRef, useEffect } from 'react';
import { useTranslation } from 'react-i18next';
import { BusinessData } from '../types';
import { analyzeInvoice } from '../services/ocrService';
import { fetchPurchases, createPurchase, deletePurchase, fetchSettings, listProducts, type Product, PurchaseRecord } from '../services/api';
import { formatMoney, getCurrencySymbol, getTaxLabel, formatLegacyQuantity, getProductUnitLabel } from './accountingHelpers';
import CsvImportModal from './CsvImportModal';

interface Props {
  data: BusinessData;
  selectedYear: string;
  selectedQuarter: string;
  selectedMonth: string;
}

let purchaseIdCounter = 0;
const nextPurchaseId = () => `purchase-${++purchaseIdCounter}-${Date.now()}`;

const TAX_RATE_OPTIONS: Record<string, { value: string; labelKey: string }[]> = {
  CN: [
    { value: '13%', labelKey: 'purchases.taxStandard' },
    { value: '9%', labelKey: 'purchases.taxTransport' },
    { value: '6%', labelKey: 'purchases.taxService' },
    { value: '3%', labelKey: 'purchases.taxSmall' },
  ],
  US: [
    { value: '0%', labelKey: 'purchases.taxNone' },
    { value: '7%', labelKey: 'purchases.taxSalesTax' },
    { value: '10%', labelKey: 'purchases.taxSalesTax10' },
  ],
  JP: [
    { value: '10%', labelKey: 'purchases.taxJpStandard' },
    { value: '8%', labelKey: 'purchases.taxJpReduced' },
  ],
  EU: [
    { value: '20%', labelKey: 'purchases.taxEuStandard' },
    { value: '10%', labelKey: 'purchases.taxEuReduced' },
    { value: '5%', labelKey: 'purchases.taxEuSuperReduced' },
  ],
  KR: [
    { value: '10%', labelKey: 'purchases.taxKrStandard' },
  ],
  TW: [
    { value: '5%', labelKey: 'purchases.taxTwStandard' },
  ],
};

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
  const [records, setRecords] = useState<PurchaseRecord[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [showCsvImport, setShowCsvImport] = useState(false);

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
    totalWithTax: 0,
    unitPriceWithoutTax: 0,
    taxAmount: 0
  });

  const fileInputRef = useRef<HTMLInputElement>(null);

  // Auto-calculate: when totalWithTax + quantity + taxRate change, compute price/unitPrice/taxAmount
  useEffect(() => {
    const { totalWithTax, quantity, taxRate } = newPurchase;
    if (!totalWithTax || totalWithTax <= 0) return;

    const rateNum = parseFloat(taxRate.replace('%', '')) || 13;
    const amountWithoutTax = Math.round((totalWithTax / (1 + rateNum / 100)) * 100) / 100;
    const taxAmount = Math.round((totalWithTax - amountWithoutTax) * 100) / 100;

    const tonsMatch = quantity.match(/[\d.]+/);
    const tons = tonsMatch ? parseFloat(tonsMatch[0]) : 0;
    const unitPrice = tons > 0 ? Math.round((amountWithoutTax / tons) * 100) / 100 : 0;

    // Only update if calculated values differ (avoid infinite loop)
    if (
      newPurchase.price !== amountWithoutTax ||
      newPurchase.unitPriceWithoutTax !== unitPrice ||
      newPurchase.taxAmount !== taxAmount
    ) {
      setNewPurchase(prev => ({
        ...prev,
        price: amountWithoutTax,
        unitPriceWithoutTax: unitPrice,
        taxAmount
      }));
    }
  }, [newPurchase.totalWithTax, newPurchase.quantity, newPurchase.taxRate]);

  const formatCurrency = (val: number) => fmtMoney(val);

  const handleFileChange = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (file) {
      await processFile(file);
    }
  };

  const processFile = async (file: File) => {
    setIsScanning(true);
    try {
      const reader = new FileReader();
      const base64Promise = new Promise<string>((resolve, reject) => {
        const timeout = setTimeout(() => reject(new Error(t('purchases.errorFileTimeout'))), 30000);
        reader.onload = () => {
          clearTimeout(timeout);
          const result = reader.result as string;
          const parts = result.split(',');
          if (parts.length < 2) {
            reject(new Error(t('purchases.errorFileFormat')));
            return;
          }
          resolve(parts[1]);
        };
        reader.onerror = () => {
          clearTimeout(timeout);
          reject(new Error(t('purchases.errorFileRead')));
        };
      });
      reader.readAsDataURL(file);
      const base64 = await base64Promise;

      const extracted = await analyzeInvoice(base64, file.type, accLocale, uiLang);

      if (!extracted.isInvoiceLike) {
        const docType = extracted.documentType || 'unknown';
        alert(t('purchases.notInvoiceWarning', { type: docType }));
        return;
      }

      const taxRate = extracted.price > 0 && extracted.taxAmount > 0
        ? `${Math.round((extracted.taxAmount / extracted.price) * 100)}%`
        : defaultTaxRate;

      const newRecord: PurchaseRecord = {
        id: nextPurchaseId(),
        date: extracted.date,
        supplier: extracted.customer,
        quantity: extracted.quantity || '',
        price: extracted.price,
        taxRate,
        invoiceNo: extracted.invoiceNo,
        status: '已收',
        totalWithTax: extracted.totalWithTax || 0,
        unitPriceWithoutTax: extracted.unitPriceWithoutTax || 0,
        taxAmount: extracted.taxAmount || 0,
        amountWithoutTax: extracted.price
      };

      await createPurchase(newRecord);
      setRecords(prev => [newRecord, ...prev]);
      alert(t('purchases.successRecognition'));
    } catch (err) {
      console.error(err);
      alert(t('purchases.errorFailed'));
    } finally {
      setIsScanning(false);
      if (fileInputRef.current) fileInputRef.current.value = '';
    }
  };

  const handleAddSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!newPurchase.supplier || !newPurchase.quantity) {
      alert(t('purchases.errorRequiredFields'));
      return;
    }
    const recordToAdd: PurchaseRecord = { id: nextPurchaseId(), ...newPurchase, status: '已收' };
    try {
      await createPurchase(recordToAdd);
      setRecords(prev => [recordToAdd, ...prev]);
      setShowAddModal(false);
      setNewPurchase({
        date: new Date().toISOString().split('T')[0],
        supplier: '',
        quantity: '',
        price: 0,
        taxRate: defaultTaxRate,
        invoiceNo: '',
        totalWithTax: 0,
        unitPriceWithoutTax: 0,
        taxAmount: 0
      });
    } catch (err) {
      console.error(err);
      alert(t('purchases.errorSaveFailed'));
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
        accept="image/*,application/pdf"
      />

      {/* Header Section */}
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-bold text-[#191918]">{(accLocale !== 'CN') ? taxLabel('pageTitlePurchase') : t('purchases.title')}</h1>
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
            onClick={() => setShowAddModal(true)}
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
              {records.map((row) => {
                const unitPrice = row.unitPriceWithoutTax || (row.pricePerTon || 0);
                const amtWithoutTax = row.amountWithoutTax || row.price;
                const taxAmt = row.taxAmount || 0;
                const totalWT = row.totalWithTax || (amtWithoutTax + taxAmt);
                return (
                <tr key={row.id} className="hover:bg-[#f9f9f8]/30 transition-colors">
                  <td className="px-5 py-5 text-sm text-[#4a4a48] whitespace-nowrap">{row.date}</td>
                  <td className="px-5 py-5 text-sm text-[#191918] font-medium col-name">{row.supplier}</td>
                  <td className="px-5 py-5 text-sm text-[#4a4a48]">{row.unit ? `${row.quantity} ${getProductUnitLabel(row.unit, uiLang)}` : formatLegacyQuantity(row.quantity, productUnit, uiLang)}</td>
                  <td className="px-5 py-5 text-sm text-[#191918] font-medium whitespace-nowrap">{formatCurrency(unitPrice)}</td>
                  <td className="px-5 py-5 text-sm text-[#191918] font-medium whitespace-nowrap">{formatCurrency(amtWithoutTax)}</td>
                  <td className="px-5 py-5 text-sm text-rose-600 font-medium whitespace-nowrap">{formatCurrency(taxAmt)}</td>
                  <td className="px-5 py-5 text-sm text-[#191918] font-bold whitespace-nowrap">{formatCurrency(totalWT)}</td>
                  <td className="px-5 py-5 text-sm text-[#4a4a48]">{row.taxRate}</td>
                  <td className="px-5 py-5 text-sm font-mono text-[#4a4a48] tracking-tight">{row.invoiceNo}</td>
                  <td className="px-5 py-5">
                    <span className="px-2 py-0.5 bg-emerald-500/10 text-emerald-500 border border-emerald-500/20 rounded-md text-[10px] font-bold">
                      {row.status}
                    </span>
                  </td>
                  <td className="px-5 py-5 text-xs font-medium space-x-3">
                    <button
                      onClick={() => {
                        setNewPurchase({ date: row.date, supplier: row.supplier, productId: row.productId || '', quantity: row.quantity, price: row.price, taxRate: row.taxRate, invoiceNo: row.invoiceNo, totalWithTax: row.totalWithTax || 0, unitPriceWithoutTax: row.unitPriceWithoutTax || 0, taxAmount: row.taxAmount || 0 });
                        setShowAddModal(true);
                      }}
                      className="text-primary hover:text-primary-hover transition-colors"
                    >{t('common2.edit')}</button>
                    <button
                      onClick={async () => {
                        try {
                          await deletePurchase(row.id);
                          setRecords(prev => prev.filter(r => r.id !== row.id));
                        } catch (err) {
                          console.error(err);
                          alert(t('purchases.errorDeleteFailed'));
                        }
                      }}
                      className="text-rose-500 hover:text-rose-400 transition-colors"
                    >
                      {t('common2.delete')}
                    </button>
                  </td>
                </tr>
                );
              })}
              {isLoading && (
                <tr>
                  <td colSpan={11} className="px-6 py-12 text-center text-[#5c5c5a] text-sm">
                    <i className="fas fa-spinner animate-spin mr-2"></i>{t('purchases.loading')}
                  </td>
                </tr>
              )}
              {!isLoading && records.length === 0 && (
                <tr>
                  <td colSpan={11} className="px-6 py-12 text-center text-[#5c5c5a] text-sm italic">
                    {accLocale !== 'CN' ? taxLabel('emptyPurchase') : t('purchases.empty')}
                  </td>
                </tr>
              )}
              {/* Summary row */}
              {!isLoading && records.length > 0 && (
                <tr className="bg-[#f9f9f8] border-t-2 border-[#e0ddd5] font-semibold">
                  <td className="px-5 py-4 text-sm text-[#191918]" colSpan={2}>{t('purchases.summary')}</td>
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
          <div className="absolute inset-0 bg-black/40 backdrop-blur-sm" onClick={() => setShowAddModal(false)}></div>
          <div className="relative w-full max-w-xl bg-white border border-[#e0ddd5] rounded-xl overflow-hidden animate-in zoom-in-95 duration-200" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.05)' }}>
            <div className="p-8 border-b border-[#e0ddd5] flex justify-between items-center gap-4">
              <div className="flex-shrink-0">
                <h2 className="text-xl font-bold text-[#191918] whitespace-nowrap">{(accLocale !== 'CN') ? taxLabel('modalTitlePurchase') : t('purchases.modalTitle')}</h2>
                <p className="text-xs text-[#5c5c5a] mt-1">{(accLocale !== 'CN') ? taxLabel('modalSubtitlePurchase') : t('purchases.modalSubtitle')}</p>
              </div>
              <button onClick={() => setShowAddModal(false)} className="flex-shrink-0 text-[#5c5c5a] hover:text-[#191918] transition-colors">
                <i className="fas fa-times text-xl"></i>
              </button>
            </div>

            <form onSubmit={handleAddSubmit} className="p-8 space-y-5">
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
                <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{usZh ? taxLabel('setFormPayeeLabel') : t('purchases.formSupplier')}</label>
                <input
                  type="text"
                  required
                  placeholder={usZh ? taxLabel('setFormPayeePh') : t('purchases.formSupplierPlaceholder')}
                  value={newPurchase.supplier}
                  onChange={(e) => setNewPurchase({ ...newPurchase, supplier: e.target.value })}
                  className="w-full bg-white border border-[#e0ddd5] rounded-xl px-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary text-[#191918] transition-all"
                />
              </div>

              <div className="space-y-2">
                <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{t('products.selectLabel')}</label>
                <select
                  value={newPurchase.productId || ''}
                  onChange={(e) => setNewPurchase({ ...newPurchase, productId: e.target.value })}
                  className="w-full bg-white border border-[#e0ddd5] rounded-xl px-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary text-[#191918] transition-all"
                >
                  <option value="">{t('products.unassigned')}</option>
                  {products.filter(p => p.is_active).map(p => (
                    <option key={p.id} value={p.id}>{p.name}（{getProductUnitLabel(p.unit, uiLang)}）</option>
                  ))}
                </select>
              </div>

              <div className="space-y-2">
                <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{usZh ? taxLabel('setFormQtyLabel') : t('purchases.formQuantity')}</label>
                <input
                  type="text"
                  required
                  placeholder={usZh ? taxLabel('setFormQtyPh') : t('purchases.formQuantityPlaceholder')}
                  value={newPurchase.quantity}
                  onChange={(e) => setNewPurchase({ ...newPurchase, quantity: e.target.value })}
                  className="w-full bg-white border border-[#e0ddd5] rounded-xl px-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary text-[#191918] transition-all"
                />
              </div>

              <div className="grid grid-cols-2 gap-4">
                <div className="space-y-2">
                  <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{accLocale !== 'CN' ? taxLabel('headerAmount') : t('purchases.formPrice')}</label>
                  <div className="relative">
                    <span className="absolute left-4 top-1/2 -translate-y-1/2 text-[#5c5c5a] text-sm">{currSym}</span>
                    <input
                      type="number"
                      required
                      step="0.01"
                      value={newPurchase.price || ''}
                      onChange={(e) => setNewPurchase({ ...newPurchase, price: parseFloat(e.target.value) || 0 })}
                      className={`w-full bg-white border border-[#e0ddd5] rounded-xl ${moneyPad} pr-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary text-[#191918] transition-all`}
                    />
                  </div>
                </div>
                <div className="space-y-2">
                  <label className="text-[10px] font-bold text-[#5c5c5a] tracking-widest">{taxLabel('formTaxRate')}</label>
                  <select
                    value={newPurchase.taxRate}
                    onChange={(e) => setNewPurchase({ ...newPurchase, taxRate: e.target.value })}
                    className="w-full bg-white border border-[#e0ddd5] rounded-xl px-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary text-[#191918] transition-all appearance-none"
                  >
                    {taxRateOptions.map(opt => (
                      <option key={opt.value} value={opt.value}>{t(opt.labelKey)}</option>
                    ))}
                  </select>
                </div>
              </div>

              <div className="grid grid-cols-3 gap-4">
                <div className="space-y-2">
                  <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{accLocale !== 'CN' ? taxLabel('headerUnitPrice') : t('purchases.formUnitPrice')}</label>
                  <div className="relative">
                    <span className="absolute left-4 top-1/2 -translate-y-1/2 text-[#5c5c5a] text-sm">{currSym}</span>
                    <input
                      type="number"
                      step="0.01"
                      value={newPurchase.unitPriceWithoutTax || ''}
                      onChange={(e) => setNewPurchase({ ...newPurchase, unitPriceWithoutTax: parseFloat(e.target.value) || 0 })}
                      className={`w-full bg-white border border-[#e0ddd5] rounded-xl ${moneyPad} pr-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary text-[#191918] transition-all`}
                      placeholder={t('common2.optional')}
                    />
                  </div>
                </div>
                <div className="space-y-2">
                  <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{t('purchases.formTaxAmount')}</label>
                  <div className="relative">
                    <span className="absolute left-4 top-1/2 -translate-y-1/2 text-[#5c5c5a] text-sm">{currSym}</span>
                    <input
                      type="number"
                      step="0.01"
                      value={newPurchase.taxAmount || ''}
                      onChange={(e) => setNewPurchase({ ...newPurchase, taxAmount: parseFloat(e.target.value) || 0 })}
                      className={`w-full bg-white border border-[#e0ddd5] rounded-xl ${moneyPad} pr-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary text-[#191918] transition-all`}
                      placeholder={t('common2.optional')}
                    />
                  </div>
                </div>
                <div className="space-y-2">
                  <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">{t('purchases.formTotalWithTax')}</label>
                  <div className="relative">
                    <span className="absolute left-4 top-1/2 -translate-y-1/2 text-[#5c5c5a] text-sm">{currSym}</span>
                    <input
                      type="number"
                      step="0.01"
                      value={newPurchase.totalWithTax || ''}
                      onChange={(e) => setNewPurchase({ ...newPurchase, totalWithTax: parseFloat(e.target.value) || 0 })}
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
                  {t('purchases.formCancel')}
                </button>
                <button
                  type="submit"
                  className="flex-2 px-10 py-4 bg-primary hover:bg-primary-hover text-white font-bold rounded-xl transition-all active:scale-95" style={{ boxShadow: '0 4px 16px rgba(39,76,146,0.15)' }}
                >
                  {t('purchases.formSubmit')}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}
    </div>
  );
};

export default PurchaseAndInputPage;
