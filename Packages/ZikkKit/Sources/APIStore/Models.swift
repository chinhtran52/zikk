import Foundation
import SwiftData
import APICore

// Every model carries id/createdAt/updatedAt/deletedAt/revision so a sync backend can be added later
// (tombstones via `deletedAt`, optimistic concurrency via `revision`).

@Model
public final class Workspace {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var revision: Int
    public var globalsData: Data
    public var activeEnvironmentID: UUID?

    @Relationship(deleteRule: .cascade, inverse: \APICollection.workspace) public var collections: [APICollection] = []
    @Relationship(deleteRule: .cascade, inverse: \APIEnvironment.workspace) public var environments: [APIEnvironment] = []
    @Relationship(deleteRule: .cascade, inverse: \APISpec.workspace) public var specs: [APISpec] = []
    @Relationship(deleteRule: .cascade, inverse: \Dataset.workspace) public var datasets: [Dataset] = []
    @Relationship(deleteRule: .cascade, inverse: \MockDefinition.workspace) public var mocks: [MockDefinition] = []
    @Relationship(deleteRule: .cascade, inverse: \HistoryEntry.workspace) public var history: [HistoryEntry] = []

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
        self.createdAt = .now
        self.updatedAt = .now
        self.revision = 0
        self.globalsData = Codec.encode([Variable]())
    }

    public var globals: [Variable] {
        get { Codec.decode([Variable].self, from: globalsData, default: []) }
        set { globalsData = Codec.encode(newValue); touch() }
    }

    public var activeEnvironment: APIEnvironment? {
        environments.first { $0.id == activeEnvironmentID && $0.deletedAt == nil }
    }

    public func touch() { updatedAt = .now; revision += 1 }
}

@Model
public final class APICollection {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var descriptionMD: String
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var revision: Int
    public var sortIndex: Int
    public var authData: Data
    public var preRequestScript: String
    public var testScript: String
    public var variablesData: Data

    public var workspace: Workspace?
    /// All nodes of this collection (flat). Tree structure comes from `CollectionNode.parent`.
    @Relationship(deleteRule: .cascade, inverse: \CollectionNode.collection) public var nodes: [CollectionNode] = []

    public init(id: UUID = UUID(), name: String, descriptionMD: String = "", sortIndex: Int = 0) {
        self.id = id
        self.name = name
        self.descriptionMD = descriptionMD
        self.createdAt = .now
        self.updatedAt = .now
        self.revision = 0
        self.sortIndex = sortIndex
        self.authData = Codec.encode(AuthConfig.none)
        self.preRequestScript = ""
        self.testScript = ""
        self.variablesData = Codec.encode([Variable]())
    }

    public var auth: AuthConfig {
        get { Codec.decode(AuthConfig.self, from: authData, default: .none) }
        set { authData = Codec.encode(newValue); touch() }
    }

    public var variables: [Variable] {
        get { Codec.decode([Variable].self, from: variablesData, default: []) }
        set { variablesData = Codec.encode(newValue); touch() }
    }

    /// Live top-level nodes ordered by `sortIndex`.
    public var rootNodes: [CollectionNode] {
        nodes.filter { $0.parent == nil && $0.deletedAt == nil }.sorted { $0.sortIndex < $1.sortIndex }
    }

    public func touch() { updatedAt = .now; revision += 1 }
}

public enum NodeKind: String, Codable, Sendable { case folder, request }

@Model
public final class CollectionNode {
    @Attribute(.unique) public var id: UUID
    public var kindRaw: String
    public var name: String
    public var descriptionMD: String
    public var sortIndex: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var revision: Int
    /// Request definition (request nodes only).
    public var requestData: Data
    /// Folder-level settings (folder nodes only).
    public var authData: Data
    public var preRequestScript: String
    public var testScript: String
    public var variablesData: Data

    public var collection: APICollection?
    public var parent: CollectionNode?
    @Relationship(deleteRule: .cascade, inverse: \CollectionNode.parent) public var children: [CollectionNode] = []
    @Relationship(deleteRule: .cascade, inverse: \SavedExample.node) public var examples: [SavedExample] = []

