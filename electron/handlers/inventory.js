// Per-product on-hand inventory + total cost (Phase 3).
//   Quantities are kept PER product (each its own unit) — never summed across
//   products. Total inventory cost IS summable (money). Service items
//   (is_service=1), inactive products, and "unassigned" (product_id IS NULL)
//   rows are excluded. Reads legacy purchases/sales `tons`; changes no calc.

const { getDb } = require('../db');

function computeSummary(db) {
  let rows = [];
  try {
    rows = db.prepare(`
      SELECT
        p.id   AS product_id,
        p.name AS name,
        p.unit AS unit,
        p.default_unit_cost AS default_unit_cost,
        COALESCE(pin.qty_in, 0)  AS qty_in,
        COALESCE(pin.cost_in, 0) AS cost_in,
        COALESCE(sout.qty_out, 0) AS qty_out
      FROM products p
      LEFT JOIN (
        SELECT product_id, SUM(tons) AS qty_in, SUM(totalAmount) AS cost_in
        FROM purchases WHERE product_id IS NOT NULL GROUP BY product_id
      ) pin ON pin.product_id = p.id
      LEFT JOIN (
        SELECT product_id, SUM(tons) AS qty_out
        FROM sales WHERE product_id IS NOT NULL GROUP BY product_id
      ) sout ON sout.product_id = p.id
      WHERE p.is_service = 0 AND p.is_active = 1
    `).all();
  } catch {
    // products / purchases / sales may be missing on a very old DB
    return { inStockCount: 0, totalInventoryCost: 0, details: [] };
  }

  let inStockCount = 0;
  let totalInventoryCost = 0;
  const details = [];
  for (const r of rows) {
    const qtyOnHand = Math.round(((r.qty_in || 0) - (r.qty_out || 0)) * 100) / 100;
    if (qtyOnHand <= 0) continue; // only in-stock products
    // cost basis: explicit default unit cost, else weighted-average purchase cost
    const avgCost = (r.qty_in || 0) > 0 ? (r.cost_in || 0) / r.qty_in : 0;
    const unitCost = Math.round((r.default_unit_cost > 0 ? r.default_unit_cost : avgCost) * 100) / 100;
    const lineCost = Math.round(qtyOnHand * unitCost * 100) / 100;
    inStockCount += 1;
    totalInventoryCost += lineCost;
    details.push({ product_id: r.product_id, name: r.name, unit: r.unit, qtyOnHand, unitCost, lineCost });
  }
  return {
    inStockCount,
    totalInventoryCost: Math.round(totalInventoryCost * 100) / 100,
    details,
  };
}

// GET /api/inventory/summary
async function summary() {
  return computeSummary(getDb());
}

module.exports = { summary, computeSummary };
