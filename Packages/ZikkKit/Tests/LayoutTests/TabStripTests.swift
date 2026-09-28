import Testing
import AppKit
import SwiftUI
@testable import DesignSystem

/// Finder/Safari-style tab bar: equal-width tabs filling the bar, scrolling once they reach the minimum width.
/// Set SIDEBAR_SNAPSHOT_DIR to save PNGs.
@MainActor
@Suite struct TabStripTests {
    static var keepAlive: [AnyObject] = []

    @Test func widthsShareTheBarAndClampToMinimum() {
        #expect(TabStrip<EmptyView>.tabWidth(available: 902, count: 3) == 299)
        #expect(TabStrip<EmptyView>.tabWidth(available: 600, count: 10) == TabStrip<EmptyView>.minTabWidth)
        #expect(TabStrip<EmptyView>.tabWidth(available: 600, count: 0) == 0)
    }

    @Test(arguments: [(3, true), (9, true), (3, false)])
    func render(count: Int, dark: Bool) throws {
        let names = ["Upload utters", "Train model", "List intents", "Create invoice", "Get user", "Delete user", "Health", "Login", "Refresh token"]
        let methods: [(String, Color)] = [("POST", .orange), ("GET", .green), ("DEL", .red)]
        let items = (0..<count).map { index in
            TabStripItem(id: UUID(), title: names[index], leading: methods[index % 3].0, leadingColor: methods[index % 3].1, isDirty: index == 2)
        }
        var selection: UUID? = items[1].id
        let strip = TabStrip(items: items, selection: Binding(get: { selection }, set: { selection = $0 }), onClose: { _ in }, onNew: {}) { EmptyView() }
        let host = NSHostingView(rootView: VStack(spacing: 0) { strip; Divider(); Color.clear.frame(height: 20) }.frame(width: 900)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        Self.keepAlive.append(window)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        #expect(host.fittingSize.width <= 900, "many tabs scroll instead of widening the bar")
        if let directory = ProcessInfo.processInfo.environment["SIDEBAR_SNAPSHOT_DIR"], let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("tabs-\(count)-\(dark ? "dark" : "light").png"))
        }
        window.orderOut(nil)
    }

    @Test func middleClickClosesTabAndLeftClickSelects() throws {
        _ = NSApplication.shared
        let items = ["One", "Two", "Three"].map { TabStripItem(id: UUID(), title: $0) }
        var selection: UUID? = items[0].id
        var closed: [UUID] = []
        let strip = TabStrip(items: items, selection: Binding(get: { selection }, set: { selection = $0 }), onClose: { closed.append($0) }, onNew: {}) { EmptyView() }
        let host = NSHostingView(rootView: strip.frame(width: 600))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 34), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        Self.keepAlive.append(window)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        let catchers = Self.all(MiddleClickCatcher.CatcherView.self, in: host).sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        #expect(catchers.count == 3)
        let third = catchers[2].convert(catchers[2].bounds, to: nil)
        let center = NSPoint(x: third.midX, y: third.midY)

        /// A mouse event at `point` (window coordinates). Built from a CGEvent so buttonNumber is the real button
        /// (NSEvent.mouseEvent always reports 0); without a window its location is the global point, so flip it to match.
        func event(_ type: CGEventType, at point: NSPoint, button: CGMouseButton) -> NSEvent {
            let height = NSScreen.screens.first?.frame.height ?? 0
            let cg = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: point.x, y: height - point.y), mouseButton: button)!
            return NSEvent(cgEvent: cg)!
        }
        let catcher = catchers[2]

        // Hit-testing: middle-button events land on the catcher, everything else falls through to SwiftUI.
        for view in catchers { view.currentEvent = { event(.otherMouseDown, at: center, button: .center) } }
        #expect(host.hitTest(host.superview?.convert(center, from: nil) ?? center) === catcher)
        for view in catchers { view.currentEvent = { event(.leftMouseDown, at: center, button: .left) } }
        #expect(!(host.hitTest(host.superview?.convert(center, from: nil) ?? center) is MiddleClickCatcher.CatcherView))

        // Middle-click on the third tab closes it; selection stays.
        let down = event(.otherMouseDown, at: center, button: .center)
        #expect(down.buttonNumber == 2 && down.locationInWindow == center)
        catcher.otherMouseDown(with: down)
        catcher.otherMouseUp(with: event(.otherMouseUp, at: center, button: .center))
        #expect(closed == [items[2].id])
        #expect(selection == items[0].id)

        // Releasing outside the tab cancels.
        catcher.otherMouseDown(with: down)
        catcher.otherMouseUp(with: event(.otherMouseUp, at: NSPoint(x: center.x, y: center.y + 200), button: .center))
        #expect(closed.count == 1)

        // Other "other" buttons (e.g. back/forward, button 3/4) are ignored.
        catcher.otherMouseDown(with: event(.otherMouseDown, at: center, button: CGMouseButton(rawValue: 3)!))
        catcher.otherMouseUp(with: event(.otherMouseUp, at: center, button: CGMouseButton(rawValue: 3)!))
        #expect(closed.count == 1)
        window.orderOut(nil)
    }

    static func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? [] + view.subviews.flatMap { all(type, in: $0) }
    }
}
