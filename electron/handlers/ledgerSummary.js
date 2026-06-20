// Ledger summary snapshot — read-only aggregation (PR-7B-1)
//
// 各台账余额汇总快照。POLICY-NEUTRAL 只读聚合：
//   • 把 PR-7D 五张台账各自 SUM（仅启用行 is_active=1），按 currency 分组（不折算、不跨币种合计）；
//   • 这是「管理口径数据快照」，**NOT 资产负债表**：不分类(资产/负债/权益)、不做合计、不做平衡、
//     不做折旧/留存结转/税额对冲，不碰 P&L/cashflow/reports；
//   • tax_payments 仅作「已缴税款备查汇总」，独立返回 taxPaidMemo，不并入任何其它聚合。
// 无 schema 改动；不读/不写 electron/reports/*。镜像 inventory.summary / receivables.summary 只读模式。

const { getDb } = require('../db');

const round2 = (n) => Math.round((Number(n) || 0) * 100) / 100;

function tableExists(db, name) {
  return !!db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name=?").get(name);
}

// 对某表的金额列：仅启用行(is_active=1)、按 currency 分组求和；绝不跨币种合计、绝不折算。
function aggregateByCurrency(db, table, amountCol) {
  if (!tableExists(db, table)) return { count: 0, byCurrency: [] };
  const rows = db.prepare(
    `SELECT currency AS currency, COUNT(*) AS count, COALESCE(SUM(${amountCol}), 0) AS total
       FROM ${table} WHERE is_active = 1
      GROUP BY currency
      ORDER BY currency IS NULL, currency`
  ).all();
  const byCurrency = rows.map((r) => ({
    currency: r.currency || null,
    total: round2(r.total),
    count: r.count,
  }));
  const count = byCurrency.reduce((s, r) => s + r.count, 0);
  return { count, byCurrency };
}

// GET /api/ledger-summary
async function summary() {
  const db = getDb();
  return {
    snapshot: true,    // 管理口径数据快照，非资产负债表
    statutory: false,  // 非法定报表
    balanced: false,   // 不做平衡校验
    // 各台账独立罗列（不分类为资产/负债/权益，不做跨台账合计）
    accounts: aggregateByCurrency(db, 'accounts', 'opening_balance'),
    liabilities: aggregateByCurrency(db, 'liabilities', 'opening_balance'),
    fixedAssets: aggregateByCurrency(db, 'fixed_assets', 'original_value'),
    equity: aggregateByCurrency(db, 'equity', 'amount'),
    // 独立备查：不并入任何资产/负债/权益聚合
    taxPaidMemo: aggregateByCurrency(db, 'tax_payments', 'amount'),
  };
}

module.exports = { summary };
