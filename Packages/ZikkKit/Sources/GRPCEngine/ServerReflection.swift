import Foundation
import GRPCCore
import SwiftProtobuf
import ProtoKit

/// Loads service descriptions through the gRPC Server Reflection protocol.
public struct ServerReflection: Sendable {
    public var client: DynamicGRPCClient

    public init(client: DynamicGRPCClient) {
        self.client = client
    }

    static let reflectionProto = """
    syntax = "proto3";
    package grpc.reflection.v1;
    message ServerReflectionRequest {
      string host = 1;
      oneof message_request {
        string file_by_filename = 3;
        string file_containing_symbol = 4;
        string list_services = 7;
      }
    }
    message ServerReflectionResponse {
      string valid_host = 1;
      oneof message_response {
        FileDescriptorResponse file_descriptor_response = 4;
        ListServiceResponse list_services_response = 6;
        ErrorResponse error_response = 7;
      }
    }
    message FileDescriptorResponse { repeated bytes file_descriptor_proto = 1; }
    message ListServiceResponse { repeated ServiceResponse service = 1; }
    message ServiceResponse { string name = 1; }
    message ErrorResponse { int32 error_code = 1; string error_message = 2; }
    """

    public enum Failure: LocalizedError {
        case rpc(GRPCStatus)
        case server(String)

        public var errorDescription: String? {
            switch self {
            case .rpc(let status): "Reflection failed: \(status.name) \(status.message)"
            case .server(let message): "Reflection error: \(message)"
            }
        }
    }

    /// Lists services and fetches the descriptors of each, including transitive dependencies.
    public func loadSchema(metadata: [(String, String)] = []) async throws -> ProtoSchema {
        do {
            return try await load(package: "grpc.reflection.v1", metadata: metadata)
        } catch Failure.rpc(let status) where status.code == 12 {
            return try await load(package: "grpc.reflection.v1alpha", metadata: metadata)
        }
    }

    private func load(package: String, metadata: [(String, String)]) async throws -> ProtoSchema {
        let codec = ProtoCodec(schema: try ProtoParser.parse(Self.reflectionProto))
        let services = try await exchange(package: package, codec: codec, requests: [["listServices": "*"]], metadata: metadata)
            .flatMap { ((($0["listServicesResponse"] as? [String: Any])?["service"]) as? [[String: Any]] ?? []).compactMap { $0["name"] as? String } }
            .filter { !$0.hasPrefix("grpc.reflection.") }
        var files: [String: Google_Protobuf_FileDescriptorProto] = [:]
        var pending = services.map { ["fileContainingSymbol": $0] }
        var requestedFiles: Set<String> = []
        while !pending.isEmpty {
            let responses = try await exchange(package: package, codec: codec, requests: pending, metadata: metadata)
            pending = []
            for response in responses {
                if let error = response["errorResponse"] as? [String: Any] {
                    throw Failure.server(error["errorMessage"] as? String ?? "unknown error")
                }
                for encoded in ((response["fileDescriptorResponse"] as? [String: Any])?["fileDescriptorProto"] as? [String] ?? []) {
                    guard let data = Data(base64Encoded: encoded), let file = try? Google_Protobuf_FileDescriptorProto(serializedBytes: data) else { continue }
                    files[file.name] = file
                }
            }
            // Ask for dependencies the server did not include.
            for file in files.values {
                for dependency in file.dependency where files[dependency] == nil && !dependency.hasPrefix("google/protobuf/") && requestedFiles.insert(dependency).inserted {
                    pending.append(["fileByFilename": dependency])
                }
            }
        }
        var schema = DescriptorConverter.schema(from: Array(files.values))
        schema.merge(WellKnownTypes.schema)
        return schema
    }

