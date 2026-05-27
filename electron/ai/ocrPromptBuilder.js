// Builds locale-aware OCR prompts for invoice extraction
// accountingLocale → tax regime, fields, currency
// uiLanguage → response language

const { getProfile } = require('./invoiceProfiles');

const LANG_INSTRUCTIONS = {
  'zh-CN': '请用简体中文回答。所有文本字段值用简体中文输出。',
  'zh-TW': '請用繁體中文回答。所有文字欄位值用繁體中文輸出。',
  en: 'Respond in English. Output all text field values in English.',
  ja: '日本語で回答してください。すべてのテキストフィールドは日本語で出力してください。',
  ko: '한국어로 답변하세요. 모든 텍스트 필드를 한국어로 출력하세요.',
  fr: 'Répondez en français. Tous les champs texte en français.',
};

const ROLE_INSTRUCTIONS = {
  'zh-CN': '你是一位专业的国际财务审计员，擅长识别全球各国发票和收据。',
  'zh-TW': '你是一位專業的國際財務審計員，擅長辨識全球各國發票和收據。',
  en: 'You are a professional international financial auditor, expert at extracting data from invoices and receipts worldwide.',
  ja: 'あなたはプロの国際財務監査員です。世界各国の請求書やレシートからデータを抽出する専門家です。',
  ko: '당신은 전문 국제 재무 감사인으로, 전 세계 송장과 영수증에서 데이터를 추출하는 전문가입니다.',
  fr: 'Vous êtes un auditeur financier international professionnel, expert en extraction de données depuis des factures et reçus du monde entier.',
};

function buildOutputSchema(profile) {
  const schema = {
    isInvoiceLike: 'boolean — true if this looks like an invoice/receipt/tax document, false otherwise',
    invoiceType: 'string — detected document type',
    date: 'string — YYYY-MM-DD',
    currency: `string — ISO currency code, default "${profile.defaultCurrency}"`,
  };

  if (profile.localeId === 'US') {
    Object.assign(schema, {
      vendorName: 'string — store/vendor/merchant name',
      subtotal: 'number — amount before tax',
      salesTax: 'number — sales tax amount (0 if none)',
      tip: 'number — tip amount (0 if none)',
      total: 'number — total amount paid',
      receiptNumber: 'string — receipt or invoice number',
      quantity: 'string — item quantity and unit if applicable',
      unitPrice: 'number — unit price if applicable (0 if not)',
    });
  } else if (profile.localeId === 'CN') {
    Object.assign(schema, {
      sellerName: 'string — 销方名称',
      buyerName: 'string — 购方名称',
      netAmount: 'number — 不含税金额',
      taxRate: 'string — tax rate, e.g. "13%"',
      taxAmount: 'number — 税额',
      grossAmount: 'number — 价税合计',
      invoiceNumber: 'string — 发票号码',
      quantity: 'string — quantity with unit',
      unitPrice: 'number — unit price excl. tax (0 if not found)',
      shipping: 'number — shipping cost (0 if none)',
    });
  } else if (profile.localeId === 'JP') {
    Object.assign(schema, {
      sellerName: 'string — supplier/seller name',
      buyerName: 'string — customer/buyer name (empty string if not found)',
      netAmount: 'number — tax-excluded amount (税抜)',
      taxRate: 'string — consumption tax rate, e.g. "10%"',
      taxAmount: 'number — consumption tax amount',
      grossAmount: 'number — tax-included total (税込)',
      invoiceNumber: 'string — invoice/receipt number',
      registrationNumber: 'string — 登録番号 if found (empty string if not)',
      quantity: 'string — quantity with unit if applicable',
      unitPrice: 'number — unit price (0 if not found)',
    });
  } else if (profile.localeId === 'EU') {
    Object.assign(schema, {
      sellerName: 'string — supplier name',
      buyerName: 'string — customer name (empty string if not found)',
      sellerVatId: 'string — supplier VAT registration number (empty string if not found)',
      buyerVatId: 'string — customer VAT registration number (empty string if not found)',
      netAmount: 'number — net amount (HT/netto)',
      vatRate: 'string — VAT rate, e.g. "20%"',
      vatAmount: 'number — VAT amount',
      grossAmount: 'number — gross amount (TTC/brutto)',
      invoiceNumber: 'string — invoice number',
      reverseCharge: 'boolean — true if reverse charge applies',
      quantity: 'string — quantity with unit if applicable',
      unitPrice: 'number — unit price (0 if not found)',
    });
  } else if (profile.localeId === 'KR') {
    Object.assign(schema, {
      sellerName: 'string — supplier name (공급자)',
      buyerName: 'string — customer name (공급받는자)',
      businessRegNumber: 'string — 사업자등록번호 (empty string if not found)',
      supplyAmount: 'number — 공급가액',
      vatAmount: 'number — 세액',
      total: 'number — 합계',
      invoiceNumber: 'string — invoice number',
      quantity: 'string — quantity with unit if applicable',
      unitPrice: 'number — unit price (0 if not found)',
    });
  } else if (profile.localeId === 'TW') {
    Object.assign(schema, {
      sellerName: 'string — seller name',
      buyerName: 'string — buyer name (empty string if not found)',
      sellerTaxId: 'string — seller 統一編號 (empty string if not found)',
      buyerTaxId: 'string — buyer 統一編號 (empty string if not found)',
      salesAmount: 'number — 銷售額',
      businessTax: 'number — 營業稅',
      total: 'number — total including tax',
      invoiceNumber: 'string — 發票號碼',
      quantity: 'string — quantity with unit if applicable',
      unitPrice: 'number — unit price (0 if not found)',
    });
  }

  return schema;
}

