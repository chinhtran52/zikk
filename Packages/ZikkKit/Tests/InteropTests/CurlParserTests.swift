import Testing
import Foundation
import APICore
@testable import Interop

@Suite struct CurlParserTests {
    @Test func chromeCopyAsCurl() throws {
        let command = """
        curl 'https://api.example.com/v1/users?page=2' \\
          -H 'accept: application/json' \\
          -H 'authorization: Bearer abc' \\
          -H 'content-type: application/json' \\
          --data-raw $'{"name":"O\\'Brien","tags":["a"]}' \\
          --compressed
        """
        let spec = try CurlParser.parse(command)
        #expect(spec.method == .post)
        #expect(spec.url == "https://api.example.com/v1/users?page=2")
        #expect(spec.params.map(\.key) == ["page"])
        #expect(spec.headers.map(\.key) == ["accept", "authorization", "content-type"])
        #expect(spec.body.mode == .raw)
        #expect(spec.body.rawLanguage == .json)
        #expect(spec.body.raw == #"{"name":"O'Brien","tags":["a"]}"#)
    }

    @Test func formUrlEncodedAndBasicAuth() throws {
        let spec = try CurlParser.parse(#"curl -X PUT -u admin:s3cr=t -d "a=1&b=hello%20world" --data-urlencode "c=x y" http://localhost:8080/login -L -k"#)
        #expect(spec.method == .put)
        #expect(spec.auth.type == .basic)
        #expect(spec.auth.basic.password == "s3cr=t")
        #expect(spec.body.mode == .urlEncoded)
        #expect(spec.body.urlEncoded.map(\.key) == ["a", "b", "c"])
        #expect(spec.body.urlEncoded.map(\.value) == ["1", "hello world", "x y"])
        #expect(spec.settings.followRedirects)
        #expect(!spec.settings.verifySSL)
    }

    @Test func multipartForm() throws {
        let spec = try CurlParser.parse("curl https://up.example.com -F 'meta=hello' -F 'file=@/tmp/a.png;type=image/png'")
        #expect(spec.method == .post)
        #expect(spec.body.mode == .formData)
        #expect(spec.body.formData[1].kind == .file)
        #expect(spec.body.formData[1].file?.path == "/tmp/a.png")
        #expect(spec.body.formData[1].contentType == "image/png")
    }

    @Test func getWithData() throws {
        let spec = try CurlParser.parse("curl -G https://x.test/search -d q=swift --data-urlencode 'lang=en us'")
        #expect(spec.method == .get)
        #expect(spec.url == "https://x.test/search?q=swift&lang=en%20us")
        #expect(spec.body.mode == .none)
    }

    @Test func attachedShortFlags() throws {
        let spec = try CurlParser.parse("curl -XDELETE -H'X-A: 1' http://h/r/1")
        #expect(spec.method == .delete)
        #expect(spec.headers.first?.value == "1")
    }

    @Test func errors() {
        #expect(throws: InteropError.self) { try CurlParser.parse("wget http://x") }
        #expect(throws: InteropError.self) { try CurlParser.parse("curl -H 'unterminated") }
        #expect(throws: InteropError.self) { try CurlParser.parse("curl -s") }
    }
}
