import { test, expect } from '@playwright/test';

// ───────────────────────────────────────────────────────────────────────────
// The browser oracle for the native app's `<input type="number">` and
// `<input type="date">` mirror.
//
// WHY THIS FILE EXISTS. The SwiftUI rewrite reproduces the three date and three
// numeric controls of `components/DocumentModal.tsx` in Swift. Until this round
// the only oracle for "what does the browser actually do" was a comment in the
// Swift source, and a Swift test that asserted the same thing the comment said.
// That is same-source self-证明: six of the nine shapes the Swift suite claimed
// the browser refuses are in fact submitted by it, and no test could see it.
//
// So the expectations below are measured HERE, against a real Chromium, and the
// Swift suite reads this file and maps its own answers onto the same named
// cases (`DocumentMountingTests.testDM29…`). Neither side can drift without the
// other going red.
//
// It runs inside the existing "Locale-matrix e2e (Playwright)" job — no new
// workflow, no new required check. It needs no application code: the harness is
// three inputs with exactly the attributes DocumentModal.tsx writes, fulfilled
// on the config's own origin so clipboard permissions apply.
//
// Measured on Chromium 148 / Electron 42.6.0 (148.0.7778.280). The two engines
// were compared field by field over this matrix and differ only in the language
// of `validationMessage`, which nothing here asserts.
// ───────────────────────────────────────────────────────────────────────────

test.use({ permissions: ['clipboard-read', 'clipboard-write'] });

// The attributes are DocumentModal.tsx's, verbatim: itemQty and itemUnitPrice
// carry `step="0.01" min="0"`, the tax rate adds `max="100"`. The submit button
// is `type="submit"` inside the `<form>`, which is what makes the browser's
// constraint validation decide whether a save can happen at all. `docNumber`,
// `docDate` and `customerName` are the modal's three `required` controls, filled
// in, so a refused submit is always the numeric field's doing.
const HARNESS = `<!doctype html><meta charset="utf-8"><title>oracle</title><body>
<form id="f">
  <input id="docNumber" type="text" required value="DOC-1">
  <input id="docDate" type="date" required value="2026-08-19">
  <input id="validUntil" type="date">
  <input id="customerName" type="text" required value="Acme">
  <input id="qty"   type="number" step="0.01" min="0"           name="itemQty-0">
  <input id="price" type="number" step="0.01" min="0"           name="itemUnitPrice-0">
  <input id="rate"  type="number" step="0.01" min="0" max="100" name="itemTaxRate-0">
  <button id="go" type="submit">save</button>
</form>
<script>
window.__submits = 0;
document.getElementById('f').addEventListener('submit', (e) => { e.preventDefault(); window.__submits++; });
</script></body>`;

const HARNESS_URL = 'http://127.0.0.1:4173/__documents-number-input-oracle';

// ── the named cases ────────────────────────────────────────────────────────
// ONE LINE PER CASE, and the shape is parsed by the Swift side — do not reflow.
//   typed   what the user types, character by character
//   editor  the text the control is left holding (read back through the clipboard)
//   bound   element.value; null means validity.badInput — the DOM reports both as
//           "" and the native mirror carries the difference as an Optional
//   submits whether clicking the type="submit" button fired the form's submit event
//   native  whether the native mirror allows the save. Equal to `submits` except
//           on the `b9-` rows, where the native step test is deliberately stricter — every
//           row whose two columns disagree carries that prefix, and DM29 pins the set.
export interface OracleCase {
  name: string; field: 'qty' | 'rate'; typed: string;
  editor: string; bound: string | null; submits: boolean; native: boolean;
}

