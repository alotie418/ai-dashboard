// API client for Cloudflare Worker + D1 persistence
// Handles field mapping between frontend interfaces and D1 schema

const API_BASE = (import.meta.env.VITE_API_BASE_URL as string) || 'https://api.randomabc987.icu';
const API_TOKEN = (import.meta.env.VITE_API_TOKEN as string) || '';

// ==================== Types ====================

// Frontend interfaces (match component definitions)
export interface SalesRecord {
  id: string;
  date: string;
  customer: string;
  quantity: string;
  price: number;
  shipping: number;
  invoiceNo: string;
  status: '已开' | '待开';
}

export interface PurchaseRecord {
  id: string;
  date: string;
  supplier: string;
  quantity: string;
  price: number;
  taxRate: string;
  invoiceNo: string;
  status: string;
}

export interface AppSettings {
  company_info?: {
    name: string;
    creditCode: string;
    legalPerson: string;
    industry: string;
    address: string;
  };
  tax_auto_auth?: boolean;
  ai_auto_insight?: boolean;
  notifications?: {
    stockZero: boolean;
    taxDeviation: boolean;
    priceVolatility: boolean;
    monthlyReport: boolean;
  };
}

// D1 schema types (what the Worker expects)
interface ApiSalesRecord {
  id: string;
  date: string;
  customer: string;
  tons: number;
  pricePerTon: number;
  totalAmount: number;
  amountWithoutTax: number;
  taxAmount: number;
  taxRate: number;
  shippingCost: number;
  invoiceNumber: string;
  invoiceStatus: string;
  created_at?: string;
}

interface ApiPurchaseRecord {
  id: string;
  date: string;
  supplier: string;
  tons: number;
  pricePerTon: number;
  totalAmount: number;
  amountWithoutTax: number;
  taxAmount: number;
  taxRate: number;
  invoiceNumber: string;
  invoiceStatus: string;
  created_at?: string;
}

// ==================== Helpers ====================

function parseTons(quantity: string): number {
  const match = quantity.match(/[\d.]+/);
  return match ? parseFloat(match[0]) : 0;
}

function parseTaxRatePercent(taxRate: string): number {
  const match = taxRate.match(/[\d.]+/);
  return match ? parseFloat(match[0]) : 13;
}

// ==================== Field Mapping ====================

function toApiSales(r: SalesRecord): ApiSalesRecord {
  const tons = parseTons(r.quantity);
  const totalAmount = r.price;
  const taxRate = 13;
  const amountWithoutTax = totalAmount / (1 + taxRate / 100);
  const taxAmount = totalAmount - amountWithoutTax;
  const pricePerTon = tons > 0 ? totalAmount / tons : 0;

  return {
    id: r.id,
    date: r.date,
    customer: r.customer,
    tons,
    pricePerTon: Math.round(pricePerTon * 100) / 100,
    totalAmount,
    amountWithoutTax: Math.round(amountWithoutTax * 100) / 100,
    taxAmount: Math.round(taxAmount * 100) / 100,
    taxRate,
    shippingCost: r.shipping,
    invoiceNumber: r.invoiceNo,
    invoiceStatus: r.status,
  };
}

function fromApiSales(a: ApiSalesRecord): SalesRecord {
  return {
    id: a.id,
    date: a.date,
    customer: a.customer || '',
    quantity: a.tons ? `${a.tons}吨` : '0吨',
    price: a.totalAmount,
    shipping: a.shippingCost || 0,
    invoiceNo: a.invoiceNumber || '',
    status: (a.invoiceStatus === '已开' ? '已开' : '待开') as '已开' | '待开',
  };
}

function toApiPurchase(r: PurchaseRecord): ApiPurchaseRecord {
  const tons = parseTons(r.quantity);
  const totalAmount = r.price;
  const taxRate = parseTaxRatePercent(r.taxRate);
  const amountWithoutTax = totalAmount / (1 + taxRate / 100);
  const taxAmount = totalAmount - amountWithoutTax;
  const pricePerTon = tons > 0 ? totalAmount / tons : 0;

  return {
    id: r.id,
    date: r.date,
    supplier: r.supplier,
    tons,
    pricePerTon: Math.round(pricePerTon * 100) / 100,
    totalAmount,
    amountWithoutTax: Math.round(amountWithoutTax * 100) / 100,
    taxAmount: Math.round(taxAmount * 100) / 100,
    taxRate,
    invoiceNumber: r.invoiceNo,
    invoiceStatus: r.status,
  };
}

function fromApiPurchase(a: ApiPurchaseRecord): PurchaseRecord {
  return {
    id: a.id,
    date: a.date,
    supplier: a.supplier || '',
    quantity: a.tons ? `${a.tons}吨` : '0吨',
    price: a.totalAmount,
    taxRate: `${a.taxRate || 13}%`,
    invoiceNo: a.invoiceNumber || '',
    status: a.invoiceStatus || '已收',
  };
}

// ==================== API Calls ====================

async function apiFetch<T>(path: string, options?: RequestInit): Promise<T> {
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
  };
  if (API_TOKEN) {
    headers['Authorization'] = `Bearer ${API_TOKEN}`;
  }
  const res = await fetch(`${API_BASE}${path}`, {
    ...options,
    headers: {
      ...headers,
      ...(options?.headers || {}),
    },
  });
  if (!res.ok) {
    const err = await res.text();
    throw new Error(`API error ${res.status}: ${err}`);
  }
  return res.json() as Promise<T>;
}

// --- Sales ---

export async function fetchSales(): Promise<SalesRecord[]> {
  const results = await apiFetch<ApiSalesRecord[]>('/api/sales');
  return results.map(fromApiSales);
}

export async function createSale(record: SalesRecord): Promise<void> {
  await apiFetch('/api/sales', {
    method: 'POST',
    body: JSON.stringify(toApiSales(record)),
  });
}

export async function deleteSale(id: string): Promise<void> {
  await apiFetch(`/api/sales/${encodeURIComponent(id)}`, {
    method: 'DELETE',
  });
}

// --- Purchases ---

export async function fetchPurchases(): Promise<PurchaseRecord[]> {
  const results = await apiFetch<ApiPurchaseRecord[]>('/api/purchases');
  return results.map(fromApiPurchase);
}

export async function createPurchase(record: PurchaseRecord): Promise<void> {
  await apiFetch('/api/purchases', {
    method: 'POST',
    body: JSON.stringify(toApiPurchase(record)),
  });
}

export async function deletePurchase(id: string): Promise<void> {
  await apiFetch(`/api/purchases/${encodeURIComponent(id)}`, {
    method: 'DELETE',
  });
}

// --- Settings ---

export async function fetchSettings(): Promise<AppSettings> {
  return apiFetch<AppSettings>('/api/settings');
}

export async function saveSettings(settings: AppSettings): Promise<void> {
  await apiFetch('/api/settings', {
    method: 'PUT',
    body: JSON.stringify(settings),
  });
}

// --- Search Proxy ---

export async function searchBrave(q: string, count = 15): Promise<any> {
  return apiFetch('/api/search/brave', {
    method: 'POST',
    body: JSON.stringify({ q, count }),
  });
}

export async function searchTavily(query: string, maxResults = 15): Promise<any> {
  return apiFetch('/api/search/tavily', {
    method: 'POST',
    body: JSON.stringify({ query, search_depth: 'advanced', max_results: maxResults }),
  });
}
