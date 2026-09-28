import Foundation

public enum RequestKind: String, Codable, CaseIterable, Sendable {
    case http, graphQL, webSocket, sse, grpc
}

public struct RequestSettings: Codable, Hashable, Sendable {
    public var followRedirects = true
    public var maxRedirects = 10
    /// 0 means use the app default.
    public var timeoutMilliseconds = 0
    public var verifySSL = true
    public var encodeURL = true
    public var disableCookieJar = false

    public init() {}
}

/// A message saved on a WebSocket request for quick re-sending.
public struct SavedMessage: Codable, Hashable, Identifiable, Sendable {
    public enum Format: String, Codable, CaseIterable, Sendable { case text, json, binaryBase64 }
    public var id: UUID
    public var name: String
    public var body: String
    public var format: Format

    public init(id: UUID = UUID(), name: String, body: String, format: Format = .text) {
        self.id = id
        self.name = name
        self.body = body
        self.format = format
    }
}

/// Settings for WebSocket/SSE/gRPC requests.
public struct RealtimeSettings: Codable, Hashable, Sendable {
    /// `Sec-WebSocket-Protocol` values.
    public var subprotocols: [String] = []
    /// Reconnect automatically after the connection drops (SSE).
    public var autoReconnect = true
    /// Seconds between WebSocket pings (0 = disabled).
    public var pingInterval = 0
    public init() {}
}

/// A complete, self-contained request definition. Stored as a single Codable column in SwiftData.
/// Decoding tolerates missing keys so new fields never break stored data.
public struct RequestSpec: Codable, Hashable, Sendable {
    public var kind: RequestKind
    public var method: HTTPMethod
    /// Raw URL as typed by the user; may contain `{{variables}}` and `:pathParams`.
    public var url: String
    public var params: [KeyValue]
    public var pathVariables: [KeyValue]
    public var headers: [KeyValue]
    public var body: RequestBody
    public var auth: AuthConfig
    public var preRequestScript: String
    public var testScript: String
    public var settings: RequestSettings
    public var messages: [SavedMessage] = []
    public var realtime = RealtimeSettings()
    /// Draft message in the WebSocket composer.
    public var draftMessage = ""
    /// gRPC: fully qualified method, e.g. `package.Service/Method`.
    public var grpcMethod = ""
    /// gRPC: `.proto` source used to describe services (empty = server reflection).
    public var protoSource = ""

    public init(kind: RequestKind = .http, method: HTTPMethod = .get, url: String = "", params: [KeyValue] = [], pathVariables: [KeyValue] = [], headers: [KeyValue] = [], body: RequestBody = RequestBody(), auth: AuthConfig = .inherit, preRequestScript: String = "", testScript: String = "", settings: RequestSettings = RequestSettings()) {
        self.kind = kind
        self.method = method
        self.url = url
        self.params = params
        self.pathVariables = pathVariables
        self.headers = headers
        self.body = body
        self.auth = auth
        self.preRequestScript = preRequestScript
        self.testScript = testScript
        self.settings = settings
    }
}

extension RequestSpec {
    enum CodingKeys: String, CodingKey {
        case kind, method, url, params, pathVariables, headers, body, auth, preRequestScript, testScript, settings
        case messages, realtime, draftMessage, grpcMethod, protoSource
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        kind = try c.decodeIfPresent(RequestKind.self, forKey: .kind) ?? .http
        method = try c.decodeIfPresent(HTTPMethod.self, forKey: .method) ?? .get
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        params = try c.decodeIfPresent([KeyValue].self, forKey: .params) ?? []
        pathVariables = try c.decodeIfPresent([KeyValue].self, forKey: .pathVariables) ?? []
        headers = try c.decodeIfPresent([KeyValue].self, forKey: .headers) ?? []
        body = try c.decodeIfPresent(RequestBody.self, forKey: .body) ?? RequestBody()
        auth = try c.decodeIfPresent(AuthConfig.self, forKey: .auth) ?? .inherit
        preRequestScript = try c.decodeIfPresent(String.self, forKey: .preRequestScript) ?? ""
        testScript = try c.decodeIfPresent(String.self, forKey: .testScript) ?? ""
        settings = try c.decodeIfPresent(RequestSettings.self, forKey: .settings) ?? RequestSettings()
        messages = try c.decodeIfPresent([SavedMessage].self, forKey: .messages) ?? []
        realtime = try c.decodeIfPresent(RealtimeSettings.self, forKey: .realtime) ?? RealtimeSettings()
        draftMessage = try c.decodeIfPresent(String.self, forKey: .draftMessage) ?? ""
        grpcMethod = try c.decodeIfPresent(String.self, forKey: .grpcMethod) ?? ""
        protoSource = try c.decodeIfPresent(String.self, forKey: .protoSource) ?? ""
    }
}
