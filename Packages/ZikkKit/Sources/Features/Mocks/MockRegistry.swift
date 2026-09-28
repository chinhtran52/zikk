import Foundation
import Observation
import SwiftData
import APICore
import APIStore
import HTTPServer
import Interop
import MockServer
import SpecKit

/// Running mock servers, shared by all windows.
@MainActor
@Observable
public final class MockRegistry {
    struct Running {
        let instance: MockServerInstance
        let port: UInt16
    }

    private(set) var running: [UUID: Running] = [:]
    private(set) var logs: [UUID: [MockLogEntry]] = [:]
    private(set) var errors: [UUID: String] = [:]
    /// Workspace/context each running mock reads its routes from (kept on the main actor).
    private var sources: [UUID: (workspace: Workspace, context: ModelContext)] = [:]
    static let logLimit = 500

    public init() {}

    func isRunning(_ id: UUID) -> Bool { running[id] != nil }
    func port(of id: UUID) -> UInt16? { running[id]?.port }

    func url(of mock: MockDefinition) -> String? {
        port(of: mock.id).map { "http://127.0.0.1:\($0)" }
    }

    func start(_ mock: MockDefinition, workspace: Workspace, context: ModelContext) async {
        guard running[mock.id] == nil else { return }
        let id = mock.id
        errors[id] = nil
        sources[id] = (workspace, context)
        // Routes are rebuilt for every request so edits to examples apply immediately.
        let instance = MockServerInstance(provider: { [weak self] in
            await MainActor.run { self?.responder(for: id) ?? MockResponder(routes: []) }
        }, onLog: { [weak self] entry in
            await MainActor.run { self?.append(entry, to: id) }
        })
        do {
            let port = try await instance.start(port: UInt16(clamping: mock.port))
            running[id] = Running(instance: instance, port: port)
        } catch {
            errors[id] = error.localizedDescription
            sources[id] = nil
        }
    }

    func stop(_ id: UUID) {
        running[id]?.instance.stop()
        running[id] = nil
        sources[id] = nil
    }

    func stopAll() {
        for id in running.keys { stop(id) }
    }

    func clearLog(_ id: UUID) { logs[id] = [] }

    private func append(_ entry: MockLogEntry, to id: UUID) {
        var entries = logs[id] ?? []
        entries.append(entry)
        if entries.count > Self.logLimit { entries.removeFirst(entries.count - Self.logLimit) }
        logs[id] = entries
    }

    func responder(for id: UUID) -> MockResponder? {
        guard let workspace = sources[id]?.workspace, let mock = workspace.mocks.first(where: { $0.id == id }) else { return nil }
        let options = MockOptions(delay: .milliseconds(mock.defaultDelayMilliseconds), matchHeaders: mock.matchHeaders, matchBody: mock.matchBody)
        let environment = mock.environmentID.flatMap { envID in workspace.environments.first { $0.id == envID } }
        let variables = environment?.variables.asDictionary ?? [:]
        return MockResponder(routes: Self.routes(for: mock, workspace: workspace), options: options, variables: variables)
    }

    /// Routes from the mock's collection (saved examples) or spec (generated examples).
    static func routes(for mock: MockDefinition, workspace: Workspace) -> [MockRoute] {
        if let specID = mock.specID, let spec = workspace.specs.first(where: { $0.id == specID }), let document = try? SpecDocument(text: spec.content) {
            return OpenAPIImporter.collection(from: document).allRequests.map { route(for: $0) }
        }
        guard let collectionID = mock.collectionID, let collection = workspace.collections.first(where: { $0.id == collectionID }) else { return [] }
        return collection.nodes.filter { !$0.isFolder && $0.deletedAt == nil }.compactMap { node in
            let examples = node.examples.filter { $0.deletedAt == nil }.sorted { $0.createdAt < $1.createdAt }
            guard !examples.isEmpty else { return nil }
            let spec = node.request
            return MockRoute(method: spec.method.rawValue, url: spec.url, name: node.name, examples: examples.map { example in
                let response = example.response
                return MockExample(name: example.name, statusCode: response.statusCode, headers: response.headers, body: response.body, request: example.request)
            })
        }
    }

    static func route(for request: InteropRequest) -> MockRoute {
        MockRoute(method: request.spec.method.rawValue, url: request.spec.url, name: request.name, examples: request.examples.map {
            MockExample(name: $0.name, statusCode: $0.response.statusCode, headers: $0.response.headers, body: $0.response.body, request: $0.request)
        })
    }
}
