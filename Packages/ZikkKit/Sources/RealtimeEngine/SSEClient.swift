import Foundation

/// One server-sent event.
public struct ServerSentEvent: Sendable, Hashable, Identifiable {
    public let id = UUID()
    public var event: String
    public var data: String
    public var lastEventID: String?
    public var date: Date

    public init(event: String = "message", data: String, lastEventID: String? = nil, date: Date = Date()) {
        self.event = event
        self.data = data
        self.lastEventID = lastEventID
        self.date = date
    }
}

public enum SSEStatus: Sendable, Hashable {
    case connecting
    case open(statusCode: Int)
    case event(ServerSentEvent)
    case reconnecting(after: Duration)
    case closed(String?)
}

/// Incremental `text/event-stream` parser (WHATWG HTML spec semantics).
public struct SSEParser: Sendable {
    private var buffer = ""
    private var eventType = ""
    private var data: [String] = []
    public private(set) var lastEventID: String?
    public private(set) var retry: Int?

    public init(lastEventID: String? = nil) {
        self.lastEventID = lastEventID
    }

    /// Feeds one line (without the line terminator); returns an event when a blank line dispatches one.
    public mutating func feed(line: String) -> ServerSentEvent? {
        if line.isEmpty {
            defer { eventType = ""; data = [] }
            guard !data.isEmpty else { return nil }
            return ServerSentEvent(event: eventType.isEmpty ? "message" : eventType, data: data.joined(separator: "\n"), lastEventID: lastEventID)
        }
        if line.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": eventType = String(value)
        case "data": data.append(String(value))
        case "id" where !value.contains("\0"): lastEventID = String(value)
        case "retry": retry = Int(value)
        default: break
        }
        return nil
    }
}

/// Server-Sent Events client with automatic reconnection.
public struct SSEClient: Sendable {
    public var maxReconnects: Int
    public var defaultRetry: Duration

    public init(maxReconnects: Int = .max, defaultRetry: Duration = .seconds(3)) {
        self.maxReconnects = maxReconnects
        self.defaultRetry = defaultRetry
    }

    public func stream(_ request: URLRequest, autoReconnect: Bool) -> AsyncStream<SSEStatus> {
        let maxReconnects = autoReconnect ? maxReconnects : 0
        let defaultRetry = defaultRetry
        return AsyncStream { continuation in
            let task = Task {
                var lastEventID: String?
                var retry = defaultRetry
                var attempts = 0
                while !Task.isCancelled {
                    continuation.yield(.connecting)
                    var request = request
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                    if let lastEventID { request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID") }
                    request.timeoutInterval = 24 * 3600
                    var closeReason: String?
                    do {
                        let configuration = URLSessionConfiguration.ephemeral
                        configuration.timeoutIntervalForRequest = 24 * 3600
                        let session = URLSession(configuration: configuration)
                        defer { session.invalidateAndCancel() }
                        let (bytes, response) = try await session.bytes(for: request)
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        guard (200..<300).contains(status) else {
                            continuation.yield(.closed("HTTP \(status)"))
                            break
                        }
                        continuation.yield(.open(statusCode: status))
                        var parser = SSEParser(lastEventID: lastEventID)
                        for try await line in bytes.linesPreservingEmpty {
                            if let event = parser.feed(line: line) { continuation.yield(.event(event)) }
                            lastEventID = parser.lastEventID
                            if let ms = parser.retry { retry = .milliseconds(ms) }
                        }
                        _ = parser.feed(line: "")
                        closeReason = "Stream ended"
                    } catch is CancellationError {
                        break
                    } catch {
                        closeReason = error.localizedDescription
                    }
                    if Task.isCancelled { break }
                    attempts += 1
                    if attempts > maxReconnects {
                        continuation.yield(.closed(closeReason))
                        break
                    }
                    continuation.yield(.reconnecting(after: retry))
                    try? await Task.sleep(for: retry)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension URLSession.AsyncBytes {
    /// Lines split on CR, LF or CRLF, including empty lines (which `lines` drops but SSE needs).
    var linesPreservingEmpty: AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var buffer = [UInt8]()
                var previousWasCR = false
                do {
                    for try await byte in self {
                        if byte == 0x0A && previousWasCR { previousWasCR = false; continue }
                        previousWasCR = byte == 0x0D
                        if byte == 0x0A || byte == 0x0D {
                            continuation.yield(String(decoding: buffer, as: UTF8.self))
                            buffer.removeAll(keepingCapacity: true)
                        } else {
                            buffer.append(byte)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(String(decoding: buffer, as: UTF8.self)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
