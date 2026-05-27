
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

function isElectron(): boolean {
  return typeof window !== 'undefined' && !!(window as any).electronAPI?.isElectron;
}

export const analyzeInvoice = async (
  base64Data: string,
  mimeType: string,
  accountingLocale?: string,
  uiLanguage?: string,
): Promise<ExtractedInvoice> => {
  const body = { base64Data, mimeType, accountingLocale, uiLanguage };

  let raw: any;
  if (isElectron()) {
    raw = await (window as any).electronAPI.invoke('api:request', {
      method: 'POST',
      path: '/api/ai/ocr',
      body,
    });
  } else {
    const response = await fetch('/api/ai/ocr', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'same-origin',
      body: JSON.stringify(body),
    });
    if (!response.ok) {
      const err = await response.json().catch(() => ({ error: 'Unknown error' }));
      throw new Error(err.error || `OCR failed (${response.status})`);
    }
    raw = await response.json();
  }

  return normalizeToLegacy(raw, accountingLocale || 'CN');
};
