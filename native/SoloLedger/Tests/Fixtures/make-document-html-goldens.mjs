// D-5 / Q7-b —— 导出产物的黄金：六语各一份，由 node 直接 import Electron 的真模板生成。
//
// 这不是「原生输出的快照」。它是**对面**的输出：`components/documentPdf.ts` 的
// `buildDocumentHtml` 在同一份输入下吐出的字节。原生 `DocumentHTML.build` 必须与它逐字节相等，
// 定义域见规格 Q7-b —— 非对账单 + currency IS NULL + CN 制度 + 注入固定 generatedAt。
//
// 「同一份输入」是字面意思：标签一律从**原生的 .strings** 读出来再喂给对面的模板，所以两边
// 唯一可能不同的就是结构、转义与数值格式化 —— 也正是这个端口该负责的东西。标签措辞本身的分叉
// （§3 的 B3/B4）不在这条线上，各有各的测试。
//
// 数值格式化要确定：`formatMoney` 走 `toLocaleString(undefined, …)`，宿主区域会改分隔符。
// 本脚本因此**要求** LC_ALL=en_US.UTF-8（解析不出 en-US 就直接退出），Swift 侧对应地钉
// `Locale(identifier: "en_US")`。两边都不许跟宿主走。
//
// 用法：npm run gen:document-html-goldens（校验用 npm run check:document-html-goldens）
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { buildDocumentHtml } from '../../../../components/documentPdf.ts';
import { formatMoney } from '../../../../components/accountingHelpers.ts';

const here = dirname(fileURLToPath(import.meta.url));
export const GOLDENS_DIR = join(here, 'documentHtml');
const STRINGS = join(here, '../../Sources/SoloLedger/Resources');

/** 原生语言码 → 产物里出的 Electron 码（规格 §3 · B7）。 */
export const LANGUAGES = [
  ['zh-Hans', 'zh-CN'], ['zh-Hant', 'zh-TW'], ['en', 'en'],
  ['ja', 'ja'], ['ko', 'ko'], ['fr', 'fr'],
];

/** `"key" = "value";`，认 C 风格转义，注释与空行跳过。 */
export function parseStrings(text) {
  const out = {};
  const re = /^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";/gm;
  const unescape = (s) => s.replace(/\\(.)/g, (_, c) => (c === 'n' ? '\n' : c === 't' ? '\t' : c));
  let m;
  while ((m = re.exec(text)) !== null) out[unescape(m[1])] = unescape(m[2]);
  return out;
}

/** 产物的固定输入。非对账单、currency 为 null、CN 制度 —— 正好落在 Q7-b 的定义域里。 */
export const FIXTURE = {
  id: 'doc-golden-1',
  docType: 'commercial_invoice',
  docNumber: 'CI-2026-0007',
  docDate: '2026-08-18',
  validUntil: '2026-09-30',
  customerName: 'Acme & Sons <Holdings>',
  customerTaxId: '91310000MA1FL0"X"9',
  customerAddress: "12 O'Connell Street",
  customerContact: 'ops@acme.example',
  accLocale: 'CN',
  currency: null,
  status: 'draft',
  subtotal: 1234.5,
  taxAmount: 160.49,
  total: 1394.99,
  notes: 'Pay within 30 days.\nBank: <Acme & Co>',
  periodStart: null,
  periodEnd: null,
  items: [
    { description: 'Widget <A> & "B"', quantity: 2, unit: 'piece', unitPrice: 50,
      taxRate: '13%', taxAmount: 13, amount: 100 },
    { description: 'No numbers at all', quantity: null, unit: null, unitPrice: null,
      taxRate: null, taxAmount: null, amount: null },
    { description: 'Zero quantity, unknown unit', quantity: 0, unit: 'carton', unitPrice: 0,
      taxRate: '', taxAmount: 0, amount: 0 },
    { description: '', quantity: 1234.5, unit: '', unitPrice: 1234.5,
      taxRate: '0%', taxAmount: 0, amount: 1234.5 },
  ],
};

/** 原生 `unitOptions` 的产物侧对应物：已知单位取 `product.unit.<raw>`，未知照原样，空则空串。 */
const UNIT_KEYS = ['unit', 'kg', 'ton', 'piece', 'box', 'bag', 'liter'];
export function unitLabel(table, raw) {
  if (!raw) return '';
  return UNIT_KEYS.includes(raw) ? (table[`product.unit.${raw}`] ?? raw) : raw;
}

export function labelsFor(table, electronLang) {
  return {
    lang: electronLang,
    typeTitle: table['documents.type.commercialInvoice'],
    voidBadge: '',
    numberLabel: table['documents.col.number'],
    dateLabel: table['documents.col.date'],
    validUntilLabel: table['documents.form.validUntil'],
    periodLabel: table['documents.print.period'],
    customerLabel: table['documents.col.customer'],
    customerTaxIdLabel: table['documents.form.customerTaxID'],
    customerAddressLabel: table['documents.form.customerAddress'],
    customerContactLabel: table['documents.form.customerContact'],
    descriptionLabel: table['documents.item.description'],
    qtyLabel: table['documents.item.quantity'],
    unitPriceLabel: table['documents.item.unitPrice'],
    taxRateLabel: table['documents.item.taxRate'],
    taxAmountLabel: table['documents.item.taxAmount'],
    amountLabel: table['documents.item.amount'],
    subtotalLabel: table['documents.total.subtotal'],
    totalLabel: table['documents.total.total'],
    notesLabel: table['documents.form.notes'],
    generatedAtLabel: table['documents.print.generatedAt'],
    disclaimer: table['documents.print.disclaimer'],
  };
}

/** B6：注入的固定时刻，ISO-8601 UTC。 */
export const GENERATED_AT = '2026-08-19T03:04:05Z';

export function renderAll() {
  const resolved = new Intl.NumberFormat().resolvedOptions().locale;
  if (resolved !== 'en-US') {
    throw new Error(`this generator needs LC_ALL=en_US.UTF-8; node resolved ${resolved}. `
      + 'The money strings would otherwise carry this host\'s separators into a committed golden.');
  }
  const out = new Map();
  for (const [nativeLang, electronLang] of LANGUAGES) {
    const table = parseStrings(readFileSync(join(STRINGS, `${nativeLang}.lproj/Localizable.strings`), 'utf8'));
    const L = labelsFor(table, electronLang);
    for (const [k, v] of Object.entries(L)) {
      if (typeof v !== 'string') throw new Error(`${nativeLang}: label ${k} is missing from the strings table`);
    }
    const html = buildDocumentHtml(FIXTURE, { name: 'SoloLedger Trading Co., Ltd.' }, L, {
      money: (v) => formatMoney(v, 'CN'),
      unitLabel: (u) => unitLabel(table, u),
      generatedAt: GENERATED_AT,
    });
    out.set(nativeLang, html);
  }
  return out;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  mkdirSync(GOLDENS_DIR, { recursive: true });
  const rendered = renderAll();
  writeFileSync(join(GOLDENS_DIR, 'fixture.json'),
                JSON.stringify({ generatedAt: GENERATED_AT, document: FIXTURE }, null, 2) + '\n');
  for (const [lang, html] of rendered) writeFileSync(join(GOLDENS_DIR, `${lang}.html`), html);
  console.log(`✓ document-html goldens: ${rendered.size} languages + fixture.json → ${GOLDENS_DIR}`);
}
