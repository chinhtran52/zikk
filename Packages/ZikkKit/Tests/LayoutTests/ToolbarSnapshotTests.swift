import Testing
import AppKit
import SwiftUI
import SwiftData
import APICore
import APIStore
@testable import Features

/// Renders the whole main window (toolbar included) so the plain sidebar toggle and sidebar icon buttons can be checked.
/// Only runs when SIDEBAR_SNAPSHOT_DIR is set.
@MainActor
@Suite struct ToolbarSnapshotTests {
    static var keepAlive: [AnyObject] = []

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SIDEBAR_SNAPSHOT_DIR"] != nil))
    func windowSnapshot() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SIDEBAR_SNAPSHOT_DIR"]!)
        let container = try StoreFactory.makeContainer(inMemory: true)
        let context = container.mainContext
        let workspace = try StoreFactory.defaultWorkspace(in: context)
        let collection = APICollection(name: "Bot")
        collection.workspace = workspace
        context.insert(collection)
        try context.save()
        UserDefaults.standard.removeObject(forKey: SessionSnapshot.defaultsKey)
        let services = AppServices(secrets: InMemorySecretStore(), defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 420),
                              styleMask: [.titled, .resizable, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let controller = NSHostingController(rootView: RootView(services: services).modelContainer(container))
        controller.sizingOptions = []
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1000, height: 420))
        window.makeKeyAndOrderFront(nil)
        Self.keepAlive += [window, container]
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let frameView = try #require(window.contentView?.superview)
        if let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("window.png"))
        }
        window.orderOut(nil)
    }
}
