import SwiftUI
import AppKit

/// What a `{{variable}}` in a ``VariableTextField`` currently resolves to, shown when hovering it.
public struct VariableInfo: Equatable, Sendable {
    public var name: String
    /// Stored value; nil when the variable is not defined in any scope.
    public var value: String?
    /// Where the value comes from, e.g. "Environment · Dev".
    public var scope: String
    public var isSecret: Bool
    /// The value with nested `{{…}}` placeholders resolved, when that differs from `value`.
    public var resolvedValue: String?

    public init(name: String, value: String?, scope: String = "", isSecret: Bool = false, resolvedValue: String? = nil) {
        self.name = name
        self.value = value
        self.scope = scope
        self.isSecret = isSecret
        self.resolvedValue = resolvedValue
    }

    public var isResolved: Bool { value != nil }
}

/// Single-line text field that colors `{{variables}}` like links (red when undefined) and shows their current value on hover.
///
/// Backed by an `NSTextView` because an `NSTextField` cannot style ranges while editing; it reports the
/// accessibility role of a text field so UI tests still find it as one.
public struct VariableTextField: View {
    @Binding var text: String
    let placeholder: String
    let identifier: String?
    let lookup: (String) -> VariableInfo
    let onSubmit: () -> Void
    @State private var isFocused = false

    public init(_ placeholder: String, text: Binding<String>, identifier: String? = nil,
                lookup: @escaping (String) -> VariableInfo, onSubmit: @escaping () -> Void = {}) {
        _text = text
        self.placeholder = placeholder
        self.identifier = identifier
        self.lookup = lookup
        self.onSubmit = onSubmit
    }

    public var body: some View {
        VariableTextView(text: $text, isFocused: $isFocused, placeholder: placeholder, identifier: identifier, lookup: lookup, onSubmit: onSubmit)
            .frame(height: 22)
            .padding(.horizontal, 2)
            .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isFocused ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor), lineWidth: isFocused ? 2 : 1)
            }
    }

    /// `{{name}}` placeholders in `text`: the full range including braces and the trimmed name.
    public static func tokens(in text: String) -> [(range: NSRange, name: String)] {
        text.matches(of: /\{\{([^{}]+)\}\}/).map { match in
            (NSRange(match.range, in: text), String(match.output.1).trimmingCharacters(in: .whitespaces))
        }
    }
}

struct VariableTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String
    let identifier: String?
    let lookup: (String) -> VariableInfo
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SingleLineTextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.drawsBackground = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.maximumNumberOfLines = 1
        textView.setAccessibilityRole(.textField)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.apply(force: true)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(force: false)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: VariableTextView
        weak var textView: SingleLineTextView?
        private(set) var popover: NSPopover?
        private var hoveredToken: NSRange?
        private var pendingHover: DispatchWorkItem?

        init(_ parent: VariableTextView) { self.parent = parent }

        var font: NSFont { .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) }

        func apply(force: Bool) {
            guard let textView else { return }
            textView.setAccessibilityIdentifier(parent.identifier)
            textView.setAccessibilityPlaceholderValue(parent.placeholder)
            textView.placeholder = parent.placeholder
            textView.font = font
            if force || textView.string != parent.text {
                let selection = textView.selectedRanges
                textView.string = parent.text
                if !force { textView.selectedRanges = selection.filter { $0.rangeValue.upperBound <= (parent.text as NSString).length } }
            }
            // Re-run on every update: switching environments changes which variables resolve.
            highlight()
            textView.centerVertically()
        }

        func highlight() {
            guard let textView, let storage = textView.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([.font: font, .foregroundColor: NSColor.textColor], range: full)
            for token in VariableTextField.tokens(in: storage.string) {
                let color: NSColor = parent.lookup(token.name).isResolved ? .linkColor : .systemRed
                storage.addAttributes([.foregroundColor: color, .backgroundColor: color.withAlphaComponent(0.1)], range: token.range)
            }
            storage.endEditing()
            textView.typingAttributes = [.font: font, .foregroundColor: NSColor.textColor]
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            highlight()
            closePopover()
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            // Single line: pasted line breaks (e.g. a multi-line cURL command) become spaces.
            guard let replacement = replacementString, replacement.contains(where: \.isNewline) else { return true }
            let flattened = replacement.replacingOccurrences(of: "\\\n", with: " ").replacingOccurrences(of: "\\\r\n", with: " ")
                .components(separatedBy: .newlines).joined(separator: " ")
            textView.insertText(flattened, replacementRange: range)
            return false
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.insertTab(_:)):
                textView.window?.selectNextKeyView(nil)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                textView.window?.selectPreviousKeyView(nil)
                return true
            default:
                return false
            }
        }

        func focusChanged(_ focused: Bool) {
            if parent.isFocused != focused { parent.isFocused = focused }
        }

        // MARK: Hover

        func mouseMoved(to point: NSPoint) {
            guard let textView, let token = token(at: point, in: textView) else {
                pendingHover?.cancel()
                if hoveredToken != nil { hoveredToken = nil; closePopover() }
                return
            }
            guard token.range != hoveredToken else { return }
            hoveredToken = token.range
            closePopover()
            pendingHover?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.showPopover(for: token) }
            pendingHover = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }

        func mouseExited() {
            pendingHover?.cancel()
            hoveredToken = nil
            closePopover()
        }

        func closePopover() {
            popover?.performClose(nil)
            popover = nil
        }

        private func token(at point: NSPoint, in textView: NSTextView) -> (range: NSRange, name: String)? {
            guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return nil }
            let origin = textView.textContainerOrigin
            let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
            for token in VariableTextField.tokens(in: textView.string) {
                let glyphs = layoutManager.glyphRange(forCharacterRange: token.range, actualCharacterRange: nil)
                if layoutManager.boundingRect(forGlyphRange: glyphs, in: container).contains(local) { return token }
            }
            return nil
        }

        private func showPopover(for token: (range: NSRange, name: String)) {
            guard let textView, textView.window != nil, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: token.range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y
            let popover = NSPopover()
            popover.behavior = .semitransient
            popover.animates = false
            popover.contentViewController = NSHostingController(rootView: VariablePopoverContent(info: parent.lookup(token.name)))
            popover.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
            self.popover = popover
        }
    }
}

