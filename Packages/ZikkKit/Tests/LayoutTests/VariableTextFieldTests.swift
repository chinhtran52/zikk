import Testing
import AppKit
import SwiftUI
import APICore
@testable import DesignSystem

/// Hovering a `{{variable}}` in the URL field opens a popover with its value. Set SIDEBAR_SNAPSHOT_DIR to save PNGs.
@MainActor
@Suite struct VariableTextFieldTests {
    static var keepAlive: [AnyObject] = []

    @Test func hoverShowsVariableValue() async throws {
        var text = "{{BASE_URL}}/olivo/{{MISSING}}/upload"
        let binding = Binding(get: { text }, set: { text = $0 })
        let lookup: (String) -> VariableInfo = { name in
            name == "BASE_URL" ? VariableInfo(name: name, value: "https://api.example.com", scope: "Environment · Dev") : VariableInfo(name: name, value: nil)
        }
        let host = NSHostingView(rootView: VariableTextField("URL", text: binding, identifier: "url-field", lookup: lookup).padding().frame(width: 460))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 460, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        Self.keepAlive.append(window)
        try await Task.sleep(for: .milliseconds(300))

        let textView = try #require(Self.find(SingleLineTextView.self, in: host))
        #expect(textView.accessibilityRole() == .textField)
        #expect(textView.accessibilityIdentifier() == "url-field")
        let storage = try #require(textView.textStorage)
        #expect(storage.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor == .linkColor)
        #expect(storage.attribute(.foregroundColor, at: 14, effectiveRange: nil) as? NSColor == .textColor)
        #expect(storage.attribute(.foregroundColor, at: 21, effectiveRange: nil) as? NSColor == .systemRed)

        // Hover the middle of "{{BASE_URL}}".
        let layoutManager = try #require(textView.layoutManager), container = try #require(textView.textContainer)
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: 0, length: 12), in: container)
        let point = NSPoint(x: rect.midX + textView.textContainerOrigin.x, y: rect.midY + textView.textContainerOrigin.y)
        let coordinator = try #require(textView.coordinator)
        coordinator.mouseMoved(to: point)
        try await Task.sleep(for: .milliseconds(600))
        let popover = try #require(coordinator.popover)
        #expect(popover.isShown)

        if let directory = ProcessInfo.processInfo.environment["SIDEBAR_SNAPSHOT_DIR"] {
            try Self.snapshot(host, to: URL(fileURLWithPath: directory).appendingPathComponent("url-field.png"))
            for (index, info) in [VariableInfo(name: "BASE_URL", value: "https://{{HOST}}/v1", scope: "Environment · Dev", resolvedValue: "https://api.example.com/v1"),
                                  VariableInfo(name: "MISSING", value: nil)].enumerated() {
                let content = NSHostingView(rootView: VariablePopoverContent(info: info).background(Color(nsColor: .windowBackgroundColor)))
                content.frame.size = content.fittingSize
                try Self.snapshot(content, to: URL(fileURLWithPath: directory).appendingPathComponent("url-popover-\(index).png"))
            }
        }

        // Leaving the variable closes it; typing updates the binding.
        coordinator.mouseMoved(to: NSPoint(x: textView.bounds.maxX - 2, y: point.y))
        #expect(coordinator.popover == nil)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.insertText("?a=1", replacementRange: textView.selectedRange())
        #expect(text.hasSuffix("/upload?a=1"))
        window.orderOut(nil)
    }

    static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews { if let match = find(type, in: subview) { return match } }
        return nil
    }

    static func snapshot(_ view: NSView, to url: URL) throws {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
