import Testing
import Foundation
import Network
import APICore
import HTTPEngine
import HTTPServer
import APIStore
@testable import Features

final class WSEcho: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "features-ws-echo")
    private(set) var lastAuthorization: String?

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        let options = NWProtocolWebSocket.Options()
        options.setClientRequestHandler(queue) { [weak self] _, headers in
            self?.lastAuthorization = headers.first { $0.name.lowercased() == "authorization" }?.value
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            @Sendable func receive() {
                connection.receiveMessage { data, context, _, error in
                    guard error == nil, let data, let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
                          metadata.opcode != .close else { return }
                    let reply = NWProtocolWebSocket.Metadata(opcode: metadata.opcode)
                    connection.send(content: data, contentContext: .init(identifier: "r", metadata: [reply]), isComplete: true, completion: .contentProcessed { _ in })
                    receive()
                }
            }
            receive()
        }
        listener.start(queue: queue)
        for _ in 0..<100 where listener.port == nil || listener.port?.rawValue == 0 { try await Task.sleep(for: .milliseconds(10)) }
        return listener.port!.rawValue
    }

    func stop() { listener?.cancel() }
}

@MainActor
@Suite struct RealtimeFeatureTests {
    @Test func webSocketSessionWithAuthAndVariables() async throws {
        let server = WSEcho()
        let port = try await server.start()
        defer { server.stop() }
        var auth = AuthConfig(type: .bearer)
        auth.bearer.token = "{{token}}"
        let spec = RequestSpec(kind: .webSocket, url: "ws://127.0.0.1:{{port}}/ws", auth: auth)
        let builder = RequestBuilder(resolver: VariableResolver(scopes: [["port": "\(port)", "token": "abc"]]), auth: auth)
        let session = RealtimeSessionModel()
        session.connectWebSocket(spec, builder: builder)
        for _ in 0..<200 where !session.isConnected { try await Task.sleep(for: .milliseconds(10)) }
        #expect(session.isConnected)
        #expect(server.lastAuthorization == "Bearer abc")

        session.send(#"{"hello":1}"#, format: .json)
        session.send("AQID", format: .binaryBase64)
        session.send("not base64!", format: .binaryBase64)
        for _ in 0..<200 where session.log.filter({ $0.kind == .received }).count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        let received = session.log.filter { $0.kind == .received }
        #expect(received.first?.text == #"{"hello":1}"#)
        #expect(received.last?.isBinary == true)
        #expect(session.log.contains { $0.kind == .error })
        session.disconnect()
        #expect(session.status == .disconnected)
    }

    @Test func sseSessionReceivesEvents() async throws {
        let server = HTTPServer { _ in ServerResponse(status: 200, headers: [("Content-Type", "text/event-stream")], body: Data("event: tick\nid: 9\ndata: 1\n\n".utf8)) }
        let port = try await server.start()
        defer { server.stop() }
        var spec = RequestSpec(kind: .sse, url: "http://127.0.0.1:\(port)/stream")
        spec.realtime.autoReconnect = false
        let session = RealtimeSessionModel()
        session.connectSSE(spec, builder: RequestBuilder(resolver: VariableResolver(), auth: .none))
        for _ in 0..<200 where session.status != .disconnected || session.log.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
        let event = try #require(session.log.first { $0.kind == .received })
        #expect(event.title == "tick #9")
        #expect(event.text == "1")
    }

    @Test func templatesAndSendGuard() {
        #expect(RequestSpec.template(for: .graphQL).body.mode == .graphQL)
        #expect(RequestSpec.template(for: .graphQL).method == .post)
        let model = AppModel(services: AppServices(secrets: InMemorySecretStore()))
        model.newRequestTab(kind: .webSocket)
        let document = model.selectedTab?.request
        #expect(document?.spec.kind == RequestKind.webSocket)
        model.sendSelected()
        #expect(document?.isSending == false, "HTTP send is ignored for WebSocket tabs")
    }
}
