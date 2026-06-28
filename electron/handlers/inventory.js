// Per-product on-hand inventory + total cost (Phase 3).
//   Quantities are kept PER product (each its own unit) — never summed across
//   products. Total inventory cost IS summable (money). Service items
//   (is_service=1), inactive products, and "unassigned" (product_id IS NULL)
//   rows are excluded. Cost basis is tax-EXCLUSIVE (amountWithoutTax /
//   amount_net), matching the P&L COGS basis (PR-T4).
//   Sources (P3): legacy single-item headers (purchases/sales `tons`) UNION ALL
//   the multi-line items (purchase_items/sales_items `quantity`). A header that
//   carries line items is excluded from the legacy source (NOT EXISTS) so each
//   record is counted exactly once — via its items. The weighted-average cost
//   formula below is unchanged; P3 only widened where qty/cost come from.

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
        -- Purchases IN, per product: legacy single-item headers UNION ALL multi-line
        -- items. A header that now carries items is excluded from the legacy source
        -- (NOT EXISTS) so its qty/cost is counted once — via items. Cost stays
        -- tax-exclusive (amountWithoutTax / amount_net).
        SELECT product_id, SUM(qty) AS qty_in, SUM(cost) AS cost_in FROM (
          SELECT product_id, tons AS qty, COALESCE(amountWithoutTax, totalAmount) AS cost
          FROM purchases
          WHERE product_id IS NOT NULL
            AND NOT EXISTS (SELECT 1 FROM purchase_items pi WHERE pi.purchase_id = purchases.id)
          UNION ALL
          SELECT product_id, quantity AS qty, amount_net AS cost
          FROM purchase_items WHERE product_id IS NOT NULL
        ) GROUP BY product_id
      ) pin ON pin.product_id = p.id
      LEFT JOIN (
        -- Sales OUT, per product: legacy headers UNION ALL multi-line items (same
        -- NOT EXISTS de-dup; out only needs quantity).
        SELECT product_id, SUM(qty) AS qty_out FROM (
          SELECT product_id, tons AS qty
          FROM sales
          WHERE product_id IS NOT NULL
            AND NOT EXISTS (SELECT 1 FROM sales_items si WHERE si.sale_id = sales.id)
          UNION ALL
          SELECT product_id, quantity AS qty
          FROM sales_items WHERE product_id IS NOT NULL
        ) GROUP BY product_id
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
    // cost basis (tax-exclusive): explicit default unit cost, else weighted-average purchase cost
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
