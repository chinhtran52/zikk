import Testing
import Foundation
@testable import APICore

@Suite struct VariableResolverTests {
    @Test func higherScopeWins() {
        let resolver = VariableResolver(
            globals: [Variable(key: "host", value: "global.example.com"), Variable(key: "token", value: "g")],
            environment: [Variable(key: "host", value: "env.example.com")]
        )
        #expect(resolver.resolve("https://{{host}}/x?t={{token}}") == "https://env.example.com/x?t=g")
    }

    @Test func disabledVariablesIgnored() {
        let resolver = VariableResolver(globals: [Variable(key: "a", value: "1", isEnabled: false)])
        #expect(resolver.resolve("{{a}}") == "{{a}}")
        #expect(resolver.unresolvedVariables(in: "{{a}} {{ b }}") == ["a", "b"])
    }

    @Test func nestedResolution() {
        let resolver = VariableResolver(scopes: [["base": "{{scheme}}://api", "scheme": "https"]])
        #expect(resolver.resolve("{{base}}/v1") == "https://api/v1")
    }

    @Test func cyclesTerminate() {
        let resolver = VariableResolver(scopes: [["a": "{{b}}", "b": "{{a}}"]])
        _ = resolver.resolve("{{a}}")
    }

    @Test func dynamicVariables() {
        let resolver = VariableResolver()
        #expect(resolver.resolve("{{$guid}}").count == 36)
        #expect(Int(resolver.resolve("{{$timestamp}}")) != nil)
    }
}

@Suite struct RawURLTests {
    @Test func parsesQueryWithVariables() {
        let params = RawURL.queryParams(of: "{{base}}/users?page={{page}}&flag&q=a%20b#top")
        #expect(params.map(\.key) == ["page", "flag", "q"])
        #expect(params.map(\.value) == ["{{page}}", "", "a%20b"])
    }

    @Test func replacesQueryKeepingFragment() {
        let url = RawURL.replacingQuery(of: "http://x/a?old=1#frag", with: [KeyValue(key: "n", value: "2"), KeyValue(key: "off", value: "3", isEnabled: false)])
        #expect(url == "http://x/a?n=2#frag")
    }

    @Test func pathVariables() {
        let url = "https://api.test/users/:id/posts/:postId?x=:notPath"
        #expect(RawURL.pathVariableNames(in: url) == ["id", "postId"])
        let result = RawURL.substitutingPathVariables(in: url, with: [KeyValue(key: "id", value: "7"), KeyValue(key: "postId", value: "9")])
        #expect(result == "https://api.test/users/7/posts/9?x=:notPath")
    }
}

@Suite struct RequestSpecCodingTests {
    @Test func decodesLegacyDataWithoutNewKeys() throws {
        // Simulate data stored before the realtime fields existed.
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(RequestSpec(method: .post, url: "http://x"))) as? [String: Any])
        for key in ["messages", "realtime", "draftMessage", "grpcMethod", "protoSource"] { object.removeValue(forKey: key) }
        let spec = try JSONDecoder().decode(RequestSpec.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(spec.method == .post)
        #expect(spec.messages.isEmpty)
        let roundTrip = try JSONDecoder().decode(RequestSpec.self, from: JSONEncoder().encode(RequestSpec(kind: .webSocket, url: "ws://x")))
        #expect(roundTrip.kind == .webSocket)
    }
}
