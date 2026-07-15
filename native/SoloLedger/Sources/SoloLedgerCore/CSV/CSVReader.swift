import Foundation

/// Minimal RFC-4180 CSV parser (handles quotes, doubled quotes, embedded commas
/// and CRLF/LF/CR), used by the net-new transactions import path. Strips a
/// leading UTF-8 BOM. Returns rows of string fields.
///
/// Note: Swift models a CRLF as a SINGLE `Character` grapheme ("\r\n"), so the
/// row-terminator case must include it alongside lone "\n" / "\r".
public enum CSVReader {

    public static func parse(_ input: String) -> [[String]] {
        var text = Substring(input)
        if text.first == "\u{FEFF}" { text = text.dropFirst() }

        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false

        func endField() { row.append(field); field = "" }
        func endRow() { endField(); rows.append(row); row = [] }

        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]

            if inQuotes {
                if ch == "\"" {
                    let next = text.index(after: i)
                    if next < text.endIndex && text[next] == "\"" {
                        field.append("\"")          // escaped quote ("")
                        i = text.index(after: next)  // skip both
                    } else {
                        inQuotes = false             // closing quote
                        i = next
                    }
                    continue
                }
                field.append(ch)
                i = text.index(after: i)
                continue
            }

            switch ch {
            case "\"": inQuotes = true
            case ",": endField()
            case "\n", "\r", "\r\n": endRow()
            default: field.append(ch)
            }
            i = text.index(after: i)
        }

        // Trailing field/row if the input didn't end on a newline.
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}
