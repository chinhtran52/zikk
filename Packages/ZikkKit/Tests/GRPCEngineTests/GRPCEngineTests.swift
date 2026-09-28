import Testing
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2TransportServices
import SwiftProtobuf
import APICore
import ProtoKit
@testable import GRPCEngine

let testProto = """
syntax = "proto3";
package demo.v1;
service Greeter {
  rpc SayHello (HelloRequest) returns (HelloReply);
  rpc Watch (HelloRequest) returns (stream HelloReply);
  rpc Chat (stream HelloRequest) returns (stream HelloReply);
  rpc Fail (HelloRequest) returns (HelloReply);
}
message HelloRequest { string name = 1; int32 times = 2; }
message HelloReply { string message = 1; }
"""

/// Test service speaking raw protobuf bytes, plus a minimal reflection implementation.
struct TestGreeter: RegistrableRPCService {
    let codec: ProtoCodec
    let reflectionCodec: ProtoCodec

    func reply(_ text: String) throws -> [UInt8] {
        [UInt8](try codec.encode(["message": text], as: "demo.v1.HelloReply"))
    }

    func name(_ bytes: [UInt8]) throws -> String {
        (try codec.decode(Data(bytes), as: "demo.v1.HelloRequest") as? [String: Any])?["name"] as? String ?? ""
    }

    func registerMethods<Transport: ServerTransport>(with router: inout RPCRouter<Transport>) {
        func method(_ name: String) -> MethodDescriptor { MethodDescriptor(fullyQualifiedService: "demo.v1.Greeter", method: name) }
        router.registerHandler(forMethod: method("SayHello"), deserializer: RawBytesDeserializer(), serializer: RawBytesSerializer()) { request, _ in
            var metadata = Metadata()
            for entry in request.metadata where entry.key == "x-trace" {
                if case .string(let value) = entry.value { metadata.addString(value, forKey: "x-trace-echo") }
            }
            var first: [UInt8] = []
            for try await message in request.messages { first = message; break }
            let text = "Hello, \(try name(first))"
            return StreamingServerResponse(metadata: metadata) { writer in
                try await writer.write(try reply(text))
                return ["x-done": "yes"]
            }
        }
        router.registerHandler(forMethod: method("Watch"), deserializer: RawBytesDeserializer(), serializer: RawBytesSerializer()) { request, _ in
            var first: [UInt8] = []
            for try await message in request.messages { first = message; break }
            let who = try name(first)
            return StreamingServerResponse { writer in
                for index in 1...3 { try await writer.write(try reply("\(who) #\(index)")) }
                return [:]
            }
        }
        router.registerHandler(forMethod: method("Chat"), deserializer: RawBytesDeserializer(), serializer: RawBytesSerializer()) { request, _ in
            StreamingServerResponse { writer in
                for try await message in request.messages { try await writer.write(try reply("echo " + (try name(message)))) }
                return [:]
            }
        }
        router.registerHandler(forMethod: method("Fail"), deserializer: RawBytesDeserializer(), serializer: RawBytesSerializer()) { _, _ in
            StreamingServerResponse(error: RPCError(code: .notFound, message: "no such greeting"))
        }
        router.registerHandler(forMethod: MethodDescriptor(fullyQualifiedService: "grpc.reflection.v1.ServerReflection", method: "ServerReflectionInfo"),
                               deserializer: RawBytesDeserializer(), serializer: RawBytesSerializer()) { request, _ in
            StreamingServerResponse { writer in
                for try await message in request.messages {
                    let object = try reflectionCodec.decode(Data(message), as: "grpc.reflection.v1.ServerReflectionRequest") as? [String: Any] ?? [:]
                    let response: [String: Any]
                    if object["listServices"] != nil {
                        response = ["listServicesResponse": ["service": [["name": "demo.v1.Greeter"], ["name": "grpc.reflection.v1.ServerReflection"]]]]
                    } else {
                        response = ["fileDescriptorResponse": ["fileDescriptorProto": [try Self.fileDescriptor().serializedData().base64EncodedString()]]]
                    }
                    try await writer.write([UInt8](try reflectionCodec.encode(response, as: "grpc.reflection.v1.ServerReflectionResponse")))
                }
                return [:]
            }
        }
    }

    static func fileDescriptor() -> Google_Protobuf_FileDescriptorProto {
        var file = Google_Protobuf_FileDescriptorProto()
        file.name = "demo/v1/greeter.proto"
        file.package = "demo.v1"
        func message(_ name: String, _ fields: [(String, Int32, Google_Protobuf_FieldDescriptorProto.TypeEnum)]) -> Google_Protobuf_DescriptorProto {
            var descriptor = Google_Protobuf_DescriptorProto()
            descriptor.name = name
            descriptor.field = fields.map { name, number, type in
                var field = Google_Protobuf_FieldDescriptorProto()
                field.name = name
                field.number = number
                field.type = type
                field.label = .optional
                return field
            }
            return descriptor
        }
        file.messageType = [message("HelloRequest", [("name", 1, .string), ("times", 2, .int32)]), message("HelloReply", [("message", 1, .string)])]
        var service = Google_Protobuf_ServiceDescriptorProto()
        service.name = "Greeter"
        var sayHello = Google_Protobuf_MethodDescriptorProto()
        sayHello.name = "SayHello"
        sayHello.inputType = ".demo.v1.HelloRequest"
        sayHello.outputType = ".demo.v1.HelloReply"
        var watch = sayHello
        watch.name = "Watch"
        watch.serverStreaming = true
        service.method = [sayHello, watch]
        file.service = [service]
        return file
    }
}

