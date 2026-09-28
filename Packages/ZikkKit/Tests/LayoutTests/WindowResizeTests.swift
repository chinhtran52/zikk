import Testing
import AppKit
import SwiftUI
import SwiftData
import APICore
import APIStore
@testable import Features

/// Regression tests for AppKit layout-loop crashes ("more Update Constraints passes than views"):
/// hosts the real `RootView` like a `WindowGroup`, opens different tabs, drags the sidebar divider and resizes
/// the window. A layout loop aborts the test process, so each scenario is a separate test.
@MainActor
@Suite(.serialized) struct WindowResizeTests {
    static var keepAlive: [AnyObject] = []

    enum Scenario: String, CaseIterable { case empty, spec, mock, request, globals }

    func findSplitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        for subview in view.subviews { if let found = findSplitView(in: subview) { return found } }
        return nil
    }

    func pump(_ seconds: Double = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    func run(_ scenario: Scenario, inspector: Bool = false) throws {
        UserDefaults.standard.set(false, forKey: "NSApplicationCrashOnExceptions")
        let container = try StoreFactory.makeContainer(inMemory: true)
        let context = container.mainContext
        let workspace = try StoreFactory.defaultWorkspace(in: context)
        // Long names used to overflow the sidebar.
        let long = String(repeating: "Very long item name ", count: 4)
        let spec = APISpec(name: long, content: "openapi: 3.0.0")
        spec.workspace = workspace
        let mock = MockDefinition(name: long)
        mock.workspace = workspace
        context.insert(spec)
        context.insert(mock)
        try context.save()
        let tabs: [SessionSnapshot.Tab] = switch scenario {
        case .empty: []
        case .spec: [.init(content: .spec(spec.id), title: "Spec", spec: nil, nodeID: nil)]
        case .mock: [.init(content: .mock(mock.id), title: "Mock", spec: nil, nodeID: nil)]
        case .request: [.init(content: .request(nodeID: nil), title: "R", spec: RequestSpec(url: "https://example.com"), nodeID: nil)]
        case .globals: [.init(content: .globals, title: "Globals", spec: nil, nodeID: nil)]
        }
        UserDefaults.standard.set(try JSONEncoder().encode(SessionSnapshot(tabs: tabs, selectedIndex: tabs.isEmpty ? nil : 0)), forKey: SessionSnapshot.defaultsKey)
        UserDefaults.standard.set(inspector, forKey: "showsCodeSnippet")
        let services = AppServices(secrets: InMemorySecretStore(), defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled, .resizable, .closable, .miniaturizable], backing: .buffered, defer: false)
        let controller = NSHostingController(rootView: RootView(services: services).frame(minWidth: 1000, minHeight: 640).modelContainer(container))
        controller.sizingOptions = [.minSize]
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        Self.keepAlive += [window, container]
        pump(0.5)
        if let split = findSplitView(in: window.contentView!) {
            for position in [230.0, 400.0, 150.0, 600.0, 90.0, 420.0, 220.0, 300.0] {
                split.setPosition(position, ofDividerAt: 0)
                pump()
            }
        }
        for width in [1400.0, 1000.0, 1250.0, 1500.0, 1100.0] {
            window.setContentSize(NSSize(width: width, height: 700))
            pump()
        }
        #expect(window.frame.width < 2000, "content must not force the window wider than a laptop screen")
        window.orderOut(nil)
    }

    @Test func empty() throws { try run(.empty) }
    @Test func spec() throws { try run(.spec) }
    @Test func specWithInspector() throws { try run(.spec, inspector: true) }
    @Test func mock() throws { try run(.mock) }
    @Test func mockWithInspector() throws { try run(.mock, inspector: true) }
    @Test func request() throws { try run(.request) }
    @Test func requestWithInspector() throws { try run(.request, inspector: true) }
    @Test func globals() throws { try run(.globals) }
}
