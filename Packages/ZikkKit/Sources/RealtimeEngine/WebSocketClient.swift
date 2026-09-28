import Foundation

public enum RealtimeDirection: String, Sendable, Hashable { case sent, received }

public enum WebSocketEvent: Sendable, Hashable {
    case connected(subprotocol: String?)
    case message(RealtimeMessage)
    case disconnected(code: Int, reason: String?)
    case failed(String)
}

public struct RealtimeMessage: Sendable, Hashable, Identifiable {
    public enum Payload: Sendable, Hashable {
        case text(String)
        case binary(Data)
    }
    public let id = UUID()
    public var direction: RealtimeDirection
    public var payload: Payload
    public var date: Date

    public init(direction: RealtimeDirection, payload: Payload, date: Date = Date()) {
        self.direction = direction
        self.payload = payload
        self.date = date
    }

    public var text: String {
        switch payload {
        case .text(let text): text
        case .binary(let data): String(data: data, encoding: .utf8) ?? data.base64EncodedString()
        }
    }

    public var size: Int {
        switch payload {
        case .text(let text): text.utf8.count
        case .binary(let data): data.count
        }
    }
}

/// A WebSocket connection based on `URLSessionWebSocketTask`, exposing events as an async stream.
public final class WebSocketClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    public let events: AsyncStream<WebSocketEvent>
    private let continuation: AsyncStream<WebSocketEvent>.Continuation
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var pingTask: Task<Void, Never>?
    private let lock = NSLock()
    private var finished = false

    public override init() {
        (events, continuation) = AsyncStream.makeStream(of: WebSocketEvent.self, bufferingPolicy: .unbounded)
        super.init()
    }

    /// Opens the connection. Events (including failures) are delivered on `events`.
    public func connect(url: URL, headers: [(String, String)], subprotocols: [String], pingInterval: Int = 0) {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.addValue(value, forHTTPHeaderField: name) }
        if !subprotocols.isEmpty { request.setValue(subprotocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        lock.withLock {
            self.session = session
            self.task = task
        }
        task.resume()
        receive()
        if pingInterval > 0 {
            pingTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(pingInterval))
                    self?.task?.sendPing { _ in }
                }
            }
        }
    }

    public func send(_ payload: RealtimeMessage.Payload) async throws {
        guard let task = lock.withLock({ task }) else { throw URLError(.notConnectedToInternet) }
        switch payload {
        case .text(let text): try await task.send(.string(text))
        case .binary(let data): try await task.send(.data(data))
        }
        continuation.yield(.message(RealtimeMessage(direction: .sent, payload: payload)))
    }

    public func disconnect(code: URLSessionWebSocketTask.CloseCode = .normalClosure, reason: String? = nil) {
        lock.withLock { task }?.cancel(with: code, reason: reason.map { Data($0.utf8) })
    }

    private func receive() {
        lock.withLock { task }?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                self.continuation.yield(.message(RealtimeMessage(direction: .received, payload: .text(text))))
                self.receive()
            case .success(.data(let data)):
                self.continuation.yield(.message(RealtimeMessage(direction: .received, payload: .binary(data))))
                self.receive()
            case .success:
                self.receive()
            case .failure(let error):
                let code = self.lock.withLock { self.task?.closeCode.rawValue } ?? 0
                if code != 0 {
                    self.finish(.disconnected(code: code, reason: self.lock.withLock { self.task?.closeReason }.flatMap { String(data: $0, encoding: .utf8) }))
                } else {
                    self.finish(.failed(error.localizedDescription))
                }
            }
        }
    }

    private func finish(_ event: WebSocketEvent) {
        let alreadyFinished = lock.withLock { () -> Bool in
            defer { finished = true }
            return finished
        }
        guard !alreadyFinished else { return }
        pingTask?.cancel()
        continuation.yield(event)
        continuation.finish()
        lock.withLock { session }?.invalidateAndCancel()
    }

    // MARK: URLSessionWebSocketDelegate

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        continuation.yield(.connected(subprotocol: `protocol`))
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish(.disconnected(code: closeCode.rawValue, reason: reason.flatMap { String(data: $0, encoding: .utf8) }))
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failed(error.localizedDescription))
        } else {
            finish(.disconnected(code: URLSessionWebSocketTask.CloseCode.normalClosure.rawValue, reason: nil))
        }
    }
}
