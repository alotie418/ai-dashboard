// 业务单据 PDF 模板（Phase B）— 数据驱动组装自包含打印 HTML
// 复用 #97 的通用 IPC app:exportReportPdf（{html, defaultFileName}，主进程零改动）。
// 与 FinancePage 的 buildPrintHtml 刻意不共享代码（边界：不动财务报表 PDF 逻辑），
// 本模块自带 escapeHtml 与内联 CSS（无 Tailwind/FontAwesome，CJK 由 Chromium 原生渲染）。
// 所有标签由调用方解析后传入（t() + getTaxLabel 按单据「冻结的 acc_locale」），
// 本模块零 i18n/零会计口径依赖；用户文本全量转义。
// ⚠️ 非税务开票：PDF 页脚固定携带免责声明（内部业务单据，非正式税务发票）。

import type { BusinessDocument } from '../services/api';

export interface CompanyInfoLite {
  name?: string;
  creditCode?: string;
  legalPerson?: string;
  industry?: string;
  address?: string;
}

export interface DocumentPdfLabels {
  lang: string;               // <html lang> 取 uiLanguage
  typeTitle: string;          // 单据类型名（已本地化）
  voidBadge: string;          // 已作废角标文案；非作废单据传 ''
  numberLabel: string;
  dateLabel: string;
  validUntilLabel: string;
  customerLabel: string;
  customerTaxIdLabel: string;
  customerAddressLabel: string;
  customerContactLabel: string;
  descriptionLabel: string;
  qtyLabel: string;
  unitPriceLabel: string;
  taxRateLabel: string;       // getTaxLabel(doc.accLocale, uiLang, 'formTaxRate')
  taxAmountLabel: string;     // 非 CN: headerTaxAmount / CN: tableHeaders.taxAmount
  amountLabel: string;
  subtotalLabel: string;
  totalLabel: string;         // 非 CN: headerTotalWithTax / CN: tableHeaders.totalWithTax
  notesLabel: string;
  generatedAtLabel: string;
  disclaimer: string;         // 制度中性免责声明，永不省略
}

export interface DocumentPdfOptions {
  money: (v: number) => string;                              // formatMoney 绑定单据冻结制度
  unitLabel: (unitKey: string | null | undefined) => string; // getProductUnitLabel 绑定 uiLang
  generatedAt: string;                                       // 调用方生成的本地化时间串
}

export const escapeHtml = (s: string): string =>
  String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');

// CJK 字体按 uiLanguage 排序：显式 font-family 列表会覆盖浏览器按 lang 的系统回退，
// 客户面单据需要正确的地区字形变体（ja 日文字形、zh-TW 繁体字形、ko 韩文优先；
// 其余保持简体优先）。仅排序差异，全部为系统字体、零嵌入。
const cjkFonts = (lang: string): string => {
  if (lang === 'ja') return '"Hiragino Sans","Hiragino Kaku Gothic ProN","Yu Gothic","Noto Sans CJK JP","PingFang SC"';
  if (lang === 'zh-TW') return '"PingFang TC","Hiragino Sans CNS","Microsoft JhengHei","Noto Sans CJK TC","PingFang SC"';
  if (lang === 'ko') return '"Apple SD Gothic Neo","Malgun Gothic","Noto Sans CJK KR","PingFang SC"';
  return '"PingFang SC","Hiragino Sans","Hiragino Kaku Gothic ProN","Microsoft YaHei","Noto Sans CJK SC"';
};

