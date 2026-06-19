#!/usr/bin/env node
// PR-3c: unit test for the OCR → form mapping (services/ocrService.ts pure functions).
// Run with `node scripts/test-ocr-mapping.mjs` — Node (v23.6+) strips TS types natively when a .ts
// module is imported directly, so we exercise the app's real source.
// Locks: legacy-field → form mapping, missing text → '', missing numbers → 0 (never NaN/undefined),
// taxRate derived from tax/amount else the default, and sales-only `shipping`.

import { extractedToPurchaseForm, extractedToSalesForm, salesCounterparty } from '../services/ocrService.ts';

const failures = [];
const check = (name, cond) => { if (cond) console.log(`  ✓ ${name}`); else { console.log(`  ✗ ${name}`); failures.push(name); } };
const isNum = (v) => typeof v === 'number' && Number.isFinite(v);

console.log('\n=== OCR → form mapping (PR-3c) ===\n');

// A full, normalized ExtractedInvoice (legacy fields are what the pages consume).
// `customer` is the seller/counterparty flattened by normalizeToLegacy (= the supplier on a
// purchase invoice); buyerName is the purchaser (= the customer on a sales invoice). They must
// NOT be swapped: purchase.supplier ← seller, sales.customer ← buyer (Bug-3 reversal guard).
const full = {
  isInvoiceLike: true, date: '2026-06-13', currency: 'CNY', invoiceType: 'vat',
  customer: 'ACME Vendor', buyerName: 'Buyer Co', quantity: '10', price: 1000, taxAmount: 130,
  totalWithTax: 1130, unitPriceWithoutTax: 100, invoiceNo: 'INV-1', shipping: 50,
};

console.log('Purchase (full invoice):');
const p = extractedToPurchaseForm(full, '13%');
check('supplier ← seller (not buyer — no reversal)', p.supplier === 'ACME Vendor');
check('date', p.date === '2026-06-13');
check('quantity', p.quantity === '10');
check('totalWithTax number', p.totalWithTax === 1130 && isNum(p.totalWithTax));
check('price number', p.price === 1000 && isNum(p.price));
check('taxAmount number', p.taxAmount === 130 && isNum(p.taxAmount));
check('unitPriceWithoutTax number', isNum(p.unitPriceWithoutTax));
check('invoiceNo', p.invoiceNo === 'INV-1');
check('taxRate derived = 13%', p.taxRate === '13%');
check('no shipping field on purchase form', !('shipping' in p));

console.log('Purchase (sparse / missing fields):');
const sparse = { isInvoiceLike: true, date: '', currency: '', invoiceType: '', customer: '', quantity: '', price: 0, taxAmount: 0, totalWithTax: 0, unitPriceWithoutTax: 0, invoiceNo: '' };
const p2 = extractedToPurchaseForm(sparse, '9%');
check('missing supplier → "" (not fabricated)', p2.supplier === '');
check('missing quantity → ""', p2.quantity === '');
check('missing date → "" (page keeps its default)', p2.date === '');
check('missing numbers → 0 (never NaN/undefined)', isNum(p2.price) && p2.price === 0 && isNum(p2.totalWithTax) && p2.totalWithTax === 0 && isNum(p2.taxAmount) && p2.taxAmount === 0);
check('taxRate falls back to default', p2.taxRate === '9%');

console.log('Sales:');
const s = extractedToSalesForm(full, '13%');
check('customer ← buyerName (sales uses buyer, not seller — Bug-3 reversal guard)', s.customer === 'Buyer Co');
check('shipping ← extracted.shipping', s.shipping === 50 && isNum(s.shipping));
check('totalWithTax', s.totalWithTax === 1130);
check('taxRate derived = 13%', s.taxRate === '13%');
const s2 = extractedToSalesForm(sparse, '13%');
check('sales missing shipping → 0', s2.shipping === 0 && isNum(s2.shipping));
check('sales taxRate fallback', s2.taxRate === '13%');
check('sales has no supplier key (uses customer)', !('supplier' in s));
// buyerName empty → sales customer falls back to the flattened seller/customer (US receipts / legacy)
const sNoBuyer = extractedToSalesForm({ ...full, buyerName: '' }, '13%');
check('sales customer falls back to seller/customer when buyerName empty', sNoBuyer.customer === 'ACME Vendor');

console.log('Sales counterparty (shared by OCR preview + form fill):');
// salesCounterparty is the single source the preview modal AND extractedToSalesForm use,
// so the preview "客户" and the filled customer always agree (= buyer, not seller).
check('salesCounterparty ← buyerName (preview shows buyer)', salesCounterparty(full) === 'Buyer Co');
check('salesCounterparty falls back to seller/customer when buyerName empty', salesCounterparty({ ...full, buyerName: '' }) === 'ACME Vendor');
check('preview value === filled customer (consistent)', salesCounterparty(full) === extractedToSalesForm(full, '13%').customer);

console.log(`\n${failures.length === 0 ? '✓ all passed' : '✗ ' + failures.length + ' failed'}\n`);
process.exit(failures.length === 0 ? 0 : 1);
