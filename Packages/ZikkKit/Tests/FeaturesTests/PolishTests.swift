import Testing
import Foundation
import SwiftData
import APICore
import APIStore
@testable import Features

@MainActor
@Suite struct PolishTests {
    static var containers: [ModelContainer] = []

    func freshDefaults() -> UserDefaults {
        let name = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func sessionRestoresTabsAndUnsavedEdits() throws {
        let container = try StoreFactory.makeContainer(inMemory: true)
        Self.containers.append(container)
        let context = container.mainContext
        let workspace = try StoreFactory.defaultWorkspace(in: context)
        let defaults = freshDefaults()
        let secrets = InMemorySecretStore()

        let first = AppModel(services: AppServices(secrets: secrets, defaults: defaults))
        first.attach(workspace: workspace, context: context)
        let actions = CollectionActions(context: context, model: first)
        let collection = actions.addCollection(to: workspace)
        let saved = actions.addNode(.request, to: collection, parent: nil)   // opens a tab
        first.selectedTab?.request?.spec.url = "http://edited"               // unsaved edit
        first.openDraft(spec: RequestSpec(method: .put, url: "http://draft"), name: "Draft")
        first.open(.globals, title: "Globals")
        first.openRunner(collection: collection)
        first.selectedTabID = first.tabs[1].id
        first.saveSession(to: defaults)

        let second = AppModel(services: AppServices(secrets: secrets, defaults: defaults))
        second.attach(workspace: workspace, context: context)
        second.restoreSession(from: defaults)
        #expect(second.tabs.count == 4)
        #expect(second.tabs[0].request?.nodeID == saved.id)
        #expect(second.tabs[0].request?.spec.url == "http://edited")
        #expect(second.tabs[0].request?.isDirty == true)
        #expect(second.tabs[1].request?.spec.method == .put)
        #expect(second.tabs[1].request?.isDraft == true)
        #expect(second.tabs[2].content == .globals)
        #expect(second.tabs[3].runner != nil)
        #expect(second.selectedTabID == second.tabs[1].id)

        second.selectNextTab(offset: -2)
        #expect(second.selectedTabID == second.tabs[3].id)

        // Deleted objects are skipped; disabled restore clears the snapshot.
        context.delete(saved)
        second.services.settings.restoresTabs = false
        second.saveSession(to: defaults)
        #expect(defaults.data(forKey: SessionSnapshot.defaultsKey) == nil)
    }

    @Test func settingsDrivesClientConfiguration() {
        let defaults = freshDefaults()
        let secrets = InMemorySecretStore()
        let services = AppServices(secrets: secrets, defaults: defaults)
        let settings = services.settings
        #expect(settings.clientConfiguration.proxy == nil)
        settings.proxyEnabled = true
        settings.proxyHost = "proxy.local"
        settings.proxyPort = 3128
        settings.addCertificate(host: "mtls.test", file: FileReference(path: "/tmp/c.p12"), passphrase: "pw")
        settings.requestTimeoutSeconds = 5

        let reloaded = SettingsStore(defaults: defaults, secrets: secrets)
        #expect(reloaded.clientConfiguration.proxy == .init(host: "proxy.local", port: 3128))
        #expect(reloaded.clientConfiguration.clientCertificates.map(\.passphrase) == ["pw"])
        #expect(reloaded.certificates.first?.host == "mtls.test")
        #expect(services.applyDefaults(to: RequestSpec()).settings.timeoutMilliseconds == 5000)
        var explicit = RequestSpec()
        explicit.settings.timeoutMilliseconds = 100
        #expect(services.applyDefaults(to: explicit).settings.timeoutMilliseconds == 100)

        let id = reloaded.certificates[0].id
        reloaded.removeCertificate(id)
        #expect(secrets.value(for: SettingsStore.passphraseKey(id)) == nil)
    }
}
