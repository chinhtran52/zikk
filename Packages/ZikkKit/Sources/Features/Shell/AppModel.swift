import Foundation
import Observation
import SwiftData
import APICore
import APIStore
import Interop
import Runner
import UniformTypeIdentifiers

/// Window-level UI state: selected sidebar section and open tabs.
@MainActor
@Observable
public final class AppModel {
    public var section: SidebarSection = .collections
    public private(set) var tabs: [WorkspaceTab] = []
    public var selectedTabID: UUID?
    public let services: AppServices
    /// Presented sheets.
    public var isShowingCookies = false
    public var isShowingImport = false
    var pendingExport: PendingExport?
    var saveRequestTarget: RequestDocument?
    private(set) var workspace: Workspace?
    private(set) var context: ModelContext?

    public init(services: AppServices) {
        self.services = services
    }

    @ObservationIgnored private var autosaveTimer: Timer?

    func attach(workspace: Workspace, context: ModelContext) {
        self.workspace = workspace
        self.context = context
        // Autosave unsaved edits periodically. A run-loop timer keeps the snapshot outside SwiftUI's view
        // updates (a `.task` loop reading observable state crashed inside Observation's access tracking).
        autosaveTimer?.invalidate()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSession() }
        }
    }

    // MARK: Export

    struct PendingExport {
        var file: JSONFile
        var fileName: String
    }

    func export(_ collection: APICollection) {
        let data = PostmanCollection.encode(InteropMapper.export(collection, secrets: services.secrets))
        pendingExport = PendingExport(file: JSONFile(data: data), fileName: "\(collection.name).postman_collection.json")
    }

    func export(_ dataset: Dataset) {
        let data = Data(DatasetParser.csv(DataTable(columns: dataset.columns, rows: dataset.rows)).utf8)
        pendingExport = PendingExport(file: JSONFile(data: data, contentType: .commaSeparatedText), fileName: "\(dataset.name).csv")
    }

    func export(_ spec: APISpec) {
        let ext = spec.format == .json ? "json" : "yaml"
        pendingExport = PendingExport(file: JSONFile(data: Data(spec.content.utf8), contentType: spec.format == .json ? .json : .yaml), fileName: "\(spec.name).\(ext)")
    }

    func exportReport(_ data: Data, fileName: String, contentType: UTType) {
        pendingExport = PendingExport(file: JSONFile(data: data, contentType: contentType), fileName: fileName)
    }

    func export(_ environment: APIEnvironment) {
        let data = PostmanEnvironment.encode(InteropMapper.export(environment, secrets: services.secrets))
        pendingExport = PendingExport(file: JSONFile(data: data), fileName: "\(environment.name).postman_environment.json")
    }

    // MARK: Request actions

    func send(_ document: RequestDocument) {
        guard let workspace, let context, document.spec.kind == .http || document.spec.kind == .graphQL else { return }
        let node = document.nodeID.flatMap { CollectionQueries.node($0, in: context) }
        document.send(workspace: workspace, node: node, services: services, context: context)
    }

    func sendSelected() {
        if let document = selectedTab?.request { send(document) }
    }

    /// Saves a request in place, or asks where to save a draft.
    func requestSave(_ document: RequestDocument) {
        guard let context else { return }
        if document.isDraft {
            saveRequestTarget = document
        } else {
            document.save(context: context)
            if let nodeID = document.nodeID, let node = CollectionQueries.node(nodeID, in: context) { nodeRenamed(node) }
        }
    }

    /// The request shown in the code inspector (HTTP and GraphQL tabs only).
    var snippetDocument: RequestDocument? {
        guard let document = selectedTab?.request, document.spec.kind == .http || document.spec.kind == .graphQL else { return nil }
        return document
    }

    public var selectedTab: WorkspaceTab? {
        tabs.first { $0.id == selectedTabID }
    }

    /// Opens non-request content, focusing an existing tab if already open.
    public func open(_ content: TabContent, title: String) {
        if let existing = tabs.first(where: { $0.content == content }) {
            selectedTabID = existing.id
            return
        }
        append(WorkspaceTab(content: content, title: title))
    }

    /// Opens a saved request node.
    public func openRequest(_ node: CollectionNode) {
        if let existing = tabs.first(where: { $0.request?.nodeID == node.id }) {
            selectedTabID = existing.id
            return
        }
        let document = RequestDocument(name: node.name, spec: node.request, nodeID: node.id)
        append(WorkspaceTab(content: .request(nodeID: node.id), title: node.name, request: document))
    }

    /// Opens an unsaved request, optionally pre-filled (e.g. from history).
    public func openDraft(spec: RequestSpec = RequestSpec(), name: String? = nil, response: ResponseSnapshot? = nil) {
        let document = RequestDocument(name: name ?? L("Untitled Request"), spec: spec)
        document.response = response
        append(WorkspaceTab(content: .request(nodeID: nil), title: document.name, request: document))
    }

    public func newRequestTab() { openDraft() }

    /// Opens a new unsaved request of the given kind.
    public func newRequestTab(kind: RequestKind) {
        openDraft(spec: RequestSpec.template(for: kind), name: kind.defaultName)
    }

    /// Opens (or focuses) the Collection Runner for a collection or one of its folders.
    func openRunner(collection: APICollection, folder: CollectionNode? = nil) {
        let content = TabContent.runner(collectionID: collection.id, folderID: folder?.id)
        if let existing = tabs.first(where: { $0.content == content }) {
            selectedTabID = existing.id
            return
        }
        let title = L("Runner") + " – " + (folder?.name ?? collection.name)
        append(WorkspaceTab(content: content, title: title, runner: RunnerModel(collectionID: collection.id, folderID: folder?.id)))
    }

    private func append(_ tab: WorkspaceTab) {
        if let selected = tabs.firstIndex(where: { $0.id == selectedTabID }) {
            tabs.insert(tab, at: selected + 1)
        } else {
            tabs.append(tab)
        }
        selectedTabID = tab.id
    }

    public func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].request?.close()
        tabs[index].runner?.stop()
        tabs.remove(at: index)
        if selectedTabID == id {
            selectedTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
    }

    public func closeSelected() {
        if let selectedTabID { close(selectedTabID) }
    }

    /// Closes tabs whose content matches (e.g. after deleting the backing object).
    public func closeTabs(where predicate: (WorkspaceTab) -> Bool) {
        for tab in tabs where predicate(tab) { close(tab.id) }
    }

    /// Keeps open request tabs in sync after a node was renamed elsewhere.
    func nodeRenamed(_ node: CollectionNode) {
        for tab in tabs where tab.request?.nodeID == node.id {
            tab.request?.name = node.name
        }
    }
}
