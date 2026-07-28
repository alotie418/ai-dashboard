import Foundation

/// V8 numeric semantics, reproduced in Swift.
///
/// The native report engines are a VERBATIM mirror of `electron/reports/*.js`
/// (docs/SWIFTUI_REPORTS_MIRROR_PLAN.md §8.1). "Verbatim" is only true if the
/// arithmetic underneath is also verbatim, and it is not: on four separate
/// operations the JavaScript the engines are written in disagrees with the
/// Swift-idiomatic equivalent, on inputs the committed goldens already contain.
/// Every function here exists because of a measured disagreement, not a
/// theoretical one — each carries the node output that motivates it.
///
/// ## The four disagreements
///
/// | JS | Swift-idiomatic | diverges on |
/// | --- | --- | --- |
/// | `a \|\| b` | `a ?? b` | `a` = `0`, `-0`, `NaN` — all falsy in JS, all kept by `??` |
/// | `Math.round(x)` | `x.rounded()` | `-2.5` → JS `-2`, Swift `-3` |
/// | `Math.max(a,b)` | `Swift.max` | `(0, NaN)` → JS `NaN`, Swift `0` |
/// | `Number(v)` | `Double(String)` | `" 12 "`, `"0b101"`, `"0x1p4"`, `""` |
///
/// ## Double, deliberately — never Decimal
///
/// Everything here is `Double`, which is the same IEEE-754 binary64 the engines
/// run on. `Decimal` would be *more accurate* and therefore WRONG: the goldens
/// record what binary64 produces, including its decimal-representation artefacts
/// (`1.005 * 100 == 100.49999999999999`, so `round2(1.005) == 1.0`, not `1.01`).
/// Those artefacts are the mirroring target, not a bug to be repaired. A
/// higher-precision implementation would disagree with the goldens on real money
/// values and there would be no way to tell that apart from a genuine mirroring
/// error.
///
/// ## Ground truth
///
/// Swift cannot run JavaScript, so correctness here is not something this file
/// can assert about itself. `Tests/Fixtures/make-reportmath-corpus.mjs` executes
/// every operation below in a real V8 and commits the results;
/// `ReportMathTests` replays that corpus bit-for-bit. Where an implementation and
/// the spec's own prose disagree — and for `Math.round` they do — **the corpus
/// wins and the formula changes.**
public enum ReportMath {

    // MARK: - `||` — JS truthiness
    //
    // Call sites: `r.amount_net || r.amount || 0` (cn.js:19,22, _expenseSplit.js:24,
    // and the same line in jp/eu/kr/tw), `(v || 0)` inside the rounders
    // (us.js:142, jp.js:14, eu.js:14, kr.js:14, tw.js:14), `expenseBySlug[slug] || 0`
    // (us.js:40-58), `row.paid_amount && row.paid_amount > 0` (_cashflow.js:32).

    /// JS `ToBoolean` restricted to the values a numeric column can hold.
    ///
    /// FALSY: `+0`, `-0`, `NaN`, and absent (SQL `NULL` → JS `null`/`undefined`).
    /// Everything else is truthy. The `NaN` case is load-bearing, not pedantry:
    /// with a malformed `income_tax_rate` the US engine computes
    /// `netProfit * (NaN/100)` and `r()`'s `|| 0` turns the `NaN` into `0` —
    /// which is why `malformed-US-2025.json` records `annualIncomeTax: 0` rather
    /// than `null`. Swift's `??` would keep the `NaN` and the golden would fail.
    ///
    /// SCOPE: numbers and absence only. A TEXT value in a numeric column would be
    /// a *truthy string* in JS and would make `+` concatenate rather than add —
    /// a different class of quirk that belongs to whichever PR mirrors row
    /// decoding, not here. `SQLiteValue.doubleValue` already yields `nil` for a
    /// non-numeric TEXT, so that path cannot silently arrive as a number.
    @inlinable
    public static func isTruthy(_ v: Double?) -> Bool {
        guard let v else { return false }   // null / undefined
        return !(v == 0 || v.isNaN)         // `v == 0` covers +0 AND -0
    }

