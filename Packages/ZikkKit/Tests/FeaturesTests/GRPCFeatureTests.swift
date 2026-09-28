import Testing
import Foundation
import APICore
@testable import Features

@MainActor
@Suite struct GRPCFeatureTests {
    @Test func protoSourceTemplatesAndAuth() {
        var spec = RequestSpec.template(for: .grpc)
        spec.protoSource = """
        syntax = "proto3";
        package shop;
        service Orders { rpc Create (Order) returns (Order); rpc Upload (stream Order) returns (Order); }
        message Order { string id = 1; repeated string items = 2; }
        """
        let session = GRPCSessionModel()
        session.loadSchema(from: spec, resolver: VariableResolver(), metadata: [])
        #expect(session.schemaError == nil)
        #expect(session.schema?.methodPaths == ["shop.Orders/Create", "shop.Orders/Upload"])
        spec.grpcMethod = "shop.Orders/Create"
        #expect(session.template(for: spec)?.contains("\"items\"") == true)
        spec.grpcMethod = "shop.Orders/Upload"
        #expect(session.template(for: spec)?.hasPrefix("[") == true, "client streaming uses an array")

        spec.protoSource = "message {"
        session.loadSchema(from: spec, resolver: VariableResolver(), metadata: [])
        #expect(session.schemaError != nil)

        var bearer = AuthConfig(type: .bearer)
        bearer.bearer.token = "{{t}}"
        let metadata = GRPCSessionModel.authMetadata(bearer, resolver: VariableResolver(scopes: [["t": "abc"]]))
        #expect(metadata.map(\.key) == ["authorization"])
        #expect(metadata.map(\.value) == ["Bearer abc"])
        var apiKey = AuthConfig(type: .apiKey)
        apiKey.apiKey = APIKeyAuth(key: "X-Key", value: "k")
        #expect(GRPCSessionModel.authMetadata(apiKey, resolver: VariableResolver()).map(\.key) == ["x-key"])
    }
}
