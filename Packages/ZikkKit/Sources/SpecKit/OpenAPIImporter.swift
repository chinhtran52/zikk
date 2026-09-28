import Foundation
import APICore
import Interop

/// Converts an OpenAPI 3.x / Swagger 2.0 document into a collection (one folder per tag).
public enum OpenAPIImporter {
    public static let baseURLVariable = "baseUrl"

    public static func collection(from document: SpecDocument) -> InteropCollection {
        var folders: [String: InteropFolder] = [:]
        var folderOrder: [String] = []
        var rootItems: [InteropItem] = []
        for tag in document.root["tags"]?.items ?? [] {
            guard let name = tag["name"]?.string else { continue }
            folders[name] = InteropFolder(name: name, description: tag["description"]?.string ?? "")
            folderOrder.append(name)
        }
        let globalSecurity = document.root["security"]
        for operation in document.operations {
            let request = self.request(for: operation, in: document, globalSecurity: globalSecurity)
            if let tag = operation.tags.first {
                if folders[tag] == nil {
                    folders[tag] = InteropFolder(name: tag)
                    folderOrder.append(tag)
                }
                folders[tag]?.items.append(.request(request))
            } else {
                rootItems.append(.request(request))
            }
        }
        let items = folderOrder.compactMap { folders[$0] }.filter { !$0.items.isEmpty }.map(InteropItem.folder) + rootItems
        var description = document.description
        if !document.apiVersion.isEmpty { description = "Version \(document.apiVersion)" + (description.isEmpty ? "" : "\n\n" + description) }
        return InteropCollection(
            name: document.title,
            description: description,
            auth: auth(for: globalSecurity, in: document) ?? .none,
            variables: [Variable(key: baseURLVariable, value: document.baseURL)],
            items: items
        )
    }

    /// Request for one operation; the URL is `{{baseUrl}}` + path with `{param}` → `:param`.
    public static func request(for operation: SpecDocument.Operation, in document: SpecDocument, globalSecurity: SpecNode? = nil) -> InteropRequest {
        var spec = RequestSpec(method: HTTPMethod(rawValue: operation.method))
        let parameters = document.parameters(of: operation)
        var pathVariables: [KeyValue] = []
        var params: [KeyValue] = []
        var headers: [KeyValue] = []
        var formFields: [FormDataField] = []
        var urlEncoded: [KeyValue] = []
        var bodySchema: SpecNode?

        for parameter in parameters {
            let name = parameter["name"]?.string ?? ""
            let required = parameter["required"]?.bool ?? false
            let description = parameter["description"]?.string ?? ""
            let value = exampleString(for: parameter, in: document)
            switch parameter["in"]?.string {
            case "path":
                pathVariables.append(KeyValue(key: name, value: value, description: description))
            case "query":
                params.append(KeyValue(key: name, value: value, isEnabled: required, description: description))
            case "header":
                headers.append(KeyValue(key: name, value: value, isEnabled: required, description: description))
            case "formData":
                let isFile = parameter["type"]?.string == "file"
                formFields.append(FormDataField(key: name, kind: isFile ? .file : .text, value: isFile ? "" : value, isEnabled: required))
                urlEncoded.append(KeyValue(key: name, value: value, isEnabled: required, description: description))
            case "body":
                bodySchema = parameter["schema"]
            default:
                break
            }
        }

        let pathWithColons = operation.path.replacing(/\{([^}]+)\}/) { ":" + $0.output.1 }
        var url = "{{\(baseURLVariable)}}" + pathWithColons
        let enabledQuery = params.filter(\.isEnabled)
        if !enabledQuery.isEmpty { url = RawURL.replacingQuery(of: url, with: enabledQuery) }
        spec.url = url
        spec.params = params
        spec.pathVariables = pathVariables
        spec.headers = headers

        // Request body.
        if document.version == .swagger2 {
            let consumes = (operation.node["consumes"] ?? document.root["consumes"])?.items.compactMap(\.string) ?? []
            if let bodySchema {
                spec.body = RequestBody(mode: .raw, raw: SchemaExample.json(SchemaExample.generate(bodySchema, in: document)), rawLanguage: .json)
            } else if !formFields.isEmpty {
                spec.body = consumes.contains("multipart/form-data") || formFields.contains { $0.kind == .file }
                    ? RequestBody(mode: .formData, formData: formFields)
                    : RequestBody(mode: .urlEncoded, urlEncoded: urlEncoded)
            }
        } else if let requestBody = document.resolve(operation.node["requestBody"]), let content = requestBody["content"] {
            spec.body = body(from: content, in: document)
        }
        if spec.body.mode == .raw, !spec.headers.contains(where: { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }) {
            spec.headers.append(KeyValue(key: "Content-Type", value: "application/json"))
        }

