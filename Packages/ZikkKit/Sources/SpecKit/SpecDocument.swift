import Foundation

public enum SpecVersion: String, Sendable {
    case swagger2 = "2.0"
    case openAPI30 = "3.0"
    case openAPI31 = "3.1"
}

/// A parsed API description with `$ref` resolution helpers.
public struct SpecDocument: Sendable {
    public let root: SpecNode
    public let version: SpecVersion?

    public init(root: SpecNode) {
        self.root = root
        if let swagger = root["swagger"]?.string, swagger.hasPrefix("2") {
            version = .swagger2
        } else if let openapi = root["openapi"]?.string {
            version = openapi.hasPrefix("3.1") || openapi.hasPrefix("3.2") ? .openAPI31 : (openapi.hasPrefix("3.") ? .openAPI30 : nil)
        } else {
            version = nil
        }
    }

    public init(text: String) throws {
        self.init(root: try SpecParser.parse(text))
    }

    public var title: String { root["info"]?["title"]?.string ?? "API" }
    public var apiVersion: String { root["info"]?["version"]?.string ?? "" }
    public var description: String { root["info"]?["description"]?.string ?? "" }

    /// Follows a local JSON pointer such as `#/components/schemas/Pet`.
    public func node(at reference: String) -> SpecNode? {
        guard reference.hasPrefix("#") else { return nil }
        var current: SpecNode? = root
        for raw in reference.dropFirst().split(separator: "/", omittingEmptySubsequences: true) {
            let token = raw.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~").removingPercentEncoding ?? String(raw)
            if let index = Int(token), let items = current?.items, !items.isEmpty {
                current = index < items.count ? items[index] : nil
            } else {
                current = current?[token]
            }
            if current == nil { return nil }
        }
        return current
    }

    /// Resolves `$ref` chains (local only), returning the target node.
    public func resolve(_ node: SpecNode?) -> SpecNode? {
        var current = node
        var seen: Set<String> = []
        while let reference = current?["$ref"]?.string {
            guard seen.insert(reference).inserted else { return nil }
            current = self.node(at: reference)
        }
        return current
    }

    public static let httpMethods = ["get", "put", "post", "delete", "options", "head", "patch", "trace"]

    public struct Operation: Sendable {
        public var method: String
        public var path: String
        public var node: SpecNode
        public var pathItem: SpecNode
        public var line: Int

        public var operationID: String? { node["operationId"]?.string }
        public var summary: String? { node["summary"]?.string }
        public var tags: [String] { node["tags"]?.items.compactMap(\.string) ?? [] }
        public var displayName: String { summary ?? operationID ?? "\(method.uppercased()) \(path)" }
    }

    public var operations: [Operation] {
        guard let paths = root["paths"] else { return [] }
        return paths.entries.flatMap { pathEntry -> [Operation] in
            let item = resolve(pathEntry.value) ?? pathEntry.value
            return item.entries.filter { Self.httpMethods.contains($0.key.lowercased()) }.map {
                Operation(method: $0.key.lowercased(), path: pathEntry.key, node: $0.value, pathItem: item, line: $0.keyLine)
            }
        }
    }

    /// Parameters of an operation, merging path-level ones (operation wins on name+location).
    public func parameters(of operation: Operation) -> [SpecNode] {
        var result: [SpecNode] = []
        var seen: Set<String> = []
        for raw in (operation.node["parameters"]?.items ?? []) + (operation.pathItem["parameters"]?.items ?? []) {
            guard let parameter = resolve(raw) else { continue }
            let key = "\(parameter["in"]?.string ?? "")/\(parameter["name"]?.string ?? "")"
            if seen.insert(key).inserted { result.append(parameter) }
        }
        return result
    }

    /// Base URL from `servers` (3.x, with variable defaults) or `schemes/host/basePath` (2.0).
    public var baseURL: String {
        if version == .swagger2 {
            let scheme = root["schemes"]?.items.first?.string ?? "https"
            let host = root["host"]?.string ?? "localhost"
            return "\(scheme)://\(host)\(root["basePath"]?.string ?? "")"
        }
        guard let server = root["servers"]?.items.first, var url = server["url"]?.string else { return "" }
        for variable in server["variables"]?.entries ?? [] {
            url = url.replacingOccurrences(of: "{\(variable.key)}", with: variable.value["default"]?.string ?? "")
        }
        return url.hasSuffix("/") ? String(url.dropLast()) : url
    }
}