/// `NSTextView` that behaves like a one-line text field: vertically centered text, placeholder, focus reporting, hover tracking.
final class SingleLineTextView: NSTextView {
    weak var coordinator: VariableTextView.Coordinator?
    var placeholder = "" { didSet { if placeholder != oldValue { needsDisplay = true } } }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { coordinator?.focusChanged(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { coordinator?.focusChanged(false); setSelectedRange(NSRange(location: selectedRange().location, length: 0)) }
        return resigned
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["variables"] != nil { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: ["variables": true]))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        coordinator?.mouseMoved(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        coordinator?.mouseExited()
    }

    override func keyDown(with event: NSEvent) {
        coordinator?.closePopover()
        super.keyDown(with: event)
    }

    override func setFrameSize(_ newSize: NSSize) {
        // Never narrower than the clip view, so clicks right of the text still land in the field.
        super.setFrameSize(NSSize(width: max(newSize.width, enclosingScrollView?.contentSize.width ?? 0), height: newSize.height))
        centerVertically()
    }

    func centerVertically() {
        guard let scrollView = enclosingScrollView, let font else { return }
        let lineHeight = layoutManager?.defaultLineHeight(for: font) ?? font.pointSize
        let height = scrollView.contentSize.height
        let inset = NSSize(width: 4, height: max(0, (height - lineHeight) / 2))
        if textContainerInset != inset { textContainerInset = inset }
        if frame.height != height { super.setFrameSize(NSSize(width: frame.width, height: height)) }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty, let font else { return }
        let origin = NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), y: textContainerOrigin.y)
        (placeholder as NSString).draw(at: origin, withAttributes: [.font: font, .foregroundColor: NSColor.placeholderTextColor])
    }
}

/// Popover shown when hovering a variable.
struct VariablePopoverContent: View {
    let info: VariableInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(info.name)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                if info.isResolved, !info.scope.isEmpty {
                    Text(info.scope)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                }
            }
            if let value = info.value {
                Text(info.isSecret ? "••••••••" : (value.isEmpty ? L("(empty)") : value))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(value.isEmpty && !info.isSecret ? .secondary : .primary)
                    .textSelection(.enabled)
                    .lineLimit(4)
                if let resolved = info.resolvedValue, !info.isSecret {
                    Text(String(format: L("Resolves to %@"), resolved))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            } else {
                Label(L("Unresolved variable"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(L("Define it in the active environment, the collection or globals."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(minWidth: 180, maxWidth: 360, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}
