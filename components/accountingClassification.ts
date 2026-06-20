// PR-7B P1-1: balance-overview classification metadata (constants only).
//
// 管理口径资产负债概览的「分类 / 标签映射」元数据。POLICY-NEUTRAL · 纯常量：
//   • 只声明每个数据源的 section（资产/负债/权益）与 liquidity（流动/非流动/按到期日/无）；
//   • 只声明 accountingLocale → 四套标签集（ASBE / US_GAAP / JGAAP / IFRS）的归并（六制度收敛 4 套）；
//   • 展示标签复用现有 i18n（finance.balance*，按 UI 语言）/ accountingLocaleConfig（bal*，按制度取制度名）；
//   • 借款（borrowings）行标签 = finance.balanceBorrowings（P1-4 已接入 i18n + UI）。
//
// 明确不含（P1-1 红线）：金额、小计、合计（assets/liabilities/equityTotal）、平衡差额、折旧、
//   留存收益结转、税额对冲、多币种折算，以及任何计算函数。本文件此刻**无运行时消费方**
//   （P1-3 balanceOverview / P1-4 UI 才接入），引入它对运行时行为零影响。
//   `includeInTotals` 是「声明性意图标记」（供 P1-3 使用），不是合计值；P1-1 本身不做任何合计。

export type BalanceSection = 'asset' | 'liability' | 'equity';
export type BalanceLiquidity = 'current' | 'non_current' | 'by_maturity' | 'none';
export type BalanceLabelSetId = 'ASBE' | 'US_GAAP' | 'JGAAP' | 'IFRS';
export type BalanceSourceKey =
  | 'cash' | 'receivables' | 'inventory' | 'fixedAssets'
  | 'payables' | 'taxPayable' | 'borrowings' | 'equity';

export interface BalanceClassificationEntry {
  /** 归类：资产 / 负债 / 权益。 */
  section: BalanceSection;
  /** 流动性。'by_maturity' = 由 liabilities.maturity_date 按一年线判定（P1-3 才计算，此处仅声明）。 */
  liquidity: BalanceLiquidity;
  /** liquidity === 'by_maturity' 时，空到期日的回退档（仅声明，不在此计算）。 */
  defaultLiquidity?: BalanceLiquidity;
  /** 展示标签键（finance.* 走 UI 语言；P1-4 已为所有源接入，含 finance.balanceBorrowings）。 */
  labelKey: string;
  /** 制度名键（accountingLocaleConfig.taxConcepts 的 key，按 accountingLocale 取制度名）；无则省略。 */
  regimeLabelKey?: string;
  /** 声明性意图：P1-3 是否纳入合计（taxPayable=false：P1 仅估算占位，不参与任何合计）。非合计值。 */
  includeInTotals: boolean;
  /** 说明性备注（不参与任何逻辑/计算）。 */
  note?: string;
}

// 数据源 → 归类元数据（纯声明，无金额、无计算）。
export const BALANCE_CLASSIFICATION: Record<BalanceSourceKey, BalanceClassificationEntry> = {
  cash:        { section: 'asset',     liquidity: 'current',     labelKey: 'finance.balanceCash',       includeInTotals: true },
  receivables: { section: 'asset',     liquidity: 'current',     labelKey: 'finance.balanceReceivable', regimeLabelKey: 'balRecvLabel', includeInTotals: true },
  inventory:   { section: 'asset',     liquidity: 'current',     labelKey: 'finance.balanceInventory',  includeInTotals: true },
  fixedAssets: { section: 'asset',     liquidity: 'non_current', labelKey: 'finance.balanceFixed',      includeInTotals: true, note: 'P1 用原值；折旧/净值属 P2' },
  payables:    { section: 'liability', liquidity: 'current',     labelKey: 'finance.balancePayable',    regimeLabelKey: 'balPayLabel', includeInTotals: true },
  taxPayable:  { section: 'liability', liquidity: 'current',     labelKey: 'finance.balanceTaxPayable', regimeLabelKey: 'balTaxPayLabel', includeInTotals: false, note: 'P1 仅估算占位，不参与任何合计；税额对冲属 P3' },
  borrowings:  { section: 'liability', liquidity: 'by_maturity', defaultLiquidity: 'current', labelKey: 'finance.balanceBorrowings', includeInTotals: true, note: '按 liabilities.maturity_date 一年线分；空到期日默认流动；行标签 finance.balanceBorrowings（P1-4 接入）' },
  equity:      { section: 'equity',    liquidity: 'none',        labelKey: 'finance.balanceEquity',     regimeLabelKey: 'balEquityHeader', includeInTotals: true },
};

// accountingLocale → 四套标签集（六制度收敛 4 套：EU / KR / TW 同归 IFRS 系）。
export const LABEL_SET_BY_LOCALE: Record<string, BalanceLabelSetId> = {
  CN: 'ASBE',
  US: 'US_GAAP',
  JP: 'JGAAP',
  EU: 'IFRS',
  KR: 'IFRS',
  TW: 'IFRS',
};
