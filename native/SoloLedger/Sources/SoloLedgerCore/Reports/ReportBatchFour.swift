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
/// | `cn.js:69-75` | `vatSummary` | cumulativeInput, cumulativeOutput, certifiedInput, invoicedOutput, estimatedPayable |
/// | `jp.js:46-49` | `consumptionTax` | collected, paid, payable |
/// | `eu.js:44-46` | `vatReturn` | outputVAT, inputVAT, vatPayable |
/// | `kr.js:41-43` | `vatSummary` | outputVAT, inputVAT, vatPayable |
/// | `tw.js:41-43` | `businessTax` | collected, paid, payable |
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
/// The clamp is mirrored exactly. ``CNVATSummary/unclampedDifference`` and its
/// siblings carry the un-clamped figure ALONGSIDE it as a disclosure, so the
/// information the clamp discards is not lost — but it is not part of the
/// contract and no golden contains it; see that property's own note.

/// `cn.js:69-75` — 增值税统计.
///
/// **Two of these five fields are duplicates of two others, by construction.**
/// `cumulativeInput` and `certifiedInput` are both `r(totalExpenseTax)`
/// (`cn.js:70` and `:72`); `cumulativeOutput` and `invoicedOutput` are both
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
public struct CNVATSummary: Equatable, Sendable {
    public let cumulativeInput: Double
    public let cumulativeOutput: Double
    /// Equal to ``cumulativeInput`` for every possible input — see the type note.
    public let certifiedInput: Double
    /// Equal to ``cumulativeOutput`` for every possible input — see the type note.
    public let invoicedOutput: Double
    /// `r(Math.max(0, totalIncomeTax - totalExpenseTax))` (`cn.js:32`, `:74`).
    public let estimatedPayable: Double

    /// The un-clamped `output - input`, rounded by this engine's own rounder.
    ///
    /// **NOT part of the Electron contract and NOT in any golden.** `cn.js` never
    /// emits it; it is carried because the clamp above turns a credit position into
    /// a `0` and a report that shows only the `0` cannot distinguish "nothing owed"
    /// from "135.85 carried forward". Negative here means input tax exceeded output
    /// tax for the period.
    ///
    /// Precedent for carrying a non-contract field on a mirrored struct:
    /// ``ScheduleC/rawMealsTotal``. As there, it is excluded from the golden
    /// comparison by construction — the parity test iterates the contract fields by
    /// name and asserts the golden block's key count, so this field can never be
    /// mistaken for one of them.
    ///
    /// It is a DISCLOSURE, not a correction: `estimatedPayable` still reports what
    /// the engine reports. Whether a credit position should be presented, and in
    /// what words, is a tax-presentation decision for the view layer.
    public let unclampedDifference: Double
}

/// `jp.js:46-49` — 消費税（仕入税額控除方式）.
public struct JPConsumptionTax: Equatable, Sendable {
    public let collected: Double
    public let paid: Double
    /// `r(Math.max(0, collected - paid))` — `jp.js:34`, already rounded when it is
    /// placed into the block at `:48` rather than rounded a second time.
    public let payable: Double
    /// The un-clamped `collected - paid`. See ``CNVATSummary/unclampedDifference``.
    public let unclampedDifference: Double
}

/// `eu.js:44-46` — VAT return summary.
public struct EUVATReturn: Equatable, Sendable {
    /// Output VAT is listed FIRST here, where China lists input first. Field order
    /// is not semantics, but it is what a reader comparing the two files sees.
    public let outputVAT: Double
    public let inputVAT: Double
    /// `r(Math.max(0, vatCollected - vatDeductible))` — `eu.js:32`.
    public let vatPayable: Double
    /// The un-clamped `outputVAT - inputVAT`. See ``CNVATSummary/unclampedDifference``.
    public let unclampedDifference: Double
}

/// `kr.js:41-43` — 부가가치세 요약.
///
/// Field-for-field identical to ``EUVATReturn`` and deliberately a separate type;
/// the block is even named differently upstream (`vatSummary`, the same key China
/// uses for a FIVE-field block). A consumer that switches on the key name alone
/// and assumes China's shape is exactly the `#414` defect.
public struct KRVATSummary: Equatable, Sendable {
    public let outputVAT: Double
    public let inputVAT: Double
    /// `r(Math.max(0, totalIncomeTax - totalExpenseTax))` — `kr.js:29`.
    public let vatPayable: Double
    /// The un-clamped `outputVAT - inputVAT`. See ``CNVATSummary/unclampedDifference``.
    public let unclampedDifference: Double
}

/// `tw.js:41-43` — 營業稅.
public struct TWBusinessTax: Equatable, Sendable {
    public let collected: Double
    public let paid: Double
    /// `r(Math.max(0, totalIncomeTax - totalExpenseTax))` — `tw.js:29`.
    public let payable: Double
    /// The un-clamped `collected - paid`. See ``CNVATSummary/unclampedDifference``.
    public let unclampedDifference: Double
}
