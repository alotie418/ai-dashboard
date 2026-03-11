// API client for Cloudflare Worker + D1 persistence
// Handles field mapping between frontend interfaces and D1 schema

const API_BASE = (import.meta.env.VITE_API_BASE_URL as string) || '';
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
  taxRate?: string;
  amountWithoutTax?: number;
  taxAmount?: number;
  pricePerTon?: number;
  totalWithTax?: number;
  unitPriceWithoutTax?: number;
  paymentStatus?: string;
  paidAmount?: number;
  dueDate?: string;
  paymentDate?: string;
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
  amountWithoutTax?: number;
  taxAmount?: number;
  pricePerTon?: number;
  totalWithTax?: number;
  unitPriceWithoutTax?: number;
  paymentStatus?: string;
  paidAmount?: number;
  dueDate?: string;
  paymentDate?: string;
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
  payment_status?: string;
  paid_amount?: number;
  due_date?: string;
  payment_date?: string;
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
  payment_status?: string;
  paid_amount?: number;
  due_date?: string;
  payment_date?: string;
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
  const taxRate = parseTaxRatePercent((r as any).taxRate || '13%');
  const amountWithoutTax = r.amountWithoutTax || r.price;
  // Prefer actual values from OCR/manual entry over computed
  const taxAmount = r.taxAmount || Math.round(amountWithoutTax * (taxRate / 100) * 100) / 100;
  const totalAmount = r.totalWithTax || Math.round((amountWithoutTax + taxAmount) * 100) / 100;
  const pricePerTon = r.unitPriceWithoutTax || (tons > 0 ? Math.round((amountWithoutTax / tons) * 100) / 100 : 0);

  return {
    id: r.id,
    date: r.date,
    customer: r.customer,
    tons,
    pricePerTon,
    totalAmount,
    amountWithoutTax: Math.round(amountWithoutTax * 100) / 100,
    taxAmount,
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
    price: a.amountWithoutTax || a.totalAmount,
    shipping: a.shippingCost || 0,
    invoiceNo: a.invoiceNumber || '',
    status: (a.invoiceStatus === '已开' ? '已开' : '待开') as '已开' | '待开',
    taxRate: `${a.taxRate || 13}%`,
    amountWithoutTax: a.amountWithoutTax,
    taxAmount: a.taxAmount,
    pricePerTon: a.pricePerTon,
    totalWithTax: a.totalAmount,
    unitPriceWithoutTax: a.pricePerTon,
    paymentStatus: a.payment_status || 'unpaid',
    paidAmount: a.paid_amount || 0,
    dueDate: a.due_date || '',
    paymentDate: a.payment_date || '',
  };
}

function toApiPurchase(r: PurchaseRecord): ApiPurchaseRecord {
  const tons = parseTons(r.quantity);
  const taxRate = parseTaxRatePercent(r.taxRate);
  const amountWithoutTax = r.amountWithoutTax || r.price;
  // Prefer actual values from OCR/manual entry over computed
  const taxAmount = r.taxAmount || Math.round(amountWithoutTax * (taxRate / 100) * 100) / 100;
  const totalAmount = r.totalWithTax || Math.round((amountWithoutTax + taxAmount) * 100) / 100;
  const pricePerTon = r.unitPriceWithoutTax || (tons > 0 ? Math.round((amountWithoutTax / tons) * 100) / 100 : 0);

  return {
    id: r.id,
    date: r.date,
    supplier: r.supplier,
    tons,
    pricePerTon,
    totalAmount,
    amountWithoutTax: Math.round(amountWithoutTax * 100) / 100,
    taxAmount,
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
    price: a.amountWithoutTax || a.totalAmount,
    taxRate: `${a.taxRate || 13}%`,
    invoiceNo: a.invoiceNumber || '',
    status: a.invoiceStatus || '已收',
    amountWithoutTax: a.amountWithoutTax,
    taxAmount: a.taxAmount,
    pricePerTon: a.pricePerTon,
    totalWithTax: a.totalAmount,
    unitPriceWithoutTax: a.pricePerTon,
    paymentStatus: a.payment_status || 'unpaid',
    paidAmount: a.paid_amount || 0,
    dueDate: a.due_date || '',
    paymentDate: a.payment_date || '',
  };
}

// ==================== API Calls ====================

const API_TIMEOUT_MS = 90000; // #8: 90s default request timeout