export const NUMBER_ORACLE: OracleCase[] = [
  // ── layer 1: which characters the editor keeps ──
  { name: 'letter-between-digits', field: 'qty', typed: '1a2', editor: '12', bound: '12', submits: true, native: true },
  { name: 'letters-only', field: 'qty', typed: 'abc', editor: '', bound: '', submits: true, native: true },
  { name: 'doubled-point', field: 'qty', typed: '1..2', editor: '1.2', bound: '1.2', submits: true, native: true },
  { name: 'three-points', field: 'qty', typed: '1.2.3', editor: '1.23', bound: '1.23', submits: true, native: true },
  { name: 'doubled-exponent', field: 'qty', typed: '1e2e3', editor: '1e23', bound: '1e23', submits: true, native: true },
  { name: 'hex-prefix', field: 'qty', typed: '0x10', editor: '010', bound: '010', submits: true, native: true },
  { name: 'infinity-word', field: 'qty', typed: 'Infinity', editor: '', bound: '', submits: true, native: true },
  { name: 'leading-space', field: 'qty', typed: ' 1', editor: '1', bound: '1', submits: true, native: true },
  { name: 'underscore-separator', field: 'qty', typed: '1_0', editor: '10', bound: '10', submits: true, native: true },
  // ── layer 1: the fullwidth forms the control folds, and the ones it does not ──
  { name: 'fullwidth-digits', field: 'qty', typed: '１３', editor: '13', bound: '13', submits: true, native: true },
  { name: 'fullwidth-point', field: 'qty', typed: '１．５', editor: '1.5', bound: '1.5', submits: true, native: true },
  { name: 'fullwidth-minus', field: 'qty', typed: '－５', editor: '-5', bound: '-5', submits: false, native: false },
  { name: 'fullwidth-plus-dropped', field: 'qty', typed: '＋１．５', editor: '1.5', bound: '1.5', submits: true, native: true },
  { name: 'fullwidth-e-dropped', field: 'qty', typed: '１ｅ２', editor: '12', bound: '12', submits: true, native: true },
  { name: 'arabic-indic-digits', field: 'qty', typed: '٢٣', editor: '', bound: '', submits: true, native: true },
  { name: 'ext-arabic-indic-digits', field: 'qty', typed: '۲۳', editor: '', bound: '', submits: true, native: true },
  { name: 'devanagari-digits', field: 'qty', typed: '२३', editor: '', bound: '', submits: true, native: true },
  { name: 'bengali-digits', field: 'qty', typed: '২৩', editor: '', bound: '', submits: true, native: true },
  { name: 'thai-digits', field: 'qty', typed: '๒๓', editor: '', bound: '', submits: true, native: true },
  { name: 'roman-numeral', field: 'qty', typed: 'Ⅲ', editor: '', bound: '', submits: true, native: true },
  { name: 'vulgar-fraction', field: 'qty', typed: '½', editor: '', bound: '', submits: true, native: true },
  { name: 'superscript-two', field: 'qty', typed: '²', editor: '', bound: '', submits: true, native: true },
  { name: 'circled-digit', field: 'qty', typed: '②', editor: '', bound: '', submits: true, native: true },
  // ── layer 1: the exponent changes the rules for the characters after it ──
  // A point is dropped outright once the marker has been seen, a sign survives only while the
  // exponent is still empty, and a second marker never survives at all.
  { name: 'point-after-exponent', field: 'qty', typed: '1e2.3', editor: '1e23', bound: '1e23', submits: true, native: true },
  { name: 'point-right-after-exponent', field: 'qty', typed: '1e.2', editor: '1e2', bound: '1e2', submits: true, native: true },
  { name: 'doubled-exponent-sign', field: 'qty', typed: '1e++2', editor: '1e+2', bound: '1e+2', submits: true, native: true },
  { name: 'b9-sign-after-exponent-digit', field: 'qty', typed: '1e-2-3', editor: '1e-23', bound: '1e-23', submits: true, native: false },
  { name: 'mixed-exponent-signs', field: 'qty', typed: '1e-+2', editor: '1e-2', bound: '1e-2', submits: true, native: true },
  { name: 'sign-after-exponent-digit', field: 'qty', typed: '1e2-3', editor: '1e23', bound: '1e23', submits: true, native: true },
  { name: 'trailing-exponent-sign', field: 'qty', typed: '1e+2+', editor: '1e+2', bound: '1e+2', submits: true, native: true },
  { name: 'point-only-before-exponent', field: 'qty', typed: '1.2e3.4', editor: '1.2e34', bound: '1.2e34', submits: true, native: true },
  { name: 'doubled-exponent-marker', field: 'qty', typed: '1ee2', editor: '1e2', bound: '1e2', submits: true, native: true },
  { name: 'b9-exponent-marker-after-digit', field: 'qty', typed: '1e-2e3', editor: '1e-23', bound: '1e-23', submits: true, native: false },
  { name: 'point-before-and-after-exponent', field: 'qty', typed: '1.e.2', editor: '1.e2', bound: '1.e2', submits: true, native: true },
  { name: 'exponent-with-no-mantissa', field: 'qty', typed: 'e.2', editor: 'e2', bound: null, submits: false, native: false },
  { name: 'point-then-exponent-no-digits', field: 'qty', typed: '.e2', editor: '.e2', bound: null, submits: false, native: false },
  // ── layer 2: what element.value reads back ──
  { name: 'trailing-point', field: 'qty', typed: '1.', editor: '1.', bound: '1', submits: true, native: true },
  { name: 'trailing-point-five', field: 'qty', typed: '5.', editor: '5.', bound: '5', submits: true, native: true },
  { name: 'leading-plus', field: 'qty', typed: '+5', editor: '+5', bound: '5', submits: true, native: true },
  { name: 'leading-plus-point-five', field: 'qty', typed: '+.5', editor: '+.5', bound: '.5', submits: true, native: true },
  { name: 'leading-plus-trailing-point', field: 'qty', typed: '+1.', editor: '+1.', bound: '1', submits: true, native: true },
  { name: 'leading-minus-trailing-point', field: 'qty', typed: '-1.', editor: '-1.', bound: '-1', submits: false, native: false },
  { name: 'leading-plus-with-exponent', field: 'qty', typed: '+1e2', editor: '+1e2', bound: null, submits: false, native: false },
  { name: 'leading-minus-with-exponent', field: 'qty', typed: '-1e2', editor: '-1e2', bound: '-1e2', submits: false, native: false },
  { name: 'point-before-exponent', field: 'qty', typed: '1.e2', editor: '1.e2', bound: '1.e2', submits: true, native: true },
  { name: 'leading-point', field: 'qty', typed: '.5', editor: '.5', bound: '.5', submits: true, native: true },
  { name: 'leading-zeros', field: 'qty', typed: '0012', editor: '0012', bound: '0012', submits: true, native: true },
  { name: 'trailing-zeros', field: 'qty', typed: '2.500', editor: '2.500', bound: '2.500', submits: true, native: true },
  { name: 'minus-between-digits', field: 'qty', typed: '1-2', editor: '1-2', bound: null, submits: false, native: false },
  { name: 'exponent-no-digits', field: 'qty', typed: '1e', editor: '1e', bound: null, submits: false, native: false },
  { name: 'exponent-sign-no-digits', field: 'qty', typed: '1e-', editor: '1e-', bound: null, submits: false, native: false },
  { name: 'plus-alone', field: 'qty', typed: '+', editor: '+', bound: null, submits: false, native: false },
  { name: 'minus-alone', field: 'qty', typed: '-', editor: '-', bound: null, submits: false, native: false },
  { name: 'double-minus', field: 'qty', typed: '--5', editor: '--5', bound: null, submits: false, native: false },
  { name: 'empty', field: 'qty', typed: '', editor: '', bound: '', submits: true, native: true },
  { name: 'point-alone', field: 'qty', typed: '.', editor: '.', bound: null, submits: false, native: false },
  // ── layer 2: overflow is badInput, so the step test is never reached ──
  { name: 'overflow-exponent', field: 'qty', typed: '1e309', editor: '1e309', bound: null, submits: false, native: false },
  { name: 'overflow-int-max-exponent', field: 'qty', typed: '100e9223372036854775807', editor: '100e9223372036854775807', bound: null, submits: false, native: false },
  { name: 'overflow-exponent-past-int', field: 'qty', typed: '1e99999999999999999999', editor: '1e99999999999999999999', bound: null, submits: false, native: false },
  // ── layer 3: min / max / step ──
  { name: 'plain-integer', field: 'qty', typed: '12', editor: '12', bound: '12', submits: true, native: true },
  { name: 'two-decimals', field: 'qty', typed: '2.50', editor: '2.50', bound: '2.50', submits: true, native: true },
  { name: 'three-decimals', field: 'qty', typed: '1.005', editor: '1.005', bound: '1.005', submits: false, native: false },
  { name: 'four-decimals-via-exponent', field: 'qty', typed: '15e-4', editor: '15e-4', bound: '15e-4', submits: false, native: false },
  { name: 'two-decimals-via-exponent', field: 'qty', typed: '1500e-4', editor: '1500e-4', bound: '1500e-4', submits: true, native: true },
  { name: 'billions-with-cents', field: 'qty', typed: '1234567890.12', editor: '1234567890.12', bound: '1234567890.12', submits: true, native: true },
  { name: 'negative-below-min', field: 'qty', typed: '-5', editor: '-5', bound: '-5', submits: false, native: false },
  { name: 'zero', field: 'qty', typed: '0', editor: '0', bound: '0', submits: true, native: true },
  { name: 'quantity-has-no-max', field: 'qty', typed: '101', editor: '101', bound: '101', submits: true, native: true },
  { name: 'rate-above-max', field: 'rate', typed: '101', editor: '101', bound: '101', submits: false, native: false },
  { name: 'rate-at-max', field: 'rate', typed: '100', editor: '100', bound: '100', submits: true, native: true },
  { name: 'rate-negative', field: 'rate', typed: '-1', editor: '-1', bound: '-1', submits: false, native: false },
  // ── B9: the band where Blink's finite-precision Decimal stops seeing the remainder ──
  { name: 'b9-step-band-edge-refused', field: 'qty', typed: '15e-10', editor: '15e-10', bound: '15e-10', submits: false, native: false },
  { name: 'b9-step-band-edge-accepted', field: 'qty', typed: '15e-11', editor: '15e-11', bound: '15e-11', submits: true, native: false },
  { name: 'b9-denormal', field: 'qty', typed: '5e-324', editor: '5e-324', bound: '5e-324', submits: true, native: false },
  { name: 'b9-exponent-past-int', field: 'qty', typed: '1e-99999999999999999999', editor: '1e-99999999999999999999', bound: '1e-99999999999999999999', submits: true, native: false },
  { name: 'b9-exponent-at-int-max', field: 'qty', typed: '1.00e-9223372036854775807', editor: '1.00e-9223372036854775807', bound: '1.00e-9223372036854775807', submits: true, native: false },
  { name: 'b9-exponent-int-min-scale', field: 'qty', typed: '1.1e-9223372036854775807', editor: '1.1e-9223372036854775807', bound: '1.1e-9223372036854775807', submits: true, native: false },
];