@Suite(.serialized) struct GRPCEngineTests {
    func withServer(_ body: (GRPCTarget) async throws -> Void) async throws {
        let schema = try ProtoParser.parse(testProto)
        let service = TestGreeter(codec: ProtoCodec(schema: schema), reflectionCodec: ProtoCodec(schema: try ProtoParser.parse(ServerReflection.reflectionProto)))
        let transport = HTTP2ServerTransport.TransportServices(address: .ipv4(host: "127.0.0.1", port: 0), transportSecurity: .plaintext)
        try await withGRPCServer(transport: transport, services: [service]) { server in
            let address = try await transport.listeningAddress
            let port = try #require(address.ipv4?.port)
            try await body(GRPCTarget(host: "127.0.0.1", port: port, useTLS: false))
            server.beginGracefulShutdown()
        }
    }

    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [GRPCCallEvent] = []
        func append(_ event: GRPCCallEvent) { lock.withLock { storage.append(event) } }
        var all: [GRPCCallEvent] { lock.withLock { storage } }
        var messages: [String] {
            all.compactMap { if case .message(let json) = $0 { return (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String])?["message"] }; return nil }
        }
    }

    @Test func targets() {
        #expect(GRPCTarget.parse("localhost:50051") == GRPCTarget(host: "localhost", port: 50051, useTLS: false))
        #expect(GRPCTarget.parse("grpcs://api.test") == GRPCTarget(host: "api.test", port: 443, useTLS: true))
        #expect(GRPCTarget.parse("https://[::1]:8443/x") == GRPCTarget(host: "::1", port: 8443, useTLS: true))
        #expect(GRPCTarget.parse("  ") == nil)
    }

    @Test func unaryStreamingAndErrors() async throws {
        let schema = try ProtoParser.parse(testProto)
        try await withServer { target in
            let client = DynamicGRPCClient(target: target)

            let unary = Events()
            let status = await client.call("demo.v1.Greeter/SayHello", schema: schema, messages: [#"{"name":"Linh"}"#],
                                           metadata: [KeyValue(key: "X-Trace", value: "t1")], timeout: .seconds(5)) { unary.append($0) }
            #expect(status.isOK, "\(status)")
            #expect(unary.messages == ["Hello, Linh"])
            #expect(unary.all.contains(.headers([KeyValue(key: "x-trace-echo", value: "t1")])) || unary.all.contains { if case .headers(let h) = $0 { return h.contains { $0.key == "x-trace-echo" && $0.value == "t1" } }; return false })
            #expect(status.trailers.contains { $0.key == "x-done" && $0.value == "yes" })

            let stream = Events()
            _ = await client.call("demo.v1.Greeter/Watch", schema: schema, messages: [#"{"name":"An"}"#], metadata: [], timeout: nil) { stream.append($0) }
            #expect(stream.messages == ["An #1", "An #2", "An #3"])

            let chat = Events()
            let chatStatus = await client.call("demo.v1.Greeter/Chat", schema: schema, messages: [#"{"name":"a"}"#, #"{"name":"b"}"#], metadata: [], timeout: nil) { chat.append($0) }
            #expect(chatStatus.isOK)
            #expect(chat.messages == ["echo a", "echo b"])

            let failure = await client.call("demo.v1.Greeter/Fail", schema: schema, messages: ["{}"], metadata: [], timeout: nil) { _ in }
            #expect(failure.code == 5)
            #expect(failure.name == "NOT_FOUND")
            #expect(failure.message == "no such greeting")

            let invalid = await client.call("demo.v1.Greeter/SayHello", schema: schema, messages: [#"{"nope":1}"#], metadata: [], timeout: nil) { _ in }
            #expect(invalid.code == 3)
        }
    }

    @Test func serverReflection() async throws {
        try await withServer { target in
            let schema = try await ServerReflection(client: DynamicGRPCClient(target: target)).loadSchema()
            #expect(schema.methodPaths == ["demo.v1.Greeter/SayHello", "demo.v1.Greeter/Watch"])
            #expect(schema.messages["demo.v1.HelloRequest"]?.field(named: "times")?.kind == .int32)
            // The reflected schema is usable for calls.
            let events = Events()
            _ = await DynamicGRPCClient(target: target).call("demo.v1.Greeter/SayHello", schema: schema, messages: [#"{"name":"R"}"#], metadata: [], timeout: nil) { events.append($0) }
            #expect(events.messages == ["Hello, R"])
        }
    }

    @Test func unreachableServer() async {
        let status = await DynamicGRPCClient(target: GRPCTarget(host: "127.0.0.1", port: 1, useTLS: false))
            .call("demo.v1.Greeter/SayHello", schema: try! ProtoParser.parse(testProto), messages: ["{}"], metadata: [], timeout: .seconds(3)) { _ in }
        #expect(!status.isOK)
    }
}