    /// JS `a || b`. Returns `a` when `a` is truthy, otherwise `b` — including when
    /// `b` is itself falsy, which is why the result stays optional.
    @inlinable
    public static func or(_ a: Double?, _ b: Double?) -> Double? {
        isTruthy(a) ? a : b
    }

    /// JS `v || 0` — the guard the rounders in us/jp/eu/kr/tw apply and the one
    /// `cn.js` does NOT (see ``round2(_:)``).
    @inlinable
    public static func orZero(_ v: Double?) -> Double {
        isTruthy(v) ? v! : 0
    }

    /// JS `row.amount_net || row.amount || 0` — the engines' net-amount convention,
    /// named because it appears in every engine and in `_expenseSplit.js:24`.
    ///
    /// The interesting input is `amount_net == 0`, which JS treats as falsy and
    /// therefore falls back to the TAX-INCLUSIVE `amount`. Swift's `??` would
    /// return the `0`. The report fixture carries such a row on purpose
    /// (plan §5.2, "`amount_net = 0` 的行").
    @inlinable
    public static func netAmount(_ amountNet: Double?, _ amount: Double?) -> Double {
        if isTruthy(amountNet) { return amountNet! }
        if isTruthy(amount) { return amount! }
        return 0
    }

    // MARK: - `Math.round`
    //
    // Call sites: every `r()` helper (cn.js:43, us.js:142, jp.js:14, eu.js:14,
    // kr.js:14, tw.js:14), the margin lines (cn.js:30,41), the tax lines
    // (cn.js:33,39) and `_cashflow.js:26`.

    /// JS `Math.round(x)`.
    ///
    /// BOTH obvious Swift spellings are wrong, each in a different place — measured,
    /// not assumed:
    ///
    /// ```text
    ///   x                     Math.round   x.rounded()   (x+0.5).rounded(.down)
    ///   0.49999999999999994   0            0             1     ← formula wrong
    ///   -2.5                  -2           -3  ← wrong   -2
    ///   -12.5                 -12          -13 ← wrong   -12
    ///   -0.5                  -0           -1  ← wrong   0     ← sign wrong
    ///   -0.4                  -0           -0            0     ← sign wrong
    /// ```
    ///
    /// `x.rounded()` breaks because JS rounds ties toward `+∞`, not away from zero
    /// — and `r(-0.125)` (`Math.round(-12.5)/100`) is exactly that case, which is
    /// why the plan names it.
    ///
    /// `floor(x + 0.5)` is what ECMA-262's own NOTE on `Math.round` claims to be
    /// equivalent, and the note is inaccurate: `0.49999999999999994 + 0.5` rounds
    /// UP to exactly `1.0` in binary64, so the formula answers `1` where every
    /// engine answers `0`. The engine is the ground truth here, so the formula is
    /// what gets discarded (plan constraint: 分歧时改公式不改真值).
    ///
    /// What follows is the normative algorithm rather than either shortcut, with
    /// `-0` preserved because it survives the engines' trailing `/ 100`
    /// (`Math.round(-0.001 * 100) / 100` is `-0`, verified in node).
    public static func round(_ x: Double) -> Double {
        // ECMA-262 states Math.round as five steps. Only ONE of them needs code:
        // the other four are subsumed by the floor-and-compare below, and writing
        // them out anyway would be unreachable lines in a function whose entire
        // job is exactness. Each was removed only after the differential corpus
        // confirmed deleting it changes no result — that is the standard applied
        // here, not "the spec lists it".
        //
        //   NaN / ±∞      f == x and (x - f) is NaN or 0, so x returns unchanged.
        //   already integral   same: (x - f) == 0, never ≥ 0.5.
        //   0 < x < 0.5 → +0   f is +0 and (x - f) == x < 0.5, so +0 returns.
        //   -0            f is -0 and (x - f) is +0, so -0 keeps its sign.
        //
        // The negative interval below is the one that does NOT fall out, and it is
        // the reason this cannot be `floor(x + 0.5)` either: for -0.5 ≤ x < 0,
        // floor takes x to -1 and the fraction is ≥ 0.5, which would answer +0
        // where every engine answers -0.
        if x < 0 && x >= -0.5 { return -0.0 }
        // Ties toward +∞ — this is where `x.rounded()` diverges, since it rounds
        // them away from zero. `x - f` is exact for every x that reaches this
        // line: |x| ≥ 2^52 is integral (so the comparison is 0 ≥ 0.5 either way),
        // and the sub-1 negative magnitudes where the subtraction could round were
        // returned above.
        let f = x.rounded(.down)
        return (x - f) >= 0.5 ? f + 1 : f
    }

