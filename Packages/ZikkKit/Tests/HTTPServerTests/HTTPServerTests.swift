import Testing
import Foundation
@testable import HTTPServer

@Suite struct HTTPServerTests {
    @Test func parsesContentLengthAndPipelinedRequests() throws {
        var parser = RequestParser()
        parser.append(Data("POST /a?x=1 HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\n\r\nabcGET /b HTTP/1.1\r\n\r\n".utf8))
        let first = try #require(try parser.next())
        #expect(first.method == "POST")
        #expect(first.path == "/a")
        #expect(first.query == "x=1")
        #expect(String(data: first.body, encoding: .utf8) == "abc")
        let second = try #require(try parser.next())
        #expect(second.target == "/b")
        #expect(try parser.next() == nil)
    }

    @Test func parsesChunkedBody() throws {
        var parser = RequestParser()
        parser.append(Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n".utf8))
        #expect(try parser.next() == nil)
        parser.append(Data("0\r\n\r\n".utf8))
        let request = try #require(try parser.next())
        #expect(String(data: request.body, encoding: .utf8) == "abcde")
    }

    @Test func servesRequests() async throws {
        let server = HTTPServer { request in
            ServerResponse(text: "\(request.method) \(request.path) \(request.body.count)")
        }
        let port = try await server.start()
        defer { server.stop() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/hello")!)
        request.httpMethod = "PUT"
        request.httpBody = Data("12345".utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: data, encoding: .utf8) == "PUT /hello 5")
        // Keep-alive: a second request on the same session succeeds.
        let (again, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/x")!)
        #expect(String(data: again, encoding: .utf8) == "GET /x 0")
    }
}