// ── the date cases ─────────────────────────────────────────────────────────
//   assigned   what is put into the control
//   readBack   element.value afterwards; "" means the control refused it
//   native     whether the native mirror's isCalendarDate accepts `assigned`
export interface DateOracleCase {
  name: string; assigned: string; readBack: string; native: boolean;
}

export const DATE_ORACLE: DateOracleCase[] = [
  { name: 'year-0001', assigned: '0001-01-01', readBack: '0001-01-01', native: true },
  { name: 'year-9999', assigned: '9999-12-31', readBack: '9999-12-31', native: true },
  { name: 'leap-2024', assigned: '2024-02-29', readBack: '2024-02-29', native: true },
  { name: 'leap-2000', assigned: '2000-02-29', readBack: '2000-02-29', native: true },
  { name: 'no-leap-2023', assigned: '2023-02-29', readBack: '', native: false },
  { name: 'no-leap-1900', assigned: '1900-02-29', readBack: '', native: false },
  { name: 'proleptic-1500', assigned: '1500-02-29', readBack: '', native: false },
  { name: 'julian-gap-start', assigned: '1582-10-05', readBack: '1582-10-05', native: true },
  { name: 'julian-gap-end', assigned: '1582-10-15', readBack: '1582-10-15', native: true },
  { name: 'year-0000', assigned: '0000-01-01', readBack: '', native: false },
  { name: 'february-31', assigned: '2026-02-31', readBack: '', native: false },
  { name: 'month-13', assigned: '2026-13-01', readBack: '', native: false },
  { name: 'unpadded', assigned: '2026-1-1', readBack: '', native: false },
  { name: 'locale-shaped', assigned: '8/1/2026', readBack: '', native: false },
  // B10 — the four rows where the native mirror is deliberately narrower.
  { name: 'b10-year-10000', assigned: '10000-01-01', readBack: '10000-01-01', native: false },
  { name: 'b10-year-12345', assigned: '12345-06-07', readBack: '12345-06-07', native: false },
  { name: 'b10-year-99999', assigned: '99999-12-31', readBack: '99999-12-31', native: false },
  { name: 'b10-control-maximum', assigned: '275760-09-13', readBack: '275760-09-13', native: false },
  { name: 'past-control-maximum', assigned: '275760-09-14', readBack: '', native: false },
];