async function apiFetch<T>(path: string, options?: RequestInit & { signal?: AbortSignal }): Promise<T> {
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
  };
  if (API_TOKEN) {
    headers['Authorization'] = `Bearer ${API_TOKEN}`;
  }

  // #8: Compose user signal with timeout signal
  const timeoutController = new AbortController();
  const timeoutId = setTimeout(() => timeoutController.abort(), API_TIMEOUT_MS);

  // If user provided a signal, abort on either user cancel OR timeout
  const userSignal = options?.signal;
  const onUserAbort = () => timeoutController.abort();
  if (userSignal) {
    if (userSignal.aborted) { clearTimeout(timeoutId); throw new Error('cancelled'); }
    userSignal.addEventListener('abort', onUserAbort, { once: true });
  }

  try {
    const res = await fetch(`${API_BASE}${path}`, {
      ...options,
      signal: timeoutController.signal,
      headers: {
        ...headers,
        ...(options?.headers || {}),
      },
    });
    if (!res.ok) {
      const err = await res.text();
      throw new Error(`API ${options?.method || 'GET'} ${path} failed (${res.status}): ${err.slice(0, 300)}`);
    }
    return res.json() as Promise<T>;
  } catch (err: any) {
    // Distinguish timeout from user cancel
    if (userSignal?.aborted) throw new Error('cancelled');
    if (err?.name === 'AbortError') throw new Error(`请求超时 (${API_TIMEOUT_MS / 1000}s): ${path}`);
    throw err;
  } finally {
    clearTimeout(timeoutId);
    if (userSignal) userSignal.removeEventListener('abort', onUserAbort);
  }
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

