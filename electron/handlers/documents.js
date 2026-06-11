// 业务单据 CRUD（Phase A）+ 正式税务发票关联（Phase D）
// 仅内部业务单据：非税务发票开具，不接税控/税局，正式发票号码只能手工录入
// （updateTaxInvoice 仅记录外部开具的发票信息），永不自动生成。
// 单据为自包含快照：明细/客户/金额保存时冻结；acc_locale 冻结创建时的会计制度。
// 纯增量：不触碰 purchases/sales/products/库存/金额税额计算。
// 注意：发票关联走专用子路由（PUT /:id/tax-invoice），与 update() 的 draft-only
// 编辑规则解耦——关联必须对「已签发」单据可用；update() 的 EDITABLE 白名单不动。

const { getDb } = require('../db');
const { isValidAttachmentRelPath, safeDeleteAttachment } = require('./attachments');

const DOC_TYPES = ['quotation', 'sales_order', 'proforma_invoice', 'commercial_invoice', 'statement'];
const DOC_STATUSES = ['draft', 'issued', 'void'];
const ACC_LOCALES = ['CN', 'US', 'JP', 'EU', 'KR', 'TW'];
// 内部单据编号前缀（仅作建议值，可编辑；不是正式发票号码）
const NUMBER_PREFIX = { quotation: 'QT', sales_order: 'SO', proforma_invoice: 'PI', commercial_invoice: 'CI', statement: 'ST' };
// 状态机：草稿可签发/作废；已签发只能作废；作废为终态
const STATUS_TRANSITIONS = { draft: ['issued', 'void'], issued: ['void'], void: [] };

function safeString(v, maxLen = 200) {
  if (v === undefined || v === null) return null;
  return String(v).slice(0, maxLen);
}

function num(v, fallback = 0) {
  const n = Number(v);
  return Number.isFinite(n) ? n : fallback;
}

function round2(v) {
  return Math.round(num(v) * 100) / 100;
}

// 唯一索引 (doc_type, doc_number) 冲突 → 翻成稳定错误码，前端显示友好提示
function runGuardingNumberConflict(fn) {
  try {
    return fn();
  } catch (e) {
    if (e && String(e.code || '').startsWith('SQLITE_CONSTRAINT')) throw new Error('DOC_NUMBER_EXISTS');
    throw e;
  }
}

function sanitizeItems(items) {
  if (!Array.isArray(items)) return [];
  return items
    .filter((it) => it && String(it.description || '').trim())
    .map((it, i) => ({
      product_id: safeString(it.product_id) || null,
      description: safeString(String(it.description).trim(), 500),
      quantity: it.quantity === null || it.quantity === undefined || it.quantity === '' ? null : num(it.quantity, null),
      unit: safeString(it.unit, 30) || null,
      unit_price: it.unit_price === null || it.unit_price === undefined || it.unit_price === '' ? null : num(it.unit_price, null),
      tax_rate: safeString(it.tax_rate, 20) || null,
      tax_amount: round2(it.tax_amount),
      amount: round2(it.amount),
      line_no: Number.isFinite(Number(it.line_no)) ? Number(it.line_no) : i,
      ref_sales_id: safeString(it.ref_sales_id) || null,
      ref_date: safeString(it.ref_date, 30) || null,
    }));
}

// 表头合计 = 明细行已存金额求和（只求和、不重算行金额，避免四舍五入差异）
function sumTotals(items) {
  const subtotal = round2(items.reduce((s, it) => s + num(it.amount), 0));
  const taxAmount = round2(items.reduce((s, it) => s + num(it.tax_amount), 0));
  return { subtotal, taxAmount, total: round2(subtotal + taxAmount) };
}

function resolveAccLocale(db, bodyValue) {
  if (ACC_LOCALES.includes(bodyValue)) return bodyValue;
  const row = db.prepare("SELECT value FROM settings WHERE key = 'accounting_locale'").get();
  let v = row ? row.value : 'CN';
  if (typeof v === 'string') { try { v = JSON.parse(v); } catch { /* raw string */ } }
  return ACC_LOCALES.includes(v) ? v : 'CN';
}

function loadItems(db, docId) {
  return db.prepare(
    `SELECT id, product_id, description, quantity, unit, unit_price, tax_rate, tax_amount, amount, line_no, ref_sales_id, ref_date
       FROM business_document_items WHERE doc_id = ? ORDER BY line_no, id`
  ).all(docId);
}