// ── driving ────────────────────────────────────────────────────────────────

async function openHarness(page: import('@playwright/test').Page) {
  await page.route(HARNESS_URL, (route) =>
    route.fulfill({ status: 200, contentType: 'text/html; charset=utf-8', body: HARNESS }));
  await page.goto(HARNESS_URL);
  await page.waitForSelector('#qty');
}

/** The editor's own text, which `element.value` cannot show: select it and copy it. */
async function editorText(page: import('@playwright/test').Page, id: string) {
  // A sentinel first, so an EMPTY field is distinguishable from a copy that did
  // nothing and left the previous contents on the clipboard.
  await page.evaluate(() => navigator.clipboard.writeText('<<empty>>'));
  await page.focus('#' + id);
  await page.keyboard.press('ControlOrMeta+A');
  await page.keyboard.press('ControlOrMeta+C');
  const text = await page.evaluate(() => navigator.clipboard.readText());
  // Collapse the selection the copy left behind, so a caller that keeps typing
  // is not silently replacing the whole field.
  await page.keyboard.press('End');
  return text === '<<empty>>' ? '' : text;
}

async function readField(page: import('@playwright/test').Page, id: string) {
  return page.evaluate((f) => {
    const el = document.getElementById(f) as HTMLInputElement;
    return { value: el.value, badInput: el.validity.badInput };
  }, id);
}

