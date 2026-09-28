import Foundation
import Markdown

public enum MarkdownRenderer {
    /// HTML for CommonMark + GitHub-flavored Markdown. All text is escaped and raw HTML is shown literally,
    /// so descriptions cannot inject markup or scripts into previews and exported docs.
    public static func html(_ markdown: String) -> String {
        var renderer = SafeHTMLRenderer()
        renderer.visit(Document(parsing: markdown))
        return renderer.result
    }

    /// Standalone page (with styles) used for in-app Markdown preview.
    public static func page(_ markdown: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <style>\(DocsStyle.css)</style></head><body class="markdown"><main class="content">\(html(markdown))</main></body></html>
        """
    }
}

private struct SafeHTMLRenderer: MarkupWalker {
    var result = ""
    private var tightLists: [Bool] = []

    mutating func defaultVisit(_ markup: Markup) {
        for child in markup.children { visit(child) }
    }

    private mutating func wrap(_ tag: String, _ markup: Markup, attributes: String = "") {
        result += "<\(tag)\(attributes)>"
        defaultVisit(markup)
        result += "</\(tag)>"
    }

    mutating func visitHeading(_ heading: Heading) {
        let level = min(max(heading.level, 1), 6)
        wrap("h\(level)", heading)
        result += "\n"
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        if tightLists.last == true, paragraph.parent is ListItem {
            defaultVisit(paragraph)
        } else {
            wrap("p", paragraph)
            result += "\n"
        }
    }

    mutating func visitText(_ text: Text) { result += HTML.escape(text.string) }
    mutating func visitEmphasis(_ emphasis: Emphasis) { wrap("em", emphasis) }
    mutating func visitStrong(_ strong: Strong) { wrap("strong", strong) }
    mutating func visitStrikethrough(_ strikethrough: Strikethrough) { wrap("del", strikethrough) }
    mutating func visitInlineCode(_ inlineCode: InlineCode) { result += "<code>\(HTML.escape(inlineCode.code))</code>" }
    mutating func visitSoftBreak(_ softBreak: SoftBreak) { result += "\n" }
    mutating func visitLineBreak(_ lineBreak: LineBreak) { result += "<br>\n" }
    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) { result += "<hr>\n" }
    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) { result += HTML.escape(inlineHTML.rawHTML) }
    mutating func visitHTMLBlock(_ html: HTMLBlock) { result += "<p>\(HTML.escape(html.rawHTML))</p>\n" }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        let language = codeBlock.language.map { " class=\"language-\(HTML.escape($0))\"" } ?? ""
        result += "<pre><code\(language)>\(HTML.escape(codeBlock.code))</code></pre>\n"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        wrap("blockquote", blockQuote)
        result += "\n"
    }

    mutating func visitUnorderedList(_ list: UnorderedList) {
        tightLists.append(Self.isTight(list))
        wrap("ul", list)
        tightLists.removeLast()
        result += "\n"
    }

    mutating func visitOrderedList(_ list: OrderedList) {
        tightLists.append(Self.isTight(list))
        wrap("ol", list, attributes: list.startIndex == 1 ? "" : " start=\"\(list.startIndex)\"")
        tightLists.removeLast()
        result += "\n"
    }

    mutating func visitListItem(_ listItem: ListItem) {
        let checkbox: String = switch listItem.checkbox {
        case .checked: "<input type=\"checkbox\" checked disabled> "
        case .unchecked: "<input type=\"checkbox\" disabled> "
        case nil: ""
        }
        result += "<li>" + checkbox
        defaultVisit(listItem)
        result += "</li>\n"
    }

    mutating func visitLink(_ link: Link) {
        let href = link.destination.flatMap(Self.safeURL) ?? "#"
        wrap("a", link, attributes: " href=\"\(HTML.escape(href))\"")
    }

    mutating func visitImage(_ image: Image) {
        guard let source = image.source.flatMap(Self.safeURL) else { return }
        result += "<img src=\"\(HTML.escape(source))\" alt=\"\(HTML.escape(image.plainText))\">"
    }

    mutating func visitTable(_ table: Table) {
        result += "<table>"
        let alignments = table.columnAlignments
        result += "<thead><tr>"
        for (index, cell) in table.head.cells.enumerated() {
            result += "<th\(Self.alignment(alignments, index))>"
            defaultVisit(cell)
            result += "</th>"
        }
        result += "</tr></thead><tbody>"
        for row in table.body.rows {
            result += "<tr>"
            for (index, cell) in row.cells.enumerated() {
                result += "<td\(Self.alignment(alignments, index))>"
                defaultVisit(cell)
                result += "</td>"
            }
            result += "</tr>"
        }
        result += "</tbody></table>\n"
    }

    private static func alignment(_ alignments: [Table.ColumnAlignment?], _ index: Int) -> String {
        guard index < alignments.count, let alignment = alignments[index] else { return "" }
        switch alignment {
        case .left: return " style=\"text-align:left\""
        case .center: return " style=\"text-align:center\""
        case .right: return " style=\"text-align:right\""
        }
    }

    /// Only web and anchor links are allowed (no `javascript:` or `data:` URLs).
    private static func safeURL(_ url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:") || lower.hasPrefix("#") || lower.hasPrefix("/") {
            return trimmed
        }
        return lower.contains(":") ? nil : trimmed
    }

    private static func isTight(_ list: ListItemContainer) -> Bool {
        // A list is loose when any item contains more than one block or blank lines separate items.
        for item in list.listItems where item.childCount > 1 {
            return false
        }
        return true
    }
}

public enum HTML {
    public static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }
}
