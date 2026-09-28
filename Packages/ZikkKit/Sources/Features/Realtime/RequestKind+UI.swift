import Foundation
import APICore

extension RequestKind {
    var menuTitle: String {
        switch self {
        case .http: L("HTTP Request")
        case .graphQL: L("GraphQL Request")
        case .webSocket: L("WebSocket Request")
        case .sse: L("Server-Sent Events")
        case .grpc: L("gRPC Request")
        }
    }

    var defaultName: String {
        switch self {
        case .http: L("Untitled Request")
        case .graphQL: L("Untitled GraphQL Request")
        case .webSocket: L("Untitled WebSocket")
        case .sse: L("Untitled Event Stream")
        case .grpc: L("Untitled gRPC Request")
        }
    }

    func badge(method: HTTPMethod) -> String {
        switch self {
        case .http: method.rawValue
        case .graphQL: "GQL"
        case .webSocket: "WS"
        case .sse: "SSE"
        case .grpc: "gRPC"
        }
    }
}

extension RequestSpec {
    /// Starting point for a new request of `kind`.
    static func template(for kind: RequestKind) -> RequestSpec {
        switch kind {
        case .http:
            RequestSpec()
        case .graphQL:
            RequestSpec(kind: .graphQL, method: .post, body: RequestBody(mode: .graphQL, graphQL: GraphQLBody(query: "query {\n  \n}\n")))
        case .webSocket:
            RequestSpec(kind: .webSocket)
        case .sse:
            RequestSpec(kind: .sse)
        case .grpc:
            RequestSpec(kind: .grpc, body: RequestBody(mode: .raw, raw: "{}", rawLanguage: .json))
        }
    }
}