    /// JS `Math.round(x * 100) / 100` — `cn.js:43`'s `r`.
    ///
    /// NOTE the missing `|| 0`: China's rounder is the only one without it, so a
    /// `NaN` flows straight through and `JSON.stringify` writes it as `null`. That
    /// asymmetry is pinned by `malformed-CN-2025.json` (five null fields) against
    /// `malformed-US-2025.json` (zeros), and the mirror must reproduce it rather
    /// than tidy it (plan §9, row "cn.js 遇不可解析税率时产出 NaN").
    @inlinable
    public static func round2(_ x: Double) -> Double {
        round(x * 100) / 100
    }

    /// JS `Math.round((v || 0) * 100) / 100` — the `r` in us.js:142, jp.js:14,
    /// eu.js:14, kr.js:14, tw.js:14. Identical to ``round2(_:)`` except that a
    /// falsy input (including `NaN`) is flattened to `0` first.
    @inlinable
    public static func round2OrZero(_ v: Double?) -> Double {
        round2(orZero(v))
    }

    /// JS `Math.round(x * 10000) / 100` — `cn.js:30` and `cn.js:41`, the margin
    /// percentages. Scaling by 10000 rather than composing `round2` with `* 100`
    /// is what the source does, and the two are NOT interchangeable: they round at
    /// different magnitudes and overflow to `Infinity` 100× sooner.
    @inlinable
    public static func percent2(_ x: Double) -> Double {
        round(x * 10000) / 100
    }

    // MARK: - `Math.max` / `Math.min`
    //
    // Call sites: `Math.max(0, totalIncomeTax - totalExpenseTax)` (cn.js:32 and the
    // VAT line in jp/eu/kr/tw), `Math.max(0, profitBeforeTax)` (cn.js:39) and the
    // same clamp before every income-tax line, `Math.min(seEarnings, ssTaxCap)`
    // (us.js:70).

    /// JS `Math.max(a, b)`.
    ///
    /// Swift's `Swift.max` is defined by comparison (`y >= x ? y : x`), which gives
    /// it two behaviours JS does not have:
    ///
    /// - **NaN is swallowed.** `Swift.max(0, .nan)` is `0`; `Math.max(0, NaN)` is
    ///   `NaN`. This one is load-bearing. `malformed-CN-2025.json` records
    ///   `incomeTax: null`, which only happens because `Math.max(0, profitBeforeTax)`
    ///   propagates the `NaN` from the unparseable surcharge rate into
    ///   `cn.js:39`. A comparison-based max would answer `0` there and the mirror
    ///   would print a plausible tax figure where the engine prints nothing.
    /// - **Signed zero is ordered.** JS treats `+0` as greater than `-0`, so
    ///   `Math.max(0, -0)` is `+0`; `Swift.max(0.0, -0.0)` returns `-0`.
    public static func max(_ a: Double, _ b: Double) -> Double {
        if a.isNaN || b.isNaN { return .nan }
        if a == 0 && b == 0 { return (a.sign == .plus || b.sign == .plus) ? 0 : -0.0 }
        return a > b ? a : b
    }

