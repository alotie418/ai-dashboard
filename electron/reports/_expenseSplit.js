// Expense partition helper (PR-T5) — split expense rows into COGS vs operating.
//
// A row is COGS iff its category has is_cogs = 1 (seeded for the 'cogs' slug in
// CN/JP/KR/TW and the 'purchases' slug in EU; see migration v13). Uncategorized
// rows and any non-COGS category are operating expenses.
//
// operatingExpensesNet is the EXACT complement of cogsNet
// (operatingExpensesNet = totalExpenseNet - cogsNet), so the identity
//   cogsNet + operatingExpensesNet === totalExpenseNet
// holds by construction — the split only re-partitions the same total, it never
// adds or drops an expense. This is the management-estimate invariant that keeps
// net profit unchanged by the split.
//
// `net()` matches the engines' existing convention (amount_net || amount || 0)
// so totalExpenseNet equals each engine's own pre-split expense total.

function isCogsRow(row, categories) {
  if (!row || row.category_id == null) return false;
  const cat = categories && categories.find((c) => c.id === row.category_id);
  return !!(cat && cat.is_cogs);
}

function net(row) {
  return row.amount_net || row.amount || 0;
}

function splitExpenses(expenseRows, categories) {
  const rows = expenseRows || [];
  const totalExpenseNet = rows.reduce((s, r) => s + net(r), 0);
  const cogsNet = rows.filter((r) => isCogsRow(r, categories)).reduce((s, r) => s + net(r), 0);
  const operatingExpensesNet = totalExpenseNet - cogsNet;
  return { totalExpenseNet, cogsNet, operatingExpensesNet };
}

module.exports = { splitExpenses, isCogsRow };