const HEADER_COLUMNS = `id, doc_type, doc_number, status, doc_date, valid_until,
       customer_name, customer_tax_id, customer_address, customer_contact,
       acc_locale, subtotal, tax_amount, total, notes, source_sales_id,
       period_start, period_end, tax_invoice_issued, tax_invoice_number,
       tax_invoice_date, tax_invoice_attachment_path, created_at, updated_at`;

// GET /api/documents?type=quotation
async function list({ query }) {
  const db = getDb();
  const type = query && query.type;
  if (type && type !== 'all') {
    if (!DOC_TYPES.includes(type)) throw new Error(`type must be one of ${DOC_TYPES.join('/')}`);
    return db.prepare(`SELECT ${HEADER_COLUMNS} FROM business_documents WHERE doc_type = ? ORDER BY doc_date DESC, created_at DESC`).all(type);
  }
  return db.prepare(`SELECT ${HEADER_COLUMNS} FROM business_documents ORDER BY doc_date DESC, created_at DESC`).all();
}

// GET /api/documents/next-number?type=quotation — 建议下一个内部编号（可编辑，仅建议）
async function nextNumber({ query }) {
  const db = getDb();
  const type = query && query.type;
  if (!NUMBER_PREFIX[type]) throw new Error(`type must be one of ${DOC_TYPES.join('/')}`);
  const prefix = NUMBER_PREFIX[type];
  const year = new Date().getFullYear();
  // LIKE 限定前缀 + 年份，再在 JS 里取数字后缀最大值（不能 MAX(TEXT)：
  // 用户自定义编号会污染字典序）
  const rows = db.prepare('SELECT doc_number FROM business_documents WHERE doc_type = ? AND doc_number LIKE ?')
    .all(type, `${prefix}-${year}-%`);
  let max = 0;
  for (const r of rows) {
    const m = /^[A-Z]{2}-\d{4}-(\d+)$/.exec(r.doc_number);
    if (m) max = Math.max(max, parseInt(m[1], 10));
  }
  return { number: `${prefix}-${year}-${String(max + 1).padStart(4, '0')}` };
}

// GET /api/documents/:id — 表头 + 明细
async function get({ params }) {
  const db = getDb();
  const id = params.id;
  if (!id) throw new Error('Invalid ID');
  const doc = db.prepare(`SELECT ${HEADER_COLUMNS} FROM business_documents WHERE id = ?`).get(id);
  if (!doc) throw new Error('Document not found');
  return { ...doc, items: loadItems(db, id) };
}