    public init(id: UUID = UUID(), kind: NodeKind, name: String, request: RequestSpec? = nil, sortIndex: Int = 0) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.name = name
        self.descriptionMD = ""
        self.sortIndex = sortIndex
        self.createdAt = .now
        self.updatedAt = .now
        self.revision = 0
        self.requestData = request.map { Codec.encode($0) } ?? Data()
        self.authData = Codec.encode(AuthConfig.inherit)
        self.preRequestScript = ""
        self.testScript = ""
        self.variablesData = Codec.encode([Variable]())
    }

    public var kind: NodeKind { NodeKind(rawValue: kindRaw) ?? .request }
    public var isFolder: Bool { kind == .folder }

    public var request: RequestSpec {
        get { Codec.decode(RequestSpec.self, from: requestData, default: RequestSpec()) }
        set { requestData = Codec.encode(newValue); touch() }
    }

    public var auth: AuthConfig {
        get { Codec.decode(AuthConfig.self, from: authData, default: .inherit) }
        set { authData = Codec.encode(newValue); touch() }
    }

    public var variables: [Variable] {
        get { Codec.decode([Variable].self, from: variablesData, default: []) }
        set { variablesData = Codec.encode(newValue); touch() }
    }

    /// Live children ordered by `sortIndex`; `nil` for requests so it plugs into `OutlineGroup`.
    public var sortedChildren: [CollectionNode]? {
        guard isFolder else { return nil }
        return children.filter { $0.deletedAt == nil }.sorted { $0.sortIndex < $1.sortIndex }
    }

    /// Ancestors from the root folder down to the direct parent.
    public var ancestors: [CollectionNode] {
        var result: [CollectionNode] = []
        var current = parent
        while let node = current {
            result.insert(node, at: 0)
            current = node.parent
        }
        return result
    }

    public func touch() { updatedAt = .now; revision += 1 }
}

@Model
public final class SavedExample {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var revision: Int
    public var requestData: Data
    @Attribute(.externalStorage) public var responseData: Data

    public var node: CollectionNode?

    public init(id: UUID = UUID(), name: String, request: RequestSpec, response: ResponseSnapshot) {
        self.id = id
        self.name = name
        self.createdAt = .now
        self.updatedAt = .now
        self.revision = 0
        self.requestData = Codec.encode(request)
        self.responseData = Codec.encode(response)
    }

    public var request: RequestSpec {
        get { Codec.decode(RequestSpec.self, from: requestData, default: RequestSpec()) }
        set { requestData = Codec.encode(newValue); updatedAt = .now; revision += 1 }
    }

    public var response: ResponseSnapshot {
        get { Codec.decode(ResponseSnapshot.self, from: responseData, default: ResponseSnapshot(statusCode: 200)) }
        set { responseData = Codec.encode(newValue); updatedAt = .now; revision += 1 }
    }
}

@Model
public final class APIEnvironment {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var sortIndex: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var revision: Int
    /// Secret variables are persisted with an empty value; the real value lives in `SecretStore`.
    public var variablesData: Data

    public var workspace: Workspace?

    public init(id: UUID = UUID(), name: String, variables: [Variable] = [], sortIndex: Int = 0) {
        self.id = id
        self.name = name
        self.sortIndex = sortIndex
        self.createdAt = .now
        self.updatedAt = .now
        self.revision = 0
        self.variablesData = Codec.encode(variables)
    }

    public var variables: [Variable] {
        get { Codec.decode([Variable].self, from: variablesData, default: []) }
        set { variablesData = Codec.encode(newValue); updatedAt = .now; revision += 1 }
    }
}

public enum SpecFormat: String, Codable, CaseIterable, Sendable { case yaml, json }

@Model
public final class APISpec {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var formatRaw: String
    public var version: String
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var revision: Int
    @Attribute(.externalStorage) public var content: String
    public var linkedCollectionID: UUID?
    public var lastSyncHash: String?

    public var workspace: Workspace?

