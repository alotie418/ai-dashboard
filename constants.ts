
import { BusinessData } from './types';

export const MOCK_BUSINESS_DATA: BusinessData = {
  metrics: [
    {
      label: '库存余量 (实时)',
      value: '—',
      subValue: '—',
      icon: 'fa-boxes',
      color: 'bg-blue-500'
    },
    {
      label: '2026年度 采购',
      value: '—',
      subValue: '—',
      icon: 'fa-truck-loading',
      color: 'bg-purple-500'
    },
    {
      label: '2026年度 销售',
      value: '—',
      subValue: '—',
      icon: 'fa-chart-line',
      color: 'bg-green-500'
    },
    {
      label: '平均成本',
      value: '—',
      subValue: '—',
      icon: 'fa-tags',
      color: 'bg-orange-500'
    },
  ],
  monthlyPerformance: [
    { name: '1月', revenue: 0, cost: 0, profit: 0, purchaseTons: 0, salesTons: 0, netProfit: 0, yoy: 0, mom: 0, deflator: 0 },
    { name: '2月', revenue: 0, cost: 0, profit: 0, purchaseTons: 0, salesTons: 0, netProfit: 0, yoy: 0, mom: 0, deflator: 0 },
    { name: '3月', revenue: 0, cost: 0, profit: 0, purchaseTons: 0, salesTons: 0, netProfit: 0, yoy: 0, mom: 0, deflator: 0 },
    { name: '4月', revenue: 0, cost: 0, profit: 0, purchaseTons: 0, salesTons: 0, netProfit: 0, yoy: 0, mom: 0, deflator: 0 },
    { name: '5月', revenue: 0, cost: 0, profit: 0, purchaseTons: 0, salesTons: 0, netProfit: 0, yoy: 0, mom: 0, deflator: 0 },
    { name: '6月', revenue: 0, cost: 0, profit: 0, purchaseTons: 0, salesTons: 0, netProfit: 0, yoy: 0, mom: 0, deflator: 0 },
    { name: '7月', revenue: 0, cost: 0, profit: 0, purchaseTons: 0, salesTons: 0, netProfit: 0, yoy: 0, mom: 0, deflator: 0 },
    { name: '8月', revenue: 0, cost: 0, profit: 0, purchaseTons: 0, salesTons: 0, netProfit: 0, yoy: 0, mom: 0, deflator: 0 },
    { name: '9月', revenue: 0, cost: 0, profit: 0, purchaseTons: 0, salesTons: 0, netProfit: 0, yoy: 0, mom: 0, deflator: 0 },
    { name: '10月', revenue: 0, cost: 0, profit: 0, purchaseTons: 0, salesTons: 0, netProfit: 0, yoy: 0, mom: 0, deflator: 0 },
    { name: '11月', revenue: 0, cost: 0, profit: 0, purchaseTons: 0, salesTons: 0, netProfit: 0, yoy: 0, mom: 0, deflator: 0 },
    { name: '12月', revenue: 0, cost: 0, profit: 0, purchaseTons: 0, salesTons: 0, netProfit: 0, yoy: 0, mom: 0, deflator: 0 },
  ],
  financialStatement: {
    salesRevenue: 0,
    costOfSales: 0,
    taxSurcharge: 0,
    shippingFee: 0,
    adminExpense: 0,
    incomeTax: 0,
    grossProfit: 0,
    grossMargin: 0,
    netProfit: 0,
    netMargin: 0
  },
  vatStatistics: {
    cumulativeInput: 0,
    cumulativeOutput: 0,
    certifiedInput: 0,
    invoicedOutput: 0,
    estimatedPayable: 0
  },
  taxInclusiveSummary: {
    purchaseTotal: 0,
    salesTotal: 0,
    difference: 0
  },
  categoryDistribution: [],
  recentOrders: [],
};

export const AI_SYSTEM_INSTRUCTION = `
你是一位资深财务与供应链分析 AI。你将获得 JSON 格式的业务运营数据。
你的分析重点包括：
1. 损益表盈利能力（毛利、净利）。
2. 税务统计（增值税进销项平衡）。
3. 吨位分析（采购与销售吨位平衡）。
4. 价格趋势（平减指数分析与通胀调整建议）。
5. 增长指标（同比、环比异常波动的根因推测）。
请务必使用中文回答，并提供执行摘要、核心洞察、行动建议和异常检测。
返回符合结构的 JSON。
`;
