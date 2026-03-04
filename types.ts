
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
  yoy: number; // Year-on-Year growth %
  mom: number; // Month-on-Month growth %
  deflator: number; // Price deflator index
}

export interface CategoryData {
  name: string;
  value: number;
}

export interface BusinessData {
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

export type PlatformCategory = 'B2C' | 'B2B' | 'industry' | 'international';

export interface MarketPriceResult {
  platform: string;
  title: string;
  price: number;
  priceUnit?: string;  // 如 "元/kg"、"元/吨"、"元/袋"、"元/台"、"元"
  link: string;
  platformCategory?: PlatformCategory;
}

export interface MarketSummaryRow {
  label: string;
  value: string;
}

export interface MarketSearchResponse {
  analysis: string;
  prices: MarketPriceResult[];
  summaryTable?: MarketSummaryRow[];
}

export interface BraveSearchResult {
  title: string;
  url: string;
  description: string;
}

export interface BraveSearchResponse {
  web?: { results: BraveSearchResult[] };
}

export interface GeminiSearchProxyResponse {
  text: string;
  grounding: { title: string; uri: string }[];
}

export interface DirectPriceResult {
  product: string;
  price: number;
  priceUnit: string;
  spec?: string;
  region?: string;
  date?: string;
  source: string;
}

export interface DirectSearchResponse {
  prices: DirectPriceResult[];
  matched: boolean;
  sources: { name: string; keyword: string; url: string }[];
}

export interface InternationalSearchResult {
  title: string;
  url: string;
  description: string;
}

export interface InternationalSearchResponse {
  results: InternationalSearchResult[];
  translatedQuery: string;
  translationMethod: 'static' | 'static_partial' | 'gemini' | 'fallback_original';
  originalQuery: string;
}

export interface EcommerceSearchResult {
  title: string;
  url: string;
  description: string;
  category: string;
  categoryLabel: string;
}

export interface EcommerceSearchCategory {
  category: string;
  label: string;
  results: EcommerceSearchResult[];
}

export interface EcommerceSearchResponse {
  categories: EcommerceSearchCategory[];
  query: string;
}

export interface MergeSearchRequest {
  geminiRaw: string;
  braveResults: { title: string; url: string; content: string }[];
  tavilyResults: { title: string; url: string; content: string }[];
  directResults?: DirectPriceResult[];
  internationalResults?: { title: string; url: string; description: string }[];
  ecommerceResults?: EcommerceSearchCategory[];
}

// ==================== Price History (Feature 1) ====================

export interface PriceHistoryPoint {
  id: number;
  query: string;
  query_normalized: string;
  search_date: string;
  min_price: number;
  max_price: number;
  avg_price: number;
  price_count: number;
  price_unit: string;
  source_breakdown: string;
}

export interface PriceHistoryResponse {
  query: string;
  days: number;
  history: PriceHistoryPoint[];
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
