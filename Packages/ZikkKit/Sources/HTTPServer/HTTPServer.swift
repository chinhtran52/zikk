import Foundation
import Network

/// Minimal HTTP/1.1 server on Network.framework, used by the mock server and by tests.
public final class HTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ServerRequest) async -> ServerResponse

    public enum State: Sendable, Equatable { case idle, starting, running(port: UInt16), failed(String), stopped }

    private let handler: Handler
    private let queue = DispatchQueue(label: "HTTPServer")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let lock = NSLock()
    private var _state: State = .idle

    public var state: State { lock.withLock { _state } }

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Starts listening. Pass port 0 to pick a free port. Returns the bound port.
    @discardableResult
    public func start(port: UInt16 = 0, loopbackOnly: Bool = true) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if loopbackOnly {
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        }
        let listener = try loopbackOnly ? NWListener(using: parameters) : NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? .any)
        self.listener = listener
        setState(.starting)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = Resumed()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    let bound = listener.port?.rawValue ?? port
                    self?.setState(.running(port: bound))
                    if resumed.claim() { continuation.resume(returning: bound) }
                case .failed(let error):
                    self?.setState(.failed(error.localizedDescription))
                    if resumed.claim() { continuation.resume(throwing: error) }
                case .cancelled:
                    self?.setState(.stopped)
                    if resumed.claim() { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        let open = lock.withLock { () -> [NWConnection] in
            let values = Array(connections.values)
            connections.removeAll()
            return values
        }
        open.forEach { $0.cancel() }
        setState(.stopped)
    }

    private func setState(_ state: State) { lock.withLock { _state = state } }

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        lock.withLock { connections[key] = connection }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                _ = self?.lock.withLock { self?.connections.removeValue(forKey: key) }
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, parser: RequestParser())
    }

    private func receive(on connection: NWConnection, parser: RequestParser) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var parser = parser
            if let data { parser.append(data) }
            do {
                if let request = try parser.next() {
                    Task {
                        let response = await self.handler(request)
                        let keepAlive = request.header("Connection")?.lowercased() != "close" && request.version == "HTTP/1.1"
                        connection.send(content: response.serialized(keepAlive: keepAlive), completion: .contentProcessed { _ in
                            if keepAlive { self.receive(on: connection, parser: parser) } else { connection.cancel() }
                        })
                    }
                    return
                }
            } catch {
                connection.send(content: ServerResponse(status: 400, text: "Bad Request").serialized(keepAlive: false), completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, parser: parser)
            }
        }
    }
}

/// One-shot flag guarding a continuation.
private final class Resumed: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
}
