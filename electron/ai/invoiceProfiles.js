// Invoice extraction profiles — one per accountingLocale
// Drives prompt generation, field expectations, and validation

const PROFILES = {
  CN: {
    localeId: 'CN',
    invoiceTypes: ['增值税专用发票', '增值税普通发票', '电子发票', '收据'],
    defaultCurrency: 'CNY',
    currencySymbol: '¥',
    taxRegime: 'Chinese VAT (增值税)',
    taxRates: [0.13, 0.09, 0.06, 0.03, 0],
    requiredFields: ['date', 'sellerName', 'buyerName', 'netAmount', 'taxRate', 'taxAmount', 'grossAmount', 'invoiceNumber'],
    optionalFields: ['quantity', 'unitPrice', 'shipping'],
    promptContext: `Tax regime: Chinese VAT (增值税).
Invoice types: 增值税专用发票, 增值税普通发票, 电子发票.
Common tax rates: 13% (standard goods), 9% (transport/agriculture), 6% (services), 3% (small-scale).
Fields on a Chinese VAT invoice: 开票日期, 购方名称, 销方名称, 金额(不含税), 税率, 税额, 价税合计, 发票号码.
Currency: CNY (¥).`,
    fieldAliases: {
      sellerName: ['销方名称', '销售方', '开票方'],
      buyerName: ['购方名称', '购买方', '收票方'],
      netAmount: ['金额', '不含税金额', '合计金额'],
      taxAmount: ['税额', '合计税额'],
      grossAmount: ['价税合计', '含税合计'],
      invoiceNumber: ['发票号码', '发票代码'],
      taxRate: ['税率'],
    },
  },

  US: {
    localeId: 'US',
    invoiceTypes: ['receipt', 'sales receipt', 'expense receipt', 'invoice'],
    defaultCurrency: 'USD',
    currencySymbol: '$',
    taxRegime: 'US Sales Tax / no VAT',
    taxRates: [0, 0.05, 0.06, 0.07, 0.08, 0.09, 0.10],
    requiredFields: ['date', 'vendorName', 'subtotal', 'total'],
    optionalFields: ['salesTax', 'tip', 'receiptNumber', 'paymentMethod', 'quantity', 'unitPrice'],
    promptContext: `Tax regime: US — no VAT system. Sales Tax varies by state (0-10%).
Document types: receipt, sales receipt, expense receipt, invoice.
Do NOT use VAT / Input VAT / Output VAT terminology.
Fields: transaction date, vendor/store name, subtotal (pre-tax), sales tax, tip (if any), total, receipt/invoice number.
Currency: USD ($).`,
    fieldAliases: {
      vendorName: ['vendor', 'store', 'merchant', 'seller'],
      subtotal: ['subtotal', 'sub-total', 'amount before tax'],
      salesTax: ['sales tax', 'tax', 'state tax'],
      total: ['total', 'amount due', 'total due', 'grand total'],
      receiptNumber: ['receipt #', 'invoice #', 'transaction #', 'order #'],
    },
  },

  JP: {
    localeId: 'JP',
    invoiceTypes: ['適格請求書', 'インボイス', '領収書', 'レシート'],
    defaultCurrency: 'JPY',
    currencySymbol: '¥',
    taxRegime: 'Japanese Consumption Tax (消費税)',
    taxRates: [0.10, 0.08],
    requiredFields: ['date', 'sellerName', 'netAmount', 'taxRate', 'taxAmount', 'grossAmount'],
    optionalFields: ['invoiceNumber', 'registrationNumber', 'buyerName', 'quantity', 'unitPrice'],
    promptContext: `Tax regime: Japanese Consumption Tax (消費税) — 10% standard, 8% reduced rate.
Invoice types: 適格請求書 (qualified invoice), インボイス, 領収書, レシート.
Under the Invoice System (インボイス制度), look for 登録番号 (registration number, format T + 13 digits).
Fields: date, supplier name, net amount (税抜), consumption tax rate, consumption tax amount (消費税額), total (税込), invoice/receipt number, registration number.
Currency: JPY (¥). JPY amounts are always integers (no decimals).`,
    fieldAliases: {
      sellerName: ['発行者', '売主', '店名'],
      registrationNumber: ['登録番号', 'T番号'],
      netAmount: ['税抜金額', '本体価格', '小計'],
      taxAmount: ['消費税額', '税額'],
      grossAmount: ['税込金額', '合計', '合計金額'],
    },
  },

  EU: {
    localeId: 'EU',
    invoiceTypes: ['VAT invoice', 'Facture', 'Rechnung', 'Factura', 'Fattura'],
    defaultCurrency: 'EUR',
    currencySymbol: '€',
    taxRegime: 'EU VAT',
    taxRates: [0.20, 0.19, 0.21, 0.10, 0.07, 0.05, 0],
    requiredFields: ['date', 'sellerName', 'buyerName', 'netAmount', 'vatRate', 'vatAmount', 'grossAmount', 'invoiceNumber'],
    optionalFields: ['sellerVatId', 'buyerVatId', 'reverseCharge', 'quantity', 'unitPrice'],
    promptContext: `Tax regime: EU VAT.
Invoice types: VAT invoice, Facture (FR), Rechnung (DE), Factura (ES), Fattura (IT).
VAT rates vary by country: DE 19%/7%, FR 20%/10%/5.5%, NL 21%/9%, IT 22%/10%/4%, ES 21%/10%/4%.
Look for VAT Registration Numbers (format varies: DE=DE123456789, FR=FRXX123456789, etc.).
Look for reverse charge indication if applicable.
Fields: invoice date, supplier name, customer name, supplier VAT ID, customer VAT ID, net amount (HT/netto), VAT rate, VAT amount, gross amount (TTC/brutto), invoice number.
Tax labels: VAT, TVA (FR), MwSt/USt (DE), IVA (IT/ES), BTW (NL/BE).
Currency: EUR (€) by default, but GBP (£), SEK, CHF, etc. are possible.`,
    fieldAliases: {
      sellerName: ['supplier', 'fournisseur', 'Lieferant', 'proveedor', 'fornitore'],
      buyerName: ['customer', 'client', 'Kunde', 'cliente'],
      vatAmount: ['VAT', 'TVA', 'MwSt', 'USt', 'IVA', 'BTW'],
      netAmount: ['net', 'HT', 'netto', 'base imponible', 'imponibile'],
      grossAmount: ['gross', 'TTC', 'brutto', 'total'],
    },
  },

  KR: {
    localeId: 'KR',
    invoiceTypes: ['세금계산서', '계산서', '영수증'],
    defaultCurrency: 'KRW',
    currencySymbol: '₩',
    taxRegime: 'Korean VAT (부가가치세)',
    taxRates: [0.10],
    requiredFields: ['date', 'sellerName', 'buyerName', 'supplyAmount', 'vatAmount', 'total'],
    optionalFields: ['invoiceNumber', 'businessRegNumber', 'quantity', 'unitPrice'],
    promptContext: `Tax regime: Korean VAT (부가가치세) — standard rate 10%.
Invoice types: 세금계산서 (tax invoice), 계산서, 영수증 (receipt).
Look for 사업자등록번호 (Business Registration Number, format XXX-XX-XXXXX).
Fields: date, supplier name (공급자), customer name (공급받는자), supply amount (공급가액), VAT amount (세액), total (합계), invoice number, business registration numbers.
Currency: KRW (₩). KRW amounts are always integers (no decimals).`,
    fieldAliases: {
      sellerName: ['공급자', '공급하는자'],
      buyerName: ['공급받는자'],
      supplyAmount: ['공급가액'],
      vatAmount: ['세액', '부가세'],
      total: ['합계', '합계금액'],
      businessRegNumber: ['사업자등록번호'],
    },
  },

  TW: {
    localeId: 'TW',
    invoiceTypes: ['統一發票', '電子發票', '收據'],
    defaultCurrency: 'TWD',
    currencySymbol: 'NT$',
    taxRegime: 'Taiwan Business Tax (營業稅)',
    taxRates: [0.05],
    requiredFields: ['date', 'sellerName', 'salesAmount', 'businessTax', 'total'],
    optionalFields: ['invoiceNumber', 'sellerTaxId', 'buyerTaxId', 'buyerName', 'quantity', 'unitPrice'],
    promptContext: `Tax regime: Taiwan Business Tax (營業稅) — standard rate 5%.
Invoice types: 統一發票 (uniform invoice), 電子發票 (electronic invoice), 收據.
Look for 統一編號 (Unified Business Number, 8 digits).
Fields: date, seller name, buyer name, seller 統一編號, buyer 統一編號, sales amount (銷售額), business tax (營業稅), total (含稅總計), uniform invoice number.
Currency: TWD (NT$).`,
    fieldAliases: {
      sellerName: ['賣方', '銷售人'],
      buyerName: ['買方', '買受人'],
      sellerTaxId: ['統一編號', '賣方統編'],
      salesAmount: ['銷售額', '金額'],
      businessTax: ['營業稅', '稅額'],
      total: ['含稅總計', '合計'],
      invoiceNumber: ['發票號碼'],
    },
  },
};

function getProfile(accountingLocale) {
  return PROFILES[accountingLocale] || PROFILES.CN;
}

module.exports = { PROFILES, getProfile };
