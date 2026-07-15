import Foundation

/// A CSV cell that knows whether it is numeric — numbers bypass the formula-
/// injection guard exactly like `csvCell` in electron/handlers/_csvExport.js.
public enum CSVCell {
    case number(Double?)
    case text(String?)
}

/// RFC-4180 CSV writer that reproduces `_csvExport.js`:
///  - fields containing " , \n or \r are quoted; inner " doubled
///  - CRLF line separators, trailing CRLF
///  - formula-injection guard: TEXT cells starting with = + - @ TAB CR get a
///    leading single quote (numbers are exempt)
///  - optional UTF-8 BOM (subsystem A prefixes one)
public enum CSVWriter {

    public static func format(rows: [[CSVCell]], header: [String], includeBOM: Bool = true) -> String {
        var lines: [String] = [header.map { escape(guardText($0)) }.joined(separator: ",")]
        for row in rows {
            lines.append(row.map { render($0) }.joined(separator: ","))
        }
        let body = lines.joined(separator: "\r\n") + "\r\n"
        return includeBOM ? "\u{FEFF}" + body : body
    }

    private static func render(_ cell: CSVCell) -> String {
        switch cell {
        case .number(let n):
            guard let n, n.isFinite else { return "" }
            return escape(numberString(n))            // numbers skip the injection guard
        case .text(let s):
            return escape(guardText(s ?? ""))
        }
    }

    /// Apply the formula-injection guard to a text value.
    private static func guardText(_ text: String) -> String {
        guard let first = text.first else { return text }
        let dangerous: Set<Character> = ["=", "+", "-", "@", "\t", "\r"]
        return dangerous.contains(first) ? "'" + text : text
    }

    /// RFC-4180 escape.
    private static func escape(_ s: String) -> String {
        if s.contains("\"") || s.contains(",") || s.contains("\n") || s.contains("\r") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    /// Approximate JS `String(Number)`: integral values print without a decimal.
    static func numberString(_ n: Double) -> String {
        if n == n.rounded() && abs(n) < 9.007e15 {
            return String(Int64(n))
        }
        let s = String(n)
        // Never trim scientific-notation output (e.g. "1.5e+20"): stripping trailing
        // zeros there would corrupt the exponent (1.5e+20 -> 1.5e+2). Only trim a
        // plain fractional tail.
        if s.contains("e") || s.contains("E") { return s }
        guard s.contains(".") else { return s }
        var t = s
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }
}
