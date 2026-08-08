import Foundation

/// Batch-4 output shapes: the five turnover-tax blocks.
///
/// ## Five types for what looks like one block
///
/// The engines emit this concept under five different key names with three
/// different field vocabularies:
///
/// | engine | block | fields |
/// | --- | --- | --- |
/// | `cn.js vatSummary` | `vatSummary` | cumulativeInput, cumulativeOutput, certifiedInput, invoicedOutput, estimatedPayable |
/// | `jp.js consumptionTax` | `consumptionTax` | collected, paid, payable |
/// | `eu.js vatReturn` | `vatReturn` | outputVAT, inputVAT, vatPayable |
/// | `kr.js vatSummary` | `vatSummary` | outputVAT, inputVAT, vatPayable |
/// | `tw.js businessTax` | `businessTax` | collected, paid, payable |
///
/// EU and KR are field-for-field identical and still get separate types, as do JP
/// and TW. Plan §1.2 forbids unifying the names, and the reason is not tidiness:
/// the one time a downstream consumer assumed two of these blocks were the same
/// shape, four of six accounting profiles printed five fabricated zeros under a
/// disclaimer that implied they were real (fixed in `#414`). A shared type here is
/// that assumption, compiled in.
///
/// ## What the whole batch does NOT read
///
/// No tax rate. Not `vat_rate`, not `surcharge_rate`, not `income_tax_rate`. These
/// blocks sum the `tax_amount` column that each row already carries, so they are
/// the largest remaining set of fields with no parameter risk — which is why the
/// plan schedules the jurisdiction-copy review here (§2, batch 4). Measured
/// against the goldens: the block is byte-identical across the `base`, `unset`,
/// `zero` and `malformed` rate variants, and `ReportBatch4ParityTests` asserts it.
///
/// They do not read `amount` or `amount_net` either, so the `||` net-amount
/// semantics that batches 1–2 turn on cannot arise here.
///
/// ## The clamp, and the number it hides
///
/// Every engine clamps the payable at zero — `Math.max(0, output - input)`. When
/// input tax exceeds output tax the real position is a CREDIT carried forward
/// (留抵税额), and the clamp reports it as `0`. The fixture reaches this: in
/// `base-CN-2025Q2` the ledger has 135.85 of input tax and no output tax, and the
/// golden says `estimatedPayable: 0`.
///
/// **The clamp is mirrored exactly, and nothing here compensates for it.** An
/// earlier revision of this batch also exported the un-clamped difference as a
/// disclosure field. That was an overreach and was removed: `electron/reports/*`
/// emits no such value and no golden contains one, so carrying it made a mirror
/// PR the place where a new number entered the product — which is precisely what
/// this phase's premise (逐字照搬公式、不做任何修正) exists to prevent. The
/// information the clamp discards is registered in plan Appendix A14 instead, and
/// re-introducing any form of it requires a separate, explicitly approved
/// non-mirror PR.

/// `cn.js vatSummary` — 增值税统计.
///
/// **Two of these five fields are duplicates of two others, by construction.**
/// `cumulativeInput` and `certifiedInput` are both `r(totalExpenseTax)`
/// (`cn.js cumulativeInput` and `:72`); `cumulativeOutput` and `invoicedOutput` are both
/// `r(totalIncomeTax)` (`:71`, `:73`). No input can separate them — verified over
/// 200 random draws against the real `cn.js`, and every committed CN golden shows
/// the pair equal.
///
/// So the card renders the same two numbers twice under labels that promise a
/// distinction the data does not have. The label side of that was already
/// de-escalated in the UI (`9c2931f` replaced "已认证进项税额" with "进项税额合计"),
/// and the R5 copy review resolved the display half by dropping the duplicate
/// section from the card — a separate Electron PR, not this one. **The engine
/// contract is unchanged here: all five fields are mirrored.**
struct CNVATSummary: Equatable, Sendable {
    let cumulativeInput: Double
    let cumulativeOutput: Double
    /// Equal to ``cumulativeInput`` for every possible input — see the type note.
    let certifiedInput: Double
    /// Equal to ``cumulativeOutput`` for every possible input — see the type note.
    let invoicedOutput: Double
    /// `r(Math.max(0, totalIncomeTax - totalExpenseTax))` (`cn.js vatPayable`, `:74`).
    let estimatedPayable: Double
}

/// `jp.js consumptionTax` — 消費税（仕入税額控除方式）.
struct JPConsumptionTax: Equatable, Sendable {
    let collected: Double
    let paid: Double
    /// `r(Math.max(0, collected - paid))` — `jp.js consumptionTaxPayable`, already rounded when it is
    /// placed into the block at `:48` rather than rounded a second time.
    let payable: Double
}

/// `eu.js vatReturn` — VAT return summary.
struct EUVATReturn: Equatable, Sendable {
    /// Output VAT is listed FIRST here, where China lists input first. Field order
    /// is not semantics, but it is what a reader comparing the two files sees.
    let outputVAT: Double
    let inputVAT: Double
    /// `r(Math.max(0, vatCollected - vatDeductible))` — `eu.js vatPayable`.
    let vatPayable: Double
}

/// `kr.js vatSummary` — 부가가치세 요약.
///
/// Field-for-field identical to ``EUVATReturn`` and deliberately a separate type;
/// the block is even named differently upstream (`vatSummary`, the same key China
/// uses for a FIVE-field block). A consumer that switches on the key name alone
/// and assumes China's shape is exactly the `#414` defect.
struct KRVATSummary: Equatable, Sendable {
    let outputVAT: Double
    let inputVAT: Double
    /// `r(Math.max(0, totalIncomeTax - totalExpenseTax))` — `kr.js vatPayable`.
    let vatPayable: Double
}

/// `tw.js businessTax` — 營業稅.
struct TWBusinessTax: Equatable, Sendable {
    let collected: Double
    let paid: Double
    /// `r(Math.max(0, totalIncomeTax - totalExpenseTax))` — `tw.js businessTaxPayable`.
    let payable: Double
}
