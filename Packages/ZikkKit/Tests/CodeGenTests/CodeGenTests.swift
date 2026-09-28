import Testing
import Foundation
import APICore
@testable import CodeGen

@Suite struct CodeGenTests {
    func request(body: RequestBody = RequestBody(), auth: AuthConfig = .none) throws -> SnippetRequest {
        let spec = RequestSpec(method: .post, url: "{{base}}/items?x=1", headers: [KeyValue(key: "X-Trace", value: "{{trace}}")], body: body)
        return try SnippetRequest(spec: spec, resolver: VariableResolver(scopes: [["base": "https://api.test", "trace": "t1"]]), auth: auth)
    }

    @Test func resolvesVariablesAndAuth() throws {
        var auth = AuthConfig(type: .bearer)
        auth.bearer.token = "tok"
        let snippet = try request(body: RequestBody(mode: .raw, raw: #"{"a":"b"}"#, rawLanguage: .json), auth: auth)
        #expect(snippet.url == "https://api.test/items?x=1")
        #expect(snippet.headers.map(\.name) == ["X-Trace", "Authorization", "Content-Type"])
        #expect(snippet.headers[1].value == "Bearer tok")
    }

    @Test func curlSnippet() throws {
        let code = CodeGenerator.generate(try request(body: RequestBody(mode: .raw, raw: "it's", rawLanguage: .text)), language: .curl)
        #expect(code == """
        curl --location --request POST 'https://api.test/items?x=1' \\
        --header 'X-Trace: t1' \\
        --header 'Content-Type: text/plain' \\
        --data-raw 'it'\\''s'
        """)
    }

    @Test func pythonFormData() throws {
        let body = RequestBody(mode: .formData, formData: [FormDataField(key: "n", value: "v"), FormDataField(key: "f", kind: .file, file: FileReference(path: "/tmp/a.txt"))])
        let code = CodeGenerator.generate(try request(body: body), language: .python)
        #expect(code.contains(#"payload = {"n": "v"}"#))
        #expect(code.contains(#"("f", ("a.txt", open("/tmp/a.txt", 'rb'), "application/octet-stream")),"#))
        #expect(code.contains(#"response = requests.request("POST", url, headers=headers, data=payload, files=files)"#))
    }

    @Test func everyLanguageProducesOutput() throws {
        let bodies: [RequestBody] = [
            RequestBody(),
            RequestBody(mode: .raw, raw: "{\"q\": \"$x\"}", rawLanguage: .json),
            RequestBody(mode: .urlEncoded, urlEncoded: [KeyValue(key: "a b", value: "c&d")]),
            RequestBody(mode: .formData, formData: [FormDataField(key: "f", kind: .file, file: FileReference(path: "/tmp/x"))]),
            RequestBody(mode: .binary, binary: FileReference(path: "/tmp/bin")),
            RequestBody(mode: .graphQL, graphQL: GraphQLBody(query: "{ me { id } }")),
        ]
        for body in bodies {
            let snippet = try request(body: body)
            for language in SnippetLanguage.allCases {
                let code = CodeGenerator.generate(snippet, language: language)
                #expect(code.contains("api.test"), "\(language) missing URL")
            }
        }
        let kotlin = CodeGenerator.generate(try request(body: bodies[1]), language: .kotlinOkHttp)
        #expect(kotlin.contains(#"\$x"#))
        #expect(CodeGenerator.generate(try request(body: bodies[2]), language: .http).contains("a%20b=c%26d"))
    }
}
