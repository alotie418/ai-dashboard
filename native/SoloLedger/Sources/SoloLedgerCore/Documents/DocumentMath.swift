import Foundation

/// The business-document arithmetic, moved from the interface into Core.
///
/// `docs/BUSINESS_DOCUMENTS_SPEC.md` Q4 and Q9 together say what this file is: Electron computes a
/// document's line amounts in the **editor** (`components/DocumentModal.tsx computed`) and only sums
/// them in the **handler** (`electron/handlers/documents.js sumTotals`); the native port moves the
/// computation into Core, **but reproduces the arithmetic and the rounding chain word for word**.
/// The acceptance bar Q9 sets is equality with Electron on the same input, so nothing here may be
/// tidied — not the double rounding, not the falsy folding, not the two different `round2`s.
///
/// ## There really are TWO `round2`s, and they are not the same function
///
/// | source | expression | `-0` | `±∞` |
/// | --- | --- | --- | --- |
/// | `DocumentModal.tsx:52` | `Math.round((v \|\| 0) * 100) / 100` | `+0` | `±∞` |
/// | `documents.js:30-32` | `Math.round(num(v) * 100) / 100`, `num` = finite-or-0 | `-0` | `0` |
///
/// `-0` is falsy, so the editor's `|| 0` flattens it; `Infinity` is truthy, so the editor's chain
/// carries it through while the handler's `Number.isFinite` test folds it to zero. Measured in node
/// over 12,045 scalars: the two chains disagree on exactly those three values and nowhere else.
/// Which one applies is decided by WHICH SIDE of the Electron split a value came from, so both are
/// here under names that say so — ``lineRound2(_:)`` and ``storedRound2(_:)``.
///
/// ## Why `round(_:)` is a third copy of `Math.round` rather than a call
///
/// `ReportMath.round` and `MonthlyComparisons.jsRound` already implement this rule. The convention
/// this package settled on — stated at `InventoryPosting.swift:41` and again at
/// `MonthlyComparisons.swift`'s `jsRound` — is **one rounding rule per subsystem that needs one**,
/// so that a change made for a report-golden reason cannot silently become a change to what a
/// customer is invoiced. Separate is not licence to drift: `DocumentMathTests` pins all three equal
/// over a wide sample, and `ReportMath.round` is itself replayed against a committed V8 corpus
/// (`Tests/Fixtures/make-reportmath-corpus.mjs`), so this copy inherits an engine-measured oracle
/// through that equality rather than through a second corpus of its own.
public enum DocumentMath {

    // MARK: - JS primitives

    /// JS `Math.round(x)`.
    ///
    /// Neither obvious Swift spelling is right: `x.rounded()` rounds ties AWAY from zero where JS
    /// rounds them toward `+∞` (`Math.round(-2.5)` is `-2`), and `floor(x + 0.5)` — which ECMA-262's
    /// own note claims is equivalent — answers `1` for `0.49999999999999994` where every engine
    /// answers `0`. Both were measured, not assumed; see `ReportMath.round`'s table.
    ///
    /// `-0` is preserved deliberately. `Math.round(-0.4)` and `Math.round(-0.5)` are both `-0`, and
    /// the sign survives the trailing `/ 100`, so a document line really can hold `-0`.
    static func round(_ x: Double) -> Double {
        // `NaN`, ±∞ and ±0 come back unchanged, sign included.
        if x.isNaN || x.isInfinite || x == 0 { return x }
        let f = x.rounded(.down)
        let r = (x - f) < 0.5 ? f : f + 1
        if r == 0, x < 0 { return -0.0 }
        return r
    }

    /// `value || 0` for a number: everything falsy in JS — `undefined`, `null`, `0`, `-0` and `NaN`
    /// — becomes `+0`. This is the fold in `DocumentModal.tsx:52` and in the editor's
    /// `parseFloat(...) || 0` reads of the quantity, unit-price and tax-rate fields.
    ///
    /// `internal` rather than `private` so a test can pin the `-0` arm directly: it is the one arm
    /// that decides a divergence from ``finiteOrZero(_:)``, and it is invisible from outside
    /// because `-0 == 0` compares true.
    static func truthyOrZero(_ value: Double?) -> Double {
        guard let value, value != 0, !value.isNaN else { return 0 }
        return value
    }

