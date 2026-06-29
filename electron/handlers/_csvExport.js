// CSV 结构化导出助手（§2A）—— 纯 node，不依赖 electron，便于单测。
// 供会计师对接 / 迁出：把交易 / 采购 / 销售 / 单据按表导出为 CSV（UTF-8，含表头）。
//
// 安全两点：
//  1. RFC 4180 转义：含 " , 换行 的字段整体加引号、内部 " 转 ""；行分隔用 CRLF。
//  2. 防 CSV 公式注入：以 = + - @ TAB CR 开头的【文本】字段前缀单引号，避免 Excel 当公式执行
//     （OWASP 集合，含 -：如 "-2+3+cmd|..." 也是有效注入）。数字按数值原样输出（走 number 分支，
//     不经此处），故负数金额不受影响；只有以 - 开头的【文本】字段会被前缀（罕见、可接受）。

const EXPORTABLE_TABLES = {
  transactions: { table: 'transactions', order: 'date DESC, created_at DESC' },
  purchases: { table: 'purchases', order: 'date DESC' },
  sales: { table: 'sales', order: 'date DESC' },
  documents: { table: 'business_documents', order: 'doc_date DESC' },
  // 多商品明细子表（schema v20）。无 date 列，按「父 id + 行号」排序，使同一单的明细聚在一起；
  // 导出含 purchase_id/sale_id，可按 id 关联回 purchases/sales 主表 CSV。无任何凭证/密钥列。
  purchase_items: { table: 'purchase_items', order: 'purchase_id, line_no' },
  sales_items: { table: 'sales_items', order: 'sale_id, line_no' },
};

function csvCell(v) {
  if (v == null) return '';
  if (typeof v === 'number') return Number.isFinite(v) ? String(v) : '';
  let s = String(v);
  // 公式注入防护：文本以 = + - @ TAB CR 开头时前缀 '（数字走上面的 number 分支，不到这里）
  if (/^[=+\-@\t\r]/.test(s)) s = `'${s}`;
  // RFC 4180 转义
  if (/[",\n\r]/.test(s)) s = `"${s.replace(/"/g, '""')}"`;
  return s;
}

// rows: 对象数组；columns: 显式列顺序（缺省时取 rows[0] 的键）。空表也输出表头。
function rowsToCsv(rows, columns) {
  const cols = columns && columns.length ? columns : (rows.length ? Object.keys(rows[0]) : []);
  const lines = [cols.map(csvCell).join(',')];
  for (const r of rows) lines.push(cols.map((c) => csvCell(r[c])).join(','));
  return lines.join('\r\n') + '\r\n';
}

// 查指定表 → CSV。tableKey 必须在白名单内（表名 / 排序均来自固定字面量，无注入面）。
// columns 用 PRAGMA table_info 取，保证空表也有表头、列序与 schema 一致。
function tableToCsv(db, tableKey) {
  const spec = EXPORTABLE_TABLES[tableKey];
  if (!spec) throw new Error('INVALID_TABLE');
  const cols = db.prepare(`PRAGMA table_info(${spec.table})`).all().map((c) => c.name);
  const rows = db.prepare(`SELECT * FROM ${spec.table} ORDER BY ${spec.order}`).all();
  return { table: tableKey, rows: rows.length, csv: rowsToCsv(rows, cols) };
}

module.exports = { rowsToCsv, csvCell, tableToCsv, EXPORTABLE_TABLES };