    private func exchange(package: String, codec: ProtoCodec, requests: [[String: Any]], metadata: [(String, String)]) async throws -> [[String: Any]] {
        let messages = try requests.map { request -> String in
            String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        }
        // Encode with the v1 message names; the v1alpha wire format is identical.
        let schema = codec.schema
        var renamed = ProtoSchema()
        for (name, message) in schema.messages { renamed.messages[name.replacingOccurrences(of: "grpc.reflection.v1.", with: "\(package).")] = message }
        renamed.services = [ProtoService(fullName: "\(package).ServerReflection", methods: [
            ProtoMethod(name: "ServerReflectionInfo", inputType: "grpc.reflection.v1.ServerReflectionRequest",
                        outputType: "grpc.reflection.v1.ServerReflectionResponse", clientStreaming: true, serverStreaming: true),
        ])]
        renamed.messages.merge(schema.messages) { a, _ in a }
        let collector = Collector()
        let status = await client.call("\(package).ServerReflection/ServerReflectionInfo", schema: renamed, messages: messages,
                                       metadata: metadata.map { .init(key: $0.0, value: $0.1) }, timeout: .seconds(20)) { event in
            if case .message(let json) = event { collector.append(json) }
        }
        guard status.isOK else { throw Failure.rpc(status) }
        return collector.values.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }
}

final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ value: String) { lock.withLock { storage.append(value) } }
    var values: [String] { lock.withLock { storage } }
}

/// Converts `FileDescriptorProto`s into a `ProtoSchema`.
public enum DescriptorConverter {
    public static func schema(from files: [Google_Protobuf_FileDescriptorProto]) -> ProtoSchema {
        var schema = ProtoSchema()
        for file in files {
            let package = file.package
            func qualify(_ name: String, _ scope: String) -> String { scope.isEmpty ? name : scope + "." + name }
            func addEnum(_ descriptor: Google_Protobuf_EnumDescriptorProto, scope: String) {
                let name = qualify(descriptor.name, scope)
                schema.enums[name] = ProtoEnum(fullName: name, values: descriptor.value.map { ($0.name, Int($0.number)) })
            }
            func addMessage(_ descriptor: Google_Protobuf_DescriptorProto, scope: String) {
                let name = qualify(descriptor.name, scope)
                let fields = descriptor.field.map { field -> ProtoField in
                    let kind = Self.kind(field.type)
                    let oneof = field.hasOneofIndex && !field.proto3Optional && Int(field.oneofIndex) < descriptor.oneofDecl.count
                        ? descriptor.oneofDecl[Int(field.oneofIndex)].name : nil
                    return ProtoField(name: field.name, number: Int(field.number), kind: kind,
                                      typeName: field.typeName.isEmpty ? nil : String(field.typeName.drop { $0 == "." }),
                                      isRepeated: field.label == .repeated, oneofName: oneof)
                }
                schema.messages[name] = ProtoMessage(fullName: name, fields: fields, isMapEntry: descriptor.options.mapEntry)
                descriptor.nestedType.forEach { addMessage($0, scope: name) }
                descriptor.enumType.forEach { addEnum($0, scope: name) }
            }
            file.messageType.forEach { addMessage($0, scope: package) }
            file.enumType.forEach { addEnum($0, scope: package) }
            for service in file.service {
                schema.services.append(ProtoService(fullName: qualify(service.name, package), methods: service.method.map {
                    ProtoMethod(name: $0.name, inputType: String($0.inputType.drop { $0 == "." }), outputType: String($0.outputType.drop { $0 == "." }),
                                clientStreaming: $0.clientStreaming, serverStreaming: $0.serverStreaming)
                }))
            }
        }
        return schema
    }

    static func kind(_ type: Google_Protobuf_FieldDescriptorProto.TypeEnum) -> ProtoField.Kind {
        switch type {
        case .double: .double
        case .float: .float
        case .int64: .int64
        case .uint64: .uint64
        case .int32: .int32
        case .fixed64: .fixed64
        case .fixed32: .fixed32
        case .bool: .bool
        case .string: .string
        case .bytes: .bytes
        case .uint32: .uint32
        case .enum: .enumeration
        case .sfixed32: .sfixed32
        case .sfixed64: .sfixed64
        case .sint32: .sint32
        case .sint64: .sint64
        case .message, .group: .message
        }
    }
}