export function buildDocumentHtml(
  doc: BusinessDocument,
  company: CompanyInfoLite | null,
  L: DocumentPdfLabels,
  opts: DocumentPdfOptions,
): string {
  const e = escapeHtml;
  const items = doc.items || [];

  // 公司抬头（letterhead 风格：名称大字，税号/地址/负责人小字、为空跳过）
  const companyMeta = [company?.creditCode, company?.address, company?.legalPerson]
    .filter((v) => v && String(v).trim())
    .map((v) => `<span>${e(String(v))}</span>`)
    .join('');

  // 单据 meta 行：编号 / 日期 / 有效期（可选）
  const docMeta = [
    `<span>${e(L.numberLabel)}: ${e(doc.docNumber)}</span>`,
    `<span>${e(L.dateLabel)}: ${e(doc.docDate)}</span>`,
    doc.validUntil ? `<span>${e(L.validUntilLabel)}: ${e(doc.validUntil)}</span>` : '',
  ].join('');

  // 客户信息块（税号/地址/联系方式为空跳过）
  const custLines = [
    `<div class="cline"><span class="clabel">${e(L.customerLabel)}</span>${e(doc.customerName)}</div>`,
    doc.customerTaxId ? `<div class="cline"><span class="clabel">${e(L.customerTaxIdLabel)}</span>${e(doc.customerTaxId)}</div>` : '',
    doc.customerAddress ? `<div class="cline"><span class="clabel">${e(L.customerAddressLabel)}</span>${e(doc.customerAddress)}</div>` : '',
    doc.customerContact ? `<div class="cline"><span class="clabel">${e(L.customerContactLabel)}</span>${e(doc.customerContact)}</div>` : '',
  ].join('');

  // 明细行：数量与单位合并一格；空值留白；金额经调用方 money（冻结制度币种）
  const rows = items.map((it) => {
    const qty = it.quantity === null || it.quantity === undefined ? '' : String(it.quantity);
    const unit = opts.unitLabel(it.unit);
    const qtyCell = `${qty}${qty && unit ? ' ' : ''}${unit}`;
    const priceCell = it.unitPrice === null || it.unitPrice === undefined ? '' : opts.money(it.unitPrice);
    return `<tr>`
      + `<td>${e(it.description)}</td>`
      + `<td class="val">${e(qtyCell)}</td>`
      + `<td class="val">${e(priceCell)}</td>`
      + `<td class="val">${e(it.taxRate || '')}</td>`
      + `<td class="val">${e(opts.money(it.taxAmount || 0))}</td>`
      + `<td class="val">${e(opts.money(it.amount || 0))}</td>`
      + `</tr>`;
  }).join('');

  const voidBadge = L.voidBadge ? `<span class="void">${e(L.voidBadge)}</span>` : '';
  const notesBlock = doc.notes
    ? `<div class="notes"><div class="nlabel">${e(L.notesLabel)}</div>${e(doc.notes)}</div>`
    : '';

  return `<!DOCTYPE html><html lang="${e(L.lang)}"><head><meta charset="utf-8"><style>
*{box-sizing:border-box;}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",${cjkFonts(L.lang)},sans-serif;color:#191918;margin:0;padding:32px;font-size:13px;line-height:1.5;}
.hdr{border-bottom:2px solid #d97757;padding-bottom:14px;margin-bottom:16px;}
.company{font-size:20px;font-weight:700;}
.cmeta{margin-top:4px;font-size:11px;color:#5c5c5a;}
.cmeta span{margin-right:16px;}
.rname{font-size:16px;margin-top:12px;font-weight:700;color:#333;}
.void{margin-left:10px;font-size:11px;font-weight:700;color:#be123c;border:1px solid #be123c;border-radius:4px;padding:1px 6px;vertical-align:middle;}
.meta{margin-top:6px;font-size:11px;color:#5c5c5a;}
.meta span{margin-right:20px;}
.cust{margin:0 0 14px;font-size:12px;}
.cline{margin-top:2px;}
.clabel{display:inline-block;min-width:90px;color:#5c5c5a;margin-right:8px;}
table{width:100%;border-collapse:collapse;margin-top:4px;}
th{padding:7px 10px;border-bottom:2px solid #e0ddd5;font-size:11px;color:#5c5c5a;text-align:left;font-weight:600;}
th.val{text-align:right;}
td{padding:7px 10px;border-bottom:1px solid #eee;}
td.val{text-align:right;white-space:nowrap;font-variant-numeric:tabular-nums;}
.totals{margin-top:12px;margin-left:auto;width:60%;font-size:13px;}
.totals .trow{display:flex;justify-content:space-between;padding:4px 10px;}
.totals .grand{font-weight:700;font-size:14px;border-top:2px solid #e0ddd5;margin-top:4px;padding-top:8px;}
.notes{margin-top:18px;font-size:12px;color:#4a4a48;white-space:pre-wrap;}
.nlabel{font-weight:700;font-size:11px;color:#5c5c5a;margin-bottom:3px;}
.footer{margin-top:24px;font-size:10px;color:#8a8a88;border-top:1px solid #eee;padding-top:10px;}
</style></head><body>
<div class="hdr">
<div class="company">${e(company?.name || '—')}</div>
${companyMeta ? `<div class="cmeta">${companyMeta}</div>` : ''}
<div class="rname">${e(L.typeTitle)}${voidBadge}</div>
<div class="meta">${docMeta}</div>
</div>
<div class="cust">${custLines}</div>
<table>
<thead><tr><th>${e(L.descriptionLabel)}</th><th class="val">${e(L.qtyLabel)}</th><th class="val">${e(L.unitPriceLabel)}</th><th class="val">${e(L.taxRateLabel)}</th><th class="val">${e(L.taxAmountLabel)}</th><th class="val">${e(L.amountLabel)}</th></tr></thead>
<tbody>${rows}</tbody>
</table>
<div class="totals">
<div class="trow"><span>${e(L.subtotalLabel)}</span><span>${e(opts.money(doc.subtotal || 0))}</span></div>
<div class="trow"><span>${e(L.taxAmountLabel)}</span><span>${e(opts.money(doc.taxAmount || 0))}</span></div>
<div class="trow grand"><span>${e(L.totalLabel)}</span><span>${e(opts.money(doc.total || 0))}</span></div>
</div>
${notesBlock}
<div class="footer">${e(L.disclaimer)}<br>${e(L.generatedAtLabel)}: ${e(opts.generatedAt)}</div>
</body></html>`;
}