    /// `documents.js num(v, 0)` — `const n = Number(v); return Number.isFinite(n) ? n : fallback`.
    ///
    /// Differs from ``truthyOrZero(_:)`` in both directions: it KEEPS `-0` (finite) and it DROPS
    /// `±∞` (not finite). A missing value is `Number(undefined)`, i.e. `NaN`, which fails the finite
    /// test and lands on the fallback — `nil` here takes the same branch.
    static func finiteOrZero(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 0 }
        return value
    }

    // MARK: - The two round2 chains

    /// `DocumentModal.tsx:52` — `Math.round((v || 0) * 100) / 100`.
    ///
    /// The editor's rounder: it computes every line amount and line tax. Named for the side of the
    /// Electron split it comes from, because ``storedRound2(_:)`` is a different function.
    public static func lineRound2(_ v: Double?) -> Double {
        round(truthyOrZero(v) * 100) / 100
    }

    /// `documents.js:30-32` — `Math.round(num(v) * 100) / 100`.
    ///
    /// The handler's rounder: applied to every value on its way INTO the two tables, and to the
    /// three header totals. This is the one that decides what the ledger holds.
    public static func storedRound2(_ v: Double?) -> Double {
        round(finiteOrZero(v) * 100) / 100
    }

    // MARK: - Q4 · the line arithmetic

    /// A line's tax-exclusive amount — `DocumentModal.tsx:130-132`:
    ///
    /// ```js
    /// const qty   = parseFloat(r.quantity) || 0;
    /// const price = parseFloat(r.unitPrice) || 0;
    /// const amount = round2(qty * price);
    /// ```
    ///
    /// `nil` stands for the editor's empty field: `parseFloat("")` is `NaN` and `NaN || 0` is `0`.
    /// The unit price is tax-EXCLUSIVE (Q4; `services/api.ts`'s own field comment says so) — this
    /// chapter has no tax-inclusive entry mode and no discount field.
    public static func lineAmount(quantity: Double?, unitPrice: Double?) -> Double {
        lineRound2(truthyOrZero(quantity) * truthyOrZero(unitPrice))
    }

    /// A line's tax — `DocumentModal.tsx:133-134`:
    ///
    /// ```js
    /// const pct = parseFloat(r.taxRatePct) || 0;
    /// const tax = round2(amount * pct / 100);
    /// ```
    ///
    /// **The order is the whole point and Q4 pins it: round the amount to the cent FIRST, then
    /// multiply, then round again.** One step is not a simplification, it is a different answer —
    /// at quantity 1, unit price 3.335 and 25%, two steps give `0.84` and one step `0.83`.
    /// `amount` is the ALREADY-ROUNDED line amount, i.e. the output of
    /// ``lineAmount(quantity:unitPrice:)``, exactly as `computed` feeds its own `amount` in.
    ///
    /// `ratePercent` is a percentage, not a fraction: 13 means 13%.
    public static func lineTax(amount: Double, ratePercent: Double?) -> Double {
        lineRound2(amount * truthyOrZero(ratePercent) / 100)
    }

    /// `DocumentModal.tsx:65-69` — read a stored `tax_rate` back as a number.
    ///
    /// ```js
    /// if (!it.taxRate) return '';
    /// const n = parseFloat(it.taxRate.replace('%', ''));
    /// return Number.isFinite(n) ? String(n) : '';
    /// ```
    ///
    /// `nil` means "no rate stored", which is NOT `0`: `"0%"` is a rate of zero the editor keeps as
    /// an explicit `0`, while `NULL` and `""` come back empty so a re-save cannot invent a
    /// zero-rate line. Only the FIRST `%` is removed, because JS `String.replace` with a string
    /// pattern replaces one occurrence. A non-finite reading is `nil` as well — that is the
    /// `Number.isFinite(n)` arm, and it is why `"Infinity%"` does not come back as a rate.
    public static func taxRatePercent(from stored: String?) -> Double? {
        guard let stored, !stored.isEmpty else { return nil }   // JS: `!it.taxRate` catches "" and null
        var stripped = stored
        if let range = stripped.range(of: "%") { stripped.removeSubrange(range) }
        guard let n = jsParseFloat(stripped), n.isFinite else { return nil }
        return n
    }

    // MARK: - Q4 · the header totals

    /// `documents.js:62-66 sumTotals` — the header's three money columns.
    ///
    /// ```js
    /// const subtotal  = round2(items.reduce((s, it) => s + num(it.amount), 0));
    /// const taxAmount = round2(items.reduce((s, it) => s + num(it.tax_amount), 0));
    /// return { subtotal, taxAmount, total: round2(subtotal + taxAmount) };
    /// ```
    ///
    /// **It sums the stored line values; it never recomputes a line from quantity × unit price.**
    /// That is the handler's own comment and it is load-bearing twice over: it keeps a header
    /// consistent with the lines under it when a line was COPIED rather than computed (registered
    /// form A5), and it makes the total reproducible from the two tables alone.
    ///
    /// The fold runs left to right in the order given, because floating-point addition is not
    /// associative and a different order is a different number — three lines of `1/3` are not
    /// interchangeable with any regrouping of them.
    ///
    /// A `nil` amount or tax is `num(undefined)` → `0`, which is how a line holding SQL `NULL` tax
    /// (the statement generator's, per Q2-a) contributes nothing to the tax total while still
    /// reading back as "no tax recorded" rather than as a zero somebody chose.
    ///
    /// The editor shows its own running total using ``lineRound2(_:)`` instead; the two agree except
    /// on `-0` and `±∞`. What this function returns is what the ledger holds.
    public static func totals(ofLines lines: [(amount: Double?, taxAmount: Double?)]) -> DocumentTotals {
        let subtotal = storedRound2(lines.reduce(0.0) { $0 + finiteOrZero($1.amount) })
        let taxAmount = storedRound2(lines.reduce(0.0) { $0 + finiteOrZero($1.taxAmount) })
        return DocumentTotals(subtotal: subtotal,
                              taxAmount: taxAmount,
                              total: storedRound2(subtotal + taxAmount))
    }

    // MARK: - JS string primitives

    /// ECMAScript's `StrWhiteSpace` — `WhiteSpace ∪ LineTerminator`, the set both
    /// `String.prototype.trim` and `parseFloat` skip. **Written out rather than borrowed from
    /// Foundation, and the difference is not cosmetic.**
    ///
    /// `CharacterSet.whitespacesAndNewlines` is wrong in both directions for this job: it OMITS
    /// U+FEFF (which ECMAScript includes) and it INCLUDES U+0085 NEL (which ECMAScript does not).
    /// A counterparty name with a leading U+0085 would therefore trim on the Swift side and not on
    /// the JS side, and Q2-c makes trimmed equality the statement generator's matching rule — so
    /// that row would be selected here and skipped there. Exactly 25 scalars, listed:
    /// tab/LF/VT/FF/CR/space, NBSP, U+1680, U+2000–U+200A, LS, PS, U+202F, U+205F, U+3000, U+FEFF.
    ///
    /// `ProductCatalog.swift`'s `jsTrimSet` takes the Foundation-plus-FEFF shortcut; it is left
    /// alone here because changing it would change what that file refuses, which is not this
    /// round's subject. The divergence is registered, not inherited.
    static let stringWhitespace: Set<Unicode.Scalar> = [
        "\u{0009}", "\u{000A}", "\u{000B}", "\u{000C}", "\u{000D}", "\u{0020}",
        "\u{00A0}", "\u{1680}",
        "\u{2000}", "\u{2001}", "\u{2002}", "\u{2003}", "\u{2004}", "\u{2005}",
        "\u{2006}", "\u{2007}", "\u{2008}", "\u{2009}", "\u{200A}",
        "\u{2028}", "\u{2029}", "\u{202F}", "\u{205F}", "\u{3000}", "\u{FEFF}",
    ]

    /// `String.prototype.trim()` — strip ``stringWhitespace`` from both ends.
    ///
    /// Operates on unicode scalars rather than `Character`s: JS trims code units, and a grapheme
    /// cluster that merely BEGINS with a whitespace scalar (`"\u{0020}\u{0301}"`, a combining acute
    /// on a space) is one `Character` that must not be removed whole.
    static func jsTrim(_ s: String) -> String {
        var scalars = Substring(s).unicodeScalars[...]
        while let first = scalars.first, stringWhitespace.contains(first) { scalars = scalars.dropFirst() }
        while let last = scalars.last, stringWhitespace.contains(last) { scalars = scalars.dropLast() }
        return String(String.UnicodeScalarView(scalars))
    }

    /// `String.prototype.slice(0, end)` — **counted in UTF-16 code units**, which is what every
    /// `safeString(v, n)` clamp on the Electron side does.
    ///
    /// `String.prefix(n)` is the wrong instrument and the difference is not academic: it counts
    /// extended grapheme clusters. A `doc_number` of 31 thumbs-up emoji is 62 code units and 31
    /// characters, so Electron cuts it to 30 emoji and `prefix(60)` cuts nothing at all — the same
    /// input then produces two different numbers, and `idx_docs_type_number` disagrees about
    /// whether a second one collides.
    ///
    /// ## What happens when the cut lands inside a surrogate pair
    ///
    /// JS strings may hold an unpaired surrogate; Swift `String` may not. That looked like it might
    /// make this mirror unreachable, so it was MEASURED on both sides rather than reasoned about:
    ///
    /// ```text
    ///   input "A" + 30 × U+1F44D (61 code units), cut at 60
    ///     Electron  slice → …D83D DC4D D83D  (trailing LONE high surrogate)
    ///               better-sqlite3 stores     …F0 9F 91 8D EF BF BD   ← U+FFFD, not WTF-8
    ///     Swift     this function             …F0 9F 91 8D EF BF BD   ← identical
    /// ```
    ///
    /// The engines agree because both replace the unpaired unit with exactly one U+FFFD: V8 does it
    /// when better-sqlite3 asks for the UTF-8 bytes, and `String(decoding:as:)` does it here. Had
    /// better-sqlite3 written WTF-8 (`ED A0 BD`) this would have been a mirror Swift cannot reach,
    /// and this round would have had to stop and ask. It measured `EF BF BD`, so it does not.
    ///
    /// Verified case by case against a real `better-sqlite3` bind: 31 emoji at 60, "A" + 30 emoji
    /// at 60, "A" + 100 emoji at 200, 30 emoji at 60, one `e` + 60 combining acutes at 60, and ten
    /// ZWJ family emoji at 60 — all six identical in stored bytes and in code-unit count.
    ///
    /// **One asymmetry stays, and it is inherent rather than introduced:** a JS string can ARRIVE
    /// holding an unpaired surrogate, and a Swift `String` cannot, so the two sides' input domains
    /// differ before any clamp runs. Nothing this API accepts can be in that state.
    static func jsSlice(_ s: String, to end: Int) -> String {
        guard end < s.utf16.count else { return s }   // `slice` past the end returns the whole string
        guard end > 0 else { return "" }
        return String(decoding: Array(s.utf16.prefix(end)), as: UTF16.self)
    }

    /// `parseFloat(s)` — the longest leading `StrDecimalLiteral`, which is NOT `Double(s)`.
    ///
    /// `Double("12abc")` is `nil`; `parseFloat("12abc")` is `12`. Returns `nil` where `parseFloat`
    /// returns `NaN`, since every caller here folds that to "no reading" rather than to a number.
    ///
    /// The grammar, and the four places a naive port gets it wrong:
    ///
    ///  * **`"5."` and `".5"` are both legal** (`DecimalDigits . DecimalDigits_opt` and
    ///    `. DecimalDigits`) and both are values `Double(String)` handles differently, so the
    ///    literal is rebuilt with the missing side filled in rather than handed over as written.
    ///  * **An exponent counts only when complete.** `parseFloat("1e")` is `1`, not `NaN`: `"e"`
    ///    with no digits is simply not part of the longest matching prefix.
    ///  * **`Infinity` is a literal, case-sensitively**, and takes the sign. `parseFloat("infinity")`
    ///    is `NaN`.
    ///  * **Hex is not special.** `parseFloat("0x10")` is `0` — the prefix `"0"` matches and `"x"`
    ///    ends it — where `Double("0x10")` is 16.
    static func jsParseFloat(_ s: String) -> Double? {
        var rest = Substring(s).unicodeScalars[...]
        while let first = rest.first, stringWhitespace.contains(first) { rest = rest.dropFirst() }

        var negative = false
        if let sign = rest.first, sign == "+" || sign == "-" {
            negative = (sign == "-")
            rest = rest.dropFirst()
        }

        if rest.starts(with: "Infinity".unicodeScalars) { return negative ? -.infinity : .infinity }

        var integerDigits = ""
        while let c = rest.first, c.isASCIIDigit { integerDigits.unicodeScalars.append(c); rest = rest.dropFirst() }

        var fractionDigits = ""
        var sawPoint = false
        if rest.first == "." {
            sawPoint = true
            rest = rest.dropFirst()
            while let c = rest.first, c.isASCIIDigit { fractionDigits.unicodeScalars.append(c); rest = rest.dropFirst() }
        }
        // `StrUnsignedDecimalLiteral` needs at least one digit on one side of the point; `"."`
        // alone, `"+"` alone and `""` are all `NaN`.
        guard !integerDigits.isEmpty || !fractionDigits.isEmpty else { return nil }

        var literal = negative ? "-" : ""
        literal += integerDigits.isEmpty ? "0" : integerDigits
        if sawPoint { literal += "." + (fractionDigits.isEmpty ? "0" : fractionDigits) }

        if let e = rest.first, e == "e" || e == "E" {
            var tail = rest.dropFirst()
            var exponentSign = ""
            if let sign = tail.first, sign == "+" || sign == "-" {
                exponentSign = String(sign)
                tail = tail.dropFirst()
            }
            var exponentDigits = ""
            while let c = tail.first, c.isASCIIDigit { exponentDigits.unicodeScalars.append(c); tail = tail.dropFirst() }
            if !exponentDigits.isEmpty { literal += "e" + exponentSign + exponentDigits }
        }

        return Double(literal)
    }
}

/// The three money columns on a document header, as ``DocumentMath/totals(ofLines:)`` computes them.
public struct DocumentTotals: Equatable, Sendable {
    /// `business_documents.subtotal` — the tax-exclusive sum of the line amounts.
    public let subtotal: Double
    /// `business_documents.tax_amount` — the sum of the line taxes.
    public let taxAmount: Double
    /// `business_documents.total` — `subtotal + taxAmount`, rounded once more.
    public let total: Double
}

private extension Unicode.Scalar {
    var isASCIIDigit: Bool { self >= "0" && self <= "9" }
}
