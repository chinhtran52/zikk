import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2TransportServices
import APICore
import ProtoKit

/// Events of a gRPC call, in order: headers, messages, then status.
public enum GRPCCallEvent: Sendable, Hashable {
    case sent(json: String)
    case headers([KeyValue])
    case message(json: String)
    case finished(GRPCStatus)
}

public struct GRPCStatus: Sendable, Hashable {
    public var code: Int
    public var name: String
    public var message: String
    public var trailers: [KeyValue]

    public var isOK: Bool { code == 0 }

    public static let codeNames = ["OK", "CANCELLED", "UNKNOWN", "INVALID_ARGUMENT", "DEADLINE_EXCEEDED", "NOT_FOUND", "ALREADY_EXISTS",
                                   "PERMISSION_DENIED", "RESOURCE_EXHAUSTED", "FAILED_PRECONDITION", "ABORTED", "OUT_OF_RANGE",
                                   "UNIMPLEMENTED", "INTERNAL", "UNAVAILABLE", "DATA_LOSS", "UNAUTHENTICATED"]

    public init(code: Int, message: String, trailers: [KeyValue] = []) {
        self.code = code
        self.name = code < Self.codeNames.count ? Self.codeNames[code] : "CODE_\(code)"
        self.message = message
        self.trailers = trailers
    }
}

/// Passes protobuf bytes through unchanged (the dynamic codec produces/consumes them).
struct RawBytesSerializer: MessageSerializer {
    func serialize<Bytes: GRPCContiguousBytes>(_ message: [UInt8]) throws -> Bytes { Bytes(message) }
}

struct RawBytesDeserializer: MessageDeserializer {
    func deserialize<Bytes: GRPCContiguousBytes>(_ serializedMessageBytes: Bytes) throws -> [UInt8] {
        serializedMessageBytes.withUnsafeBytes { Array($0) }
    }
}

public enum GRPCClientError: LocalizedError, Equatable {
    case unknownMethod(String)
    case invalidTarget(String)

    public var errorDescription: String? {
        switch self {
        case .unknownMethod(let path): "Method `\(path)` is not described by the loaded schema."
        case .invalidTarget(let target): "Invalid gRPC server address `\(target)`."
        }
    }
}

/// Calls gRPC methods described by a runtime `ProtoSchema`.
public struct DynamicGRPCClient: Sendable {
    public var target: GRPCTarget

    public init(target: GRPCTarget) {
        self.target = target
    }

    func makeTransport() throws -> HTTP2ClientTransport.TransportServices {
        let security: HTTP2ClientTransport.TransportServices.TransportSecurity = target.useTLS
            ? .tls { config in if !target.verifyTLS { config.serverCertificateVerification = .noVerification } }
            : .plaintext
        return try HTTP2ClientTransport.TransportServices(target: .dns(host: target.host, port: target.port), transportSecurity: security)
    }

    /// Runs `body` with a connected client, shutting it down afterwards.
    func withClient<Result: Sendable>(_ body: @Sendable @escaping (GRPCClient<HTTP2ClientTransport.TransportServices>) async throws -> Result) async throws -> Result {
        let transport = try makeTransport()
        return try await withGRPCClient(transport: transport) { client in
            try await body(client)
        }
    }

    /// Calls `path` (`package.Service/Method`). `messages` are JSON request messages (one for unary/server streaming).
    public func call(_ path: String, schema: ProtoSchema, messages: [String], metadata: [KeyValue], timeout: Duration?,
                     onEvent: @escaping @Sendable (GRPCCallEvent) async -> Void) async -> GRPCStatus {
        guard let (service, method) = schema.method(path) else {
            let status = GRPCStatus(code: 3, message: GRPCClientError.unknownMethod(path).localizedDescription)
            await onEvent(.finished(status))
            return status
        }
        let codec = ProtoCodec(schema: schema)
        let encoded: [[UInt8]]
        do {
            encoded = try messages.map { [UInt8](try codec.encode(json: $0, as: method.inputType)) }
        } catch {
            let status = GRPCStatus(code: 3, message: error.localizedDescription)
            await onEvent(.finished(status))
            return status
        }
        var grpcMetadata = Metadata()
        for entry in metadata where entry.isEnabled && !entry.key.isEmpty {
            if entry.key.lowercased().hasSuffix("-bin") {
                grpcMetadata.addBinary(Array(Data(base64Encoded: entry.value) ?? Data(entry.value.utf8)), forKey: entry.key.lowercased())
            } else {
                grpcMetadata.addString(entry.value, forKey: entry.key.lowercased())
            }
        }
        var callOptions = CallOptions.defaults
        callOptions.timeout = timeout
        let options = callOptions
        let descriptor = MethodDescriptor(fullyQualifiedService: service.fullName, method: method.name)
        let outputType = method.outputType
        let request = StreamingClientRequest<[UInt8]>(metadata: grpcMetadata) { writer in
            for (json, bytes) in zip(messages, encoded) {
                try await writer.write(bytes)
                await onEvent(.sent(json: json))
            }
        }
        do {
            return try await withClient { client in
                try await client.bidirectionalStreaming(request: request, descriptor: descriptor, serializer: RawBytesSerializer(),
                                                        deserializer: RawBytesDeserializer(), options: options) { response in
                    switch response.accepted {
                    case .failure(let error):
                        let status = Self.status(from: error)
                        await onEvent(.finished(status))
                        return status
                    case .success(let contents):
                        await onEvent(.headers(Self.keyValues(contents.metadata)))
                        var trailers: [KeyValue] = []
                        do {
                            for try await part in contents.bodyParts {
                                switch part {
                                case .message(let bytes):
                                    let json = (try? codec.decodeJSON(Data(bytes), as: outputType)) ?? "<\(bytes.count) bytes: undecodable as \(outputType)>"
                                    await onEvent(.message(json: json))
                                case .trailingMetadata(let metadata):
                                    trailers = Self.keyValues(metadata)
                                }
                            }
                        } catch let error as RPCError {
                            let status = Self.status(from: error)
                            await onEvent(.finished(status))
                            return status
                        }
                        let status = GRPCStatus(code: 0, message: "", trailers: trailers)
                        await onEvent(.finished(status))
                        return status
                    }
                }
            }
        } catch let error as RPCError {
            let status = Self.status(from: error)
            await onEvent(.finished(status))
            return status
        } catch {
            let status = GRPCStatus(code: 14, message: error.localizedDescription)
            await onEvent(.finished(status))
            return status
        }
    }

    static func status(from error: RPCError) -> GRPCStatus {
        GRPCStatus(code: error.code.rawValue, message: error.message, trailers: keyValues(error.metadata))
    }

    static func keyValues(_ metadata: Metadata) -> [KeyValue] {
        metadata.map { entry in
            switch entry.value {
            case .string(let string): KeyValue(key: entry.key, value: string)
            case .binary(let bytes): KeyValue(key: entry.key, value: Data(bytes).base64EncodedString())
            }
        }
    }
}
