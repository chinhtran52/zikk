import Testing
import Foundation
import Network
import HTTPServer
@testable import RealtimeEngine

@Suite struct SSEParserTests {
    @Test func parsesEventsPerSpec() {
        var parser = SSEParser()
        var events: [ServerSentEvent] = []
        for line in [": comment", "event: update", "id: 7", "data: line1", "data:line2", "retry: 1500", "", "data: plain", "", "", "id"] {
            if let event = parser.feed(line: line) { events.append(event) }
        }
        #expect(events.map(\.event) == ["update", "message"])
        #expect(events.map(\.data) == ["line1\nline2", "plain"])
        #expect(events.first?.lastEventID == "7")
        #expect(parser.retry == 1500)
        #expect(parser.lastEventID == "", "empty id field resets the last event id")
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String?] = []
    func record(_ value: String?) { lock.withLock { values.append(value) } }
    var all: [String?] { lock.withLock { values } }
}

@Suite struct SSEClientTests {
    @Test func streamsAndReconnectsWithLastEventID() async throws {
        let seen = Counter()
        let server = HTTPServer { request in
            seen.record(request.header("Last-Event-ID"))
            let body = seen.all.count == 1 ? "retry: 10\r\nid: 1\r\ndata: first\r\n\r\n" : "id: 2\ndata: second\n\n"
            return ServerResponse(status: 200, headers: [("Content-Type", "text/event-stream")], body: Data(body.utf8))
        }
        let port = try await server.start()
        defer { server.stop() }

        var received: [String] = []
        var statuses: [String] = []
        let stream = SSEClient(maxReconnects: 1).stream(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/events")!), autoReconnect: true)
        for await status in stream {
            switch status {
            case .event(let event): received.append(event.data)
            case .open: statuses.append("open")
            case .reconnecting: statuses.append("reconnecting")
            case .closed: statuses.append("closed")
            case .connecting: break
            }
        }
        #expect(received == ["first", "second"])
        #expect(statuses == ["open", "reconnecting", "open", "closed"])
        #expect(seen.all == [nil, "1"])
    }

    @Test func httpErrorsClose() async throws {
        let server = HTTPServer { _ in ServerResponse(status: 503, text: "down") }
        let port = try await server.start()
        defer { server.stop() }
        var last: SSEStatus?
        for await status in SSEClient().stream(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!), autoReconnect: false) { last = status }
        #expect(last == .closed("HTTP 503"))
    }
}

/// Minimal WebSocket echo server on Network.framework.
final class EchoWebSocketServer: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "echo-ws")

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.setClientRequestHandler(queue) { subprotocols, _ in
            NWProtocolWebSocket.Response(status: .accept, subprotocol: subprotocols.contains("chat") ? "chat" : nil)
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self!.queue)
            self?.receive(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { continuation.resume(returning: listener.port!.rawValue) }
                case .failed(let error): if once.claim() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard error == nil, let data, let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata else { return }
            if metadata.opcode == .close { connection.cancel(); return }
            let text = String(decoding: data, as: UTF8.self)
            let reply = metadata.opcode == .text ? Data(("echo:" + text).utf8) : data
            let replyMetadata = NWProtocolWebSocket.Metadata(opcode: metadata.opcode)
            if text == "close-me" {
                let close = NWProtocolWebSocket.Metadata(opcode: .close)
                close.closeCode = .protocolCode(.goingAway)
                connection.send(content: nil, contentContext: NWConnection.ContentContext(identifier: "close", metadata: [close]), isComplete: true, completion: .contentProcessed { _ in })
                return
            }
            connection.send(content: reply, contentContext: NWConnection.ContentContext(identifier: "reply", metadata: [replyMetadata]), isComplete: true, completion: .contentProcessed { _ in })
            self?.receive(connection)
        }
    }

    func stop() { listener?.cancel() }
}

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
}

@Suite struct WebSocketClientTests {
    @Test func echoAndServerClose() async throws {
        let server = EchoWebSocketServer()
        let port = try await server.start()
        defer { server.stop() }
        let client = WebSocketClient()
        client.connect(url: URL(string: "ws://127.0.0.1:\(port)/socket")!, headers: [("X-Test", "1")], subprotocols: ["chat"])
        var log: [String] = []
        for await event in client.events {
            switch event {
            case .connected(let subprotocol):
                log.append("connected:\(subprotocol ?? "-")")
                try await client.send(.text("hello"))
                try await client.send(.binary(Data([1, 2, 3])))
            case .message(let message):
                log.append("\(message.direction.rawValue):\(message.payload == .binary(Data([1, 2, 3])) ? "bin" : message.text)")
                if message.direction == .received, message.text == "echo:hello" { continue }
                if message.direction == .received { try await client.send(.text("close-me")) }
            case .disconnected(let code, _):
                log.append("closed:\(code)")
            case .failed(let error):
                log.append("failed:\(error)")
            }
        }
        #expect(log == ["connected:chat", "sent:hello", "sent:bin", "received:echo:hello", "received:bin", "sent:close-me", "closed:1001"])
    }
}

@Suite struct GraphQLSchemaTests {
    @Test func parsesIntrospection() throws {
        let json = """
        {"data":{"__schema":{"queryType":{"name":"Query"},"mutationType":null,"subscriptionType":null,"types":[
          {"kind":"OBJECT","name":"Query","fields":[{"name":"user","description":"Find a user","isDeprecated":false,
            "args":[{"name":"id","type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"SCALAR","name":"ID","ofType":null}}}],
            "type":{"kind":"OBJECT","name":"User","ofType":null}}],"inputFields":null,"enumValues":null},
          {"kind":"OBJECT","name":"User","fields":[
            {"name":"id","isDeprecated":false,"args":[],"type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"SCALAR","name":"ID","ofType":null}}},
            {"name":"friends","isDeprecated":false,"args":[],"type":{"kind":"LIST","name":null,"ofType":{"kind":"NON_NULL","name":null,"ofType":{"kind":"OBJECT","name":"User","ofType":null}}}}],
            "inputFields":null,"enumValues":null},
          {"kind":"SCALAR","name":"ID","fields":null},
          {"kind":"OBJECT","name":"__Type","fields":[]}
        ]}}}
        """
        let schema = try GraphQLSchema.parse(Data(json.utf8))
        #expect(schema.queryType == "Query")
        #expect(schema.visibleTypes.map(\.name) == ["ID", "Query", "User"])
        let user = try #require(schema.type(named: "Query")?.fields.first)
        #expect(user.arguments.first?.type.display == "ID!")
        #expect(schema.type(named: "User")?.fields[1].type.display == "[User!]")
        #expect(schema.sampleOperation(for: user, operation: "query") == "query($id: ID!) {\n  user(id: $id) {\n    id\n  }\n}\n")
        #expect(throws: GraphQLSchema.ParseError.self) { try GraphQLSchema.parse(Data(#"{"errors":[{"message":"introspection disabled"}]}"#.utf8)) }
    }
}
