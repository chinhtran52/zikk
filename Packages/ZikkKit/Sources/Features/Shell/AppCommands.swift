import SwiftUI
import APICore

/// Menu bar commands for the main window.
public struct AppCommands: Commands {
    @FocusedValue(\.appModel) private var model
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L("New Window")) { openWindow(id: "main") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button(L("New Request")) { model?.newRequestTab() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(model == nil)
            Menu(L("New…")) {
                ForEach(RequestKind.allCases, id: \.self) { kind in
                    Button(kind.menuTitle) { model?.newRequestTab(kind: kind) }
                }
            }
            .disabled(model == nil)
        }
        CommandGroup(after: .newItem) {
            Button(L("Import…")) { model?.isShowingImport = true }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(model == nil)
            Divider()
            Button(L("Close Tab")) { model?.closeSelected() }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(model?.selectedTab == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button(L("Save")) {
                if let document = model?.selectedTab?.request { model?.requestSave(document) }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(model?.selectedTab?.request == nil)
        }
        CommandGroup(after: .windowArrangement) {
            Button(L("Show Next Tab")) { model?.selectNextTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(model?.tabs.isEmpty ?? true)
            Button(L("Show Previous Tab")) { model?.selectNextTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(model?.tabs.isEmpty ?? true)
        }
        CommandMenu(L("Request")) {
            Button(L("Send")) { model?.sendSelected() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model?.selectedTab?.request == nil)
            Divider()
            Button(L("Cookies…")) { model?.isShowingCookies = true }
                .disabled(model == nil)
            Button(L("Show Console")) { openWindow(id: "console") }
                .keyboardShortcut("c", modifiers: [.command, .option])
        }
    }
}
