// API client — 桌面版走 Electron IPC，Web 版仍走 fetch（开发兼容）
// Field mapping 在下方保持不变

const API_BASE = '';

// 判断是否运行在 Electron 桌面壳内
function isElectron(): boolean {
  return typeof window !== 'undefined' && !!(window as any).electronAPI?.isElectron;
}

function electronInvoke<T = any>(channel: string, payload?: any): Promise<T> {
  if (!isElectron()) throw new Error('该接口仅在桌面版可用');
  return (window as any).electronAPI.invoke(channel, payload);
}

// ==================== 数据备份 / 恢复（仅桌面版 · 本地 SQLite）====================
// 备份/恢复直连 app:* IPC（非 REST 路由），仅在 Electron 桌面壳内可用。

/** 是否运行在桌面版（决定数据备份按钮是否可用） */
export function isDesktop(): boolean {
  return isElectron();
}

export interface BackupResult {
  ok: boolean;
  path?: string;   // 成功时：备份文件保存路径
  error?: string;  // 失败时：错误码
}

export interface RestoreResult {
  ok: boolean;
  restoredFrom?: string;    // 成功时：恢复所用的备份文件
  autoBackupPath?: string;  // 成功时：恢复前自动备份当前库的保存路径
  error?: string;           // 失败时：错误码（INVALID_FILE / INTEGRITY_FAILED / NEWER_VERSION / AUTOBACKUP_FAILED / ...）
}

/** 备份数据库：弹保存框，checkpoint 后拷出主 .db。ok=false 且无 error 表示用户取消。 */
export function backupDatabase(): Promise<BackupResult> {
  return electronInvoke<BackupResult>('app:exportDb');
}

/** 恢复数据库：弹选择框，校验→自动备份当前库→原子替换→清 wal/shm。ok=false 且无 error 表示用户取消。 */
export function restoreDatabase(): Promise<RestoreResult> {
  return electronInvoke<RestoreResult>('app:importDb');
}

/** 立即重启应用（恢复完成后加载新库）。开发模式不真正重启，返回 devMode=true 由 UI 提示手动重启。 */
export function relaunchApp(): Promise<{ ok: boolean; devMode?: boolean }> {
  return electronInvoke<{ ok: boolean; devMode?: boolean }>('app:relaunch');
}

// ==================== 财务报表 PDF 导出（仅桌面版）====================

export interface PdfExportResult {
  ok: boolean;
  path?: string;   // 成功时：PDF 保存路径
  error?: string;  // 失败时：错误码
}

/**
 * 导出财务报表 PDF：前端传入自包含打印 HTML，主进程离屏渲染 + printToPDF + 另存。
 * ok=false 且无 error 表示用户取消保存框。
 */
export function exportReportPdf(html: string, defaultFileName?: string): Promise<PdfExportResult> {
  return electronInvoke<PdfExportResult>('app:exportReportPdf', { html, defaultFileName });
}

// ==================== AI Providers 管理（仅桌面版）====================

import type { AIProviderConfig, AIProviderId, SaveProviderRequest, TestProviderRequest } from '../types';

export function listProviders(): Promise<AIProviderConfig[]> {
  return electronInvoke<AIProviderConfig[]>('providers:list');
}

export function hasAnyProvider(): Promise<boolean> {
  return electronInvoke<boolean>('providers:hasAny');
}

export function saveProvider(payload: SaveProviderRequest): Promise<{ success: boolean }> {
  return electronInvoke('providers:save', payload);
}

export function removeProvider(provider: AIProviderId): Promise<{ success: boolean }> {
  return electronInvoke('providers:remove', { provider });
}

export function setDefaultProvider(provider: AIProviderId): Promise<{ success: boolean }> {
  return electronInvoke('providers:setDefault', { provider });
}

export interface TestProviderResult {
  ok: boolean;
  error?: string;
  status?: number;     // HTTP 状态码（如 401/403/404/429）
  code?: string;       // 服务商错误码（如 invalid_api_key / model_not_found）
  providerMessage?: string; // 服务商原始 message
  rawMessage?: string; // 完整错误字符串（含状态码、code、friendly）
}

export function testProvider(payload: TestProviderRequest): Promise<TestProviderResult> {
  return electronInvoke<TestProviderResult>('providers:test', payload);
}

// ==================== Categories（国际化数据模型 v4）====================
// AIProviderId is already imported at the top of this file; no re-import here.

import { JP_TXN_CATEGORY_LABELS, EU_TXN_CATEGORY_LABELS, KR_TXN_CATEGORY_LABELS, TW_TXN_CATEGORY_LABELS, CN_TXN_CATEGORY_LABELS } from '../components/accountingLocaleConfig';

