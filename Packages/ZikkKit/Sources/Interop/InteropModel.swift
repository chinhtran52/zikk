import Foundation
import APICore

/// Storage-independent collection tree used by importers and exporters.
public struct InteropCollection: Hashable, Sendable {
    public var name: String
    public var description: String
    public var auth: AuthConfig
    public var preRequestScript: String
    public var testScript: String
    public var variables: [Variable]
    public var items: [InteropItem]

    public init(name: String, description: String = "", auth: AuthConfig = .none, preRequestScript: String = "", testScript: String = "", variables: [Variable] = [], items: [InteropItem] = []) {
        self.name = name
        self.description = description
        self.auth = auth
        self.preRequestScript = preRequestScript
        self.testScript = testScript
        self.variables = variables
        self.items = items
    }

    /// All requests in depth-first order.
    public var allRequests: [InteropRequest] {
        func collect(_ items: [InteropItem]) -> [InteropRequest] {
            items.flatMap { item -> [InteropRequest] in
                switch item {
                case .folder(let folder): collect(folder.items)
                case .request(let request): [request]
                }
            }
        }
        return collect(items)
    }
}

public indirect enum InteropItem: Hashable, Sendable {
    case folder(InteropFolder)
    case request(InteropRequest)

    public var name: String {
        switch self {
        case .folder(let folder): folder.name
        case .request(let request): request.name
        }
    }
}

public struct InteropFolder: Hashable, Sendable {
    public var name: String
    public var description: String
    public var auth: AuthConfig
    public var preRequestScript: String
    public var testScript: String
    public var items: [InteropItem]

    public init(name: String, description: String = "", auth: AuthConfig = .inherit, preRequestScript: String = "", testScript: String = "", items: [InteropItem] = []) {
        self.name = name
        self.description = description
        self.auth = auth
        self.preRequestScript = preRequestScript
        self.testScript = testScript
        self.items = items
    }
}

public struct InteropRequest: Hashable, Sendable {
    public var name: String
    public var description: String
    public var spec: RequestSpec
    public var examples: [InteropExample]

    public init(name: String, description: String = "", spec: RequestSpec, examples: [InteropExample] = []) {
        self.name = name
        self.description = description
        self.spec = spec
        self.examples = examples
    }
}

public struct InteropExample: Hashable, Sendable {
    public var name: String
    public var request: RequestSpec
    public var response: ResponseSnapshot

    public init(name: String, request: RequestSpec, response: ResponseSnapshot) {
        self.name = name
        self.request = request
        self.response = response
    }
}

public struct InteropEnvironment: Hashable, Sendable {
    public var name: String
    public var variables: [Variable]

    public init(name: String, variables: [Variable]) {
        self.name = name
        self.variables = variables
    }
}

public enum InteropError: LocalizedError, Equatable {
    case invalidJSON
    case unsupportedFormat(String)
    case invalidCurl(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON: "The file is not valid JSON."
        case .unsupportedFormat(let detail): "Unsupported format: \(detail)"
        case .invalidCurl(let detail): "Could not parse cURL command: \(detail)"
        }
    }
}
