
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

export interface MarketPriceResult {
  platform: string;
  title: string;
  price: number;
  link: string;
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

export interface MergeSearchRequest {
  geminiRaw: string;
  braveResults: { title: string; url: string; content: string }[];
  tavilyResults: { title: string; url: string; content: string }[];
}