    /// JS `Math.min(a, b)`. Same two corrections as ``max(_:_:)``, mirrored: `NaN`
    /// wins, and `-0` is ordered below `+0`.
    ///
    /// `Swift.min` is additionally ARGUMENT-ORDER dependent with `NaN`
    /// (`Swift.min(.nan, 5)` is `NaN` but `Swift.min(5, .nan)` is `5`), so which of
    /// the two it gets wrong depends on how the call happens to be written.
    public static func min(_ a: Double, _ b: Double) -> Double {
        if a.isNaN || b.isNaN { return .nan }
        if a == 0 && b == 0 { return (a.sign == .minus || b.sign == .minus) ? -0.0 : 0 }
        return a < b ? a : b
    }

    // MARK: - `Number(v)`
    //
    // Call site: `Number(readSetting(db, key, fallback))` — index.js:74-78, for
    // vat_rate / surcharge_rate / income_tax_rate / admin_expense_annual.

    /// A `JSON.parse` result, which is exactly the domain `Number()` is applied to
    /// at `index.js:74-78`: `readSetting` returns `JSON.parse(row.value)` when the
    /// row exists and a numeric literal when it does not.
    public enum JSValue: Equatable, Sendable {
        /// No such settings row at all. `readSetting` substitutes its fallback
        /// before `Number()` ever sees this, so it is unreachable from the report
        /// path — carried only so the coercion table is complete and testable.
        case undefined
        case null
        case boolean(Bool)
        case number(Double)
        case string(String)
        case array([JSValue])
        /// Any non-array object. Its `toString` is `"[object Object]"` for every
        /// instance, so the contents cannot change the answer and are not modelled.
        case object
    }

    /// JS `Number(v)`.
    ///
    /// This is where the report engines' `NaN` path is BORN: a settings row holding
    /// the string `"25%"` (which the repo's own e2e fixtures write) coerces to
    /// `NaN` here and propagates all the way to five `null` fields in
    /// `malformed-CN-2025.json`. A missing row is a different thing entirely — it
    /// never reaches this function, because `readSetting` substitutes China's
    /// fallback first. Keeping the two apart is the hard constraint of plan §6.2.
    ///
    /// `Number(null)` is `0` while `Number(undefined)` is `NaN`; the asymmetry is
    /// JS's, not a typo.
    public static func number(_ v: JSValue) -> Double {
        switch v {
        case .undefined:          return .nan
        case .null:               return 0
        case .boolean(let b):     return b ? 1 : 0
        case .number(let d):      return d
        case .string(let s):      return stringToNumber(s)
        case .object:             return .nan          // "[object Object]"
        case .array(let items):
            // ToPrimitive(array, number) has no valueOf, so it falls to
            // Array.prototype.toString → join(","), recursively, with null and
            // undefined contributing the empty string. Hence Number([]) === 0,
            // Number([5]) === 5, Number([[3]]) === 3 and Number([1,2]) === NaN.
            return stringToNumber(arrayToString(items))
        }
    }

    // MARK: - StringNumericLiteral

    /// JS `StrWhiteSpace` — `WhiteSpace` ∪ `LineTerminator`.
    ///
    /// Enumerated rather than taken from `CharacterSet.whitespacesAndNewlines`,
    /// whose membership is a Foundation/ICU decision that can move between OS
    /// versions. What may be trimmed is fixed by ECMA-262, so it is spelled out:
    /// the Unicode `Space_Separator` (Zs) category plus TAB/VT/FF, NBSP, ZWNBSP,
    /// and the four line terminators.
    private static let jsWhitespace: Set<Unicode.Scalar> = [
        "\u{0009}", "\u{000B}", "\u{000C}", "\u{0020}",            // TAB VT FF SP
        "\u{00A0}", "\u{FEFF}",                                     // NBSP ZWNBSP
        "\u{000A}", "\u{000D}", "\u{2028}", "\u{2029}",             // LF CR LS PS
        "\u{1680}",                                                 // Zs …
        "\u{2000}", "\u{2001}", "\u{2002}", "\u{2003}", "\u{2004}",
        "\u{2005}", "\u{2006}", "\u{2007}", "\u{2008}", "\u{2009}",
        "\u{200A}", "\u{202F}", "\u{205F}", "\u{3000}",
    ]