function schemaToJsonExample(schema) {
  const lines = Object.entries(schema).map(([k, desc]) => {
    if (desc.startsWith('number')) return `  "${k}": 0`;
    if (desc.startsWith('boolean')) return `  "${k}": true`;
    return `  "${k}": ""`;
  });
  return `{\n${lines.join(',\n')}\n}`;
}

function schemaToFieldDescriptions(schema) {
  return Object.entries(schema)
    .map(([k, desc]) => `  - ${k}: ${desc}`)
    .join('\n');
}

function buildPrompt(accountingLocale, uiLanguage) {
  const profile = getProfile(accountingLocale);
  const lang = uiLanguage || 'en';
  const role = ROLE_INSTRUCTIONS[lang] || ROLE_INSTRUCTIONS.en;
  const langInst = LANG_INSTRUCTIONS[lang] || LANG_INSTRUCTIONS.en;
  const schema = buildOutputSchema(profile);

  return `${role}

TASK: Analyze this image and determine if it is an invoice, receipt, or tax document. If it is, extract the structured data. If it is NOT an invoice-like document (e.g. a product label, brochure, menu, manual, nutrition facts, advertisement), return isInvoiceLike=false.

ACCOUNTING CONTEXT:
${profile.promptContext}

EXPECTED OUTPUT — strict JSON only (no markdown, no code blocks):

Field descriptions:
${schemaToFieldDescriptions(schema)}

JSON template:
${schemaToJsonExample(schema)}

RULES:
- Number fields must be numbers, not strings. Use 0 if not found.
- String fields use empty string "" if not found.
- Date must be YYYY-MM-DD format.
- If the document is clearly NOT an invoice/receipt/tax document, set isInvoiceLike to false and fill a "documentType" field describing what it is (e.g. "product_label", "menu", "brochure"), plus a "reason" field explaining why.
- If it IS an invoice-like document, set isInvoiceLike to true and extract all fields.
- Currency should be the ISO code (e.g. "EUR", "USD", "JPY"). Default to "${profile.defaultCurrency}" if unclear.

${langInst}`;
}

module.exports = { buildPrompt, buildOutputSchema };
