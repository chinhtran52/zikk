import Testing
import Foundation
@testable import ProtoKit

let greeterProto = """
syntax = "proto3";
package demo.v1;

import "google/protobuf/timestamp.proto";

// A greeting service.
service Greeter {
  rpc SayHello (HelloRequest) returns (HelloReply);
  rpc Chat (stream ChatMessage) returns (stream ChatMessage) {}
  rpc Watch (HelloRequest) returns (stream HelloReply) { option deprecated = true; }
}

message HelloRequest {
  string name = 1;
  int32 times = 2 [deprecated = true];
  repeated int32 lucky = 4;
  Mood mood = 5;
  map<string, int64> scores = 6;
  oneof target {
    string email = 7;
    Address address = 8;
  }
  google.protobuf.Timestamp sent_at = 9;
  sint32 delta = 10;
  bytes blob = 11;
  message Address { string city = 1; }
  enum Mood { MOOD_UNSPECIFIED = 0; HAPPY = 1; SAD = 2; }
}

message HelloReply { string message = 1; repeated HelloRequest.Address places = 2; }
message ChatMessage { string text = 1; }
"""

@Suite struct ProtoParserTests {
    @Test func parsesServicesMessagesAndNesting() throws {
        let schema = try ProtoParser.parse(greeterProto)
        #expect(schema.methodPaths == ["demo.v1.Greeter/SayHello", "demo.v1.Greeter/Chat", "demo.v1.Greeter/Watch"])
        let (_, chat) = try #require(schema.method("/demo.v1.Greeter/Chat"))
        #expect(chat.clientStreaming && chat.serverStreaming)
        #expect(chat.kindLabel == "Bidirectional streaming")
        let request = try #require(schema.messages["demo.v1.HelloRequest"])
        #expect(request.field(named: "mood")?.kind == .enumeration)
        #expect(request.field(named: "mood")?.typeName == "demo.v1.HelloRequest.Mood")
        #expect(request.field(named: "address")?.typeName == "demo.v1.HelloRequest.Address")
        #expect(request.field(named: "address")?.oneofName == "target")
        #expect(request.field(named: "sentAt")?.typeName == "google.protobuf.Timestamp")
        #expect(schema.messages["demo.v1.HelloRequest.ScoresEntry"]?.isMapEntry == true)
        #expect(schema.messages["demo.v1.HelloReply"]?.field(named: "places")?.typeName == "demo.v1.HelloRequest.Address")
    }

    @Test func reportsErrorsWithLines() {
        #expect(throws: ProtoParseError(message: "Unknown type `Missing`", line: 3)) {
            try ProtoParser.parse("syntax = \"proto3\";\nmessage A {\n  Missing m = 1;\n}")
        }
        #expect(throws: ProtoParseError.self) { try ProtoParser.parse("message A { string x = ; }") }
    }
}

@Suite struct ProtoCodecTests {
    let schema = try! ProtoParser.parse("""
    syntax = "proto3";
    message Test1 { int32 a = 1; }
    message Test2 { string b = 2; }
    message Test4 { repeated int32 d = 4; }
    """)

    @Test func officialEncodingExamples() throws {
        let codec = ProtoCodec(schema: schema)
        #expect(try codec.encode(json: #"{"a": 150}"#, as: "Test1") == Data([0x08, 0x96, 0x01]))
        #expect(try codec.encode(json: #"{"b": "testing"}"#, as: "Test2") == Data([0x12, 0x07, 0x74, 0x65, 0x73, 0x74, 0x69, 0x6e, 0x67]))
        #expect(try codec.encode(json: #"{"d": [3, 270, 86942]}"#, as: "Test4") == Data([0x22, 0x06, 0x03, 0x8E, 0x02, 0x9E, 0xA7, 0x05]))
        #expect(try codec.decode(Data([0x22, 0x06, 0x03, 0x8E, 0x02, 0x9E, 0xA7, 0x05]), as: "Test4") as? [String: [Int32]] == ["d": [3, 270, 86942]])
        // Unpacked repeated values are accepted too.
        #expect(try codec.decode(Data([0x20, 0x03, 0x20, 0x04]), as: "Test4") as? [String: [Int32]] == ["d": [3, 4]])
        // Unknown fields are skipped.
        #expect(try codec.decode(Data([0x08, 0x01, 0x50, 0x07]), as: "Test1") as? [String: Int32] == ["a": 1])
    }

    @Test func roundTripsComplexMessage() throws {
        let codec = ProtoCodec(schema: try ProtoParser.parse(greeterProto))
        let json = #"{"name":"Linh","lucky":[7,-1],"mood":"HAPPY","scores":{"a":"9007199254740993"},"address":{"city":"Hanoi"},"sentAt":"2024-05-01T10:00:00.250Z","delta":-3,"blob":"AQID"}"#
        let bytes = try codec.encode(json: json, as: "demo.v1.HelloRequest")
        let decoded = try #require(try codec.decode(bytes, as: "demo.v1.HelloRequest") as? [String: Any])
        #expect(decoded["name"] as? String == "Linh")
        #expect(decoded["lucky"] as? [Int32] == [7, -1])
        #expect(decoded["mood"] as? String == "HAPPY")
        #expect((decoded["scores"] as? [String: String])?["a"] == "9007199254740993")
        #expect((decoded["address"] as? [String: String])?["city"] == "Hanoi")
        #expect(decoded["sentAt"] as? String == "2024-05-01T10:00:00.250Z")
        #expect(decoded["delta"] as? Int32 == -3)
        #expect(decoded["blob"] as? String == "AQID")
    }

    @Test func validationErrors() throws {
        let codec = ProtoCodec(schema: try ProtoParser.parse(greeterProto))
        #expect(throws: ProtoCodecError.unknownField(message: "demo.v1.HelloRequest", field: "nope")) {
            try codec.encode(json: #"{"nope": 1}"#, as: "demo.v1.HelloRequest")
        }
        #expect(throws: ProtoCodecError.invalidValue(field: "mood", expected: "a value of demo.v1.HelloRequest.Mood")) {
            try codec.encode(json: #"{"mood": "ANGRY"}"#, as: "demo.v1.HelloRequest")
        }
        #expect(throws: ProtoCodecError.self) { try codec.decode(Data([0x0A, 0x05, 0x01]), as: "demo.v1.HelloRequest") }
    }

    @Test func templates() throws {
        let codec = ProtoCodec(schema: try ProtoParser.parse(greeterProto))
        let template = try #require(codec.template(for: "demo.v1.HelloRequest") as? [String: Any])
        #expect(template["mood"] as? String == "MOOD_UNSPECIFIED")
        #expect(template["sentAt"] as? String == "1970-01-01T00:00:00Z")
        #expect(template["email"] != nil && template["address"] == nil, "only the first member of a oneof")
        // The template is valid input.
        _ = try codec.encode(json: codec.templateJSON(for: "demo.v1.HelloRequest"), as: "demo.v1.HelloRequest")
    }
}
