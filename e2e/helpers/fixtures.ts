// Shared mock data for the locale-matrix e2e suite.
//
// SETTINGS / DASHBOARD are the locale-agnostic JSON factories used by BOTH the
// legacy Web-boot path (bootCombo / page.route('**/api/**')) and the IPC-boot
// path (installElectronMock / electronAPI.invoke('api:request')). Keeping them in
// one place guarantees the two boot mechanisms return byte-identical data, so the
// rendered DOM — and therefore every forbidden-word / i18n assertion — is the same
// regardless of how the app was booted. (Phase 3 e2e IPC migration.)

export const SETTINGS = (acc: string) => ({
  accounting_locale: acc,
  product_unit: 'ton',
  company_name: 'Test Co',
  legal_person: 'Tester',
  vat_rate: acc === 'TW' ? '5%' : acc === 'US' ? '7%' : '13%',
  industry: 'Trade',
});

export const DASHBOARD = (acc: string) => ({
  locale: acc,
  metrics: { inventoryTons: 0, purchaseTotalTons: 0, purchaseTotalAmount: 0, salesTotalTons: 0, salesTotalAmount: 0, avgCostPerTon: 0 },
  monthlyPerformance: [],
  financialStatement: { salesRevenue: 0, costOfSales: 0, costOfGoodsSold: 0, operatingExpenses: 0, operatingProfit: 0, taxSurcharge: 0, adminExpense: 0, incomeTax: 0, shippingFee: 0, grossProfit: 0, grossMargin: 0, netProfit: 0, netMargin: 0 },
  vatStatistics: { cumulativeInput: 0, cumulativeOutput: 0, certifiedInput: 0, invoicedOutput: 0, estimatedPayable: 0 },
  taxInclusiveSummary: { purchaseTotal: 0, salesTotal: 0, difference: 0 },
  inventory: { inStockCount: 1, totalInventoryCost: 100, details: [{ product_id: 'p1', name: 'Item-A', unit: 'piece', qtyOnHand: 10, unitCost: 10, lineCost: 100 }] },
});
