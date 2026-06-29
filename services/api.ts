// API client — 桌面版走 Electron IPC（api:request）；不再有 Web fetch 路径
// Field mapping 在下方保持不变

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

// ==================== 结构化 CSV 导出（§2A · 仅桌面版 · 供会计师对接/迁出）====================

export type CsvExportTable = 'transactions' | 'purchases' | 'sales' | 'documents';

export interface CsvExportResult {
  ok: boolean;
  path?: string;   // 成功时：CSV 保存路径
  rows?: number;   // 成功时：导出行数
  error?: string;  // 失败时：错误码（INVALID_TABLE / EXPORT_FAILED）
}

/** 把指定表导出为 CSV（UTF-8 BOM，含表头）。ok=false 且无 error 表示用户取消保存框。 */
export function exportTableCsv(table: CsvExportTable): Promise<CsvExportResult> {
  return electronInvoke<CsvExportResult>('app:exportTableCsv', { table });
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
  status?: number;     // HTTP 状态码（如 401/403/404/429）
  code?: string;       // 稳定错误码（aiError.* 枚举，如 auth / quota / modelNotFound）
  providerMessage?: string; // 服务商原始 message（英文，仅供调试展示）
  rawMessage?: string; // 完整错误字符串（含 AI_ERR:<code> + 状态码）
}

export function testProvider(payload: TestProviderRequest): Promise<TestProviderResult> {
  return electronInvoke<TestProviderResult>('providers:test', payload);
}

// ==================== AI 助手聊天（走统一 apiFetch：桌面 IPC / Web fetch）====================
// 业务上下文由 /api/ai/context 现查（本地聚合 DB，不调外部 AI）；对话走 /api/ai/chat。
// 系统提示词由调用方（useAssistant）按 accountingLocale×uiLanguage 组装后传入。

/** AI 助手多轮对话 */
export function aiChat(messages: any[], systemInstruction: string): Promise<{ text?: string }> {
  return apiFetch('/api/ai/chat', { method: 'POST', body: JSON.stringify({ messages, systemInstruction }) });
}

/** 拉取业务上下文文本（服务端聚合本地数据，渲染端缓存 60s） */
export function aiContext(year: string): Promise<{ context?: string }> {
  return apiFetch('/api/ai/context', { method: 'POST', body: JSON.stringify({ year }) });
}

/** AI 工具轨迹项（只读：工具名 / 参数摘要 / 行数 / 截断标志；绝不含 API Key 或结果明细） */
export interface ToolTraceItem {
  name: string;
  argsSummary?: string;
  rowCount: number;
  truncated: boolean;
}

/**
 * AI 助手只读查账对话（R2b-1）。主进程跑「LLM ↔ 只读工具」循环后返回最终回答 + 工具轨迹。
 * API Key 全程不出主进程；与 aiChat 同样走统一 apiFetch（桌面 IPC / Web fetch）。
 */
export function aiAgentChat(messages: any[], systemInstruction: string): Promise<{ text?: string; toolTrace?: ToolTraceItem[] }> {
  return apiFetch('/api/ai/agent-chat', { method: 'POST', body: JSON.stringify({ messages, systemInstruction }) });
}

// ==================== AI 助手会话持久化（R4a-1；仅桌面 · 本地 SQLite）====================
// 会话表只存聊天历史 —— 绝不存 API Key/敏感明细；toolTrace 沿用 R2b 脱敏。
// web 模式 /api/conversations 404，调用方 try/catch 后降级为纯内存会话（不阻断聊天）。

export interface ConversationMeta {
  id: string;
  title?: string | null;
  acc_locale?: string | null;
  ui_language?: string | null;
  created_at?: string;
  updated_at?: string;
}

export interface StoredMessage {
  role: 'user' | 'model';
  text: string;
  toolTrace?: ToolTraceItem[];
}

/** 会话列表（最近更新在前） */
export function listConversations(): Promise<ConversationMeta[]> {
  return apiFetch('/api/conversations');
}

/** 新建空会话（懒建：首次发消息时调用） */
export function createConversation(opts?: { accLocale?: string; uiLanguage?: string; title?: string }): Promise<{ id: string }> {
  return apiFetch('/api/conversations', { method: 'POST', body: JSON.stringify(opts || {}) });
}

/** 某会话全部消息（按顺序） */
export function fetchConversationMessages(id: string): Promise<StoredMessage[]> {
  return apiFetch(`/api/conversations/${encodeURIComponent(id)}/messages`);
}

/** 追加一条消息（首条 user 消息会自动生成标题） */
export function appendConversationMessage(id: string, msg: StoredMessage): Promise<{ ok: boolean }> {
  return apiFetch(`/api/conversations/${encodeURIComponent(id)}/messages`, { method: 'POST', body: JSON.stringify(msg) });
}

/** 删除会话（连同消息；用于「清空当前对话」/侧栏删除） */
export function deleteConversation(id: string): Promise<{ ok: boolean }> {
  return apiFetch(`/api/conversations/${encodeURIComponent(id)}`, { method: 'DELETE' });
}

