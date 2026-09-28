import Foundation

public struct SpecDiagnostic: Hashable, Sendable, Identifiable {
    public enum Severity: String, Sendable { case error, warning }
    public var id: String { "\(line):\(severity):\(message)" }
    public var severity: Severity
    public var message: String
    public var line: Int

    public init(_ severity: Severity, _ message: String, line: Int) {
        self.severity = severity
        self.message = message
        self.line = line
    }
}

/// Structural validation of Swagger 2.0 / OpenAPI 3.x documents with source lines.
public enum SpecValidator {
    public static func validate(_ text: String) -> [SpecDiagnostic] {
        do {
            return validate(try SpecDocument(text: text))
        } catch let error as SpecSyntaxError {
            return [SpecDiagnostic(.error, "Syntax error: \(error.message)", line: error.line)]
        } catch {
            return [SpecDiagnostic(.error, error.localizedDescription, line: 1)]
        }
    }

    public static func validate(_ document: SpecDocument) -> [SpecDiagnostic] {
        var diagnostics: [SpecDiagnostic] = []
        func error(_ message: String, _ line: Int) { diagnostics.append(SpecDiagnostic(.error, message, line: line)) }
        func warning(_ message: String, _ line: Int) { diagnostics.append(SpecDiagnostic(.warning, message, line: line)) }
        let root = document.root

        guard root.isObject else {
            error("The document must be a mapping with `openapi` or `swagger` at the top level.", max(root.line, 1))
            return diagnostics
        }
        guard let version = document.version else {
            if let value = root["openapi"] ?? root["swagger"] {
                error("Unsupported version `\(value.string ?? "")`. Supported: Swagger 2.0, OpenAPI 3.0 and 3.1.", value.line)
            } else {
                error("Missing `openapi` (3.x) or `swagger` (2.0) version field.", 1)
            }
            return diagnostics
        }

        // info
        if let info = root["info"] {
            if info["title"]?.string == nil { error("`info.title` is required.", root.line(of: "info")) }
            if info["version"]?.string == nil { error("`info.version` is required.", root.line(of: "info")) }
        } else {
            error("`info` object is required.", 1)
        }

        // servers
        for server in root["servers"]?.items ?? [] where server["url"]?.string == nil {
            error("Server object requires a `url`.", server.line)
        }

        // paths
        let paths = root["paths"]
        if paths == nil && version != .openAPI31 {
            error("`paths` object is required.", 1)
        }
        let validLocations = version == .swagger2 ? ["query", "header", "path", "formData", "body"] : ["query", "header", "path", "cookie"]
        var operationIDs: [String: Int] = [:]
        for pathEntry in paths?.entries ?? [] {
            if !pathEntry.key.hasPrefix("/") {
                error("Path `\(pathEntry.key)` must begin with `/`.", pathEntry.keyLine)
            }
            let item = document.resolve(pathEntry.value) ?? pathEntry.value
            let templateNames = Set(pathEntry.key.matches(of: /\{([^}]+)\}/).map { String($0.output.1) })
            for entry in item.entries where !SpecDocument.httpMethods.contains(entry.key.lowercased())
                && !["parameters", "summary", "description", "servers", "$ref"].contains(entry.key) && !entry.key.hasPrefix("x-") {
                warning("Unknown field `\(entry.key)` in path item.", entry.keyLine)
            }
            for operation in document.operations where operation.path == pathEntry.key {
                let node = operation.node
                if let id = operation.operationID {
                    if let first = operationIDs[id] {
                        error("Duplicate operationId `\(id)` (first used on line \(first)).", node.line(of: "operationId"))
                    } else {
                        operationIDs[id] = node.line(of: "operationId")
                    }
                }
                let responses = node["responses"]
                if responses == nil || responses?.entries.isEmpty == true {
                    if version != .openAPI31 { error("Operation `\(operation.method.uppercased()) \(operation.path)` must define `responses`.", operation.line) }
                }
                for response in responses?.entries ?? [] where !isValidStatus(response.key) {
                    error("Invalid response status `\(response.key)`.", response.keyLine)
                }
                var declaredPathParameters: Set<String> = []
                for parameter in document.parameters(of: operation) {
                    let name = parameter["name"]?.string
                    let location = parameter["in"]?.string
                    if name == nil { error("Parameter is missing `name`.", parameter.line) }
                    if let location, !validLocations.contains(location) {
                        error("Invalid parameter location `\(location)`.", parameter.line(of: "in"))
                    } else if location == nil {
                        error("Parameter `\(name ?? "")` is missing `in`.", parameter.line)
                    }
                    if location == "path", let name {
                        declaredPathParameters.insert(name)
                        if parameter["required"]?.bool != true {
                            error("Path parameter `\(name)` must have `required: true`.", parameter.line)
                        }
                        if !templateNames.contains(name) {
                            error("Path parameter `\(name)` does not appear in path `\(operation.path)`.", parameter.line)
                        }
                    }
                }
                for name in templateNames.subtracting(declaredPathParameters).sorted() {
                    error("Path template parameter `{\(name)}` is not declared in `\(operation.method.uppercased()) \(operation.path)`.", operation.line)
                }
            }
        }

