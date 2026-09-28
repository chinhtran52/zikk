import Testing
import AppKit
import SwiftUI
import APICore
@testable import Features

/// Renders the form-data body table (with the Notes column). Only runs when SIDEBAR_SNAPSHOT_DIR is set.
@MainActor
@Suite struct FormDataTableSnapshotTests {
    static var keepAlive: [AnyObject] = []

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SIDEBAR_SNAPSHOT_DIR"] != nil))
    func snapshot() throws {
        var fields = [FormDataField(key: "utters", value: "Xin chào", notes: "One utterance per line"),
                      FormDataField(key: "file", kind: .file, file: FileReference(path: "/tmp/utters.csv"), contentType: "text/csv", notes: "CSV export from the NLU tool"),
                      FormDataField(key: "lang", value: "vi", isEnabled: false)]
        let table = FormDataTable(fields: Binding(get: { fields }, set: { fields = $0 }))
        let host = NSHostingView(rootView: table.padding().frame(width: 900).background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame.size = NSSize(width: 900, height: host.fittingSize.height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        Self.keepAlive.append(window)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SIDEBAR_SNAPSHOT_DIR"]!)
        try rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("form-data.png"))
        window.orderOut(nil)
    }
}