    /// JS `StringToNumber`. Anything the grammar does not accept in FULL — no
    /// trailing characters — is `NaN`.
    ///
    /// Swift's `Double(String)` is not this grammar and disagrees in both
    /// directions, so it is used only for the final decimal conversion, after the
    /// shape has been validated here:
    ///
    /// | input | `Number` | `Double(String)` |
    /// | --- | --- | --- |
    /// | `" 12 "` | `12` | `nil` — no trimming |
    /// | `""` | `0` | `nil` |
    /// | `"0b101"` / `"0o17"` | `5` / `15` | `nil` |
    /// | `"0x1p4"` | `NaN` | `16` — Swift takes hex FLOATS |
    /// JS `String.prototype.trim` — the same `StrWhiteSpace` set ``stringToNumber(_:)``
    /// strips, exposed rather than duplicated.
    ///
    /// A caller sometimes needs to know that trimming left NOTHING, and the coerced
    /// value cannot tell it: `Number("")` and `Number("   ")` are both `0`, which is
    /// indistinguishable from a stored `0`. A-4's rate gate has to see that difference
    /// (an empty string is a corrupt rate; a zero is a real one), so it asks here
    /// instead of carrying a second copy of a Unicode set that must not drift.
    static func jsTrim(_ raw: String) -> String {
        let scalars = Array(raw.unicodeScalars)
        var start = 0, end = scalars.count
        while start < end && jsWhitespace.contains(scalars[start]) { start += 1 }
        while end > start && jsWhitespace.contains(scalars[end - 1]) { end -= 1 }
        return String(String.UnicodeScalarView(scalars[start..<end]))
    }

    static func stringToNumber(_ raw: String) -> Double {
        var scalars = Array(raw.unicodeScalars)
        var start = 0, end = scalars.count
        while start < end && jsWhitespace.contains(scalars[start]) { start += 1 }
        while end > start && jsWhitespace.contains(scalars[end - 1]) { end -= 1 }
        scalars = Array(scalars[start..<end])

        // StrWhiteSpace with no literal at all → +0. Number("") and Number("  ")
        // are both 0, which is the single most surprising entry in the table.
        if scalars.isEmpty { return 0 }
        let s = String(String.UnicodeScalarView(scalars))

        if s == "Infinity" || s == "+Infinity" { return .infinity }
        if s == "-Infinity" { return -.infinity }

        // Radix literals. No sign is permitted before them ("-0x10" is NaN), and
        // there must be at least one digit.
        if s.count > 2, s.first == "0" {
            let marker = s[s.index(s.startIndex, offsetBy: 1)]
            let digits = String(s.dropFirst(2))
            switch marker {
            case "x", "X": return integerLiteral(digits, radix: 16)
            case "o", "O": return integerLiteral(digits, radix: 8)
            case "b", "B": return integerLiteral(digits, radix: 2)
            default: break
            }
        }

        return decimalLiteral(s)
    }

