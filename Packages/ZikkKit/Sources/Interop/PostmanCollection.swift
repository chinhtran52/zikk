import Foundation
import APICore

/// Postman Collection Format v2.0 / v2.1 import and v2.1 export.
public enum PostmanCollection {
    public static let schemaV21 = "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"

    /// Whether the JSON looks like a Postman collection.
    public static func detect(_ object: [String: Any]) -> Bool {
        guard let info = object["info"] as? [String: Any] else { return false }
        return (info["schema"] as? String)?.contains("schema.getpostman.com") == true || object["item"] != nil
    }

    public static func decode(_ data: Data) throws -> InteropCollection {
        let root = try JSONCoding.object(from: data)
        guard detect(root) else { throw InteropError.unsupportedFormat("not a Postman collection") }
        let info = root.object("info") ?? [:]
        let (pre, test) = scripts(root.array("event"))
        return InteropCollection(
            name: info.string("name") ?? "Imported Collection",
            description: description(info["description"]),
            auth: auth(root.object("auth"), default: .none),
            preRequestScript: pre,
            testScript: test,
            variables: root.array("variable").map(variable),
            items: root.array("item").map(item)
        )
    }

    // MARK: Decoding

    static func item(_ object: JSONObject) -> InteropItem {
        let name = object.string("name") ?? "Untitled"
        let (pre, test) = scripts(object.array("event"))
        if object["item"] != nil || object["request"] == nil {
            return .folder(InteropFolder(name: name, description: description(object["description"]), auth: auth(object.object("auth"), default: .inherit),
                                         preRequestScript: pre, testScript: test, items: object.array("item").map(item)))
        }
        var spec = request(object["request"])
        spec.preRequestScript = pre
        spec.testScript = test
        let examples = object.array("response").map { example($0, fallbackRequest: spec) }
        let requestDescription = (object["request"] as? JSONObject).map { description($0["description"]) } ?? ""
        return .request(InteropRequest(name: name, description: requestDescription, spec: spec, examples: examples))
    }

    static func request(_ value: Any?) -> RequestSpec {
        // A request may be a bare URL string.
        if let url = value as? String { return RequestSpec(url: url, params: RawURL.queryParams(of: url)) }
        guard let object = value as? JSONObject else { return RequestSpec() }
        var spec = RequestSpec()
        spec.method = HTTPMethod(rawValue: object.string("method") ?? "GET")
        let (url, params, pathVariables) = self.url(object["url"])
        spec.url = url
        spec.params = params
        spec.pathVariables = pathVariables
        spec.headers = keyValues(object["header"])
        spec.body = body(object.object("body"))
        spec.auth = auth(object.object("auth"), default: .inherit)
        if spec.body.mode == .graphQL { spec.kind = .graphQL }
        return spec
    }

    static func url(_ value: Any?) -> (String, [KeyValue], [KeyValue]) {
        if let raw = value as? String { return (raw, RawURL.queryParams(of: raw), []) }
        guard let object = value as? JSONObject else { return ("", [], []) }
        var raw = object.string("raw") ?? ""
        if raw.isEmpty {
            var built = ""
            if let proto = object.string("protocol") { built += proto + "://" }
            if let host = object["host"] as? [String] { built += host.joined(separator: ".") } else if let host = object.string("host") { built += host }
            if let port = object.string("port") { built += ":" + port }
            if let path = object["path"] as? [String] { built += "/" + path.joined(separator: "/") } else if let path = object.string("path") { built += path.hasPrefix("/") ? path : "/" + path }
            raw = built
        }
        let query = object.array("query").map { item in
            KeyValue(key: item.string("key") ?? "", value: item.string("value") ?? "", isEnabled: !(item.bool("disabled") ?? false), description: description(item["description"]))
        }
        // `raw` only carries enabled params; `query` also lists disabled ones.
        let params = query.isEmpty ? RawURL.queryParams(of: raw) : query
        if !query.isEmpty { raw = RawURL.replacingQuery(of: raw, with: params) }
        let variables = object.array("variable").map { KeyValue(key: $0.string("key") ?? "", value: $0.string("value") ?? "", description: description($0["description"])) }
        let pathVariables = RawURL.syncPathVariables(url: raw, existing: variables)
        return (raw, params, pathVariables)
    }

