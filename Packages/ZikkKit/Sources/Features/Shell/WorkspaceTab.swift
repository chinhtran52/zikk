import Foundation
import Observation
import APICore

/// What a workspace tab shows.
public enum TabContent: Hashable, Sendable, Codable {
    /// A request; `nodeID` is nil for an unsaved draft.
    case request(nodeID: UUID?)
    case collection(UUID)
    case folder(UUID)
    case example(UUID)
    /// Generated documentation for a collection.
    case docs(UUID)
    case environment(UUID)
    case globals
    case spec(UUID)
    case dataset(UUID)
    case mock(UUID)
    case runner(collectionID: UUID, folderID: UUID?)
}

@MainActor
@Observable
public final class WorkspaceTab: Identifiable {
    public let id = UUID()
    public var content: TabContent
    private var fixedTitle: String
    /// Editing state for request tabs.
    public let request: RequestDocument?
    /// State for runner tabs.
    let runner: RunnerModel?

    init(content: TabContent, title: String, request: RequestDocument? = nil, runner: RunnerModel? = nil) {
        self.content = content
        self.fixedTitle = title
        self.request = request
        self.runner = runner
    }

    public var title: String {
        get { request?.name ?? fixedTitle }
        set { if let request { request.name = newValue } else { fixedTitle = newValue } }
    }

    public var isDirty: Bool { request?.isDirty ?? false }

    /// Tabs whose content is tied to a saved request node.
    var nodeID: UUID? {
        switch content {
        case .request(let id): request?.nodeID ?? id
        case .folder(let id): id
        default: nil
        }
    }
}
