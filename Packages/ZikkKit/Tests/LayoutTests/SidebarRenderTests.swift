import Testing
import AppKit
import SwiftUI
import SwiftData
import APICore
import APIStore
@testable import Features

/// Renders every sidebar section at the narrowest column width with long item names and checks that nothing
/// forces the sidebar wider than its column (the "overflow" bug). Set SIDEBAR_SNAPSHOT_DIR to save PNGs.
@MainActor
@Suite struct SidebarRenderTests {
    static var keepAlive: [AnyObject] = []

    @Test(arguments: SidebarSection.allCases)
    func sidebarFitsNarrowColumn(section: SidebarSection) throws {
        let container = try StoreFactory.makeContainer(inMemory: true)
        let context = container.mainContext
        let workspace = try StoreFactory.defaultWorkspace(in: context)
        let model = AppModel(services: AppServices(secrets: InMemorySecretStore(), defaults: UserDefaults(suiteName: UUID().uuidString)!))
        model.attach(workspace: workspace, context: context)
        model.section = section
        let long = "A very long name that does not fit in the sidebar column at all"
        let spec = APISpec(name: long, content: "openapi: 3.0.0")
        spec.workspace = workspace
        let mock = MockDefinition(name: long)
        mock.workspace = workspace
        let environment = APIEnvironment(name: long)
        environment.workspace = workspace
        let dataset = Dataset(name: long, columns: ["a"], rows: [["a": "1"]])
        dataset.workspace = workspace
        let collection = APICollection(name: long)
        collection.workspace = workspace
        // Enough rows that the list runs underneath the bottom bar.
        for index in 0..<30 {
            let extra = APICollection(name: "Collection \(index)", sortIndex: index + 1)
            extra.workspace = workspace
            context.insert(extra)
        }
        context.insert(spec); context.insert(mock); context.insert(environment); context.insert(dataset); context.insert(collection)
        let history = HistoryEntry(request: RequestSpec(url: "https://example.com/" + long), resolvedURL: "https://example.com/" + long, response: nil)
        history.workspace = workspace
        context.insert(history)
        try context.save()

        let width: CGFloat = 220
        let host = NSHostingView(rootView: SidebarView(workspace: workspace).frame(width: width, height: 600).environment(model).modelContainer(container))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        Self.keepAlive += [window, container]
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        // The content's minimum width must fit the narrowest sidebar column.
        let fitting = host.fittingSize
        #expect(host.intrinsicContentSize.width <= width || host.intrinsicContentSize.width == NSView.noIntrinsicMetric,
                "\(section) sidebar needs \(host.intrinsicContentSize.width)pt")
        if let directory = ProcessInfo.processInfo.environment["SIDEBAR_SNAPSHOT_DIR"],
           let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("sidebar-\(section.rawValue).png"))
        }
        _ = fitting
        window.orderOut(nil)
    }
}

@MainActor
@Suite struct CollectionsSearchRenderTests {
    /// Searching "utters" shows only the matching request, with its collection and folder expanded.
    /// Set SIDEBAR_SNAPSHOT_DIR to save a PNG of the result.
    @Test func searchExpandsAndHighlights() throws {
        let container = try StoreFactory.makeContainer(inMemory: true)
        let context = container.mainContext
        let workspace = try StoreFactory.defaultWorkspace(in: context)
        let model = AppModel(services: AppServices(secrets: InMemorySecretStore(), defaults: UserDefaults(suiteName: UUID().uuidString)!))
        model.attach(workspace: workspace, context: context)
        for (index, name) in ["Bot", "Billing"].enumerated() {
            let collection = APICollection(name: name, sortIndex: index)
            collection.workspace = workspace
            context.insert(collection)
            let folder = CollectionNode(kind: .folder, name: "NLU", sortIndex: 0)
            folder.collection = collection
            context.insert(folder)
            for (position, request) in (index == 0 ? ["Upload utters", "Train model"] : ["Create invoice"]).enumerated() {
                let node = CollectionNode(kind: .request, name: request, request: RequestSpec(url: "https://example.com/x"), sortIndex: position)
                node.collection = collection
                node.parent = folder
                context.insert(node)
            }
        }
        try context.save()

        let host = NSHostingView(rootView: NavigationStack { CollectionsSidebar(workspace: workspace, search: "utters") }
            .frame(width: 260, height: 300).environment(model).modelContainer(container))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        SidebarRenderTests.keepAlive += [window, container]
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        if let directory = ProcessInfo.processInfo.environment["SIDEBAR_SNAPSHOT_DIR"],
           let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("sidebar-search.png"))
        }
        window.orderOut(nil)
    }
}
