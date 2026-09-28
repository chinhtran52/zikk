import SwiftUI
import APICore

extension HTTPMethod {
    public var tint: Color {
        switch self {
        case .get: .green
        case .post: .orange
        case .put: .blue
        case .patch: .purple
        case .delete: .red
        case .head, .options: .teal
        default: .secondary
        }
    }
}

/// Compact colored method label, e.g. "GET".
public struct MethodBadge: View {
    let method: HTTPMethod
    let kind: RequestKind

    public init(_ method: HTTPMethod, kind: RequestKind = .http) {
        self.method = method
        self.kind = kind
    }

    public var body: some View {
        Text(label)
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .frame(minWidth: 34, alignment: .leading)
    }

    private var label: String {
        switch kind {
        case .http: method.rawValue == "DELETE" ? "DEL" : method.rawValue
        case .graphQL: "GQL"
        case .webSocket: "WS"
        case .sse: "SSE"
        case .grpc: "gRPC"
        }
    }

    private var color: Color {
        kind == .http ? method.tint : .pink
    }
}

/// Colored HTTP status code label.
public struct StatusBadge: View {
    let code: Int

    public init(_ code: Int) { self.code = code }

    public var body: some View {
        Text(verbatim: "\(code) \(HTTPURLResponse.localizedString(forStatusCode: code).capitalized)")
            .font(.system(.callout, design: .monospaced).weight(.semibold))
            .foregroundStyle(Self.color(for: code))
    }

    public static func color(for code: Int) -> Color {
        switch code {
        case 200..<300: .green
        case 300..<400: .blue
        case 400..<500: .orange
        default: .red
        }
    }
}