export type AccountingLocale = 'CN' | 'US' | 'JP' | 'EU' | 'KR' | 'TW';
export type CategoryType = 'income' | 'expense';

export interface Category {
  id: string;
  locale: AccountingLocale;
  type: CategoryType;
  slug: string;
  label_zh_cn: string;
  label_zh_tw: string | null;
  label_en: string;
  label_ja: string | null;
  label_ko: string | null;
  label_fr: string | null;
  schedule_line: string | null;
  is_deductible: boolean;
  deductible_pct: number;
  parent_id: string | null;
  sort_order: number;
  is_system: boolean;
  displayLabel: string; // 由后端按当前 lang 计算填入
}

export interface CategoryUpsert {
  locale: AccountingLocale;
  type: CategoryType;
  slug: string;
  label_zh_cn?: string;
  label_zh_tw?: string;
  label_en: string;
  label_ja?: string;
  label_ko?: string;
  label_fr?: string;
  schedule_line?: string;
  is_deductible?: boolean;
  deductible_pct?: number;
  parent_id?: string;
  sort_order?: number;
}

// Canonicalize the IRS form-name casing for US category report lines on read, so
// the UI never shows a stale "schedule C" / "SCHEDULE C LINE" / "form 8829" variant
// left over in older seeded DB rows (the committed seed is correct, but INSERT OR
// IGNORE never overwrites pre-existing rows). Only the official form names are
// canonicalized — "Schedule C Line" + line number (8 / 16b / 24a …) and "Form 8829";
// stray double spaces are collapsed. Non-US schedule_line values (e.g. CN 损益表-*)
// don't match and are left untouched. Display-only; category↔line mapping unchanged.
const normalizeScheduleLine = (s: string): string =>
  s.replace(/schedule\s*c\s*line/gi, 'Schedule C Line')
    .replace(/form\s*8829/gi, 'Form 8829')
    .replace(/ {2,}/g, ' ')
    .trim();

export function listCategories(opts: { locale?: AccountingLocale; type?: CategoryType; lang?: string } = {}): Promise<Category[]> {
  const qs = new URLSearchParams();
  if (opts.locale) qs.set('locale', opts.locale);
  if (opts.type) qs.set('type', opts.type);
  if (opts.lang) qs.set('lang', opts.lang);
  // JP/EU/KR + Chinese UI: localize the category dropdown label + report-line display,
  // keyed by the stable slug. This also fixes stale-DB rows (older seeds left raw
  // Japanese 損益計算書/販管費, English EU report lines P&L - … / VAT Return, or Korean
  // KR report lines 손익계산서-… / 판관비-…) since it ignores the stored value. Display
  // only — id/slug and the backend report mapping (by slug) are unchanged. zh-CN/zh-TW only.
  const zhLang = opts.lang === 'zh-CN' || opts.lang === 'zh-TW';
  const catMap = zhLang
    ? (opts.locale === 'JP' ? JP_TXN_CATEGORY_LABELS : opts.locale === 'EU' ? EU_TXN_CATEGORY_LABELS : opts.locale === 'KR' ? KR_TXN_CATEGORY_LABELS : opts.locale === 'TW' ? TW_TXN_CATEGORY_LABELS : opts.locale === 'CN' ? CN_TXN_CATEGORY_LABELS : null)
    : null;
  return apiFetch<Category[]>(`/api/categories${qs.toString() ? '?' + qs.toString() : ''}`)
    .then(cats => cats.map(c => {
      if (catMap) {
        const m = catMap[c.slug];
        if (m) return { ...c, displayLabel: m.label[opts.lang as 'zh-CN' | 'zh-TW'], schedule_line: m.scheduleLine[opts.lang as 'zh-CN' | 'zh-TW'] };
      }
      return c.schedule_line ? { ...c, schedule_line: normalizeScheduleLine(c.schedule_line) } : c;
    }));
}

export function createCategory(payload: CategoryUpsert): Promise<{ success: boolean; id: string }> {
  return apiFetch('/api/categories', { method: 'POST', body: JSON.stringify(payload) });
}

export function updateCategory(id: string, payload: Partial<CategoryUpsert>): Promise<{ success: boolean }> {
  return apiFetch(`/api/categories/${encodeURIComponent(id)}`, { method: 'PUT', body: JSON.stringify(payload) });
}

export function deleteCategory(id: string): Promise<{ success: boolean }> {
  return apiFetch(`/api/categories/${encodeURIComponent(id)}`, { method: 'DELETE' });
}

