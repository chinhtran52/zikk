import Foundation

/// Re-indents JSON text without parsing it into dictionaries, so key order is preserved.
public enum JSONFormatter {
    /// Pretty-printed JSON, or nil if `text` is not valid JSON.
    public static func prettyPrinted(_ text: String, indent: String = "  ") -> String? {
        guard let data = text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else { return nil }
        var output = ""
        output.reserveCapacity(text.utf8.count + text.utf8.count / 4)
        var level = 0
        var inString = false
        var escaped = false
        var pendingEmpty: Character?

        func newline() {
            output.append("\n")
            for _ in 0..<level { output.append(indent) }
        }

        for char in text {
            if inString {
                output.append(char)
                if escaped { escaped = false } else if char == "\\" { escaped = true } else if char == "\"" { inString = false }
                continue
            }
            if let opener = pendingEmpty {
                pendingEmpty = nil
                if (opener == "{" && char == "}") || (opener == "[" && char == "]") {
                    output.append(char)
                    continue
                }
                level += 1
                newline()
                if char.isWhitespace { continue }
            }
            switch char {
            case "\"":
                inString = true
                output.append(char)
            case "{", "[":
                output.append(char)
                pendingEmpty = char
            case "}", "]":
                level -= 1
                newline()
                output.append(char)
            case ",":
                output.append(char)
                newline()
            case ":":
                output.append(": ")
            case _ where char.isWhitespace:
                continue
            default:
                output.append(char)
            }
        }
        return output
    }

    /// Minified JSON preserving key order, or nil if invalid.
    public static func minified(_ text: String) -> String? {
        guard prettyPrinted(text) != nil else { return nil }
        var output = ""
        var inString = false
        var escaped = false
        for char in text {
            if inString {
                output.append(char)
                if escaped { escaped = false } else if char == "\\" { escaped = true } else if char == "\"" { inString = false }
            } else if char == "\"" {
                inString = true
                output.append(char)
            } else if !char.isWhitespace {
                output.append(char)
            }
        }
        return output
    }
}
