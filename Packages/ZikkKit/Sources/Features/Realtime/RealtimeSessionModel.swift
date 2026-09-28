import Foundation
import Observation
import APICore
import HTTPEngine
import RealtimeEngine

/// Connection state and message log for a WebSocket or SSE tab.
@MainActor
@Observable
final class RealtimeSessionModel {
    enum Status: Equatable { case disconnected, connecting, connected, reconnecting }

    struct LogItem: Identifiable, Hashable {
        enum Kind: Hashable { case sent, received, info, error }
        let id = UUID()
        let date: Date
        let kind: Kind
        /// SSE event name.
        var title: String?
        let text: String
        let size: Int
        let isBinary: Bool
    }

    private(set) var status: Status = .disconnected
    private(set) var log: [LogItem] = []
    private var webSocket: WebSocketClient?
    private var task: Task<Void, Never>?
    static let logLimit = 5000

    var isConnected: Bool { status == .connected }
    var isActive: Bool { status != .disconnected }

    // MARK: WebSocket

    func connectWebSocket(_ spec: RequestSpec, builder: RequestBuilder) {
        disconnect()
        let prepared: PreparedRequest
        do {
            var httpSpec = spec
            httpSpec.body = RequestBody()
            prepared = try builder.build(httpSpec)
        } catch {
            append(.error, error.localizedDescription)
            return
        }
        guard var components = URLComponents(url: prepared.url, resolvingAgainstBaseURL: false) else { return }
        if components.scheme == "http" { components.scheme = "ws" } else if components.scheme == "https" { components.scheme = "wss" }
        guard let url = components.url else { return }
        let headers = (prepared.urlRequest.allHTTPHeaderFields ?? [:]).filter { !["accept", "user-agent"].contains($0.key.lowercased()) }.map { ($0.key, $0.value) }
        let client = WebSocketClient()
        webSocket = client
        status = .connecting
        append(.info, String(format: L("Connecting to %@"), url.absoluteString))
        client.connect(url: url, headers: headers, subprotocols: spec.realtime.subprotocols, pingInterval: spec.realtime.pingInterval)
        task = Task { [weak self] in
            for await event in client.events {
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: WebSocketEvent) {
        switch event {
        case .connected(let subprotocol):
            status = .connected
            append(.info, subprotocol.map { String(format: L("Connected (subprotocol: %@)"), $0) } ?? L("Connected"))
        case .message(let message):
            let isBinary = if case .binary = message.payload { true } else { false }
            append(message.direction == .sent ? .sent : .received, message.text, size: message.size, isBinary: isBinary)
        case .disconnected(let code, let reason):
            status = .disconnected
            append(.info, String(format: L("Disconnected (code %lld)"), code) + (reason.map { ": \($0)" } ?? ""))
        case .failed(let error):
            status = .disconnected
            append(.error, error)
        }
    }

    func send(_ text: String, format: SavedMessage.Format) {
        guard let webSocket else { return }
        let payload: RealtimeMessage.Payload
        switch format {
        case .text, .json: payload = .text(text)
        case .binaryBase64:
            guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                append(.error, L("The message is not valid Base64."))
                return
            }
            payload = .binary(data)
        }
        Task {
            do { try await webSocket.send(payload) } catch { append(.error, error.localizedDescription) }
        }
    }

    // MARK: SSE

    func connectSSE(_ spec: RequestSpec, builder: RequestBuilder) {
        disconnect()
        let prepared: PreparedRequest
        do { prepared = try builder.build(spec) } catch {
            append(.error, error.localizedDescription)
            return
        }
        status = .connecting
        append(.info, String(format: L("Connecting to %@"), prepared.url.absoluteString))
        let stream = SSEClient().stream(prepared.urlRequest, autoReconnect: spec.realtime.autoReconnect)
        task = Task { [weak self] in
            for await update in stream {
                guard let self else { return }
                switch update {
                case .connecting:
                    break
                case .open(let code):
                    self.status = .connected
                    self.append(.info, String(format: L("Connected (HTTP %lld)"), code))
                case .event(let event):
                    self.append(.received, event.data, title: event.event + (event.lastEventID.map { " #\($0)" } ?? ""))
                case .reconnecting(let delay):
                    self.status = .reconnecting
                    self.append(.info, String(format: L("Reconnecting in %@"), delay.formatted()))
                case .closed(let reason):
                    self.status = .disconnected
                    self.append(.info, L("Disconnected") + (reason.map { ": \($0)" } ?? ""))
                }
            }
            if self?.status != .disconnected { self?.status = .disconnected }
        }
    }

    // MARK: Common

    func disconnect() {
        webSocket?.disconnect()
        webSocket = nil
        task?.cancel()
        task = nil
        if status != .disconnected {
            status = .disconnected
            append(.info, L("Disconnected"))
        }
    }

    func clear() { log.removeAll() }

    private func append(_ kind: LogItem.Kind, _ text: String, title: String? = nil, size: Int? = nil, isBinary: Bool = false) {
        log.append(LogItem(date: .now, kind: kind, title: title, text: text, size: size ?? text.utf8.count, isBinary: isBinary))
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }
}