    /// `StrDecimalLiteral`, validated character by character. Numeric separators
    /// (`1_000`) are NOT part of it — they exist in source literals only, so
    /// `Number("1_000")` is `NaN` — and neither is a trailing `%`, which is how the
    /// real-world `"25%"` settings row becomes `NaN`.
    private static func decimalLiteral(_ s: String) -> Double {
        var i = s.startIndex
        let end = s.endIndex
        if i < end, s[i] == "+" || s[i] == "-" { i = s.index(after: i) }

        var integerDigits = 0, fractionDigits = 0
        while i < end, s[i].isASCII, s[i].isNumber { integerDigits += 1; i = s.index(after: i) }
        if i < end, s[i] == "." {
            i = s.index(after: i)
            while i < end, s[i].isASCII, s[i].isNumber { fractionDigits += 1; i = s.index(after: i) }
        }
        // At least one digit total; "5." and ".5" are both legal, "." alone is not.
        if integerDigits == 0 && fractionDigits == 0 { return .nan }

        if i < end, s[i] == "e" || s[i] == "E" {
            i = s.index(after: i)
            if i < end, s[i] == "+" || s[i] == "-" { i = s.index(after: i) }
            var exponentDigits = 0
            while i < end, s[i].isASCII, s[i].isNumber { exponentDigits += 1; i = s.index(after: i) }
            if exponentDigits == 0 { return .nan }
        }
        // Anything left over means the literal did not consume the whole string.
        if i != end { return .nan }

        // Shape is valid, so Swift's correctly-rounded parser can produce the value.
        // Every form reaching here ("5.", ".5", "+3", "00.5", "1e400" → inf) was
        // checked against node to give the same Double.
        return Double(s) ?? .nan
    }

    /// `0x` / `0o` / `0b` literals, EXACTLY.
    ///
    /// Not accumulated as `value * radix + digit`: that loses the last bits past
    /// 2^53, whereas V8 computes the mathematical value and rounds once. The digits
    /// are converted to an exact decimal string first, then handed to Swift's
    /// correctly-rounded decimal parser, so a 30-digit hex literal lands on the
    /// same Double both sides.
    private static func integerLiteral(_ digits: String, radix: Int) -> Double {
        if digits.isEmpty { return .nan }
        var decimal: [UInt8] = [0]          // little-endian decimal digits
        for ch in digits {
            // `isASCII` FIRST. Swift's `hexDigitValue` is Unicode-aware and accepts
            // the fullwidth forms — U+FF10 answers 0 and U+FF21 answers 10 — while
            // JS's grammar is ASCII-only, so `Number("0x\u{FF10}")` is NaN. Without
            // this guard the shim would invent a value for a string V8 rejects.
            guard ch.isASCII, let d = ch.hexDigitValue, d < radix else { return .nan }
            var carry = d
            for k in decimal.indices {
                let acc = Int(decimal[k]) * radix + carry
                decimal[k] = UInt8(acc % 10)
                carry = acc / 10
            }
            while carry > 0 { decimal.append(UInt8(carry % 10)); carry /= 10 }
        }
        return Double(String(decimal.reversed().map { Character(UnicodeScalar($0 + 48)) })) ?? .nan
    }

    /// `Array.prototype.toString` — `join(",")`, recursive, with `null`/`undefined`
    /// contributing an empty string.
    private static func arrayToString(_ items: [JSValue]) -> String {
        items.map { item -> String in
            switch item {
            case .null, .undefined:  return ""
            case .boolean(let b):    return b ? "true" : "false"
            case .number(let d):     return numberToString(d)
            case .string(let s):     return s
            case .array(let inner):  return arrayToString(inner)
            case .object:            return "[object Object]"
            }
        }.joined(separator: ",")
    }

    /// JS `String(number)`, to the extent the array path can observe it.
    ///
    /// Swift's own `String(Double)` round-trips to the same value for every finite
    /// non-zero input and its output ("1.0", "1e+21", "1e-07") is re-read
    /// identically by ``stringToNumber(_:)``, so only the three forms where Swift
    /// prints something JS does not need naming: `-0.0` prints "-0.0" and would
    /// come back NEGATIVE zero where JS gives `+0`, and the infinities print "inf",
    /// which is not a JS numeric literal at all.
    private static func numberToString(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d == 0 { return "0" }                 // JS String(-0) === "0"
        if d == .infinity { return "Infinity" }
        if d == -.infinity { return "-Infinity" }
        return String(d)
    }
}
