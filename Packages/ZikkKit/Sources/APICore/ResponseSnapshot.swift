import Foundation

/// Timing breakdown in milliseconds, derived from `URLSessionTaskMetrics`.
public struct ResponseTimings: Codable, Hashable, Sendable {
    public var dns: Double?
    public var connect: Double?
    public var tls: Double?
    public var request: Double?
    public var firstByte: Double?
    public var download: Double?
    public var total: Double

    public init(dns: Double? = nil, connect: Double? = nil, tls: Double? = nil, request: Double? = nil, firstByte: Double? = nil, download: Double? = nil, total: Double = 0) {
        self.dns = dns
        self.connect = connect
        self.tls = tls
        self.request = request
        self.firstByte = firstByte
        self.download = download
        self.total = total
    }
}

/// The request as actually sent on the wire (after auth, cookies and redirects).
public struct SentRequest: Codable, Hashable, Sendable {
    public var method: String
    public var url: String
    public var headers: [KeyValue]
    public var bodySize: Int

    public init(method: String, url: String, headers: [KeyValue], bodySize: Int) {
        self.method = method
        self.url = url
        self.headers = headers
        self.bodySize = bodySize
    }
}

/// A received response, serializable for history and saved examples.
public struct ResponseSnapshot: Codable, Hashable, Sendable {
    public var statusCode: Int
    public var headers: [KeyValue]
    public var body: Data
    public var url: String
    public var httpVersion: String
    public var timings: ResponseTimings
    public var receivedAt: Date
    public var sentRequest: SentRequest?

    public init(statusCode: Int, headers: [KeyValue] = [], body: Data = Data(), url: String = "", httpVersion: String = "", timings: ResponseTimings = ResponseTimings(), receivedAt: Date = Date(), sentRequest: SentRequest? = nil) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.url = url
        self.httpVersion = httpVersion
        self.timings = timings
        self.receivedAt = receivedAt
        self.sentRequest = sentRequest
    }

    public var statusText: String { HTTPURLResponse.localizedString(forStatusCode: statusCode).capitalized }
    public var isSuccess: Bool { (200..<300).contains(statusCode) }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public var contentType: String? { header("Content-Type") }
    public var bodyText: String? { String(data: body, encoding: .utf8) }

    /// Approximate size on the wire: status line + headers + body.
    public var size: Int {
        body.count + headers.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count + 4 } + 17
    }
}
