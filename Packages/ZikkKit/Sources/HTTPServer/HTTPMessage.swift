import Foundation

public struct ServerRequest: Sendable {
    public var method: String
    /// Request target as sent (path + optional query).
    public var target: String
    public var version: String
    public var headers: [(name: String, value: String)]
    public var body: Data

    public init(method: String, target: String, version: String = "HTTP/1.1", headers: [(name: String, value: String)] = [], body: Data = Data()) {
        self.method = method
        self.target = target
        self.version = version
        self.headers = headers
        self.body = body
    }

    public var path: String { String(target.split(separator: "?", maxSplits: 1).first ?? "") }

    public var query: String? {
        let parts = target.split(separator: "?", maxSplits: 1)
        return parts.count > 1 ? String(parts[1]) : nil
    }

    public var queryItems: [URLQueryItem] {
        URLComponents(string: "http://x" + target)?.queryItems ?? []
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public struct ServerResponse: Sendable {
    public var status: Int
    public var headers: [(name: String, value: String)]
    public var body: Data

    public init(status: Int = 200, headers: [(name: String, value: String)] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public init(status: Int = 200, text: String, contentType: String = "text/plain; charset=utf-8") {
        self.init(status: status, headers: [("Content-Type", contentType)], body: Data(text.utf8))
    }

    public static func json(_ object: Any, status: Int = 200) -> ServerResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return ServerResponse(status: status, headers: [("Content-Type", "application/json")], body: data)
    }

    func serialized(keepAlive: Bool) -> Data {
        var head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)\r\n"
        var hasLength = false
        for (name, value) in headers {
            if name.caseInsensitiveCompare("Content-Length") == .orderedSame { hasLength = true }
            if name.caseInsensitiveCompare("Connection") == .orderedSame { continue }
            head += "\(name): \(value)\r\n"
        }
        if !hasLength { head += "Content-Length: \(body.count)\r\n" }
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// Incremental HTTP/1.1 request parser (Content-Length and chunked bodies).
struct RequestParser {
    private var buffer = Data()
    static let maxHeaderSize = 64 * 1024

    enum ParseError: Error { case malformed, headerTooLarge }

    mutating func append(_ data: Data) { buffer.append(data) }

    /// Returns the next complete request, or nil if more data is needed.
    mutating func next() throws -> ServerRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.firstRange(of: separator) else {
            if buffer.count > Self.maxHeaderSize { throw ParseError.headerTooLarge }
            return nil
        }
        guard let headText = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else { throw ParseError.malformed }
        var lines = headText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3 else { throw ParseError.malformed }
        let headers: [(name: String, value: String)] = lines.compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        func header(_ name: String) -> String? { headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value }

        let bodyStart = headerEnd.upperBound
        var body = Data()
        var consumedUpTo = bodyStart
        if header("Transfer-Encoding")?.lowercased().contains("chunked") == true {
            guard let (decoded, end) = try Self.decodeChunked(buffer, from: bodyStart) else { return nil }
            body = decoded
            consumedUpTo = end
        } else if let length = header("Content-Length").flatMap(Int.init), length > 0 {
            guard buffer.endIndex - bodyStart >= length else { return nil }
            body = buffer[bodyStart..<bodyStart + length]
            consumedUpTo = bodyStart + length
        }
        let request = ServerRequest(method: String(requestLine[0]), target: String(requestLine[1]), version: String(requestLine[2]), headers: headers, body: Data(body))
        buffer = Data(buffer[consumedUpTo...])
        return request
    }

    private static func decodeChunked(_ data: Data, from start: Data.Index) throws -> (Data, Data.Index)? {
        var index = start
        var result = Data()
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = data[index...].firstRange(of: crlf) else { return nil }
            guard let sizeText = String(data: data[index..<lineEnd.lowerBound], encoding: .ascii),
                  let size = Int(sizeText.split(separator: ";").first ?? "", radix: 16) else { throw ParseError.malformed }
            index = lineEnd.upperBound
            if size == 0 {
                // Skip optional trailers until the terminating blank line.
                guard let end = data[index...].firstRange(of: crlf) else { return nil }
                if end.lowerBound == index { return (result, end.upperBound) }
                guard let trailersEnd = data[index...].firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
                return (result, trailersEnd.upperBound)
            }
            guard data.endIndex - index >= size + 2 else { return nil }
            result.append(data[index..<index + size])
            index += size + 2
        }
    }
}