export function resetCategoriesToDefault(locale: AccountingLocale): Promise<{ success: boolean; removedUserCategories: number }> {
  return apiFetch('/api/categories/reset', { method: 'POST', body: JSON.stringify({ locale }) });
}

// ==================== Products / Service Items（商品/服务项目主数据，Phase 1）====================

export interface Product {
  id: string;
  name: string;
  unit: string;                 // key from PRODUCT_UNIT_KEYS (accountingHelpers)
  default_unit_cost: number;
  is_service: boolean;          // service items are excluded from inventory
  is_active: boolean;
  sort_order: number;
  created_at?: string;
  updated_at?: string;
}

export interface ProductUpsert {
  name: string;
  unit: string;
  default_unit_cost?: number;
  is_service?: boolean;
  is_active?: boolean;
  sort_order?: number;
}

export function listProducts(): Promise<Product[]> {
  return apiFetch<Product[]>('/api/products');
}
export function createProduct(payload: ProductUpsert): Promise<{ success: boolean; id: string }> {
  return apiFetch('/api/products', { method: 'POST', body: JSON.stringify(payload) });
}
export function updateProduct(id: string, payload: Partial<ProductUpsert>): Promise<{ success: boolean }> {
  return apiFetch(`/api/products/${encodeURIComponent(id)}`, { method: 'PUT', body: JSON.stringify(payload) });
}
export function deleteProduct(id: string): Promise<{ success: boolean }> {
  return apiFetch(`/api/products/${encodeURIComponent(id)}`, { method: 'DELETE' });
}

// ==================== Transactions（国际化数据模型 v5，C 阶段）====================

export type TransactionType = 'income' | 'expense';
export type InvoiceStatus = 'issued' | 'pending' | 'n/a';
export type TxPaymentStatus = 'paid' | 'partial' | 'unpaid';

export interface Transaction {
  id: string;
  type: TransactionType;
  date: string;
  amount: number;
  amount_net: number | null;
  tax_amount: number;
  tax_rate: number;
  currency: string;
  category_id: string | null;
  counterparty: string;
  invoice_no: string;
  invoice_status: InvoiceStatus;
  payment_status: TxPaymentStatus;
  paid_amount: number;
  payment_date: string | null;
  due_date: string | null;
  description: string;
  attachment_path: string | null;
  source_meta: string | null;
  created_at: string;
  updated_at: string;
}

export interface TransactionUpsert {
  id: string;
  type: TransactionType;
  date: string;
  amount: number;
  amount_net?: number;
  tax_amount?: number;
  tax_rate?: number;
  currency?: string;
  category_id?: string | null;
  counterparty?: string;
  invoice_no?: string;
  invoice_status?: InvoiceStatus;
  payment_status?: TxPaymentStatus;
  paid_amount?: number;
  payment_date?: string;
  due_date?: string;
  description?: string;
  attachment_path?: string;
  source_meta?: any;
}

export interface TransactionSummary {
  income: { total: number; count: number };
  expense: { total: number; count: number };
  net: number;
}

export function listTransactions(opts: { type?: TransactionType; from?: string; to?: string; category_id?: string; limit?: number } = {}): Promise<Transaction[]> {
  const qs = new URLSearchParams();
  if (opts.type) qs.set('type', opts.type);
  if (opts.from) qs.set('from', opts.from);
  if (opts.to) qs.set('to', opts.to);
  if (opts.category_id) qs.set('category_id', opts.category_id);
  if (opts.limit != null) qs.set('limit', String(opts.limit));
  return apiFetch<Transaction[]>(`/api/transactions${qs.toString() ? '?' + qs.toString() : ''}`);
}

export function getTransaction(id: string): Promise<Transaction> {
  return apiFetch<Transaction>(`/api/transactions/${encodeURIComponent(id)}`);
}

export function createTransaction(payload: TransactionUpsert): Promise<{ success: boolean; id: string }> {
  return apiFetch('/api/transactions', { method: 'POST', body: JSON.stringify(payload) });
}

export function updateTransaction(id: string, payload: Partial<TransactionUpsert>): Promise<{ success: boolean }> {
  return apiFetch(`/api/transactions/${encodeURIComponent(id)}`, { method: 'PUT', body: JSON.stringify(payload) });
}

export function deleteTransaction(id: string): Promise<{ success: boolean }> {
  return apiFetch(`/api/transactions/${encodeURIComponent(id)}`, { method: 'DELETE' });
}