        // References
        func visit(_ node: SpecNode) {
            if let reference = node["$ref"]?.string {
                if !reference.hasPrefix("#") {
                    warning("External reference `\(reference)` is not resolved.", node.line(of: "$ref"))
                } else if document.node(at: reference) == nil {
                    error("Reference `\(reference)` cannot be resolved.", node.line(of: "$ref"))
                }
            }
            for entry in node.entries { visit(entry.value) }
            for item in node.items { visit(item) }
        }
        visit(root)

        // Schema types
        let validTypes: Set<String> = ["string", "number", "integer", "boolean", "array", "object", "null", "file"]
        func checkSchemas(_ node: SpecNode) {
            if let type = node["type"] {
                let names = type.string.map { [$0] } ?? type.items.compactMap(\.string)
                for name in names where !validTypes.contains(name) {
                    // `type` might be a property called "type" inside `properties`.
                    if type.string != nil || type.isArray { warning("Unknown schema type `\(name)`.", type.line) }
                }
            }
            for entry in node.entries where entry.key != "properties" && entry.key != "example" && entry.key != "examples" { checkSchemas(entry.value) }
            for property in node["properties"]?.entries ?? [] { checkSchemas(property.value) }
            for item in node.items { checkSchemas(item) }
        }
        checkSchemas(root)

        return diagnostics.sorted { $0.line < $1.line }
    }

    static func isValidStatus(_ code: String) -> Bool {
        code == "default" || code.wholeMatch(of: /[1-5]([0-9]{2}|XX)/) != nil
    }
}

/// Navigable structure of a document for the editor sidebar.
public struct SpecOutline: Sendable {
    public struct Item: Hashable, Sendable, Identifiable {
        public var id: String { "\(line):\(title)" }
        public var title: String
        public var detail: String?
        public var line: Int
        public var children: [Item]?
    }

    public var items: [Item]

    public init(_ document: SpecDocument) {
        var items: [Item] = []
        let root = document.root
        if root["info"] != nil {
            items.append(Item(title: "Info", detail: document.title, line: root.line(of: "info"), children: nil))
        }
        if let servers = root["servers"], !servers.items.isEmpty {
            items.append(Item(title: "Servers", detail: nil, line: root.line(of: "servers"),
                              children: servers.items.map { Item(title: $0["url"]?.string ?? "", detail: nil, line: $0.line, children: nil) }))
        }
        if let paths = root["paths"] {
            let children = paths.entries.map { entry in
                Item(title: entry.key, detail: nil, line: entry.keyLine, children: document.operations.filter { $0.path == entry.key }.map {
                    Item(title: $0.method.uppercased(), detail: $0.summary ?? $0.operationID, line: $0.line, children: nil)
                })
            }
            items.append(Item(title: "Paths", detail: "\(paths.entries.count)", line: root.line(of: "paths"), children: children))
        }
        let schemas = root["components"]?["schemas"] ?? root["definitions"]
        if let schemas {
            items.append(Item(title: "Schemas", detail: "\(schemas.entries.count)", line: schemas.line,
                              children: schemas.entries.map { Item(title: $0.key, detail: nil, line: $0.keyLine, children: nil) }))
        }
        if let tags = root["tags"], !tags.items.isEmpty {
            items.append(Item(title: "Tags", detail: nil, line: root.line(of: "tags"),
                              children: tags.items.map { Item(title: $0["name"]?.string ?? "", detail: nil, line: $0.line, children: nil) }))
        }
        self.items = items
    }
}