        // Auth: operation-level `security` overrides the global one.
        if let security = operation.node["security"] {
            spec.auth = security.items.isEmpty ? .none : (auth(for: security, in: document) ?? .inherit)
        }

        // Examples from responses.
        let examples = (operation.node["responses"]?.entries ?? []).compactMap { entry -> InteropExample? in
            guard let response = document.resolve(entry.value) else { return nil }
            let status = Int(entry.key) ?? (entry.key == "default" ? 500 : Int(entry.key.prefix(1)).map { $0 * 100 } ?? 200)
            var headers: [KeyValue] = []
            var bodyText = ""
            if document.version == .swagger2 {
                if let example = response["examples"]?["application/json"] {
                    bodyText = SchemaExample.json(example.foundation)
                } else if let schema = response["schema"] {
                    bodyText = SchemaExample.json(SchemaExample.generate(schema, in: document))
                }
                if !bodyText.isEmpty { headers.append(KeyValue(key: "Content-Type", value: "application/json")) }
            } else if let (mediaType, media) = preferredMedia(response["content"]) {
                headers.append(KeyValue(key: "Content-Type", value: mediaType))
                if let example = SchemaExample.example(forMediaType: media, in: document) {
                    bodyText = example as? String ?? SchemaExample.json(example)
                }
            }
            let name = response["description"]?.string.map { "\(entry.key) \($0)" } ?? entry.key
            return InteropExample(name: name, request: spec, response: ResponseSnapshot(statusCode: status, headers: headers, body: Data(bodyText.utf8)))
        }