// POST /api/documents
async function create({ body }) {
  const db = getDb();
  const b = body || {};
  if (!DOC_TYPES.includes(b.doc_type)) throw new Error(`doc_type must be one of ${DOC_TYPES.join('/')}`);
  const docNumber = safeString(b.doc_number, 60);
  if (!docNumber || !docNumber.trim()) throw new Error('doc_number required');
  const customerName = safeString(b.customer_name, 200);
  if (!customerName || !customerName.trim()) throw new Error('customer_name required');
  if (!b.doc_date) throw new Error('doc_date required');

  const items = sanitizeItems(b.items);
  const totals = sumTotals(items);
  const accLocale = resolveAccLocale(db, b.acc_locale);
  const id = `doc-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;

  const insertDoc = db.prepare(`
    INSERT INTO business_documents (
      id, doc_type, doc_number, status, doc_date, valid_until,
      customer_name, customer_tax_id, customer_address, customer_contact,
      acc_locale, subtotal, tax_amount, total, notes, source_sales_id, period_start, period_end
    ) VALUES (?, ?, ?, 'draft', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);
  const insertItem = db.prepare(`
    INSERT INTO business_document_items (doc_id, product_id, description, quantity, unit, unit_price, tax_rate, tax_amount, amount, line_no, ref_sales_id, ref_date)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);

  runGuardingNumberConflict(() => db.transaction(() => {
    insertDoc.run(
      id, b.doc_type, docNumber.trim(), String(b.doc_date), safeString(b.valid_until, 30) || null,
      customerName.trim(), safeString(b.customer_tax_id, 100) || null, safeString(b.customer_address, 300) || null,
      safeString(b.customer_contact, 200) || null,
      accLocale, totals.subtotal, totals.taxAmount, totals.total,
      safeString(b.notes, 2000) || null, safeString(b.source_sales_id) || null,
      safeString(b.period_start, 30) || null, safeString(b.period_end, 30) || null,
    );
    for (const it of items) {
      insertItem.run(id, it.product_id, it.description, it.quantity, it.unit, it.unit_price, it.tax_rate, it.tax_amount, it.amount, it.line_no, it.ref_sales_id, it.ref_date);
    }
  })());
  return { success: true, id };
}

// PUT /api/documents/:id — 字段/明细仅草稿可改；状态按状态机流转（签发/作废）
async function update({ params, body }) {
  const db = getDb();
  const id = params.id;
  if (!id) throw new Error('Invalid ID');
  const existing = db.prepare('SELECT id, status FROM business_documents WHERE id = ?').get(id);
  if (!existing) throw new Error('Document not found');

  const b = body || {};
  if (b.status !== undefined && b.status !== existing.status) {
    if (!DOC_STATUSES.includes(b.status)) throw new Error(`status must be one of ${DOC_STATUSES.join('/')}`);
    if (!STATUS_TRANSITIONS[existing.status].includes(b.status)) {
      throw new Error(`Invalid status transition: ${existing.status} -> ${b.status}`);
    }
  }

  const EDITABLE = ['doc_type', 'doc_number', 'doc_date', 'valid_until', 'customer_name', 'customer_tax_id', 'customer_address', 'customer_contact', 'notes'];
  const editsFields = EDITABLE.some((k) => b[k] !== undefined) || b.items !== undefined;
  if (editsFields && existing.status !== 'draft') throw new Error('Only draft documents can be edited');

  const sets = [];
  const vals = [];
  if (b.doc_type !== undefined) {
    if (!DOC_TYPES.includes(b.doc_type)) throw new Error(`doc_type must be one of ${DOC_TYPES.join('/')}`);
    sets.push('doc_type = ?'); vals.push(b.doc_type);
  }
  if (b.doc_number !== undefined) {
    const n = safeString(b.doc_number, 60);
    if (!n || !n.trim()) throw new Error('doc_number cannot be empty');
    sets.push('doc_number = ?'); vals.push(n.trim());
  }
  if (b.doc_date !== undefined) {
    if (!b.doc_date) throw new Error('doc_date cannot be empty');
    sets.push('doc_date = ?'); vals.push(String(b.doc_date));
  }
  if (b.valid_until !== undefined) { sets.push('valid_until = ?'); vals.push(safeString(b.valid_until, 30) || null); }
  if (b.customer_name !== undefined) {
    const c = safeString(b.customer_name, 200);
    if (!c || !c.trim()) throw new Error('customer_name cannot be empty');
    sets.push('customer_name = ?'); vals.push(c.trim());
  }
  if (b.customer_tax_id !== undefined) { sets.push('customer_tax_id = ?'); vals.push(safeString(b.customer_tax_id, 100) || null); }
  if (b.customer_address !== undefined) { sets.push('customer_address = ?'); vals.push(safeString(b.customer_address, 300) || null); }
  if (b.customer_contact !== undefined) { sets.push('customer_contact = ?'); vals.push(safeString(b.customer_contact, 200) || null); }
  if (b.notes !== undefined) { sets.push('notes = ?'); vals.push(safeString(b.notes, 2000) || null); }
  if (b.status !== undefined && b.status !== existing.status) { sets.push('status = ?'); vals.push(b.status); }
  // acc_locale 创建时冻结，更新时忽略（单据口径不随设置切换漂移）

  let items = null;
  if (b.items !== undefined) {
    items = sanitizeItems(b.items);
    const totals = sumTotals(items);
    sets.push('subtotal = ?'); vals.push(totals.subtotal);
    sets.push('tax_amount = ?'); vals.push(totals.taxAmount);
    sets.push('total = ?'); vals.push(totals.total);
  }
  if (sets.length === 0 && items === null) return { success: true };

  sets.push("updated_at = datetime('now')");
  vals.push(id);

  const deleteItems = db.prepare('DELETE FROM business_document_items WHERE doc_id = ?');
  const insertItem = db.prepare(`
    INSERT INTO business_document_items (doc_id, product_id, description, quantity, unit, unit_price, tax_rate, tax_amount, amount, line_no, ref_sales_id, ref_date)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);

  runGuardingNumberConflict(() => db.transaction(() => {
    db.prepare(`UPDATE business_documents SET ${sets.join(', ')} WHERE id = ?`).run(...vals);
    if (items !== null) {
      deleteItems.run(id);
      for (const it of items) {
        insertItem.run(id, it.product_id, it.description, it.quantity, it.unit, it.unit_price, it.tax_rate, it.tax_amount, it.amount, it.line_no, it.ref_sales_id, it.ref_date);
      }
    }
  })());
  return { success: true };
}