async function clickSave(page: import('@playwright/test').Page) {
  await page.evaluate(() => { (window as never as { __submits: number }).__submits = 0; });
  await page.click('#go');
  return page.evaluate(() => (window as never as { __submits: number }).__submits);
}

test.describe('documents page · the number control, three layers', () => {
  test('typing: editor text, bound value and submit', async ({ page }) => {
    await openHarness(page);
    for (const c of NUMBER_ORACLE) {
      await openHarness(page);
      await page.focus('#' + c.field);
      if (c.typed) await page.keyboard.type(c.typed);
      const read = await readField(page, c.field);
      const editor = await editorText(page, c.field);
      const submits = await clickSave(page);
      expect(editor, `${c.name}: editor text`).toBe(c.editor);
      expect(read.value, `${c.name}: element.value`).toBe(c.bound === null ? '' : c.bound);
      expect(read.badInput, `${c.name}: validity.badInput`).toBe(c.bound === null);
      expect(submits === 1, `${c.name}: the form submitted`).toBe(c.submits);
    }
  });

  test('pasting through the real clipboard gives the same answer as typing', async ({ page }) => {
    await openHarness(page);
    for (const c of NUMBER_ORACLE) {
      if (!c.typed) continue; // nothing to paste
      await openHarness(page);
      await page.evaluate((t) => navigator.clipboard.writeText(t), c.typed);
      await page.focus('#' + c.field);
      await page.keyboard.press('ControlOrMeta+V');
      const read = await readField(page, c.field);
      const submits = await clickSave(page);
      expect(read.value, `${c.name}: pasted element.value`).toBe(c.bound === null ? '' : c.bound);
      expect(read.badInput, `${c.name}: pasted validity.badInput`).toBe(c.bound === null);
      expect(submits === 1, `${c.name}: the form submitted after a paste`).toBe(c.submits);
    }
  });

  test('a keystroke can change the editor and leave element.value alone', async ({ page }) => {
    // WHAT THIS TEST MEASURES, EXACTLY: the DOM primitive React's value tracker observes —
    // the string `element.value` returns across a keystroke — and NOT React's `onChange`
    // itself. No React runs in this page.
    //
    // The link between the two is `updateValueIfChanged` in react-dom's `inputValueTracking`:
    // the synthetic change event is emitted only when that string has moved, so a keystroke
    // that leaves it alone reaches no `onChange` and therefore no `setRow`. The raw DOM
    // `input` event is deliberately not used as the primitive here — it fires on the
    // keystroke below carrying the same value as before, which is precisely the case React
    // drops, and reading it as "a change happened" is the mistake this whole round is about.
    await openHarness(page);
    await page.evaluate(() => {
      const el = document.getElementById('qty') as HTMLInputElement;
      (window as never as { __values: string[] }).__values = [];
      el.addEventListener('input', () => {
        (window as never as { __values: string[] }).__values.push(el.value);
      });
    });
    const values = () => page.evaluate(() => (window as never as { __values: string[] }).__values);
    await page.focus('#qty');
    await page.keyboard.type('2');
    expect(await values()).toEqual(['2']);

    await page.keyboard.type('.');
    expect(await editorText(page, 'qty'), 'the point IS in the editor').toBe('2.');
    expect(await values(),
      'the input event fired, and it carried the SAME value — which is what React drops')
      .toEqual(['2', '2']);

    await page.keyboard.press('Backspace');
    expect(await editorText(page, 'qty'), 'the editor is back to 2').toBe('2');
    expect(await values(), 'and the value never moved across either keystroke')
      .toEqual(['2', '2', '2']);

    await page.keyboard.type('5');
    expect(await values(), 'a keystroke that DOES move the value is visible in it')
      .toEqual(['2', '2', '2', '25']);
  });
});

