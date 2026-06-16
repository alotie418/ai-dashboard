import type { PurchaseRecord, SalesRecord } from './api';

export interface ExtractedInvoice {
  isInvoiceLike: boolean;
  documentType?: string;
  reason?: string;
  date: string;
  currency: string;
  invoiceType: string;
  // CN fields
  sellerName?: string;
  buyerName?: string;
  netAmount?: number;
  taxRate?: string;
  taxAmount?: number;
  grossAmount?: number;
  invoiceNumber?: string;
  quantity?: string;
  unitPrice?: number;
  shipping?: number;
  // US fields
  vendorName?: string;
  subtotal?: number;
  salesTax?: number;
  tip?: number;
  total?: number;
  receiptNumber?: string;
  // EU fields
  sellerVatId?: string;
  buyerVatId?: string;
  vatRate?: string;
  vatAmount?: number;
  reverseCharge?: boolean;
  // JP fields
  registrationNumber?: string;
  // KR fields
  businessRegNumber?: string;
  supplyAmount?: number;
  // TW fields
  sellerTaxId?: string;
  buyerTaxId?: string;
  salesAmount?: number;
  businessTax?: number;
  // Legacy compat — mapped by normalizeResult
  customer: string;
  price: number;
  invoiceNo: string;
  totalWithTax: number;
  unitPriceWithoutTax: number;
}

// Normalize locale-specific result to legacy fields used by Purchase/Sales pages
export function normalizeToLegacy(raw: any, accountingLocale: string): ExtractedInvoice {
  const base = {
    ...raw,
    isInvoiceLike: raw.isInvoiceLike !== false,
  };

  if (!base.isInvoiceLike) {
    return { ...base, customer: '', price: 0, invoiceNo: '', totalWithTax: 0, unitPriceWithoutTax: 0, taxAmount: 0, date: '', currency: '', invoiceType: '' };
  }

  switch (accountingLocale) {
    case 'US':
      base.customer = raw.vendorName || '';
      base.price = raw.subtotal || 0;
      base.taxAmount = raw.salesTax || 0;
      base.invoiceNo = raw.receiptNumber || '';
      base.totalWithTax = raw.total || 0;
      base.unitPriceWithoutTax = raw.unitPrice || 0;
      base.shipping = raw.shipping || 0;
      break;
    case 'KR':
      base.customer = raw.sellerName || '';
      base.price = raw.supplyAmount || 0;
      base.taxAmount = raw.vatAmount || 0;
      base.invoiceNo = raw.invoiceNumber || '';
      base.totalWithTax = raw.total || 0;
      base.unitPriceWithoutTax = raw.unitPrice || 0;
      base.shipping = 0;
      break;
    case 'TW':
      base.customer = raw.sellerName || '';
      base.price = raw.salesAmount || 0;
      base.taxAmount = raw.businessTax || 0;
      base.invoiceNo = raw.invoiceNumber || '';
      base.totalWithTax = raw.total || 0;
      base.unitPriceWithoutTax = raw.unitPrice || 0;
      base.shipping = 0;
      break;
    case 'EU':
      base.customer = raw.sellerName || '';
      base.price = raw.netAmount || 0;
      base.taxAmount = raw.vatAmount || 0;
      base.invoiceNo = raw.invoiceNumber || '';
      base.totalWithTax = raw.grossAmount || 0;
      base.unitPriceWithoutTax = raw.unitPrice || 0;
      base.shipping = 0;
      break;
    default: // CN, JP
      base.customer = raw.sellerName || raw.buyerName || '';
      base.price = raw.netAmount || 0;
      base.taxAmount = raw.taxAmount || 0;
      base.invoiceNo = raw.invoiceNumber || '';
      base.totalWithTax = raw.grossAmount || 0;
      base.unitPriceWithoutTax = raw.unitPrice || 0;
      base.shipping = raw.shipping || 0;
      break;
  }

  return base as ExtractedInvoice;
}

export const analyzeInvoice = async (
  base64Data: string,
  mimeType: string,
  accountingLocale?: string,
  uiLanguage?: string,
): Promise<ExtractedInvoice> => {
  const body = { base64Data, mimeType, accountingLocale, uiLanguage };

  // 桌面版：OCR 走 Electron IPC（api:request → /api/ai/ocr），不经过 HTTP
  const raw = await (window as any).electronAPI.invoke('api:request', {
    method: 'POST',
    path: '/api/ai/ocr',
    body,
  });

  return normalizeToLegacy(raw, accountingLocale || 'CN');
};

// PR-3c: map an OCR ExtractedInvoice (already normalized to legacy fields) onto the Purchase / Sales
// form state. PURE (no React, no Date) so it is unit-testable. Missing text → ''; missing numbers → 0;
// taxRate is derived from the extracted tax/amount when both are present, else the page's default.
// The page applies the result with setState ONLY (no DB write); the page's existing auto-calc effect
// then re-derives price/taxAmount/unitPrice from totalWithTax+quantity+taxRate (no calc duplicated here).
export function extractedToPurchaseForm(
  e: ExtractedInvoice,
  defaultTaxRate: string,
): Omit<PurchaseRecord, 'status' | 'id'> {
  const taxRate = e.price > 0 && (e.taxAmount || 0) > 0
    ? `${Math.round(((e.taxAmount || 0) / e.price) * 100)}%`
    : defaultTaxRate;
  return {
    date: e.date || '',
    supplier: e.customer || '',
    quantity: e.quantity || '',
    price: e.price || 0,
    taxRate,
    invoiceNo: e.invoiceNo || '',
    totalWithTax: e.totalWithTax || 0,
    unitPriceWithoutTax: e.unitPriceWithoutTax || 0,
    taxAmount: e.taxAmount || 0,
  };
}

export function extractedToSalesForm(
  e: ExtractedInvoice,
  fallbackTaxRate: string,
): Omit<SalesRecord, 'status' | 'id'> {
  const taxRate = e.price > 0 && (e.taxAmount || 0) > 0
    ? `${Math.round(((e.taxAmount || 0) / e.price) * 100)}%`
    : fallbackTaxRate;
  return {
    date: e.date || '',
    customer: e.customer || '',
    quantity: e.quantity || '',
    price: e.price || 0,
    shipping: e.shipping || 0,
    invoiceNo: e.invoiceNo || '',
    totalWithTax: e.totalWithTax || 0,
    unitPriceWithoutTax: e.unitPriceWithoutTax || 0,
    taxAmount: e.taxAmount || 0,
    taxRate,
  };
}