/** 重命名会话标题（R4a-2 侧栏就地编辑） */
export function renameConversation(id: string, title: string): Promise<{ ok: boolean }> {
  return apiFetch(`/api/conversations/${encodeURIComponent(id)}`, { method: 'PUT', body: JSON.stringify({ title }) });
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
  is_cogs: boolean; // PR-T5: true = cost of goods sold; false = operating expense
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
  is_cogs?: boolean; // PR-T5: mark a category as cost of goods sold
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
  // en/ja/ko/fr + CN: localize ONLY the report-line display (keep the handler's per-lang
  // displayLabel), keyed by slug. Display only — stored value + by-slug backend report
  // mapping unchanged; user/custom categories (no slug match) pass through their raw value.
  const cnSchedLang = !zhLang && opts.locale === 'CN' && ['en', 'ja', 'ko', 'fr'].includes(opts.lang || '');
  return apiFetch<Category[]>(`/api/categories${qs.toString() ? '?' + qs.toString() : ''}`)
    .then(cats => cats.map(c => {
      if (catMap) {
        const m = catMap[c.slug];
        if (m) return { ...c, displayLabel: m.label[opts.lang as 'zh-CN' | 'zh-TW'], schedule_line: m.scheduleLine[opts.lang as 'zh-CN' | 'zh-TW'] };
      }
      if (cnSchedLang) {
        const m = CN_TXN_CATEGORY_LABELS[c.slug];
        const sl = m?.scheduleLine[opts.lang as 'en' | 'ja' | 'ko' | 'fr'];
        if (sl) return { ...c, schedule_line: sl };
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

// ==================== Accounts（现金/银行账户 + 期初余额，PR-7D-1 管道层）====================
// 政策中性主数据：仅录入/读取/编辑/删除·停用。不接资产负债表、不 roll-up、不做平衡断言、
// 不与 sales/purchases/transactions 联动。opening_balance 仅为用户手输数字（允许为负）。

export type AccountType = 'cash' | 'bank';

export interface Account {
  id: string;
  name: string;
  type: AccountType;
  currency: string | null;
  opening_balance: number;
  opening_date: string | null;
  note: string | null;
  is_active: boolean;
  sort_order: number;
  created_at?: string;
  updated_at?: string;
}

export interface AccountUpsert {
  name: string;
  type?: AccountType;
  currency?: string | null;
  opening_balance?: number;
  opening_date?: string | null;
  note?: string | null;
  is_active?: boolean;
  sort_order?: number;
}

export function listAccounts(): Promise<Account[]> {
  return apiFetch<Account[]>('/api/accounts');
}
export function createAccount(payload: AccountUpsert): Promise<{ success: boolean; id: string }> {
  return apiFetch('/api/accounts', { method: 'POST', body: JSON.stringify(payload) });
}
export function updateAccount(id: string, payload: Partial<AccountUpsert>): Promise<{ success: boolean }> {
  return apiFetch(`/api/accounts/${encodeURIComponent(id)}`, { method: 'PUT', body: JSON.stringify(payload) });
}
export function deleteAccount(id: string): Promise<{ success: boolean }> {
  return apiFetch(`/api/accounts/${encodeURIComponent(id)}`, { method: 'DELETE' });
}

// ==================== Liabilities（负债/借款手工台账，PR-7D-2 管道层）====================
// 政策中性主数据：仅录入/读取/编辑/删除·结清。≠ 采购应付（payables 仍由 purchases 聚合）。
// 不接资产负债表、不 roll-up、不做还款计划、不算利息。opening_balance 用户手输（允许为负）；
// interest_rate 仅备查、不参与计算。

export type LiabilityType = 'loan' | 'other';

export interface Liability {
  id: string;
  name: string;
  lender: string | null;
  liability_type: LiabilityType;
  currency: string | null;
  principal: number | null;
  opening_balance: number;
  opening_date: string | null;
  interest_rate: number | null;
  maturity_date: string | null;
  note: string | null;
  is_active: boolean;
  sort_order: number;
  created_at?: string;
  updated_at?: string;
}

export interface LiabilityUpsert {
  name: string;
  lender?: string | null;
  liability_type?: LiabilityType;
  currency?: string | null;
  principal?: number | null;
  opening_balance?: number;
  opening_date?: string | null;
  interest_rate?: number | null;
  maturity_date?: string | null;
  note?: string | null;
  is_active?: boolean;
  sort_order?: number;
}

export function listLiabilities(): Promise<Liability[]> {
  return apiFetch<Liability[]>('/api/liabilities');
}
export function createLiability(payload: LiabilityUpsert): Promise<{ success: boolean; id: string }> {
  return apiFetch('/api/liabilities', { method: 'POST', body: JSON.stringify(payload) });
}
export function updateLiability(id: string, payload: Partial<LiabilityUpsert>): Promise<{ success: boolean }> {
  return apiFetch(`/api/liabilities/${encodeURIComponent(id)}`, { method: 'PUT', body: JSON.stringify(payload) });
}
export function deleteLiability(id: string): Promise<{ success: boolean }> {
  return apiFetch(`/api/liabilities/${encodeURIComponent(id)}`, { method: 'DELETE' });
}

// ==================== Fixed Assets（固定资产登记台账，PR-7D-3 管道层）====================
// 政策中性主数据：仅录入/读取/编辑/删除·停用。不折旧、不出净值、不接资产负债表、不碰 reports。
// 无 depreciation_method/useful_life/salvage_value（留 PR-7B）。category 自由文本无映射；
// original_value 用户手输（NaN→0，不 clamp）；status='disposed' 仅登记标签不出表。

export type AssetStatus = 'in_use' | 'idle' | 'disposed';
export type DepreciationMethod = 'straight_line';
export type DepreciationStartPolicy = 'next_month' | 'same_month' | 'daily';

export interface FixedAsset {
  id: string;
  name: string;
  category: string | null;
  acquisition_date: string | null;
  original_value: number;
  currency: string | null;
  supplier: string | null;
  serial_no: string | null;
  note: string | null;
  status: AssetStatus;
  // PR-7B P2-1 折旧参数（仅登记，不计算；null = 用类别默认）。
  depreciation_method: DepreciationMethod;
  useful_life_months: number | null;
  salvage_rate: number | null;
  depreciation_start_policy: DepreciationStartPolicy;
  disposal_date: string | null;
  is_active: boolean;
  sort_order: number;
  created_at?: string;
  updated_at?: string;
}

export interface FixedAssetUpsert {
  name: string;
  category?: string | null;
  acquisition_date?: string | null;
  original_value?: number;
  currency?: string | null;
  supplier?: string | null;
  serial_no?: string | null;
  note?: string | null;
  status?: AssetStatus;
  depreciation_method?: DepreciationMethod;
  useful_life_months?: number | null;
  salvage_rate?: number | null;
  depreciation_start_policy?: DepreciationStartPolicy;
  disposal_date?: string | null;
  is_active?: boolean;
  sort_order?: number;
}

export function listFixedAssets(): Promise<FixedAsset[]> {
  return apiFetch<FixedAsset[]>('/api/fixed-assets');
}
export function createFixedAsset(payload: FixedAssetUpsert): Promise<{ success: boolean; id: string }> {
  return apiFetch('/api/fixed-assets', { method: 'POST', body: JSON.stringify(payload) });
}
export function updateFixedAsset(id: string, payload: Partial<FixedAssetUpsert>): Promise<{ success: boolean }> {
  return apiFetch(`/api/fixed-assets/${encodeURIComponent(id)}`, { method: 'PUT', body: JSON.stringify(payload) });
}
export function deleteFixedAsset(id: string): Promise<{ success: boolean }> {
  return apiFetch(`/api/fixed-assets/${encodeURIComponent(id)}`, { method: 'DELETE' });
}

// ==================== Equity（权益/资本登记台账，PR-7D-4 管道层）====================
// 政策中性主数据：仅录入/读取/编辑/删除·停用。不做权益合计、不做留存收益/利润结转、不做平衡、
// 不接资产负债表、不碰 reports、不联动 accounts/transactions。equity_type 仅中性分类无科目映射；
// amount 用户手输（NaN→0，不 clamp，允许负，系统不解释方向）。

export type EquityType = 'capital_contribution' | 'owner_draw' | 'adjustment' | 'other';

export interface EquityEntry {
  id: string;
  name: string;
  owner: string | null;
  equity_type: EquityType;
  amount: number;
  currency: string | null;
  event_date: string | null;
  note: string | null;
  is_active: boolean;
  sort_order: number;
  created_at?: string;
  updated_at?: string;
}

export interface EquityUpsert {
  name: string;
  owner?: string | null;
  equity_type?: EquityType;
  amount?: number;
  currency?: string | null;
  event_date?: string | null;
  note?: string | null;
  is_active?: boolean;
  sort_order?: number;
}

export function listEquity(): Promise<EquityEntry[]> {
  return apiFetch<EquityEntry[]>('/api/equity');
}
export function createEquity(payload: EquityUpsert): Promise<{ success: boolean; id: string }> {
  return apiFetch('/api/equity', { method: 'POST', body: JSON.stringify(payload) });
}
export function updateEquity(id: string, payload: Partial<EquityUpsert>): Promise<{ success: boolean }> {
  return apiFetch(`/api/equity/${encodeURIComponent(id)}`, { method: 'PUT', body: JSON.stringify(payload) });
}
export function deleteEquity(id: string): Promise<{ success: boolean }> {
  return apiFetch(`/api/equity/${encodeURIComponent(id)}`, { method: 'DELETE' });
}

// ==================== Tax Payments（已缴税款登记台账，PR-7D-5 管道层）====================
// 政策中性主数据：仅录入/读取/编辑/删除·停用。不算税额/税率、不抵扣 VAT、不对冲所得税/附加税、
// 不确认税费费用、不进 cashflow、不联动 accounts/transactions、不接资产负债表、不碰 reports，
// 且不与 estimatedPayable/estimatedTax/vatSummary 做任何勾稽。tax_type 仅中性分类无科目映射；
// amount 用户手输（NaN→0，不 clamp，允许负——仅退税/冲正记录，系统不解释方向）。

export type TaxType = 'vat' | 'income_tax' | 'surcharge' | 'payroll_tax' | 'sales_tax' | 'other';

export interface TaxPayment {
  id: string;
  name: string;
  tax_type: TaxType;
  amount: number;
  currency: string | null;
  payment_date: string | null;
  period_start: string | null;
  period_end: string | null;
  authority: string | null;
  reference_no: string | null;
  note: string | null;
  is_active: boolean;
  sort_order: number;
  created_at?: string;
  updated_at?: string;
}

export interface TaxPaymentUpsert {
  name: string;
  tax_type?: TaxType;
  amount?: number;
  currency?: string | null;
  payment_date?: string | null;
  period_start?: string | null;
  period_end?: string | null;
  authority?: string | null;
  reference_no?: string | null;
  note?: string | null;
  is_active?: boolean;
  sort_order?: number;
}

export function listTaxPayments(): Promise<TaxPayment[]> {
  return apiFetch<TaxPayment[]>('/api/tax-payments');
}
export function createTaxPayment(payload: TaxPaymentUpsert): Promise<{ success: boolean; id: string }> {
  return apiFetch('/api/tax-payments', { method: 'POST', body: JSON.stringify(payload) });
}
export function updateTaxPayment(id: string, payload: Partial<TaxPaymentUpsert>): Promise<{ success: boolean }> {
  return apiFetch(`/api/tax-payments/${encodeURIComponent(id)}`, { method: 'PUT', body: JSON.stringify(payload) });
}
export function deleteTaxPayment(id: string): Promise<{ success: boolean }> {
  return apiFetch(`/api/tax-payments/${encodeURIComponent(id)}`, { method: 'DELETE' });
}

// ==================== Ledger Summary（各台账余额汇总快照，PR-7B-1 只读）====================
// 管理口径只读快照：五张 7D 台账各自 SUM、按币种分组（仅启用行，不折算、不跨币种合计）。
// 非资产负债表：不分类、不做合计、不做平衡、不折旧、不结转、不对冲、不碰 reports。
// taxPaidMemo 仅为「已缴税款备查」，独立、不并入任何其它聚合。

export interface LedgerCurrencyTotal {
  currency: string | null;   // 原币（自由文本）；null = 未指定
  total: number;             // 该币种小计（未折算）
  count: number;
}
export interface LedgerGroup {
  count: number;             // 启用行总笔数
  byCurrency: LedgerCurrencyTotal[];
}
export interface LedgerSummary {
  snapshot: boolean;         // 恒 true：管理口径数据快照
  statutory: boolean;        // 恒 false：非法定报表
  balanced: boolean;         // 恒 false：不做平衡校验
  accounts: LedgerGroup;
  liabilities: LedgerGroup;
  fixedAssets: LedgerGroup;
  equity: LedgerGroup;
  taxPaidMemo: LedgerGroup;  // 已缴税款备查（独立，不参与任何合计）
}

export function fetchLedgerSummary(): Promise<LedgerSummary> {
  return apiFetch<LedgerSummary>('/api/ledger-summary');
}

// ==================== Cash Position（现金/银行期末结转只读预览，PR-7B P1-2）====================
// 只读预览：endingEstimate = Σ accounts.opening_balance(启用) + 本期实收 − 本期实付，按币种。
// 不写回 accounts、不改历史交易；仅经营活动实收付（未含投资/筹资）；多币种不折算、不跨币种合计。
// 不做 balanceOverview / 资产负债概览 / 平衡差额 / 折旧 / 留存结转 / 税额对冲。

export interface CashPositionCurrencyRow {
  currency: string | null;   // 原币（自由文本）；null = 未指定
  opening: number;           // 期初（启用账户）
  inflow: number;            // 本期实收
  outflow: number;           // 本期实付
  endingEstimate: number;    // 期末估算 = opening + inflow − outflow
}
export interface CashPosition {
  estimate: boolean;         // 恒 true
  source: 'transactions' | 'legacy';
  period: { from: string; to: string };
  baseCurrency: string;
  byCurrency: CashPositionCurrencyRow[];
  limitations: string[];
  excludedNotes: string[];
}

export function fetchCashPosition(opts: { from?: string; to?: string; year?: string } = {}): Promise<CashPosition> {
  const qs = new URLSearchParams();
  if (opts.from) qs.set('from', opts.from);
  if (opts.to) qs.set('to', opts.to);
  if (opts.year) qs.set('year', opts.year);
  const suffix = qs.toString() ? `?${qs.toString()}` : '';
  return apiFetch<CashPosition>(`/api/cash-position${suffix}`);
}

// ==================== Balance Overview（管理口径资产负债概览，PR-7B P1-3 只读聚合）====================
// 非法定资产负债表：按币种归集 资产/负债/权益 + 各小计 + 显式 balanceDifference（= 资产−负债−权益）。
// 现金来自 cash-position endingEstimate；固定资产按原值（不折旧）；借款按 maturity_date 一年线分；
// 权益取 equity.amount 之和（不做结转）；税不进合计；多币种不折算、不跨币种合计；只读不写回。

// PR-7B P2-3：仅 fixedAssets 行携带；amount=净值，meta 含原值/累计折旧供 UI 辅助说明。
export interface BalanceLineMeta {
  originalValue: number;
  accumulatedDepreciation: number;
  netBookValue: number;
  estimate: boolean;
  hasWarnings?: boolean;
}
export interface BalanceLine {
  key: string;       // = accountingClassification BALANCE_CLASSIFICATION 的 key（前端据此取标签）
  amount: number;    // fixedAssets：净值（netBookValue）
  meta?: BalanceLineMeta;
}
export interface BalanceCurrencyBlock {
  currency: string | null;
  assets: { current: BalanceLine[]; nonCurrent: BalanceLine[] };
  liabilities: { current: BalanceLine[]; nonCurrent: BalanceLine[] };
  equity: BalanceLine[];
  totals: { assets: number; liabilities: number; equity: number };
  balanceDifference: number;   // 资产 − 负债 − 权益（按币种，非 0 为常态，不隐藏）
  warnings: string[];
}
export interface BalanceOverview {
  estimate: boolean;                                   // 恒 true
  reportType: 'management_balance_overview';           // 非法定 balance sheet
  entityType?: 'individual' | 'company';               // PR-7B P2-4b：出资行 entity-aware（company=实收资本 / individual=业主资本）
  period: { from: string; to: string };
  asOf: string;
  baseCurrency: string;
  byCurrency: BalanceCurrencyBlock[];
  disclaimerKey: string;
  limitations: string[];
  excludedNotes: string[];
}

export function fetchBalanceOverview(opts: { from?: string; to?: string; year?: string } = {}): Promise<BalanceOverview> {
  const qs = new URLSearchParams();
  if (opts.from) qs.set('from', opts.from);
  if (opts.to) qs.set('to', opts.to);
  if (opts.year) qs.set('year', opts.year);
  const suffix = qs.toString() ? `?${qs.toString()}` : '';
  return apiFetch<BalanceOverview>(`/api/balance-overview${suffix}`);
}

// ==================== Depreciation Preview（固定资产直线法折旧只读预览，PR-7B P2-2）====================
// 只读：每资产累计折旧/账面净值/月折旧（直线法）。不写回 fixed_assets、不进 P&L、不接概览、不碰 reports。
// 空 useful_life_months/salvage_rate 回退类别默认；disposed 不计入 totals；多币种分别列示不折算。

export interface DepreciationAsset {
  id: string;
  name: string;
  category: string | null;
  currency: string | null;
  originalValue: number;
  usefulLifeMonths: number;
  salvageRate: number;
  salvageValue: number;
  depreciableAmount: number;
  monthlyDepreciation: number;
  monthsElapsed: number;
  accumulatedDepreciation: number;
  netBookValue: number;
  acquisitionDate: string | null;
  depreciationStartPolicy: string;
  disposalDate: string | null;
  status: string;
  disposed: boolean;
  usedDefaults: { usefulLifeMonths: boolean; salvageRate: boolean };
  categoryResolved: string;   // canonical 类别（含 'DEFAULT_FALLBACK'）
  warnings: string[];         // code（前端映射 i18n）
}
export interface DepreciationCurrencyBlock {
  currency: string | null;
  assets: DepreciationAsset[];
  totals: { originalValue: number; accumulatedDepreciation: number; netBookValue: number };  // disposed 不计入
}
export interface DepreciationPreview {
  estimate: boolean;
  reportType: 'depreciation_preview';
  asOf: string;
  baseCurrency: string;
  byCurrency: DepreciationCurrencyBlock[];
  limitations: string[];
  disclaimerKey: string;
}

export function fetchDepreciationPreview(opts: { asOf?: string; year?: string } = {}): Promise<DepreciationPreview> {
  const qs = new URLSearchParams();
  if (opts.asOf) qs.set('asOf', opts.asOf);
  if (opts.year) qs.set('year', opts.year);
  const suffix = qs.toString() ? `?${qs.toString()}` : '';
  return apiFetch<DepreciationPreview>(`/api/depreciation-preview${suffix}`);
}

// ==================== Retained Earnings Preview（留存/未分配利润只读预览，PR-7B P2-4a）====================
// 只读：期末未分配利润 = 期初(settings) + 本期净利 − 分红/利润分配。单一本位币口径（不做 byCurrency/折算）。
// 本期净利只读复用 P&L incomeStatement.netProfit（US 无 → scheduleC.line31_netProfit）；不改 electron/reports/*。
// entityType=individual：owner_draw 不冲减未分配利润（留 P2-4b 冲减出资行）→ distributions=0；
// entityType=company：owner_draw 暂按分红冲减（仅本位币·期间内·非空日期）。不写回 equity、不自动年结、不接概览。

export interface RetainedEarningsPreview {
  estimate: boolean;                              // 恒 true
  reportType: 'retained_earnings_preview';        // 非法定
  entityType: 'individual' | 'company';
  locale: string;                                 // 取净利用的 accounting_locale
  period: { from: string; to: string };
  baseCurrency: string;
  openingRetainedEarnings: number;                // 期初未分配利润（本位币，允许负）
  netProfit: number;                              // 本期净利（本位币）
  netProfitSource: 'incomeStatement' | 'scheduleC';
  distributions: number;                          // 本期分红/利润分配（company owner_draw；individual=0）
  endingRetainedEarnings: number;                 // = 期初 + 本期净利 − 分红
  disclaimerKey: string;
  limitations: string[];
  excludedNotes: string[];
}

export function fetchRetainedEarningsPreview(opts: { from?: string; to?: string; year?: string } = {}): Promise<RetainedEarningsPreview> {
  const qs = new URLSearchParams();
  if (opts.from) qs.set('from', opts.from);
  if (opts.to) qs.set('to', opts.to);
  if (opts.year) qs.set('year', opts.year);
  const suffix = qs.toString() ? `?${qs.toString()}` : '';
  return apiFetch<RetainedEarningsPreview>(`/api/retained-earnings-preview${suffix}`);
}

// ==================== Income Tax Position（所得税同税种同期间对冲只读预览，PR-7B P3-1）====================
// 只读：期末应交所得税 = 本期应计 − 本期已缴（同 tax_type=income_tax·同期间·本位币）。
// 应计只读复用 reports incomeStatement.incomeTax（US 取 estimatedTax.annualIncomeTax）；不改 electron/reports/*。
// 仅本位币·非本位币缴款进 excludedPayments；不折算·不接概览(P3-4 才接)·不写回 tax_payments。

export interface IncomeTaxMatchedPayment {
  id: string;
  name: string;
  amount: number;
  currency: string | null;
  payment_date: string | null;
  period_start: string | null;
  period_end: string | null;
  matchBasis: 'period' | 'payment_date';
}
export interface IncomeTaxExcludedPayment {
  id: string;
  name: string;
  amount: number;
  currency: string | null;
  reason: 'non_base_currency' | 'out_of_period' | 'no_date';
}
export interface IncomeTaxPosition {
  estimate: boolean;                                   // 恒 true
  reportType: 'income_tax_position';                   // 非法定
  taxType: 'income_tax';
  locale: string;                                      // accounting_locale
  accruedSource: 'incomeStatement.incomeTax' | 'estimatedTax.annualIncomeTax';
  period: { from: string; to: string };
  baseCurrency: string;
  accruedIncomeTax: number;                            // 本期应计（本位币，来自 reports）
  paidIncomeTax: number;                               // 本期已缴（本位币，Σ matched）
  netPosition: number;                                 // = 应计 − 已缴
  positionType: 'payable' | 'prepaid' | 'zero';        // >0 净欠缴 / <0 净多缴预缴 / 0
  matchedPayments: IncomeTaxMatchedPayment[];
  excludedPayments: IncomeTaxExcludedPayment[];
  warnings: string[];                                  // negativePaymentPresent / partialPeriodOverlap / accruedNegativeLossPeriod
  limitations: string[];
  excludedNotes: string[];
  disclaimerKey: string;
}

export function fetchIncomeTaxPosition(opts: { from?: string; to?: string; year?: string } = {}): Promise<IncomeTaxPosition> {
  const qs = new URLSearchParams();
  if (opts.from) qs.set('from', opts.from);
  if (opts.to) qs.set('to', opts.to);
  if (opts.year) qs.set('year', opts.year);
  const suffix = qs.toString() ? `?${qs.toString()}` : '';
  return apiFetch<IncomeTaxPosition>(`/api/income-tax-position${suffix}`);
}

// ==================== FX Reference Conversion（多币种参考折算只读预览，PR-7B P3-3）====================
// 只读：把 balanceOverview 各币种 totals + balanceDifference 按用户参考汇率折成本位币「参考合计」。
// converted = amount × rate（rate=本位币/外币，如 USD:7.2=1USD=7.2CNY）；本位币 rate=1。
// 汇率来源 settings.fx_reference_rates(主) + query rates(覆盖·优先)；缺/非法/无币种代码 → missingRates，排除出 totalsReference。
// **仅供参考**：不写回·不改 balanceOverview 原值/byCurrency·不生成汇兑损益·不入账·不接 UI(P3-3 handler-only)。

export interface FxAmounts {
  assets: number;
  liabilities: number;
  equity: number;
  balanceDifference: number;
}
export interface FxConvertedBlock {
  currency: string;
  rate: number;                 // 本位币/外币
  original: FxAmounts;
  converted: FxAmounts;         // = original × rate
}
export interface FxMissingRate {
  currency: string | null;
  reason: 'missing' | 'invalid_rate' | 'no_currency_code';
}
export interface FxTotalsReference extends FxAmounts {
  baseCurrency: string;
  includedCurrencies: (string | null)[];
  excludedCurrencies: (string | null)[];
}
export interface FxReferenceConversion {
  estimate: boolean;                              // 恒 true
  reportType: 'fx_reference_conversion';          // 非法定
  period: { from: string; to: string };
  baseCurrency: string;
  source: 'user_reference_rates';
  rateSource: 'settings' | 'query' | 'merged';
  rates: Record<string, number>;                  // 生效汇率（含 base=1）
  converted: FxConvertedBlock[];                  // 仅有有效汇率的币种
  missingRates: FxMissingRate[];
  totalsReference: FxTotalsReference;             // 跨币种参考合计（本位币）
  warnings: string[];                             // invalidRatePresent / missingRatesPresent
  limitations: string[];
  disclaimerKey: string;
}

export function fetchFxReferenceConversion(opts: { from?: string; to?: string; year?: string; rates?: string } = {}): Promise<FxReferenceConversion> {
  const qs = new URLSearchParams();
  if (opts.from) qs.set('from', opts.from);
  if (opts.to) qs.set('to', opts.to);
  if (opts.year) qs.set('year', opts.year);
  if (opts.rates) qs.set('rates', opts.rates);
  const suffix = qs.toString() ? `?${qs.toString()}` : '';
  return apiFetch<FxReferenceConversion>(`/api/fx-reference-conversion${suffix}`);
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

// PR-T5-2B-1: batch-move expense transactions between categories (management
// classification only). Always preview with dryRun:true first, then commit with
// dryRun:false; pass expectedAffected (the previewed count) so a drift since the
// preview is rejected (409) instead of silently moving a different set.
export interface RecategorizeResult {
  dryRun: boolean;
  fromCategoryId: string;
  toCategoryId: string;
  affected?: number; // present when dryRun:true
  moved?: number;    // present when dryRun:false
}

export function recategorizeTransactions(
  fromCategoryId: string,
  toCategoryId: string,
  dryRun: boolean,
  expectedAffected?: number,
): Promise<RecategorizeResult> {
  return apiFetch('/api/transactions/recategorize', {
    method: 'POST',
    body: JSON.stringify({ fromCategoryId, toCategoryId, dryRun, expectedAffected }),
  });
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
  // PR-7C: management-basis operating cash-flow (cash basis). Operating figures are real;
  // investing/financing/beginningCash/endingCash are null = "not configured" (UI never shows 0).
  cashflowStatement?: {
    basis: string;
    statutory: boolean;
    source: string;
    operating: { inflow: number; outflow: number; net: number };
    investing: null;
    financing: null;
    beginningCash: null;
    endingCash: null;
  };
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
// Detail line item (P4a) — camelCase mirror of purchase_items / sales_items columns.
// Read side only: populated by getPurchase/getSale detail reads. The write mapping
// (toApi* sending items) is deferred to P4b/c.
export interface LineItem {
  id?: number;
  productId: string | null;
  description: string | null;
  unitSnapshot: string | null;
  quantity: number | null;
  unitPrice: number | null;
  amountNet: number;
  taxRate: number | null;
  taxAmount: number;
  amountGross: number;
  lineNo: number;
}

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
  items?: LineItem[];       // P4a: present on getSale detail; undefined from list()
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
  items?: LineItem[];       // P4a: present on getPurchase detail; undefined from list()
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
  entity_type?: 'individual' | 'company';   // PR-7B P2：经营主体类型（管理口径概览权益标签：company=实收资本 / individual=业主资本）
  opening_retained_earnings?: number;        // PR-7B P2：期初未分配利润（本位币，允许负=累计亏损；仅管理估算参数）
}

// API record types
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
  items?: any[];            // P4a: present on the /:id detail read; absent from the list
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
  items?: any[];            // P4a: present on the /:id detail read; absent from the list
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

// P4a: map one detail item row (snake_case from purchase_items/sales_items) → LineItem.
function fromApiLineItem(r: any): LineItem {
  return {
    id: r.id,
    productId: r.product_id ?? null,
    description: r.description ?? null,
    unitSnapshot: r.unit_snapshot ?? null,
    quantity: r.quantity ?? null,
    unitPrice: r.unit_price ?? null,
    amountNet: r.amount_net ?? 0,
    taxRate: r.tax_rate ?? null,
    taxAmount: r.tax_amount ?? 0,
    amountGross: r.amount_gross ?? 0,
    lineNo: r.line_no ?? 0,
  };
}

// P4b: map an editor LineItem (camel) → the snake-case row the backend items[] expects
// (purchase_items columns; tax_rate is numeric here, unlike business_document_items' string).
// Purchases only — the sales write mapping is deferred to P4c.
function toApiLineItem(it: LineItem, idx: number): any {
  return {
    product_id: it.productId ?? null,
    description: it.description ?? null,
    unit_snapshot: it.unitSnapshot ?? null,
    quantity: it.quantity ?? null,
    unit_price: it.unitPrice ?? null,
    amount_net: it.amountNet ?? 0,
    tax_rate: it.taxRate ?? null,
    tax_amount: it.taxAmount ?? 0,
    amount_gross: it.amountGross ?? 0,
    line_no: it.lineNo ?? idx,
  };
}

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
    // Carry the AR/AP due date through to the backend (was previously dropped here).
    // Empty → undefined so it is omitted: on create the backend defaults it to null;
    // on update the backend only writes due_date when present, preserving the old value.
    due_date: r.dueDate || undefined,
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
    items: Array.isArray(a.items) ? a.items.map(fromApiLineItem) : undefined,
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

  const api: ApiPurchaseRecord = {
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
    // Carry the AR/AP due date through to the backend (was previously dropped here).
    // Empty → undefined so it is omitted: on create the backend defaults it to null;
    // on update the backend only writes due_date when present, preserving the old value.
    due_date: r.dueDate || undefined,
    product_id: r.productId || null,
  };
  // P4b: when the editor produced multiple lines, send items[] — the backend (P2) then
  // treats the lines as the source of truth (header money = Σ items, legacy cols neutralised).
  // A single-line purchase carries no items and stays on the legacy header path.
  if (Array.isArray(r.items)) api.items = r.items.map(toApiLineItem);
  return api;
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
    items: Array.isArray(a.items) ? a.items.map(fromApiLineItem) : undefined,
  };
}

// ==================== API Calls ====================

const API_TIMEOUT_MS = 90000; // #8: 90s default request timeout

async function apiFetch<T>(path: string, options?: RequestInit & { signal?: AbortSignal }): Promise<T> {
  const method = (options?.method || 'GET').toUpperCase();
  const body = options?.body ? JSON.parse(options.body as string) : undefined;
  const userSignal = options?.signal;

  // 桌面版：所有请求走 Electron IPC（api:request），不经过 HTTP
  if (userSignal?.aborted) throw new Error('cancelled');
  const electronAPI = (window as any).electronAPI;

  const timeoutPromise = new Promise<never>((_, reject) => {
    setTimeout(() => reject(new Error(`AI_ERR:timeout (request timeout ${API_TIMEOUT_MS / 1000}s: ${path})`)), API_TIMEOUT_MS);
  });
  const cancelPromise = new Promise<never>((_, reject) => {
    userSignal?.addEventListener('abort', () => reject(new Error('cancelled')), { once: true });
  });
  const invokePromise = electronAPI.invoke('api:request', { method, path, body });

  return Promise.race([invokePromise, timeoutPromise, cancelPromise]) as Promise<T>;
}

// --- Sales ---

export async function fetchSales(): Promise<SalesRecord[]> {
  const results = await apiFetch<ApiSalesRecord[]>('/api/sales');
  return results.map(fromApiSales);
}

// P4a: detail read — sale header + its line items (items: [] for legacy single-item records).
export async function getSale(id: string): Promise<SalesRecord> {
  return fromApiSales(await apiFetch<ApiSalesRecord>(`/api/sales/${encodeURIComponent(id)}`));
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

// P4a: detail read — purchase header + its line items (items: [] for legacy single-item records).
export async function getPurchase(id: string): Promise<PurchaseRecord> {
  return fromApiPurchase(await apiFetch<ApiPurchaseRecord>(`/api/purchases/${encodeURIComponent(id)}`));
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

// --- Business Documents（业务单据 Phase A）---
// 内部业务单据（报价单/销售单/形式发票/商业发票/对账单）。非税务发票开具：
// 正式发票号码仅手工录入（关联功能在后续阶段），永不自动生成。
// accLocale 创建时冻结，保存后的单据税种/币种标签不随设置切换漂移。

export type BusinessDocType = 'quotation' | 'sales_order' | 'proforma_invoice' | 'commercial_invoice' | 'statement';
export type BusinessDocStatus = 'draft' | 'issued' | 'void';

export interface BusinessDocumentItem {
  id?: number;
  productId?: string | null;
  description: string;
  quantity?: number | null;
  unit?: string | null;       // 商品单位 key（getProductUnitLabel 渲染）
  unitPrice?: number | null;  // 不含税单价
  taxRate?: string | null;    // '13%' 风格字符串，与销售记录一致
  taxAmount?: number;
  amount?: number;            // 不含税行金额
  lineNo?: number;
  refSalesId?: string | null; // Phase C：对账单/由销售记录生成时回链的销售记录 id
  refDate?: string | null;    // Phase C：引用销售记录的日期
}

export interface BusinessDocument {
  id: string;
  docType: BusinessDocType;
  docNumber: string;          // 内部单据编号（可编辑；不是正式发票号码）
  status: BusinessDocStatus;
  docDate: string;
  validUntil?: string | null;
  customerName: string;
  customerTaxId?: string | null;
  customerAddress?: string | null;
  customerContact?: string | null;
  accLocale: string;          // 创建时冻结的会计制度
  subtotal: number;
  taxAmount: number;
  total: number;
  notes?: string | null;
  sourceSalesId?: string | null; // Phase C：由销售记录生成时的信息性回链
  periodStart?: string | null;   // Phase C：对账单期间起始
  periodEnd?: string | null;     // Phase C：对账单期间截止
  // Phase D：正式税务发票关联（仅记录外部开具的发票；号码手填、永不自动生成）
  taxInvoiceIssued?: boolean;
  taxInvoiceNumber?: string | null;
  taxInvoiceDate?: string | null;
  taxInvoiceAttachmentPath?: string | null; // 相对 userData 的附件副本路径
  items?: BusinessDocumentItem[];
  createdAt?: string;
}

function fromApiDocumentItem(r: any): BusinessDocumentItem {
  return {
    id: r.id,
    productId: r.product_id ?? null,
    description: r.description || '',
    quantity: r.quantity ?? null,
    unit: r.unit ?? null,
    unitPrice: r.unit_price ?? null,
    taxRate: r.tax_rate ?? null,
    taxAmount: r.tax_amount ?? 0,
    amount: r.amount ?? 0,
    lineNo: r.line_no ?? 0,
    refSalesId: r.ref_sales_id ?? null,
    refDate: r.ref_date ?? null,
  };
}

function fromApiDocument(r: any): BusinessDocument {
  return {
    id: r.id,
    docType: r.doc_type,
    docNumber: r.doc_number || '',
    status: r.status || 'draft',
    docDate: r.doc_date || '',
    validUntil: r.valid_until ?? null,
    customerName: r.customer_name || '',
    customerTaxId: r.customer_tax_id ?? null,
    customerAddress: r.customer_address ?? null,
    customerContact: r.customer_contact ?? null,
    accLocale: r.acc_locale || 'CN',
    subtotal: r.subtotal ?? 0,
    taxAmount: r.tax_amount ?? 0,
    total: r.total ?? 0,
    notes: r.notes ?? null,
    sourceSalesId: r.source_sales_id ?? null,
    periodStart: r.period_start ?? null,
    periodEnd: r.period_end ?? null,
    taxInvoiceIssued: !!r.tax_invoice_issued,
    taxInvoiceNumber: r.tax_invoice_number ?? null,
    taxInvoiceDate: r.tax_invoice_date ?? null,
    taxInvoiceAttachmentPath: r.tax_invoice_attachment_path ?? null,
    items: Array.isArray(r.items) ? r.items.map(fromApiDocumentItem) : undefined,
    createdAt: r.created_at,
  };
}

function toApiDocument(d: Partial<BusinessDocument>): any {
  const body: any = {};
  if (d.docType !== undefined) body.doc_type = d.docType;
  if (d.docNumber !== undefined) body.doc_number = d.docNumber;
  if (d.status !== undefined) body.status = d.status;
  if (d.docDate !== undefined) body.doc_date = d.docDate;
  if (d.validUntil !== undefined) body.valid_until = d.validUntil;
  if (d.customerName !== undefined) body.customer_name = d.customerName;
  if (d.customerTaxId !== undefined) body.customer_tax_id = d.customerTaxId;
  if (d.customerAddress !== undefined) body.customer_address = d.customerAddress;
  if (d.customerContact !== undefined) body.customer_contact = d.customerContact;
  if (d.accLocale !== undefined) body.acc_locale = d.accLocale;
  if (d.notes !== undefined) body.notes = d.notes;
  if (d.sourceSalesId !== undefined) body.source_sales_id = d.sourceSalesId;
  if (d.periodStart !== undefined) body.period_start = d.periodStart;
  if (d.periodEnd !== undefined) body.period_end = d.periodEnd;
  if (d.items !== undefined) {
    body.items = (d.items || []).map((it) => ({
      product_id: it.productId ?? null,
      description: it.description,
      quantity: it.quantity ?? null,
      unit: it.unit ?? null,
      unit_price: it.unitPrice ?? null,
      tax_rate: it.taxRate ?? null,
      tax_amount: it.taxAmount ?? 0,
      amount: it.amount ?? 0,
      line_no: it.lineNo ?? 0,
      ref_sales_id: it.refSalesId ?? null,
      ref_date: it.refDate ?? null,
    }));
  }
  return body;
}

export async function listDocuments(type?: BusinessDocType | 'all'): Promise<BusinessDocument[]> {
  const q = type && type !== 'all' ? `?type=${encodeURIComponent(type)}` : '';
  const rows = await apiFetch<any[]>(`/api/documents${q}`);
  return rows.map(fromApiDocument);
}

export async function getDocument(id: string): Promise<BusinessDocument> {
  const row = await apiFetch<any>(`/api/documents/${encodeURIComponent(id)}`);
  return fromApiDocument(row);
}

export async function createDocument(doc: Partial<BusinessDocument>): Promise<{ success: boolean; id: string }> {
  return apiFetch('/api/documents', { method: 'POST', body: JSON.stringify(toApiDocument(doc)) });
}

export async function updateDocument(id: string, patch: Partial<BusinessDocument>): Promise<void> {
  await apiFetch(`/api/documents/${encodeURIComponent(id)}`, { method: 'PUT', body: JSON.stringify(toApiDocument(patch)) });
}

export async function deleteDocument(id: string): Promise<void> {
  await apiFetch(`/api/documents/${encodeURIComponent(id)}`, { method: 'DELETE' });
}

/** 建议下一个内部单据编号（仅建议值，可编辑；不是正式发票号码） */
export async function fetchNextDocNumber(type: BusinessDocType): Promise<string> {
  const r = await apiFetch<{ number: string }>(`/api/documents/next-number?type=${encodeURIComponent(type)}`);
  return r.number;
}

// --- Phase D：正式税务发票关联（专用子路由，与通用编辑的 draft-only 规则解耦）---
// 仅记录外部开具的发票：已开标记/号码（手填）/日期/附件路径。
// 注意：toApiDocument 刻意不携带 tax 字段——通用 PUT 永远不写它们。

export interface DocTaxInvoicePatch {
  issued?: boolean;
  number?: string | null;
  date?: string | null;
  attachmentPath?: string | null;
}

export async function updateDocTaxInvoice(id: string, patch: DocTaxInvoicePatch): Promise<void> {
  const body: any = {};
  if (patch.issued !== undefined) body.tax_invoice_issued = patch.issued ? 1 : 0;
  if (patch.number !== undefined) body.tax_invoice_number = patch.number;
  if (patch.date !== undefined) body.tax_invoice_date = patch.date;
  if (patch.attachmentPath !== undefined) body.tax_invoice_attachment_path = patch.attachmentPath;
  await apiFetch(`/api/documents/${encodeURIComponent(id)}/tax-invoice`, { method: 'PUT', body: JSON.stringify(body) });
}

export interface DocAttachmentPickResult {
  ok: boolean;
  relPath?: string;   // 相对 userData 的副本路径（attachments/docs/...）
  fileName?: string;  // 用户原文件名（仅显示用）
  error?: string;     // INVALID_FILE_TYPE / FILE_TOO_LARGE / COPY_FAILED；取消时无 error
}

/** 选择发票附件：复制进 userData/attachments/docs/，返回相对路径（不落库，由保存统一持久化） */
export function pickDocAttachment(docId: string): Promise<DocAttachmentPickResult> {
  return electronInvoke<DocAttachmentPickResult>('app:pickDocAttachment', { docId });
}

/** 打开附件（系统默认应用）。error: INVALID_PATH / ATTACHMENT_NOT_FOUND / OPEN_FAILED */
export function openDocAttachment(relPath: string): Promise<{ ok: boolean; error?: string }> {
  return electronInvoke('app:openDocAttachment', { relPath });
}

/** 丢弃未保存的附件副本（选了又取消/重选时清理；被引用的文件会被拒绝） */
export function discardDocAttachment(relPath: string): Promise<{ ok: boolean; error?: string }> {
  return electronInvoke('app:discardDocAttachment', { relPath });
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