export function fetchTransactionSummary(opts: { from?: string; to?: string } = {}): Promise<TransactionSummary> {
  const qs = new URLSearchParams();
  if (opts.from) qs.set('from', opts.from);
  if (opts.to) qs.set('to', opts.to);
  return apiFetch<TransactionSummary>(`/api/transactions/summary${qs.toString() ? '?' + qs.toString() : ''}`);
}

// ==================== Legacy Data Migrations（旧 sales/purchases → transactions）====================

export interface LegacyDetectResult {
  hasLegacy: boolean;
  sales: { exists: boolean; total: number; migrated: number; pending: number };
  purchases: { exists: boolean; total: number; migrated: number; pending: number };
}

export interface MigrationRunResult {
  salesMigrated: number;
  purchasesMigrated: number;
  salesSkipped: number;
  purchasesSkipped: number;
  errors: Array<{ legacy_table: 'sales' | 'purchases'; legacy_id: string; error: string }>;
}

export function detectLegacyData(): Promise<LegacyDetectResult> {
  return apiFetch<LegacyDetectResult>('/api/migrations/detect-legacy');
}

export function runLegacyMigration(opts: { defaultIncomeCategoryId?: string; defaultExpenseCategoryId?: string; currency?: string } = {}): Promise<MigrationRunResult> {
  return apiFetch('/api/migrations/run', { method: 'POST', body: JSON.stringify(opts) });
}

export function rollbackLegacyMigration(): Promise<{ success: boolean; removed: number }> {
  return apiFetch('/api/migrations/rollback', { method: 'POST', body: JSON.stringify({}) });
}

// ==================== Reports（D 阶段 — 6 国报表引擎）====================

export interface ReportResult {
  locale: string;
  period: { from: string; to: string; year: string };
  currency: string;
  reportTypes: Array<{ id: string; name: Record<string, string> }>;
  // CN
  incomeStatement?: any;
  vatSummary?: any;
  taxInclusiveSummary?: any;
  // US
  scheduleC?: any;
  selfEmploymentTax?: any;
  estimatedTax?: any;
  // JP
  consumptionTax?: any;
  // EU
  profitLoss?: any;
  vatReturn?: any;
  // KR (same as incomeStatement + vatSummary)
  // TW
  businessTax?: any;
  // Common
  monthlyBreakdown?: Array<{ month: number; revenue: number; cost: number; profit: number }>;
  warnings: string[];
}

export function generateReport(opts: { locale?: string; year?: string; from?: string; to?: string } = {}): Promise<ReportResult> {
  return apiFetch<ReportResult>('/api/reports/generate', {
    method: 'POST',
    body: JSON.stringify(opts),
  });
}

export function getReportTypes(locale?: string): Promise<Array<{ id: string; name: Record<string, string> }>> {
  const qs = locale ? `?locale=${locale}` : '';
  return apiFetch(`/api/reports/types${qs}`);
}

// ==================== US: Mileage Tracking（F 阶段）====================

export interface MileageLog {
  id: string; date: string; start_location: string; end_location: string;
  miles: number; purpose: string; round_trip: number; rate_per_mile: number;
  deduction: number; created_at: string;
}

export interface MileageSummary { year: string; trips: number; totalMiles: number; totalDeduction: number; }

export function listMileage(opts: { from?: string; to?: string } = {}): Promise<MileageLog[]> {
  const qs = new URLSearchParams();
  if (opts.from) qs.set('from', opts.from);
  if (opts.to) qs.set('to', opts.to);
  return apiFetch(`/api/mileage${qs.toString() ? '?' + qs.toString() : ''}`);
}

export function createMileage(body: Partial<MileageLog>): Promise<{ success: boolean; id: string }> {
  return apiFetch('/api/mileage', { method: 'POST', body: JSON.stringify(body) });
}

export function updateMileage(id: string, body: Partial<MileageLog>): Promise<{ success: boolean }> {
  return apiFetch(`/api/mileage/${encodeURIComponent(id)}`, { method: 'PUT', body: JSON.stringify(body) });
}

export function deleteMileage(id: string): Promise<{ success: boolean }> {
  return apiFetch(`/api/mileage/${encodeURIComponent(id)}`, { method: 'DELETE' });
}

export function fetchMileageSummary(year?: string): Promise<MileageSummary> {
  const qs = year ? `?year=${year}` : '';
  return apiFetch(`/api/mileage/summary${qs}`);
}

// ==================== US: Home Office（F 阶段）====================

export interface HomeOfficeData {
  method: 'simplified' | 'actual'; sqft: number; rate_per_sqft: number; max_sqft: number;
  total_home_sqft: number; annual_rent: number; annual_utilities: number;
  annual_insurance: number; annual_depreciation: number; deduction: number;
}