test.describe('documents page · the date control', () => {
  test('what the control holds, and what it hands back', async ({ page }) => {
    await openHarness(page);
    for (const c of DATE_ORACLE) {
      const readBack = await page.evaluate((v) => {
        const el = document.getElementById('validUntil') as HTMLInputElement;
        el.value = v;
        return el.value;
      }, c.assigned);
      expect(readBack, `${c.name}: the control's value`).toBe(c.readBack);
    }
  });

  test('a five-digit year is keyboard-reachable and submits through a required date', async ({ page }) => {
    await openHarness(page);
    await page.focus('#docDate');
    await page.keyboard.press('ControlOrMeta+A');
    await page.keyboard.type('01');
    await page.keyboard.type('01');
    await page.keyboard.type('10000');
    expect(await page.evaluate(() => (document.getElementById('docDate') as HTMLInputElement).value))
      .toBe('10000-01-01');
    expect(await page.evaluate(() =>
      (document.getElementById('docDate') as HTMLInputElement).validity.valueMissing)).toBe(false);
    expect(await clickSave(page), 'the other app saves a document dated 10000-01-01').toBe(1);
  });

  test('an impossible date leaves the required control empty and blocks the save', async ({ page }) => {
    await openHarness(page);
    await page.focus('#docDate');
    await page.keyboard.press('ControlOrMeta+A');
    await page.keyboard.type('02');
    await page.keyboard.type('29');
    await page.keyboard.type('2023');
    expect(await page.evaluate(() => (document.getElementById('docDate') as HTMLInputElement).value))
      .toBe('');
    expect(await clickSave(page)).toBe(0);
  });
});
