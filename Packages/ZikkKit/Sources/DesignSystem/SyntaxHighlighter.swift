import AppKit

public enum CodeLanguage: String, CaseIterable, Sendable {
    case plain, json, javascript, yaml, graphQL, xml, html
}

/// Regex-based highlighter. Rules are applied in order; later rules win on overlap.
@MainActor
public struct SyntaxHighlighter {
    struct Rule {
        let regex: NSRegularExpression
        let color: NSColor
        /// Capture group to color (0 = whole match).
        let group: Int
    }

    public static let maxHighlightLength = 400_000

    let rules: [Rule]

    public init(language: CodeLanguage) {
        rules = Self.rules(for: language)
    }

    public func highlight(_ storage: NSTextStorage, font: NSFont) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor.textColor], range: full)
        if storage.length <= Self.maxHighlightLength {
            let text = storage.string
            for rule in rules {
                rule.regex.enumerateMatches(in: text, range: full) { match, _, _ in
                    guard let match else { return }
                    let range = match.range(at: rule.group)
                    if range.location != NSNotFound {
                        storage.addAttribute(.foregroundColor, value: rule.color, range: range)
                    }
                }
            }
        }
        storage.endEditing()
    }

    private static func rule(_ pattern: String, _ color: NSColor, group: Int = 0, options: NSRegularExpression.Options = []) -> Rule {
        // Patterns are compile-time constants; a failure is a programmer error.
        Rule(regex: try! NSRegularExpression(pattern: pattern, options: options), color: color, group: group)
    }

    private static let variable = rule(#"\{\{[^{}]+\}\}"#, .systemOrange)

    private static func rules(for language: CodeLanguage) -> [Rule] {
        switch language {
        case .plain:
            return [variable]
        case .json:
            return [
                rule(#"-?\b\d+(\.\d+)?([eE][+-]?\d+)?\b"#, .systemBlue),
                rule(#"\b(true|false|null)\b"#, .systemPurple),
                rule(#""(?:[^"\\]|\\.)*""#, .systemRed),
                rule(#"("(?:[^"\\]|\\.)*")\s*:"#, .systemTeal, group: 1),
                variable,
            ]
        case .javascript:
            return [
                rule(#"\b\d+(\.\d+)?\b"#, .systemBlue),
                rule(#"\b(const|let|var|function|return|if|else|for|while|do|switch|case|break|continue|new|try|catch|finally|throw|typeof|instanceof|in|of|async|await|class|extends|this|null|undefined|true|false)\b"#, .systemPink),
                rule(#"\bpm\b|\bpostman\b|\bconsole\b"#, .systemTeal),
                rule(#""(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|`(?:[^`\\]|\\.)*`"#, .systemRed),
                rule(#"//[^\n]*|/\*[\s\S]*?\*/"#, .secondaryLabelColor),
                variable,
            ]
        case .yaml:
            return [
                rule(#"\b\d+(\.\d+)?\b"#, .systemBlue),
                rule(#"\b(true|false|null|yes|no)\b"#, .systemPurple),
                rule(#"^(\s*-?\s*)([^:#\n]+?)(?=\s*:(\s|$))"#, .systemTeal, group: 2, options: .anchorsMatchLines),
                rule(#""(?:[^"\\\n]|\\.)*"|'[^'\n]*'"#, .systemRed),
                rule(#"#[^\n]*"#, .secondaryLabelColor),
                variable,
            ]
        case .graphQL:
            return [
                rule(#"\b(query|mutation|subscription|fragment|on|type|input|enum|interface|union|schema|scalar|extend|directive|implements)\b"#, .systemPink),
                rule(#"\$\w+"#, .systemOrange),
                rule(#"@\w+"#, .systemPurple),
                rule(#""(?:[^"\\\n]|\\.)*""#, .systemRed),
                rule(#"#[^\n]*"#, .secondaryLabelColor),
                variable,
            ]
        case .xml, .html:
            return [
                rule(#"</?[\w:.-]+"#, .systemPink),
                rule(#"\s([\w:.-]+)="#, .systemTeal, group: 1),
                rule(#""[^"]*"|'[^']*'"#, .systemRed),
                rule(#"<!--[\s\S]*?-->"#, .secondaryLabelColor),
                variable,
            ]
        }
    }
}
