import SwiftUI

/// Text with every occurrence of `query` emphasized (case- and diacritic-insensitive, so "hoa" matches "Hóa").
public struct HighlightedText: View {
    let text: String
    let query: String

    public init(_ text: String, highlighting query: String) {
        self.text = text
        self.query = query
    }

    public var body: some View {
        Text(Self.attributed(text, highlighting: query))
    }

    /// Ranges of `query` in `text`, case- and diacritic-insensitive, non-overlapping.
    /// "đ" is folded to "d" as well: Foundation treats it as a separate letter, but Vietnamese users type "hoa don" for "Hóa đơn".
    public static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        let needle = folded(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return [] }
        // Folding maps characters one-to-one, so ranges in the folded text translate back by character offset.
        let haystack = folded(text)
        var result: [Range<String.Index>] = []
        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex,
              let range = haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<haystack.endIndex, locale: .current) {
            let lower = text.index(text.startIndex, offsetBy: haystack.distance(from: haystack.startIndex, to: range.lowerBound))
            let upper = text.index(lower, offsetBy: haystack.distance(from: range.lowerBound, to: range.upperBound))
            result.append(lower..<upper)
            searchStart = range.upperBound
        }
        return result
    }

    /// Whether `text` contains `query` under the same rules as ``ranges(of:in:)``.
    public static func matches(_ text: String, _ query: String) -> Bool {
        !ranges(of: query, in: text).isEmpty
    }

    private static func folded(_ string: String) -> String {
        String(string.map { character -> Character in
            switch character {
            case "đ": "d"
            case "Đ": "D"
            default: character
            }
        })
    }

    public static func attributed(_ text: String, highlighting query: String) -> AttributedString {
        var attributed = AttributedString(text)
        for range in ranges(of: query, in: text) {
            guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
            attributed[lower..<upper].backgroundColor = Color.accentColor.opacity(0.35)
        }
        return attributed
    }
}