    static func keyValues(_ value: Any?) -> [KeyValue] {
        if let text = value as? String {
            // Legacy "Key: Value\n" header strings.
            return text.split(separator: "\n").compactMap { line in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return KeyValue(key: parts[0].trimmingCharacters(in: .whitespaces), value: parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return ((value as? [Any]) ?? []).compactMap { $0 as? JSONObject }.map { item in
            KeyValue(key: item.string("key") ?? "", value: item.string("value") ?? "", isEnabled: !(item.bool("disabled") ?? false), description: description(item["description"]))
        }
    }

    static func body(_ object: JSONObject?) -> RequestBody {
        guard let object, let mode = object.string("mode") else { return RequestBody() }
        var body = RequestBody()
        switch mode {
        case "raw":
            body.mode = .raw
            body.raw = object.string("raw") ?? ""
            let language = object.object("options")?.object("raw")?.string("language") ?? ""
            body.rawLanguage = RawLanguage(rawValue: language) ?? (language.isEmpty ? .text : .text)
            if language.isEmpty, body.raw.trimmingCharacters(in: .whitespaces).hasPrefix("{") { body.rawLanguage = .json }
        case "urlencoded":
            body.mode = .urlEncoded
            body.urlEncoded = keyValues(object["urlencoded"])
        case "formdata":
            body.mode = .formData
            body.formData = object.array("formdata").map { item in
                let isFile = item.string("type") == "file"
                let src = (item["src"] as? String) ?? ((item["src"] as? [String])?.first)
                return FormDataField(key: item.string("key") ?? "", kind: isFile ? .file : .text, value: item.string("value") ?? "",
                                     file: isFile ? src.map { FileReference(path: $0) } : nil, contentType: item.string("contentType") ?? "",
                                     isEnabled: !(item.bool("disabled") ?? false), notes: description(item["description"]))
            }
        case "file":
            body.mode = .binary
            body.binary = object.object("file")?.string("src").map { FileReference(path: $0) }
        case "graphql":
            body.mode = .graphQL
            let graphQL = object.object("graphql") ?? [:]
            body.graphQL = GraphQLBody(query: graphQL.string("query") ?? "", variables: graphQL.string("variables") ?? "")
        default:
            break
        }
        if object.bool("disabled") == true { body.mode = .none }
        return body
    }

    /// Parses v2.1 (array of key/value) and v2.0 (dictionary) auth blocks.
    static func auth(_ object: JSONObject?, default fallback: AuthConfig) -> AuthConfig {
        guard let object, let type = object.string("type") else { return fallback }
        func params(_ name: String) -> [String: String] {
            if let list = object[name] as? [Any] {
                var result: [String: String] = [:]
                for case let entry as JSONObject in list {
                    if let key = entry.string("key") { result[key] = entry.string("value") ?? "" }
                }
                return result
            }
            if let dictionary = object[name] as? JSONObject {
                return dictionary.reduce(into: [:]) { $0[$1.key] = ($1.value as? String) ?? "\($1.value)" }
            }
            return [:]
        }
        var auth = AuthConfig(type: .none)
        switch type {
        case "noauth":
            auth.type = .none
        case "inherit":
            auth.type = .inherit
        case "basic":
            let p = params("basic")
            auth.type = .basic
            auth.basic = BasicAuth(username: p["username"] ?? "", password: p["password"] ?? "")
        case "bearer":
            auth.type = .bearer
            auth.bearer = BearerAuth(token: params("bearer")["token"] ?? "")
        case "apikey":
            let p = params("apikey")
            auth.type = .apiKey
            auth.apiKey = APIKeyAuth(key: p["key"] ?? "", value: p["value"] ?? "", location: p["in"] == "query" ? .query : .header)
        case "digest":
            let p = params("digest")
            auth.type = .digest
            auth.digest = DigestAuth(username: p["username"] ?? "", password: p["password"] ?? "")
        case "oauth1":
            let p = params("oauth1")
            auth.type = .oauth1
            auth.oauth1.consumerKey = p["consumerKey"] ?? ""
            auth.oauth1.consumerSecret = p["consumerSecret"] ?? ""
            auth.oauth1.token = p["token"] ?? ""
            auth.oauth1.tokenSecret = p["tokenSecret"] ?? ""
            auth.oauth1.realm = p["realm"] ?? ""
            auth.oauth1.signatureMethod = OAuth1Auth.SignatureMethod(rawValue: p["signatureMethod"] ?? "") ?? .hmacSHA1
            auth.oauth1.addToQuery = p["addParamsToHeader"] == "false"
        case "oauth2":
            let p = params("oauth2")
            auth.type = .oauth2
            auth.oauth2.accessToken = p["accessToken"] ?? ""
            auth.oauth2.headerPrefix = p["headerPrefix"] ?? "Bearer"
            auth.oauth2.authURL = p["authUrl"] ?? ""
            auth.oauth2.accessTokenURL = p["accessTokenUrl"] ?? ""
            auth.oauth2.clientID = p["clientId"] ?? ""
            auth.oauth2.clientSecret = p["clientSecret"] ?? ""
            auth.oauth2.scope = p["scope"] ?? ""
            auth.oauth2.state = p["state"] ?? ""
            auth.oauth2.callbackURL = p["redirect_uri"] ?? auth.oauth2.callbackURL
            auth.oauth2.username = p["username"] ?? ""
            auth.oauth2.password = p["password"] ?? ""
            auth.oauth2.clientAuthentication = p["client_authentication"] == "body" ? .body : .basicHeader
            switch p["grant_type"] {
            case "client_credentials": auth.oauth2.grantType = .clientCredentials
            case "password_credentials": auth.oauth2.grantType = .password
            case "authorization_code": auth.oauth2.grantType = .authorizationCode
            default: auth.oauth2.grantType = .authorizationCodePKCE
            }
        case "awsv4":
            let p = params("awsv4")
            auth.type = .awsSigV4
            auth.awsSigV4.accessKey = p["accessKey"] ?? ""
            auth.awsSigV4.secretKey = p["secretKey"] ?? ""
            auth.awsSigV4.region = p["region"] ?? "us-east-1"
            auth.awsSigV4.service = p["service"] ?? ""
            auth.awsSigV4.sessionToken = p["sessionToken"] ?? ""
        default:
            return fallback
        }
        return auth
    }

    static func scripts(_ events: [JSONObject]) -> (pre: String, test: String) {
        var pre = "", test = ""
        for event in events {
            let script = event.object("script") ?? [:]
            let exec = (script["exec"] as? [String])?.joined(separator: "\n") ?? script.string("exec") ?? ""
            switch event.string("listen") {
            case "prerequest": pre = exec
            case "test": test = exec
            default: break
            }
        }
        return (pre, test)
    }

    static func variable(_ object: JSONObject) -> Variable {
        Variable(key: object.string("key") ?? "", value: object.string("value") ?? "", isEnabled: !(object.bool("disabled") ?? false), isSecret: object.string("type") == "secret")
    }

    static func description(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let object = value as? JSONObject { return object.string("content") ?? "" }
        return ""
    }

    static func example(_ object: JSONObject, fallbackRequest: RequestSpec) -> InteropExample {
        let request = object["originalRequest"].map(self.request) ?? fallbackRequest
        let headers = keyValues(object["header"])
        let response = ResponseSnapshot(statusCode: object.int("code") ?? 200, headers: headers, body: Data((object.string("body") ?? "").utf8), url: request.url)
        return InteropExample(name: object.string("name") ?? "Example", request: request, response: response)
    }

    // MARK: Encoding

    public static func encode(_ collection: InteropCollection) -> Data {
        var root: JSONObject = [
            "info": ["name": collection.name, "description": collection.description, "schema": schemaV21, "_postman_id": UUID().uuidString.lowercased()],
            "item": collection.items.map(encode),
        ]
        if collection.auth.type != .inherit { root["auth"] = encode(collection.auth) }
        let events = encodeEvents(pre: collection.preRequestScript, test: collection.testScript)
        if !events.isEmpty { root["event"] = events }
        if !collection.variables.isEmpty {
            root["variable"] = collection.variables.map { variable -> JSONObject in
                var entry: JSONObject = ["key": variable.key, "value": variable.value, "type": variable.isSecret ? "secret" : "string"]
                if !variable.isEnabled { entry["disabled"] = true }
                return entry
            }
        }
        return JSONCoding.data(root)
    }

    static func encode(_ item: InteropItem) -> JSONObject {
        switch item {
        case .folder(let folder):
            var object: JSONObject = ["name": folder.name, "item": folder.items.map(encode)]
            if !folder.description.isEmpty { object["description"] = folder.description }
            if folder.auth.type != .inherit { object["auth"] = encode(folder.auth) }
            let events = encodeEvents(pre: folder.preRequestScript, test: folder.testScript)
            if !events.isEmpty { object["event"] = events }
            return object
        case .request(let request):
            var requestObject = encodeRequest(request.spec)
            if !request.description.isEmpty { requestObject["description"] = request.description }
            var object: JSONObject = ["name": request.name, "request": requestObject]
            let events = encodeEvents(pre: request.spec.preRequestScript, test: request.spec.testScript)
            if !events.isEmpty { object["event"] = events }
            object["response"] = request.examples.map { example -> JSONObject in
                [
                    "name": example.name,
                    "originalRequest": encodeRequest(example.request),
                    "code": example.response.statusCode,
                    "status": HTTPURLResponse.localizedString(forStatusCode: example.response.statusCode).capitalized,
                    "header": example.response.headers.map { ["key": $0.key, "value": $0.value] },
                    "body": example.response.bodyText ?? "",
                    "_postman_previewlanguage": example.response.contentType?.contains("json") == true ? "json" : "text",
                ]
            }
            return object
        }
    }

    static func encodeRequest(_ spec: RequestSpec) -> JSONObject {
        var object: JSONObject = [
            "method": spec.method.rawValue,
            "header": spec.headers.filter { !$0.isBlank }.map(encodeKeyValue),
            "url": encodeURL(spec),
        ]
        if spec.auth.type != .inherit { object["auth"] = encode(spec.auth) }
        if let body = encodeBody(spec.body) { object["body"] = body }
        return object
    }

    static func encodeKeyValue(_ row: KeyValue) -> JSONObject {
        var object: JSONObject = ["key": row.key, "value": row.value]
        if !row.isEnabled { object["disabled"] = true }
        if !row.description.isEmpty { object["description"] = row.description }
        return object
    }

    static func encodeURL(_ spec: RequestSpec) -> JSONObject {
        let (base, _, _) = RawURL.split(spec.url)
        var object: JSONObject = ["raw": spec.url]
        var hostAndPath = base
        if let scheme = base.range(of: "://") {
            object["protocol"] = String(base[..<scheme.lowerBound])
            hostAndPath = String(base[scheme.upperBound...])
        }
        let slash = hostAndPath.firstIndex(of: "/") ?? hostAndPath.endIndex
        var host = String(hostAndPath[..<slash])
        if let colon = host.lastIndex(of: ":"), !host.hasSuffix("}}"), Int(host[host.index(after: colon)...]) != nil {
            object["port"] = String(host[host.index(after: colon)...])
            host = String(host[..<colon])
        }
        object["host"] = host.split(separator: ".").map(String.init)
        object["path"] = hostAndPath[slash...].split(separator: "/").map(String.init)
        if !spec.params.isEmpty { object["query"] = spec.params.filter { !$0.isBlank }.map(encodeKeyValue) }
        if !spec.pathVariables.isEmpty { object["variable"] = spec.pathVariables.map { ["key": $0.key, "value": $0.value] } }
        return object
    }

    static func encodeBody(_ body: RequestBody) -> JSONObject? {
        switch body.mode {
        case .none:
            return nil
        case .raw:
            return ["mode": "raw", "raw": body.raw, "options": ["raw": ["language": body.rawLanguage.rawValue]]]
        case .urlEncoded:
            return ["mode": "urlencoded", "urlencoded": body.urlEncoded.filter { !$0.isBlank }.map(encodeKeyValue)]
        case .formData:
            return ["mode": "formdata", "formdata": body.formData.map { field -> JSONObject in
                var object: JSONObject = ["key": field.key, "type": field.kind == .file ? "file" : "text"]
                if field.kind == .file { object["src"] = field.file?.path ?? "" } else { object["value"] = field.value }
                if !field.contentType.isEmpty { object["contentType"] = field.contentType }
                if !field.isEnabled { object["disabled"] = true }
                if !field.notes.isEmpty { object["description"] = field.notes }
                return object
            }]
        case .binary:
            return ["mode": "file", "file": ["src": body.binary?.path ?? ""]]
        case .graphQL:
            return ["mode": "graphql", "graphql": ["query": body.graphQL.query, "variables": body.graphQL.variables]]
        }
    }

    static func encode(_ auth: AuthConfig) -> JSONObject {
        func list(_ pairs: [(String, Any)]) -> [JSONObject] {
            pairs.map { ["key": $0.0, "value": $0.1, "type": $0.1 is Bool ? "boolean" : "string"] }
        }
        switch auth.type {
        case .inherit: return ["type": "inherit"]
        case .none: return ["type": "noauth"]
        case .basic: return ["type": "basic", "basic": list([("username", auth.basic.username), ("password", auth.basic.password)])]
        case .bearer: return ["type": "bearer", "bearer": list([("token", auth.bearer.token)])]
        case .apiKey: return ["type": "apikey", "apikey": list([("key", auth.apiKey.key), ("value", auth.apiKey.value), ("in", auth.apiKey.location.rawValue)])]
        case .digest: return ["type": "digest", "digest": list([("username", auth.digest.username), ("password", auth.digest.password)])]
        case .oauth1:
            let c = auth.oauth1
            return ["type": "oauth1", "oauth1": list([("consumerKey", c.consumerKey), ("consumerSecret", c.consumerSecret), ("token", c.token),
                                                    ("tokenSecret", c.tokenSecret), ("signatureMethod", c.signatureMethod.rawValue), ("realm", c.realm),
                                                    ("addParamsToHeader", !c.addToQuery)])]
        case .oauth2:
            let c = auth.oauth2
            let grant = switch c.grantType {
            case .clientCredentials: "client_credentials"
            case .password: "password_credentials"
            case .authorizationCode: "authorization_code"
            case .authorizationCodePKCE: "authorization_code_with_pkce"
            }
            return ["type": "oauth2", "oauth2": list([("accessToken", c.accessToken), ("headerPrefix", c.headerPrefix), ("grant_type", grant),
                                                    ("authUrl", c.authURL), ("accessTokenUrl", c.accessTokenURL), ("clientId", c.clientID),
                                                    ("clientSecret", c.clientSecret), ("scope", c.scope), ("state", c.state), ("redirect_uri", c.callbackURL),
                                                    ("client_authentication", c.clientAuthentication == .body ? "body" : "header"), ("addTokenTo", "header")])]
        case .awsSigV4:
            let c = auth.awsSigV4
            return ["type": "awsv4", "awsv4": list([("accessKey", c.accessKey), ("secretKey", c.secretKey), ("region", c.region),
                                                  ("service", c.service), ("sessionToken", c.sessionToken)])]
        }
    }

    static func encodeEvents(pre: String, test: String) -> [JSONObject] {
        var events: [JSONObject] = []
        if !pre.isEmpty { events.append(["listen": "prerequest", "script": ["type": "text/javascript", "exec": pre.components(separatedBy: "\n")]]) }
        if !test.isEmpty { events.append(["listen": "test", "script": ["type": "text/javascript", "exec": test.components(separatedBy: "\n")]]) }
        return events
    }
}

/// Postman environment / globals files.
public enum PostmanEnvironment {
    public static func detect(_ object: [String: Any]) -> Bool {
        object["values"] is [Any] && object["info"] == nil
    }

    public static func decode(_ data: Data) throws -> InteropEnvironment {
        let root = try JSONCoding.object(from: data)
        guard detect(root) else { throw InteropError.unsupportedFormat("not a Postman environment") }
        let variables = root.array("values").map { value in
            Variable(key: value.string("key") ?? "", value: value.string("value") ?? "", isEnabled: value.bool("enabled") ?? true, isSecret: value.string("type") == "secret")
        }
        return InteropEnvironment(name: root.string("name") ?? "Imported Environment", variables: variables)
    }

    public static func encode(_ environment: InteropEnvironment, scope: String = "environment") -> Data {
        JSONCoding.data([
            "id": UUID().uuidString.lowercased(),
            "name": environment.name,
            "values": environment.variables.map { ["key": $0.key, "value": $0.value, "enabled": $0.isEnabled, "type": $0.isSecret ? "secret" : "default"] },
            "_postman_variable_scope": scope,
        ] as JSONObject)
    }
}
