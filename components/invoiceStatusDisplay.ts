// Invoice status badge display helper (UI-03).
//
// Display-only: classifies the raw invoiceStatus value (row.status) into a
// done / pending / unknown tone and maps it to a badge color. The stored value,
// the dropdown option values, and the create/update request bodies are NOT
// touched — this only changes how the status is rendered.
//
// The value space is open: the UI writes Chinese (待开/已开 for sales,
// 未收/已收 for purchases), but CSV import writes the raw cell verbatim and
// legacy migration can produce English (issued/pending/n/a). Classification
// mirrors the backend isIssuedInvoiceStatus() set (electron/handlers/ai.js) and
// stays bilingual + case-insensitive. Anything unrecognised is treated as
// `unknown` (neutral grey, raw value shown) so a status never falsely renders
// as the green "done" state.

export type InvoiceStatusTone = 'done' | 'pending' | 'unknown';

// done = an invoice exists / is issued / received / certified
const DONE_STATUSES = new Set([
  '已开', '已收', 'issued', 'paid', 'collected', 'invoiced', 'received', 'certified',
]);
// pending = explicitly awaiting an invoice
const PENDING_STATUSES = new Set([
  '待开', '待收', '未收', '未开', 'pending', 'unissued', 'n/a', 'na',
]);

export function classifyInvoiceStatus(raw?: string | null): InvoiceStatusTone {
  const trimmed = String(raw ?? '').trim();
  const lower = trimmed.toLowerCase();
  if (DONE_STATUSES.has(trimmed) || DONE_STATUSES.has(lower)) return 'done';
  if (PENDING_STATUSES.has(trimmed) || PENDING_STATUSES.has(lower)) return 'pending';
  return 'unknown';
}

// Tailwind badge classes per tone. The render site adds the shared
// `px-2 py-0.5 border rounded-md text-[10px] font-bold` shell; these supply the
// background / text / border-color only.
export const INVOICE_STATUS_BADGE_CLASS: Record<InvoiceStatusTone, string> = {
  done: 'bg-emerald-500/10 text-emerald-500 border-emerald-500/20',
  pending: 'bg-amber-500/10 text-amber-500 border-amber-500/20',
  unknown: 'bg-[#f0eeeb] text-[#5c5c5a] border-[#e0ddd5]',
};
