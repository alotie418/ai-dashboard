
export interface Metric {
  label: string;
  value: string;
  subValue: string;
  icon: string;
  color: string;
}

export interface FinancialStatementData {
  salesRevenue: number;
  costOfSales: number;
  taxSurcharge: number; // 税金及附加
  adminExpense: number; // 管理费用
  incomeTax: number; // 所得税费用
  shippingFee: number;
  grossProfit: number;
  grossMargin: number;
  netProfit: number;
  netMargin: number;
}

export interface VATData {
  cumulativeInput: number;
  cumulativeOutput: number;
  certifiedInput: number;
  invoicedOutput: number;
  estimatedPayable: number;
}

export interface TaxInclusiveSummaryData {
  purchaseTotal: number;
  salesTotal: number;
  difference: number;
}

export interface ChartData {
  name: string;
  revenue: number;
  cost: number;
  profit: number;
  purchaseTons: number;
  salesTons: number;
  netProfit: number;
  yoy: number | null; // Year-on-Year revenue growth % (null = no prior-year base period)
  mom: number | null; // Month-on-Month revenue growth % (null = no prior month / base 0)
  deflator: number | null; // Price index = unit-revenue / avg × 100 (null = no sales volume)
}

export interface CategoryData {
  name: string;
  value: number;
}

// Phase 3: per-product inventory (quantities kept per product/unit, never summed
// across products; total cost is money and IS summable).
export interface ProductInventoryLine {
  product_id: string;
  name: string;
  unit: string;        // products.unit key
  qtyOnHand: number;
  unitCost: number;
  lineCost: number;
}

export interface InventorySummary {
  inStockCount: number;        // products with qtyOnHand > 0
  totalInventoryCost: number;  // money — summable across products
  details: ProductInventoryLine[];
}

export interface BusinessData {
  locale?: string; // accountingLocale from dashboard handler
  metrics: Metric[];
  rawMetrics?: {
    inventoryTons: number;
    purchaseTotalTons: number;
    salesTotalTons: number;
  };
  monthlyPerformance: ChartData[];
  categoryDistribution: CategoryData[];
  financialStatement: FinancialStatementData;
  vatStatistics: VATData;
  taxInclusiveSummary: TaxInclusiveSummaryData;
  inventory?: InventorySummary;
  recentOrders: {
    id: string;
    customer: string;
    product: string;
    amount: number;
    status: 'Completed' | 'Processing' | 'Pending';
  }[];
}

export interface AIAnalysis {
  summary: string;
  topInsights: string[];
  recommendations: string[];
  anomalies: string[];
}

// ==================== Accounts Receivable/Payable (Feature 3) ====================

export interface PaymentUpdate {
  paid_amount: number;
  payment_date?: string;
}

export interface AgingBucket {
  '0-30': number;
  '31-60': number;
  '61-90': number;
  '90+': number;
}

export interface ReceivablesSummary {
  totalReceivable: number;
  totalOverdue: number;
  agingBuckets: AgingBucket;
  topCustomers: { name: string; amount: number }[];
  collectionRate: number;
  details: any[];
}

export interface PayablesSummary {
  totalPayable: number;
  totalOverdue: number;
  agingBuckets: AgingBucket;
  topSuppliers: { name: string; amount: number }[];
  paymentRate: number;
  details: any[];
}

// ==================== Alerts (Feature 4) ====================

export interface Alert {
  id: number;
  type: string;
  severity: 'critical' | 'warning' | 'info';
  title: string;
  message: string;
  data: string;
  is_read: number;
  is_dismissed: number;
  created_at: string;
}

export interface AlertsCountResponse {
  count: number;
}

// ==================== Batch Import (Feature 2) ====================

export interface BatchImportResult {
  success: number;
  failed: number;
  errors: { row: number; errors: string[] }[];
}

// (Agentic RAG / Market Research types removed — feature dropped for desktop)

// ==================== AI Providers (BYOK 多服务商) ====================

export type AIProviderId = 'anthropic' | 'openai' | 'gemini' | 'deepseek';

// 主进程内部使用（带 apiKey）
export interface AIProviderRecord {
  provider: AIProviderId;
  apiKey: string;
  model: string;
  enabled: boolean;
  isDefault: boolean;
}

// 单个推荐模型条目：label 给用户看，value 给 API 用
export interface ModelOption {
  label: string;
  value: string;
}

// 暴露给渲染端的（不含明文 apiKey，仅含 hasKey 标记）
export interface AIProviderConfig {
  provider: AIProviderId;
  name: string;            // 展示名（"Claude (Anthropic)" 等）
  hasKey: boolean;         // 是否已配置 Key
  model: string;           // 当前选中的 model ID（value）
  modelLabel: string;      // 当前 model 对应的展示名（不在白名单里时显示 "(自定义)"）
  modelIsKnown: boolean;   // 当前 model 是否在 availableModels 白名单内
  availableModels: ModelOption[];
  defaultModel: string;
  enabled: boolean;
  isDefault: boolean;
  supportsOCR: boolean;
  supportsWebGrounding: boolean;
}

export interface SaveProviderRequest {
  provider: AIProviderId;
  apiKey: string;
  model?: string;
  enabled?: boolean;
  setAsDefault?: boolean;
}

export interface TestProviderRequest {
  provider: AIProviderId;
  apiKey: string;
  model?: string;
}
