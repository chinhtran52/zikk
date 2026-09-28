import Foundation
import Yams
import APICore
import Interop

/// Generates an OpenAPI 3.0.3 YAML document from a collection.
public enum OpenAPIExporter {
    public static func yaml(from collection: InteropCollection) -> String {
        let baseURL = collection.variables.first { $0.key == OpenAPIImporter.baseURLVariable }?.value
            ?? collection.allRequests.first.flatMap { host(of: $0.spec.url) }
        var root: [(String, Node)] = [
            ("openapi", "3.0.3"),
            ("info", mapping([
                ("title", Node(collection.name)),
                ("version", "1.0.0"),
            ] + (collection.description.isEmpty ? [] : [("description", Node(collection.description, .implicit, .literal))]))),
        ]
        if let baseURL, !baseURL.isEmpty { root.append(("servers", Node([mapping([("url", Node(baseURL))])]))) }

        // Paths keep first-seen order; operations are grouped under their path.
        var pathOrder: [String] = []
        var operations: [String: [(String, Node)]] = [:]
        var tags: [String] = []
        func visit(_ items: [InteropItem], tag: String?) {
            for item in items {
                switch item {
                case .folder(let folder):
                    let folderTag = tag ?? folder.name
                    if tag == nil, !tags.contains(folder.name) { tags.append(folder.name) }
                    visit(folder.items, tag: folderTag)
                case .request(let request):
                    let path = openAPIPath(request.spec.url)
                    if operations[path] == nil { pathOrder.append(path); operations[path] = [] }
                    let method = request.spec.method.rawValue.lowercased()
                    guard !(operations[path]?.contains { $0.0 == method } ?? false) else { continue }
                    operations[path]?.append((method, operation(request, tag: tag, collectionAuth: collection.auth)))
                }
            }
        }
        visit(collection.items, tag: nil)
        if !tags.isEmpty { root.append(("tags", Node(tags.map { mapping([("name", Node($0))]) }))) }
        root.append(("paths", mapping(pathOrder.map { ($0, mapping(operations[$0] ?? [])) })))

        if let scheme = securityScheme(collection.auth) {
            root.append(("components", mapping([("securitySchemes", mapping([(scheme.name, scheme.node)]))])))
            root.append(("security", Node([mapping([(scheme.name, Node([Node]()))])])))
        }
        return (try? Yams.serialize(node: mapping(root), width: -1, allowUnicode: true)) ?? ""
    }

    static func mapping(_ pairs: [(String, Node)]) -> Node {
        Node(pairs.map { (Node($0.0), $0.1) })
    }

    static func host(of url: String) -> String? {
        guard let components = URLComponents(string: url), let scheme = components.scheme, let host = components.host else { return nil }
        return "\(scheme)://\(host)" + (components.port.map { ":\($0)" } ?? "")
    }

    /// `{{baseUrl}}/pets/:id?x=1` → `/pets/{id}`.
    public static func openAPIPath(_ url: String) -> String {
        var base = RawURL.split(url).base
        if base.hasPrefix("{{"), let end = base.range(of: "}}") {
            base = String(base[end.upperBound...])
        } else if let scheme = base.range(of: "://") {
            let rest = base[scheme.upperBound...]
            base = rest.firstIndex(of: "/").map { String(rest[$0...]) } ?? "/"
        }
        if !base.hasPrefix("/") { base = "/" + base }
        return base.split(separator: "/", omittingEmptySubsequences: false).map { segment in
            segment.hasPrefix(":") ? "{\(segment.dropFirst())}" : String(segment)
        }.joined(separator: "/")
    }

    static func operation(_ request: InteropRequest, tag: String?, collectionAuth: AuthConfig) -> Node {
        let spec = request.spec
        var pairs: [(String, Node)] = []
        if let tag { pairs.append(("tags", Node([Node(tag)]))) }
        pairs.append(("summary", Node(request.name)))
        pairs.append(("operationId", Node(operationID(request.name))))
        if !request.description.isEmpty { pairs.append(("description", Node(request.description, .implicit, .literal))) }

        var parameters: [Node] = []
        for variable in spec.pathVariables {
            parameters.append(mapping([("name", Node(variable.key)), ("in", "path"), ("required", Node("true", .implicit)),
                                       ("schema", mapping([("type", "string")]))] + example(variable.value) + describe(variable.description)))
        }
        for param in spec.params where !param.key.isEmpty {
            parameters.append(mapping([("name", Node(param.key)), ("in", "query"), ("required", Node(param.isEnabled ? "true" : "false", .implicit)),
                                       ("schema", mapping([("type", "string")]))] + example(param.value) + describe(param.description)))
        }
        let skipped: Set<String> = ["content-type", "authorization", "accept", "user-agent", "content-length", "host"]
        for header in spec.headers where !header.key.isEmpty && !skipped.contains(header.key.lowercased()) {
            parameters.append(mapping([("name", Node(header.key)), ("in", "header"), ("required", Node(header.isEnabled ? "true" : "false", .implicit)),
                                       ("schema", mapping([("type", "string")]))] + example(header.value) + describe(header.description)))
        }
        if !parameters.isEmpty { pairs.append(("parameters", Node(parameters))) }
        if let body = requestBody(spec.body) { pairs.append(("requestBody", body)) }

        var responses: [(String, Node)] = []
        for example in request.examples {
            let code = String(example.response.statusCode)
            guard !responses.contains(where: { $0.0 == code }) else { continue }
            var response: [(String, Node)] = [("description", Node(example.name))]
            if let text = example.response.bodyText, !text.isEmpty {
                let type = example.response.contentType?.split(separator: ";").first.map(String.init) ?? "application/json"
                if let json = try? JSONSerialization.jsonObject(with: example.response.body, options: [.fragmentsAllowed]) {
                    response.append(("content", mapping([(type, mapping([("schema", schema(for: json)), ("example", node(from: json))]))])))
                } else {
                    response.append(("content", mapping([(type, mapping([("schema", mapping([("type", "string")])), ("example", Node(text))]))])))
                }
            }
            responses.append((code, mapping(response)))
        }
        if responses.isEmpty { responses = [("200", mapping([("description", "Successful response")]))] }
        pairs.append(("responses", mapping(responses)))

        switch spec.auth.type {
        case .none: pairs.append(("security", Node([Node]())))
        case .inherit: break
        default:
            if let scheme = securityScheme(spec.auth), spec.auth.type != collectionAuth.type {
                pairs.append(("security", Node([mapping([(scheme.name, Node([Node]()))])])))
            }
        }
        return mapping(pairs)
    }