        var description = operation.node["description"]?.string ?? ""
        if operation.node["deprecated"]?.bool == true { description = "**Deprecated**\n\n" + description }
        return InteropRequest(name: operation.displayName, description: description, spec: spec, examples: examples)
    }

    static func preferredMedia(_ content: SpecNode?) -> (String, SpecNode)? {
        guard let content, let first = content.entries.first else { return nil }
        let json = content.entries.first { $0.key.contains("json") }
        let chosen = json ?? first
        return (chosen.key, chosen.value)
    }

    static func body(from content: SpecNode, in document: SpecDocument) -> RequestBody {
        let entries = content.entries
        if let json = entries.first(where: { $0.key.contains("json") }) {
            let example = SchemaExample.example(forMediaType: json.value, in: document) ?? [:]
            return RequestBody(mode: .raw, raw: example as? String ?? SchemaExample.json(example), rawLanguage: .json)
        }
        if let form = entries.first(where: { $0.key == "application/x-www-form-urlencoded" || $0.key == "multipart/form-data" }) {
            let schema = document.resolve(form.value["schema"])
            let required = Set(schema?["required"]?.items.compactMap(\.string) ?? [])
            let properties = schema?["properties"]?.entries ?? []
            if form.key == "multipart/form-data" {
                return RequestBody(mode: .formData, formData: properties.map { property in
                    let resolved = document.resolve(property.value)
                    let isFile = resolved?["format"]?.string == "binary" || resolved?["type"]?.string == "file"
                    let value = isFile ? "" : stringValue(SchemaExample.generate(property.value, in: document))
                    return FormDataField(key: property.key, kind: isFile ? .file : .text, value: value, isEnabled: required.isEmpty || required.contains(property.key),
                                         notes: resolved?["description"]?.string ?? "")
                })
            }
            return RequestBody(mode: .urlEncoded, urlEncoded: properties.map { property in
                KeyValue(key: property.key, value: stringValue(SchemaExample.generate(property.value, in: document)),
                         isEnabled: required.isEmpty || required.contains(property.key), description: document.resolve(property.value)?["description"]?.string ?? "")
            })
        }
        if let xml = entries.first(where: { $0.key.contains("xml") }) {
            return RequestBody(mode: .raw, raw: xml.value["example"]?.string ?? "", rawLanguage: .xml)
        }
        if let text = entries.first(where: { $0.key.hasPrefix("text/") }) {
            return RequestBody(mode: .raw, raw: text.value["example"]?.string ?? "", rawLanguage: .text)
        }
        if entries.contains(where: { $0.key == "application/octet-stream" }) {
            return RequestBody(mode: .binary)
        }
        return RequestBody()
    }

    static func exampleString(for parameter: SpecNode, in document: SpecDocument) -> String {
        if let example = parameter["example"] { return stringValue(example.foundation) }
        if let first = parameter["examples"]?.entries.first, let value = document.resolve(first.value)?["value"] { return stringValue(value.foundation) }
        if let schema = parameter["schema"] {
            let resolved = document.resolve(schema)
            if resolved?["example"] != nil || resolved?["default"] != nil || resolved?["enum"] != nil {
                return stringValue(SchemaExample.generate(schema, in: document))
            }
            return ""
        }
        // Swagger 2.0 parameters carry the schema inline.
        if let value = parameter["default"] ?? parameter["enum"]?.items.first { return stringValue(value.foundation) }
        return ""
    }

    static func stringValue(_ value: Any) -> String {
        switch value {
        case let string as String: string
        case is NSNull: ""
        case let number as NSNumber: CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
        default: SchemaExample.json(value).replacingOccurrences(of: "\n", with: "").replacing(/\s{2,}/, with: " ")
        }
    }

    /// Maps the first security requirement to an auth config.
    static func auth(for security: SpecNode?, in document: SpecDocument) -> AuthConfig? {
        guard let requirement = security?.items.first, let schemeName = requirement.entries.first?.key else { return nil }
        let schemes = document.root["components"]?["securitySchemes"] ?? document.root["securityDefinitions"]
        guard let scheme = document.resolve(schemes?[schemeName]) else { return nil }
        let scopes = requirement.entries.first?.value.items.compactMap(\.string).joined(separator: " ") ?? ""
        var auth = AuthConfig(type: .none)
        switch scheme["type"]?.string {
        case "http":
            switch scheme["scheme"]?.string?.lowercased() {
            case "basic": auth.type = .basic; auth.basic = BasicAuth(username: "{{username}}", password: "{{password}}")
            case "bearer": auth.type = .bearer; auth.bearer = BearerAuth(token: "{{bearerToken}}")
            case "digest": auth.type = .digest; auth.digest = DigestAuth(username: "{{username}}", password: "{{password}}")
            default: return nil
            }
        case "basic":
            auth.type = .basic
            auth.basic = BasicAuth(username: "{{username}}", password: "{{password}}")
        case "apiKey":
            auth.type = .apiKey
            auth.apiKey = APIKeyAuth(key: scheme["name"]?.string ?? "", value: "{{apiKey}}", location: scheme["in"]?.string == "query" ? .query : .header)
        case "oauth2", "openIdConnect":
            auth.type = .oauth2
            auth.oauth2.scope = scopes
            auth.oauth2.clientID = "{{clientId}}"
            auth.oauth2.clientSecret = "{{clientSecret}}"
            if let flows = scheme["flows"] {
                if let flow = flows["authorizationCode"] {
                    auth.oauth2.grantType = .authorizationCodePKCE
                    auth.oauth2.authURL = flow["authorizationUrl"]?.string ?? ""
                    auth.oauth2.accessTokenURL = flow["tokenUrl"]?.string ?? ""
                } else if let flow = flows["clientCredentials"] {
                    auth.oauth2.grantType = .clientCredentials
                    auth.oauth2.accessTokenURL = flow["tokenUrl"]?.string ?? ""
                } else if let flow = flows["password"] {
                    auth.oauth2.grantType = .password
                    auth.oauth2.accessTokenURL = flow["tokenUrl"]?.string ?? ""
                }
            } else {
                // Swagger 2.0
                switch scheme["flow"]?.string {
                case "application": auth.oauth2.grantType = .clientCredentials
                case "password": auth.oauth2.grantType = .password
                default: auth.oauth2.grantType = .authorizationCodePKCE
                }
                auth.oauth2.authURL = scheme["authorizationUrl"]?.string ?? ""
                auth.oauth2.accessTokenURL = scheme["tokenUrl"]?.string ?? ""
            }
        default:
            return nil
        }
        return auth
    }
}