export function fetchHomeOffice(): Promise<HomeOfficeData> {
  return apiFetch('/api/home-office');
}

export function saveHomeOffice(body: Partial<HomeOfficeData>): Promise<HomeOfficeData> {
  return apiFetch('/api/home-office', { method: 'PUT', body: JSON.stringify(body) });
}

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
  productId?: string;       // Phase 2: linked product/service
  productName?: string;     // snapshot at record time
  unit?: string;            // snapshot at record time
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
  productId?: string;       // Phase 2: linked product/service
  productName?: string;     // snapshot at record time
  unit?: string;            // snapshot at record time
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
  notifications?: {
    stockZero: boolean;
    taxDeviation: boolean;
    priceVolatility: boolean;
    monthlyReport: boolean;
  };
  admin_expense_annual?: number; // 年度管理费用 (元)
  vat_rate?: string;
  ai_model?: string;
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
  product_id?: string | null;
  product_name_snapshot?: string | null;
  unit_snapshot?: string | null;
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
  product_id?: string | null;
  product_name_snapshot?: string | null;
  unit_snapshot?: string | null;
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
    product_id: r.productId || null,
  };
}

function fromApiSales(a: ApiSalesRecord): SalesRecord {
  return {
    id: a.id,
    date: a.date,
    customer: a.customer || '',
    quantity: a.tons ? String(a.tons) : '0',
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
    productId: a.product_id || '',
    productName: a.product_name_snapshot || '',
    unit: a.unit_snapshot || '',
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
    product_id: r.productId || null,
  };
}

function fromApiPurchase(a: ApiPurchaseRecord): PurchaseRecord {
  return {
    id: a.id,
    date: a.date,
    supplier: a.supplier || '',
    quantity: a.tons ? String(a.tons) : '0',
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
    productId: a.product_id || '',
    productName: a.product_name_snapshot || '',
    unit: a.unit_snapshot || '',
  };
}

// ==================== API Calls ====================

const API_TIMEOUT_MS = 90000; // #8: 90s default request timeout

async function apiFetch<T>(path: string, options?: RequestInit & { signal?: AbortSignal }): Promise<T> {
  const method = (options?.method || 'GET').toUpperCase();
  const body = options?.body ? JSON.parse(options.body as string) : undefined;
  const userSignal = options?.signal;

  // ===== Electron 桌面版：走 IPC，跳过 HTTP =====
  if (isElectron()) {
    if (userSignal?.aborted) throw new Error('cancelled');
    const electronAPI = (window as any).electronAPI;

    const timeoutPromise = new Promise<never>((_, reject) => {
      setTimeout(() => reject(new Error(`请求超时 (${API_TIMEOUT_MS / 1000}s): ${path}`)), API_TIMEOUT_MS);
    });
    const cancelPromise = new Promise<never>((_, reject) => {
      userSignal?.addEventListener('abort', () => reject(new Error('cancelled')), { once: true });
    });
    const invokePromise = electronAPI.invoke('api:request', { method, path, body });

    return Promise.race([invokePromise, timeoutPromise, cancelPromise]) as Promise<T>;
  }

  // ===== Web 版：保留原 fetch 逻辑 =====
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
  };

  const timeoutController = new AbortController();
  const timeoutId = setTimeout(() => timeoutController.abort(), API_TIMEOUT_MS);

  const onUserAbort = () => timeoutController.abort();
  if (userSignal) {
    if (userSignal.aborted) { clearTimeout(timeoutId); throw new Error('cancelled'); }
    userSignal.addEventListener('abort', onUserAbort, { once: true });
  }

  try {
    const res = await fetch(`${API_BASE}${path}`, {
      ...options,
      signal: timeoutController.signal,
      credentials: 'same-origin',
      headers: {
        ...headers,
        ...(options?.headers || {}),
      },
    });
    if (!res.ok) {
      const err = await res.text();
      throw new Error(`API ${method} ${path} failed (${res.status}): ${err.slice(0, 300)}`);
    }
    return res.json() as Promise<T>;
  } catch (err: any) {
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
  // accountingLocale echoed by the backend dashboard summary (App.tsx reads dashboard.locale)
  locale?: AccountingLocale;
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
  inventory?: import('../types').InventorySummary; // Phase 3: per-product inventory overview
}

export function fetchInventorySummary(): Promise<import('../types').InventorySummary> {
  return apiFetch<import('../types').InventorySummary>('/api/inventory/summary');
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

