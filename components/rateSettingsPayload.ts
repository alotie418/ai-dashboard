// Which rate fields a settings form is allowed to send — A4-1.
//
// A stored rate that does not read back as a finite number is DAMAGED, and a form
// that merely displays it must not launder it on the way out. The rule is one line
// and it is extracted here so it can be tested rather than trusted:
//
//   only rates the form actually holds a usable number for are sent.
//
// What it replaces, measured step by step:
//
//   stored '"25%"'  →  handler get() hands back the string "25%"
//                   →  Number("25%") is NaN, which the form put in state
//                   →  Save sent all four fields regardless of which was edited
//                   →  JSON.stringify(NaN) is the literal `null`
//                   →  the row became 'null', which reads back as Number(null) === 0
//
// So opening the accounting settings, changing only the currency and pressing Save
// silently rewrote the income-tax rate to 0%. That is the silent migration plan
// §6.4 item 3 forbids, and it was live in shipped UI code.
//
// Omitting a key is the honest move rather than sending a placeholder: the row keeps
// the user's own bytes, so the repair flow (native R8) still has the original to show
// them. Typing a replacement makes the field finite again and it is sent normally.

export interface RateFormValues {
  vatRate: number;
  surchargeRate: number;
  incomeTaxRate: number;
}

/// The rate slice of a settings payload: every field that holds a usable number,
/// and no key at all for the ones that do not.
///
/// `Number.isFinite` is the whole test, and it is deliberately the same predicate
/// the write gate applies server-side (`electron/handlers/_rateValue.js`): a value
/// this function passes must never be one the handler rejects, or the form would
/// fail a save it believed was fine.
export function rateSettingsPayload(values: RateFormValues): Record<string, number> {
  const payload: Record<string, number> = {};
  if (Number.isFinite(values.vatRate)) payload.vat_rate = values.vatRate;
  if (Number.isFinite(values.surchargeRate)) payload.surcharge_rate = values.surchargeRate;
  if (Number.isFinite(values.incomeTaxRate)) payload.income_tax_rate = values.incomeTaxRate;
  return payload;
}
