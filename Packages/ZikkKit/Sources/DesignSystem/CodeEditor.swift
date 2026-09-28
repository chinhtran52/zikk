import SwiftUI
import AppKit

/// Syntax-highlighting text editor backed by `NSTextView`.
public struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var language: CodeLanguage
    var isEditable: Bool
    var explicitFontSize: CGFloat?
    var fontSize: CGFloat { explicitFontSize ?? environmentFontSize }
    var wrapsLines: Bool
    var identifier: String?
    /// Background colors for whole lines (1-based), e.g. diagnostics.
    var lineMarkers: [Int: NSColor]
    /// Set to a 1-based line to scroll there and select it; reset to nil afterwards.
    @Binding var revealLine: Int?

    @Environment(\.codeEditorFontSize) private var environmentFontSize

    public init(text: Binding<String>, language: CodeLanguage = .plain, isEditable: Bool = true, fontSize: CGFloat? = nil, wrapsLines: Bool = true,
                identifier: String? = nil, lineMarkers: [Int: NSColor] = [:], revealLine: Binding<Int?> = .constant(nil)) {
        _text = text
        self.language = language
        self.isEditable = isEditable
        self.explicitFontSize = fontSize
        self.wrapsLines = wrapsLines
        self.identifier = identifier
        self.lineMarkers = lineMarkers
        _revealLine = revealLine
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        context.coordinator.textView = textView
        apply(to: textView, coordinator: context.coordinator, force: true)
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        apply(to: textView, coordinator: context.coordinator, force: false)
    }

    private func apply(to textView: NSTextView, coordinator: Coordinator, force: Bool) {
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.setAccessibilityIdentifier(identifier)
        configureWrapping(textView)
        let languageChanged = coordinator.language != language || coordinator.appliedFontSize != fontSize
        coordinator.appliedFontSize = fontSize
        let markersChanged = coordinator.lineMarkers != lineMarkers
        coordinator.language = language
        coordinator.lineMarkers = lineMarkers
        if force || textView.string != text {
            let selection = textView.selectedRanges
            textView.string = text
            if !force { textView.selectedRanges = selection.filter { $0.rangeValue.upperBound <= (text as NSString).length } }
            coordinator.highlight()
        } else if languageChanged || markersChanged {
            coordinator.highlight()
        }
        if let line = revealLine {
            coordinator.reveal(line: line)
            DispatchQueue.main.async { self.revealLine = nil }
        }
    }

    private func configureWrapping(_ textView: NSTextView) {
        guard let container = textView.textContainer, let scrollView = textView.enclosingScrollView else { return }
        if wrapsLines {
            container.widthTracksTextView = true
            textView.isHorizontallyResizable = false
            scrollView.hasHorizontalScroller = false
        } else {
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.isHorizontallyResizable = true
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            scrollView.hasHorizontalScroller = true
        }
    }

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        weak var textView: NSTextView?
        var language: CodeLanguage?
        var lineMarkers: [Int: NSColor] = [:]
        var appliedFontSize: CGFloat = 0

        init(_ parent: CodeEditor) { self.parent = parent }

        var font: NSFont { .monospacedSystemFont(ofSize: parent.fontSize, weight: .regular) }

        func highlight() {
            guard let textView, let storage = textView.textStorage else { return }
            SyntaxHighlighter(language: language ?? .plain).highlight(storage, font: font)
            if !lineMarkers.isEmpty {
                let text = storage.string as NSString
                storage.beginEditing()
                for (line, color) in lineMarkers {
                    if let range = Self.range(ofLine: line, in: text) {
                        storage.addAttribute(.backgroundColor, value: color, range: range)
                    }
                }
                storage.endEditing()
            }
            textView.typingAttributes = [.font: font, .foregroundColor: NSColor.textColor]
        }

        func reveal(line: Int) {
            guard let textView, let range = Self.range(ofLine: line, in: textView.string as NSString) else { return }
            textView.scrollRangeToVisible(range)
            textView.setSelectedRange(NSRange(location: range.location, length: 0))
            textView.showFindIndicator(for: range)
        }

        /// Character range of a 1-based line (without the line break).
        static func range(ofLine line: Int, in text: NSString) -> NSRange? {
            guard line >= 1 else { return nil }
            var current = 1
            var location = 0
            while current < line {
                let next = text.range(of: "\n", range: NSRange(location: location, length: text.length - location))
                guard next.location != NSNotFound else { return nil }
                location = next.location + 1
                current += 1
            }
            let end = text.range(of: "\n", range: NSRange(location: location, length: text.length - location))
            return NSRange(location: location, length: (end.location == NSNotFound ? text.length : end.location) - location)
        }

        public func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            highlight()
        }

        public func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Insert spaces for tab and keep indentation on newline.
            if selector == #selector(NSResponder.insertTab(_:)) {
                textView.insertText("  ", replacementRange: textView.selectedRange())
                return true
            }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                let text = textView.string as NSString
                let lineRange = text.lineRange(for: NSRange(location: textView.selectedRange().location, length: 0))
                let line = text.substring(with: lineRange)
                let indent = line.prefix { $0 == " " || $0 == "\t" }
                textView.insertText("\n" + indent, replacementRange: textView.selectedRange())
                return true
            }
            return false
        }
    }
}

extension EnvironmentValues {
    /// Font size for code editors (set from the app settings).
    @Entry public var codeEditorFontSize: CGFloat = 12
}
