// Cash position — read-only period-end roll-forward PREVIEW (PR-7B P1-2).
//
// 现金/银行期末结转「只读预览」。POLICY-NEUTRAL：
//   • 公式（会计师 K-4）：endingEstimate = Σ accounts.opening_balance(启用) + 本期实收 − 本期实付，按币种。
//   • 只读：**不写回 accounts、不改任何历史交易**（sales/purchases/transactions）。
//   • 实收/实付沿用 _cashflow 口径，并用 selectReportSource 选源（本期有 transactions 用 transactions、
//     否则 legacy sales/purchases）→ 防「迁移数据与旧表双计」。
//   • 多币种**分币种列示、不折算、不跨币种合计**；legacy sales/purchases 无币种字段 → 按本位币归集。
//   • 仅经营活动实收付：**未含投资/筹资现金**（权益注资/借款/固定资产购建）→ 缺口属差额行（P1-3/P1-4）。
//   • 不做：balanceOverview / 资产负债概览 / 平衡差额 / 折旧 / 留存结转 / 税额对冲。不修改 electron/reports/*。
//
// 复用 electron/reports/_reportSource.js 的纯函数 selectReportSource（require·只读·不修改 reports）。

const { getDb } = require('../db');
const { selectReportSource } = require('../reports/_reportSource');

const round2 = (n) => Math.round((Number(n) || 0) * 100) / 100;

function tableExists(db, name) {
  return !!db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name=?").get(name);
}

function readBaseCurrency(db) {
  try {
    const row = db.prepare('SELECT value FROM settings WHERE key = ?').get('currency');
    return row ? JSON.parse(row.value) : 'CNY';
  } catch { return 'CNY'; }
}

// 同 _cashflow.txnCashAmount：已知为 paid/partial 的 transactions 行的实现现金。
function txnCashAmount(row) {
  if (row && row.paid_amount && row.paid_amount > 0) return row.paid_amount;
  return row && row.payment_status === 'paid' ? (row.amount || 0) : 0;
}

// GET /api/cash-position?from=YYYY-MM-DD&to=YYYY-MM-DD
async function summary({ query } = {}) {
  const db = getDb();
  const q = query || {};
  const year = q.year || String(new Date().getFullYear());
  const from = q.from || `${year}-01-01`;
  const to = q.to || `${year}-12-31`;
  const baseCurrency = readBaseCurrency(db);

  // 每币种聚合器：{ [currency]: { opening, inflow, outflow } }。null 币种用空串 key，输出时还原 null。
  const NULL_KEY = '__null__';
  const acc = new Map();
  const bucket = (ccy) => {
    const k = ccy == null ? NULL_KEY : ccy;
    if (!acc.has(k)) acc.set(k, { opening: 0, inflow: 0, outflow: 0 });
    return acc.get(k);
  };

  // 1) 期初：accounts.opening_balance，仅启用行，按币种（不写回，纯读）。
  if (tableExists(db, 'accounts')) {
    const rows = db.prepare(
      'SELECT currency AS currency, COALESCE(SUM(opening_balance), 0) AS total FROM accounts WHERE is_active = 1 GROUP BY currency'
    ).all();
    for (const r of rows) bucket(r.currency).opening += Number(r.total) || 0;
  }

  // 2) 本期实收/实付：选源防双计。
  const hasTransactionsTable = tableExists(db, 'transactions');
  const periodTxnCount = hasTransactionsTable
    ? db.prepare('SELECT COUNT(*) AS c FROM transactions WHERE date >= ? AND date <= ?').get(from, to).c
    : 0;
  const source = selectReportSource({ hasTransactionsTable, periodTxnCount });

  if (source === 'transactions') {
    // 现金日期 = COALESCE(payment_date, date)（缺 payment_date 回退到 date）；仅 paid/partial 计入。
    const rows = db.prepare(
      `SELECT type, currency, amount, paid_amount, payment_status
         FROM transactions
        WHERE payment_status IN ('paid','partial')
          AND COALESCE(payment_date, date) >= ? AND COALESCE(payment_date, date) <= ?`
    ).all(from, to);
    for (const r of rows) {
      const cashAmt = txnCashAmount(r);
      if (cashAmt <= 0) continue;
      const b = bucket(r.currency || baseCurrency);
      if (r.type === 'income') b.inflow += cashAmt;
      else if (r.type === 'expense') b.outflow += cashAmt;
    }
  } else {
    // legacy：sales(实收)/purchases(实付)，无币种字段 → 按本位币归集；缺 payment_date 的行不计入现金。
    const b = bucket(baseCurrency);
    if (tableExists(db, 'sales')) {
      b.inflow += db.prepare(
        `SELECT COALESCE(SUM(paid_amount), 0) AS s FROM sales
          WHERE payment_status IN ('paid','partial')
            AND payment_date IS NOT NULL AND payment_date >= ? AND payment_date <= ?`
      ).get(from, to).s || 0;
    }
    if (tableExists(db, 'purchases')) {
      b.outflow += db.prepare(
        `SELECT COALESCE(SUM(paid_amount), 0) AS s FROM purchases
          WHERE payment_status IN ('paid','partial')
            AND payment_date IS NOT NULL AND payment_date >= ? AND payment_date <= ?`
      ).get(from, to).s || 0;
    }
  }

  // 3) 组装：每币种 endingEstimate = opening + inflow − outflow（不跨币种合计）。
  const byCurrency = [...acc.entries()]
    .map(([k, v]) => ({
      currency: k === NULL_KEY ? null : k,
      opening: round2(v.opening),
      inflow: round2(v.inflow),
      outflow: round2(v.outflow),
      endingEstimate: round2(v.opening + v.inflow - v.outflow),
    }))
    .sort((a, b) => (a.currency === null ? 1 : b.currency === null ? -1 : String(a.currency).localeCompare(String(b.currency))));

  return {
    estimate: true,                 // 期末为估算（见 limitations）
    source,                         // 'transactions' | 'legacy'
    period: { from, to },
    baseCurrency,
    byCurrency,
    // 局限性 / 排除项（供前端如实呈现；P1 不做折算/合计/差额）：
    limitations: [
      'endingEstimate = 期初余额 + 本期实收 − 本期实付（按 payment_date）',
      '仅经营活动实收付；未含投资/筹资现金（权益注资、借款收款、固定资产购建付款）',
      '多币种分别列示，不折算、不跨币种合计',
      'paid_amount 为累计单字段、payment_date 为最后一次 → 跨期分期付款不精确',
      '只读：不写回 accounts、不修改任何历史交易',
    ],
    excludedNotes: [
      'transactions 缺 payment_date 时回退到 date；legacy sales/purchases 缺 payment_date 的行不计入现金',
      `legacy sales/purchases 无币种字段，按本位币(${baseCurrency})归集`,
      '已缴税款(tax_payments) / 应交税费估算 不参与现金结转（税属 P3）',
    ],
  };
}

module.exports = { summary };