export async function updateSale(id: string, record: SalesRecord): Promise<void> {
  await apiFetch(`/api/sales/${encodeURIComponent(id)}`, {
    method: 'PUT',
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

export async function updatePurchase(id: string, record: PurchaseRecord): Promise<void> {
  await apiFetch(`/api/purchases/${encodeURIComponent(id)}`, {
    method: 'PUT',
    body: JSON.stringify(toApiPurchase(record)),
  });
}

export async function deletePurchase(id: string): Promise<void> {
  await apiFetch(`/api/purchases/${encodeURIComponent(id)}`, {
    method: 'DELETE',
  });
}

// --- Dashboard ---

export interface DashboardResponse {
  metrics: {
    inventoryTons: number;
    purchaseTotalTons: number;
    purchaseTotalAmount: number;
    salesTotalTons: number;
    salesTotalAmount: number;
    avgCostPerTon: number;
  };
  monthlyPerformance: import('../types').ChartData[];
  financialStatement: import('../types').FinancialStatementData;
  vatStatistics: import('../types').VATData;
  taxInclusiveSummary: import('../types').TaxInclusiveSummaryData;
}

export async function fetchDashboardData(year?: string): Promise<DashboardResponse> {
  const params = year ? `?year=${year}` : '';
  return apiFetch<DashboardResponse>(`/api/dashboard${params}`);
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

export async function searchBrave(q: string, count = 15, signal?: AbortSignal): Promise<any> {
  return apiFetch('/api/search/brave', {
    method: 'POST',
    body: JSON.stringify({ q, count }),
    signal,
  });
}

export async function searchTavily(query: string, maxResults = 15, signal?: AbortSignal): Promise<any> {
  return apiFetch('/api/search/tavily', {
    method: 'POST',
    body: JSON.stringify({ query, search_depth: 'advanced', max_results: maxResults }),
    signal,
  });
}

export async function searchGemini(query: string, signal?: AbortSignal): Promise<import('../types').GeminiSearchProxyResponse> {
  return apiFetch('/api/search/gemini', {
    method: 'POST',
    body: JSON.stringify({ query }),
    signal,
  });
}

export async function searchDirect(query: string, signal?: AbortSignal): Promise<import('../types').DirectSearchResponse> {
  return apiFetch('/api/search/direct', {
    method: 'POST',
    body: JSON.stringify({ query }),
    signal,
  });
}

export async function searchInternational(query: string, signal?: AbortSignal): Promise<import('../types').InternationalSearchResponse> {
  return apiFetch('/api/search/international', {
    method: 'POST',
    body: JSON.stringify({ query }),
    signal,
  });
}

export async function searchEcommerce(query: string, signal?: AbortSignal): Promise<import('../types').EcommerceSearchResponse> {
  return apiFetch('/api/search/ecommerce', {
    method: 'POST',
    body: JSON.stringify({ query }),
    signal,
  });
}

export async function mergeSearch(
  data: import('../types').MergeSearchRequest,
  signal?: AbortSignal
): Promise<import('../types').MarketSearchResponse> {
  return apiFetch('/api/search/merge', {
    method: 'POST',
    body: JSON.stringify(data),
    signal,
  });
}

// --- Batch Import (Feature 2) ---

export async function batchCreateSales(records: any[]): Promise<import('../types').BatchImportResult> {
  return apiFetch('/api/sales/batch', {
    method: 'POST',
    body: JSON.stringify({ records }),
  });
}

export async function batchCreatePurchases(records: any[]): Promise<import('../types').BatchImportResult> {
  return apiFetch('/api/purchases/batch', {
    method: 'POST',
    body: JSON.stringify({ records }),
  });
}

// --- Price History (Feature 1) ---

export async function savePriceHistory(query: string, prices: any[]): Promise<void> {
  await apiFetch('/api/price-history', {
    method: 'POST',
    body: JSON.stringify({
      query,
      search_date: new Date().toISOString().split('T')[0],
      prices,
    }),
  });
}

export async function fetchPriceHistory(query: string, days = 30): Promise<import('../types').PriceHistoryResponse> {
  return apiFetch(`/api/price-history?query=${encodeURIComponent(query)}&days=${days}`);
}

// --- Payment Tracking (Feature 3) ---

export async function recordSalePayment(id: string, data: import('../types').PaymentUpdate): Promise<void> {
  await apiFetch(`/api/sales/${encodeURIComponent(id)}/payment`, {
    method: 'PUT',
    body: JSON.stringify(data),
  });
}

export async function recordPurchasePayment(id: string, data: import('../types').PaymentUpdate): Promise<void> {
  await apiFetch(`/api/purchases/${encodeURIComponent(id)}/payment`, {
    method: 'PUT',
    body: JSON.stringify(data),
  });
}

export async function fetchReceivablesSummary(): Promise<import('../types').ReceivablesSummary> {
  return apiFetch('/api/receivables/summary');
}

export async function fetchPayablesSummary(): Promise<import('../types').PayablesSummary> {
  return apiFetch('/api/payables/summary');
}

// --- Alerts (Feature 4) ---

export async function fetchAlerts(unreadOnly = false, limit = 20): Promise<import('../types').Alert[]> {
  return apiFetch(`/api/alerts?unread_only=${unreadOnly}&limit=${limit}`);
}

export async function fetchAlertCount(): Promise<import('../types').AlertsCountResponse> {
  return apiFetch('/api/alerts/count');
}

export async function markAlertRead(id: number): Promise<void> {
  await apiFetch(`/api/alerts/${id}/read`, { method: 'PUT' });
}

export async function markAllAlertsRead(): Promise<void> {
  await apiFetch('/api/alerts/read-all', { method: 'PUT' });
}

export async function dismissAlert(id: number): Promise<void> {
  await apiFetch(`/api/alerts/${id}`, { method: 'DELETE' });
}

// --- Agentic RAG (Market Research) ---

export async function agentPlan(
  query: string,
  signal?: AbortSignal
): Promise<import('../types').PlanResult> {
  return apiFetch('/api/agent/plan', {
    method: 'POST',
    body: JSON.stringify({ query }),
    signal,
  });
}

export async function agentRank(
  query: string,
  results: any[],
  signal?: AbortSignal
): Promise<import('../types').RankResult> {
  return apiFetch('/api/agent/rank', {
    method: 'POST',
    body: JSON.stringify({ query, results }),
    signal,
  });
}

export async function agentExtract(
  query: string,
  searchResults: any[],
  signal?: AbortSignal
): Promise<import('../types').ExtractResult> {
  return apiFetch('/api/agent/extract', {
    method: 'POST',
    body: JSON.stringify({ query, search_results: searchResults }),
    signal,
  });
}

export async function agentSynthesize(
  query: string,
  questionType: string,
  evidencePool: import('../types').Evidence[],
  iteration: number,
  signal?: AbortSignal
): Promise<import('../types').SynthesisResult> {
  return apiFetch('/api/agent/synthesize', {
    method: 'POST',
    body: JSON.stringify({ query, question_type: questionType, evidence_pool: evidencePool, iteration }),
    signal,
  });
}

export async function agentCritique(
  query: string,
  questionType: string,
  synthesis: import('../types').SynthesisResult,
  evidencePool: import('../types').Evidence[],
  iteration: number,
  maxIterations: number,
  signal?: AbortSignal
): Promise<import('../types').CritiqueResult> {
  return apiFetch('/api/agent/critique', {
    method: 'POST',
    body: JSON.stringify({
      query,
      question_type: questionType,
      synthesis,
      evidence_pool: evidencePool,
      iteration,
      max_iterations: maxIterations,
    }),
    signal,
  });
}