    static func example(_ value: String) -> [(String, Node)] {
        value.isEmpty || value.contains("{{") ? [] : [("example", Node(value, .implicit, .doubleQuoted))]
    }

    static func describe(_ text: String) -> [(String, Node)] {
        text.isEmpty ? [] : [("description", Node(text))]
    }

    static func operationID(_ name: String) -> String {
        let words = name.split { !$0.isLetter && !$0.isNumber }
        guard let first = words.first else { return "operation" }
        return first.lowercased() + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined()
    }

    static func requestBody(_ body: RequestBody) -> Node? {
        switch body.mode {
        case .raw:
            if body.rawLanguage == .json, let json = try? JSONSerialization.jsonObject(with: Data(body.raw.utf8), options: [.fragmentsAllowed]) {
                return mapping([("content", mapping([("application/json", mapping([("schema", schema(for: json)), ("example", node(from: json))]))]))])
            }
            return mapping([("content", mapping([(body.rawLanguage.contentType, mapping([("schema", mapping([("type", "string")]))]))]))])
        case .urlEncoded:
            let properties = body.urlEncoded.filter { !$0.key.isEmpty }.map { ($0.key, mapping([("type", "string")] + example($0.value))) }
            return mapping([("content", mapping([("application/x-www-form-urlencoded", mapping([("schema", mapping([("type", "object"), ("properties", mapping(properties))]))]))]))])
        case .formData:
            let properties = body.formData.filter { !$0.key.isEmpty }.map { field in
                let notes: [(String, Node)] = field.notes.isEmpty ? [] : [("description", Node(field.notes))]
                return (field.key, field.kind == .file ? mapping([("type", "string"), ("format", "binary")] + notes) : mapping([("type", "string")] + notes + example(field.value)))
            }
            return mapping([("content", mapping([("multipart/form-data", mapping([("schema", mapping([("type", "object"), ("properties", mapping(properties))]))]))]))])
        case .binary:
            return mapping([("content", mapping([("application/octet-stream", mapping([("schema", mapping([("type", "string"), ("format", "binary")]))]))]))])
        case .graphQL:
            return mapping([("content", mapping([("application/json", mapping([("schema", mapping([("type", "object")]))]))]))])
        case .none:
            return nil
        }
    }

    /// Infers a schema from an example value.
    static func schema(for value: Any) -> Node {
        switch value {
        case let object as [String: Any]:
            return mapping([("type", "object"), ("properties", mapping(object.keys.sorted().map { ($0, schema(for: object[$0]!)) }))])
        case let array as [Any]:
            return mapping([("type", "array"), ("items", array.first.map(schema(for:)) ?? mapping([]))])
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return mapping([("type", "boolean")]) }
            return mapping([("type", Node(CFNumberIsFloatType(number) ? "number" : "integer"))])
        case is NSNull:
            return mapping([("nullable", Node("true", .implicit))])
        default:
            return mapping([("type", "string")])
        }
    }

    static func node(from value: Any) -> Node {
        switch value {
        case let object as [String: Any]: return mapping(object.keys.sorted().map { ($0, node(from: object[$0]!)) })
        case let array as [Any]: return Node(array.map(node(from:)))
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return Node(number.boolValue ? "true" : "false", .implicit) }
            return Node(number.stringValue, .implicit)
        case is NSNull: return Node("null", .implicit)
        case let string as String: return Node(string, .implicit, .doubleQuoted)
        default: return Node("\(value)")
        }
    }

    static func securityScheme(_ auth: AuthConfig) -> (name: String, node: Node)? {
        switch auth.type {
        case .basic: return ("basicAuth", mapping([("type", "http"), ("scheme", "basic")]))
        case .bearer: return ("bearerAuth", mapping([("type", "http"), ("scheme", "bearer")]))
        case .digest: return ("digestAuth", mapping([("type", "http"), ("scheme", "digest")]))
        case .apiKey:
            return ("apiKeyAuth", mapping([("type", "apiKey"), ("name", Node(auth.apiKey.key)), ("in", Node(auth.apiKey.location.rawValue))]))
        case .oauth2:
            let flow: (String, [(String, Node)]) = switch auth.oauth2.grantType {
            case .clientCredentials: ("clientCredentials", [("tokenUrl", Node(auth.oauth2.accessTokenURL))])
            case .password: ("password", [("tokenUrl", Node(auth.oauth2.accessTokenURL))])
            case .authorizationCode, .authorizationCodePKCE:
                ("authorizationCode", [("authorizationUrl", Node(auth.oauth2.authURL)), ("tokenUrl", Node(auth.oauth2.accessTokenURL))])
            }
            let scopes = auth.oauth2.scope.split(separator: " ").map { (String($0), Node("")) }
            return ("oauth2", mapping([("type", "oauth2"), ("flows", mapping([(flow.0, mapping(flow.1 + [("scopes", mapping(scopes))]))]))]))
        default:
            return nil
        }
    }
}
