import SwiftUI
import SwiftData
import APIStore
import Features

@main
struct ZikkApp: App {
    let container: ModelContainer
    @State private var services: AppServices

    init() {
        let isUITesting = ProcessInfo.processInfo.arguments.contains("-ui-testing")
        if isUITesting, let bundleID = Bundle.main.bundleIdentifier {
            // Start every UI test from a clean slate: no restored defaults or tabs.
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        do {
            container = try StoreFactory.makeContainer(inMemory: isUITesting)
        } catch {
            fatalError("Failed to open data store: \(error)")
        }
        _services = State(initialValue: AppServices(secrets: isUITesting ? InMemorySecretStore() : KeychainSecretStore()))
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView(services: services)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .modelContainer(container)
        .commands { AppCommands() }
        // Always open a fresh window at launch. AppKit's own restoration could restore "no windows" (after the
        // last window was closed before quitting), leaving the app windowless; open tabs are restored by the
        // app's session snapshot instead.
        .restorationBehavior(.disabled)

        Window(Text("Console"), id: "console") {
            ConsoleView(store: services.console)
        }
        .defaultSize(width: 760, height: 360)

        Settings {
            SettingsView(settings: services.settings)
        }
    }
}