    public init(id: UUID = UUID(), name: String, format: SpecFormat = .yaml, content: String = "", version: String = "1.0.0") {
        self.id = id
        self.name = name
        self.formatRaw = format.rawValue
        self.version = version
        self.createdAt = .now
        self.updatedAt = .now
        self.revision = 0
        self.content = content
    }

    public var format: SpecFormat {
        get { SpecFormat(rawValue: formatRaw) ?? .yaml }
        set { formatRaw = newValue.rawValue }
    }
}

public enum DatasetFormat: String, Codable, CaseIterable, Sendable { case csv, json }

@Model
public final class Dataset {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var formatRaw: String
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var revision: Int
    public var columns: [String]
    /// Rows encoded as `[[String: String]]` JSON.
    @Attribute(.externalStorage) public var rowsData: Data

    public var workspace: Workspace?

    public init(id: UUID = UUID(), name: String, format: DatasetFormat = .csv, columns: [String] = [], rows: [[String: String]] = []) {
        self.id = id
        self.name = name
        self.formatRaw = format.rawValue
        self.createdAt = .now
        self.updatedAt = .now
        self.revision = 0
        self.columns = columns
        self.rowsData = Codec.encode(rows)
    }

    public var format: DatasetFormat {
        get { DatasetFormat(rawValue: formatRaw) ?? .csv }
        set { formatRaw = newValue.rawValue }
    }

    public var rows: [[String: String]] {
        get { Codec.decode([[String: String]].self, from: rowsData, default: []) }
        set { rowsData = Codec.encode(newValue); updatedAt = .now; revision += 1 }
    }
}

@Model
public final class MockDefinition {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var port: Int
    public var collectionID: UUID?
    public var specID: UUID?
    public var environmentID: UUID?
    public var defaultDelayMilliseconds: Int
    public var matchHeaders: Bool
    public var matchBody: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var revision: Int

    public var workspace: Workspace?

    public init(id: UUID = UUID(), name: String, port: Int = 8787, collectionID: UUID? = nil) {
        self.id = id
        self.name = name
        self.port = port
        self.collectionID = collectionID
        self.defaultDelayMilliseconds = 0
        self.matchHeaders = false
        self.matchBody = false
        self.createdAt = .now
        self.updatedAt = .now
        self.revision = 0
    }
}

@Model
public final class HistoryEntry {
    @Attribute(.unique) public var id: UUID
    public var date: Date
    public var method: String
    public var url: String
    public var statusCode: Int?
    public var durationMilliseconds: Double
    public var errorMessage: String?
    public var requestData: Data
    @Attribute(.externalStorage) public var responseData: Data?
    public var sourceNodeID: UUID?

    public var workspace: Workspace?

    public init(request: RequestSpec, resolvedURL: String, response: ResponseSnapshot?, errorMessage: String? = nil, sourceNodeID: UUID? = nil) {
        self.id = UUID()
        self.date = .now
        self.method = request.method.rawValue
        self.url = resolvedURL
        self.statusCode = response?.statusCode
        self.durationMilliseconds = response?.timings.total ?? 0
        self.errorMessage = errorMessage
        self.requestData = Codec.encode(request)
        self.responseData = response.map { Codec.encode($0) }
        self.sourceNodeID = sourceNodeID
    }

    public var request: RequestSpec { Codec.decode(RequestSpec.self, from: requestData, default: RequestSpec()) }
    public var response: ResponseSnapshot? {
        responseData.flatMap { try? JSONDecoder().decode(ResponseSnapshot.self, from: $0) }
    }
}

@Model
public final class CookieRecord {
    @Attribute(.unique) public var id: UUID
    public var domain: String
    public var path: String
    public var name: String
    public var value: String
    public var expiresAt: Date?
    public var isSecure: Bool
    public var isHTTPOnly: Bool
    public var sameSite: String?

    public init(id: UUID = UUID(), domain: String, path: String = "/", name: String, value: String, expiresAt: Date? = nil, isSecure: Bool = false, isHTTPOnly: Bool = false, sameSite: String? = nil) {
        self.id = id
        self.domain = domain
        self.path = path
        self.name = name
        self.value = value
        self.expiresAt = expiresAt
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
        self.sameSite = sameSite
    }
}
