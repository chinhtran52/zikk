import Foundation
import SwiftData
import APICore
import APIStore


/// Snapshot of open tabs so they can be restored on the next launch (including unsaved edits).
struct SessionSnapshot: Codable {
    struct Tab: Codable {
        var content: TabContent
        var title: String
        /// Working copy for request tabs (drafts and saved requests with unsaved edits).
        var spec: RequestSpec?
        var nodeID: UUID?
    }

    var tabs: [Tab]
    var selectedIndex: Int?

    static let defaultsKey = "session.snapshot"
}

@MainActor
extension AppModel {
    func sessionSnapshot() -> SessionSnapshot {
        SessionSnapshot(
            tabs: tabs.map { tab in
                if let request = tab.request {
                    return .init(content: tab.content, title: request.name, spec: request.isDraft || request.isDirty ? request.spec : nil, nodeID: request.nodeID)
                }
                return .init(content: tab.content, title: tab.title, spec: nil, nodeID: nil)
            },
            selectedIndex: tabs.firstIndex { $0.id == selectedTabID }
        )
    }

    func saveSession(to defaults: UserDefaults = .standard) {
        guard services.settings.restoresTabs else {
            defaults.removeObject(forKey: SessionSnapshot.defaultsKey)
            return
        }
        defaults.set(try? JSONEncoder().encode(sessionSnapshot()), forKey: SessionSnapshot.defaultsKey)
    }

    func restoreSession(from defaults: UserDefaults = .standard) {
        guard services.settings.restoresTabs, tabs.isEmpty, let context, let workspace,
              let data = defaults.data(forKey: SessionSnapshot.defaultsKey),
              let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: data) else { return }
        for tab in snapshot.tabs {
            switch tab.content {
            case .request(let nodeID):
                if let id = tab.nodeID ?? nodeID, let node = CollectionQueries.node(id, in: context) {
                    openRequest(node)
                    if let spec = tab.spec { selectedTab?.request?.spec = spec }
                } else if let spec = tab.spec {
                    openDraft(spec: spec, name: tab.title)
                }
            case .runner(let collectionID, let folderID):
                if let collection = CollectionQueries.collection(collectionID, in: context) {
                    openRunner(collection: collection, folder: folderID.flatMap { CollectionQueries.node($0, in: context) })
                }
            case .collection(let id), .docs(let id):
                if CollectionQueries.collection(id, in: context) != nil { open(tab.content, title: tab.title) }
            case .folder(let id):
                if CollectionQueries.node(id, in: context) != nil { open(tab.content, title: tab.title) }
            case .example(let id):
                if CollectionQueries.example(id, in: context) != nil { open(tab.content, title: tab.title) }
            case .environment(let id):
                if CollectionQueries.environment(id, in: context) != nil { open(tab.content, title: tab.title) }
            case .spec(let id):
                if workspace.specs.contains(where: { $0.id == id }) { open(tab.content, title: tab.title) }
            case .dataset(let id):
                if workspace.datasets.contains(where: { $0.id == id }) { open(tab.content, title: tab.title) }
            case .mock(let id):
                if workspace.mocks.contains(where: { $0.id == id }) { open(tab.content, title: tab.title) }
            case .globals:
                open(.globals, title: tab.title)
            }
        }
        if let index = snapshot.selectedIndex, index < tabs.count { selectedTabID = tabs[index].id }
    }

    func selectNextTab(offset: Int) {
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex { $0.id == selectedTabID } ?? 0
        selectedTabID = tabs[(current + offset + tabs.count) % tabs.count].id
    }
}
