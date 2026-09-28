import Foundation

public enum BodyMode: String, Codable, CaseIterable, Sendable {
    case none, raw, formData, urlEncoded, binary, graphQL
}

public enum RawLanguage: String, Codable, CaseIterable, Sendable {
    case text, json, xml, html, javascript

    public var contentType: String {
        switch self {
        case .text: "text/plain"
        case .json: "application/json"
        case .xml: "application/xml"
        case .html: "text/html"
        case .javascript: "application/javascript"
        }
    }
}

/// Reference to a user-selected file. The bookmark keeps sandbox access across launches.
public struct FileReference: Codable, Hashable, Sendable {
    public var path: String
    public var bookmark: Data?

    public init(path: String, bookmark: Data? = nil) {
        self.path = path
        self.bookmark = bookmark
    }

    public var fileName: String { (path as NSString).lastPathComponent }
}

public struct FormDataField: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case text, file }

    public var id: UUID
    public var key: String
    public var kind: Kind
    public var value: String
    public var file: FileReference?
    public var contentType: String
    public var isEnabled: Bool

    public init(id: UUID = UUID(), key: String = "", kind: Kind = .text, value: String = "", file: FileReference? = nil, contentType: String = "", isEnabled: Bool = true) {
        self.id = id
        self.key = key
        self.kind = kind
        self.value = value
        self.file = file
        self.contentType = contentType
        self.isEnabled = isEnabled
    }
}

public struct GraphQLBody: Codable, Hashable, Sendable {
    public var query: String
    public var variables: String
    public var operationName: String

    public init(query: String = "", variables: String = "", operationName: String = "") {
        self.query = query
        self.variables = variables
        self.operationName = operationName
    }
}

/// Request body. Every mode keeps its own content so switching modes does not lose data (like Postman).
public struct RequestBody: Codable, Hashable, Sendable {
    public var mode: BodyMode
    public var raw: String
    public var rawLanguage: RawLanguage
    public var formData: [FormDataField]
    public var urlEncoded: [KeyValue]
    public var binary: FileReference?
    public var graphQL: GraphQLBody

    public init(mode: BodyMode = .none, raw: String = "", rawLanguage: RawLanguage = .json, formData: [FormDataField] = [], urlEncoded: [KeyValue] = [], binary: FileReference? = nil, graphQL: GraphQLBody = GraphQLBody()) {
        self.mode = mode
        self.raw = raw
        self.rawLanguage = rawLanguage
        self.formData = formData
        self.urlEncoded = urlEncoded
        self.binary = binary
        self.graphQL = graphQL
    }
}