// DELETE /api/documents/:id — 已签发不可直接删除（先作废）；明细随 FK CASCADE 删除；
// 附件副本随单据 best-effort 删除（目录自清洁，用户原文件不受影响）
async function remove({ params }) {
  const db = getDb();
  const id = params.id;
  if (!id) throw new Error('Invalid ID');
  const row = db.prepare('SELECT id, status, tax_invoice_attachment_path FROM business_documents WHERE id = ?').get(id);
  if (!row) throw new Error('Document not found');
  if (row.status === 'issued') throw new Error('DOC_ISSUED_VOID_FIRST');
  db.prepare('DELETE FROM business_documents WHERE id = ?').run(id);
  if (row.tax_invoice_attachment_path) safeDeleteAttachment(row.tax_invoice_attachment_path);
  return { success: true };
}

// PUT /api/documents/:id/tax-invoice — Phase D：正式税务发票关联。
// 仅记录外部开具的发票（手动标记/号码手填/日期/附件），永不开票、永不自动生成号码。
// 与 update() 的 draft-only 规则解耦：草稿/已签发可改，作废为只读（终态）。
// 附件路径替换/清除时 best-effort 删除旧副本（提交后执行，不影响事务）。
async function updateTaxInvoice({ params, body }) {
  const db = getDb();
  const id = params.id;
  if (!id) throw new Error('Invalid ID');
  const existing = db.prepare(
    'SELECT id, status, tax_invoice_attachment_path FROM business_documents WHERE id = ?'
  ).get(id);
  if (!existing) throw new Error('Document not found');
  if (existing.status === 'void') throw new Error('DOC_VOID_TAX_INVOICE_READONLY');

  const b = body || {};
  const sets = [];
  const vals = [];
  if (b.tax_invoice_issued !== undefined) {
    sets.push('tax_invoice_issued = ?'); vals.push(b.tax_invoice_issued ? 1 : 0);
  }
  if (b.tax_invoice_number !== undefined) {
    const n = safeString(b.tax_invoice_number, 100);
    sets.push('tax_invoice_number = ?'); vals.push(n && n.trim() ? n.trim() : null);
  }
  if (b.tax_invoice_date !== undefined) {
    sets.push('tax_invoice_date = ?'); vals.push(safeString(b.tax_invoice_date, 30) || null);
  }
  let oldPathToDelete = null;
  if (b.tax_invoice_attachment_path !== undefined) {
    const p = b.tax_invoice_attachment_path === null || b.tax_invoice_attachment_path === ''
      ? null : String(b.tax_invoice_attachment_path);
    if (p !== null && !isValidAttachmentRelPath(p)) throw new Error('INVALID_ATTACHMENT_PATH');
    // 所有权守卫：不得把另一张单据已关联的附件指给本单据——否则任一方替换/清除
    // 都会删掉共享文件，留下悬空引用（与 discard 通道的引用守卫对称）。
    if (p !== null && p !== existing.tax_invoice_attachment_path) {
      const inUse = db.prepare(
        'SELECT 1 FROM business_documents WHERE tax_invoice_attachment_path = ? AND id != ? LIMIT 1'
      ).get(p, id);
      if (inUse) throw new Error('ATTACHMENT_IN_USE');
    }
    sets.push('tax_invoice_attachment_path = ?'); vals.push(p);
    if (existing.tax_invoice_attachment_path && existing.tax_invoice_attachment_path !== p) {
      oldPathToDelete = existing.tax_invoice_attachment_path;
    }
  }
  if (sets.length === 0) return { success: true };

  sets.push("updated_at = datetime('now')");
  vals.push(id);
  db.prepare(`UPDATE business_documents SET ${sets.join(', ')} WHERE id = ?`).run(...vals);
  if (oldPathToDelete) safeDeleteAttachment(oldPathToDelete);
  return { success: true };
}

module.exports = { list, get, create, update, remove, nextNumber, updateTaxInvoice };
