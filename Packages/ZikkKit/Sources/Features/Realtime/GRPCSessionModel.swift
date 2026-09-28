import Foundation
import Observation
import APICore
import GRPCEngine
import HTTPEngine
import ProtoKit

/// Schema loading and call state for a gRPC tab.
@MainActor
@Observable
final class GRPCSessionModel {
    struct Entry: Identifiable, Hashable {
        enum Kind: Hashable { case sent, received, headers, status }
        let id = UUID()
        let date: Date
        let kind: Kind
        let text: String
    }

    private(set) var schema: ProtoSchema?
    private(set) var schemaError: String?
    private(set) var isLoadingSchema = false
    private(set) var isCalling = false
    private(set) var entries: [Entry] = []
    private(set) var status: GRPCStatus?
    private(set) var duration: Double?
    private var task: Task<Void, Never>?

    /// Parses `.proto` source (synchronous) or loads via reflection.
    func loadSchema(from spec: RequestSpec, resolver: VariableResolver, metadata: [KeyValue]) {
        schemaError = nil
        if !spec.protoSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do { schema = try ProtoParser.parse(spec.protoSource) } catch { schema = nil; schemaError = error.localizedDescription }
            return
        }
        guard let target = GRPCTarget.parse(resolver.resolve(spec.url), verifyTLS: spec.settings.verifySSL) else {
            schemaError = GRPCClientError.invalidTarget(spec.url).localizedDescription
            return
        }
        isLoadingSchema = true
        let pairs = metadata.filter { $0.isEnabled && !$0.key.isEmpty }.map { ($0.key.lowercased(), resolver.resolve($0.value)) }
        Task {
            do {
                schema = try await ServerReflection(client: DynamicGRPCClient(target: target)).loadSchema(metadata: pairs)
            } catch {
                schemaError = error.localizedDescription
            }
            isLoadingSchema = false
        }
    }

    func method(for spec: RequestSpec) -> ProtoMethod? {
        schema?.method(spec.grpcMethod)?.1
    }

    /// Example request JSON for the selected method.
    func template(for spec: RequestSpec) -> String? {
        guard let schema, let method = method(for: spec) else { return nil }
        let single = ProtoCodec(schema: schema).templateJSON(for: method.inputType)
        return method.clientStreaming ? "[\n" + single + "\n]" : single
    }

    func invoke(_ spec: RequestSpec, resolver: VariableResolver, auth: AuthConfig, console: ConsoleStore, requestName: String) {
        guard let schema else { return }
        guard let target = GRPCTarget.parse(resolver.resolve(spec.url), verifyTLS: spec.settings.verifySSL) else {
            status = GRPCStatus(code: 3, message: GRPCClientError.invalidTarget(spec.url).localizedDescription)
            return
        }
        cancel()
        entries = []
        status = nil
        duration = nil
        isCalling = true

        // Messages: a JSON array for client/bidi streaming, otherwise one object.
        let body = resolver.resolve(spec.body.raw)
        var messages = [body]
        if method(for: spec)?.clientStreaming == true,
           let array = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [Any] {
            messages = array.map { String(decoding: (try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed])) ?? Data("{}".utf8), as: UTF8.self) }
        }
        var metadata = spec.headers.active.map { KeyValue(key: resolver.resolve($0.key), value: resolver.resolve($0.value)) }
        metadata += Self.authMetadata(auth, resolver: resolver)
        let timeout: Duration? = spec.settings.timeoutMilliseconds > 0 ? .milliseconds(spec.settings.timeoutMilliseconds) : nil
        let client = DynamicGRPCClient(target: target)
        let path = spec.grpcMethod
        let started = Date()
        task = Task {
            let final = await client.call(path, schema: schema, messages: messages, metadata: metadata, timeout: timeout) { event in
                await MainActor.run { self.record(event) }
            }
            self.duration = Date().timeIntervalSince(started) * 1000
            self.status = final
            self.isCalling = false
            console.record(requestName: requestName, method: "gRPC", url: "\(spec.url)/\(path)", response: nil,
                           error: final.isOK ? nil : "\(final.name): \(final.message)", logs: [])
        }
    }

    private func record(_ event: GRPCCallEvent) {
        switch event {
        case .sent(let json): entries.append(Entry(date: .now, kind: .sent, text: json))
        case .message(let json): entries.append(Entry(date: .now, kind: .received, text: json))
        case .headers(let headers) where !headers.isEmpty:
            entries.append(Entry(date: .now, kind: .headers, text: headers.map { "\($0.key): \($0.value)" }.joined(separator: "\n")))
        case .headers: break
        case .finished: break
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isCalling = false
    }

    /// Authorization metadata for bearer/basic/API-key auth.
    static func authMetadata(_ auth: AuthConfig, resolver: VariableResolver) -> [KeyValue] {
        let resolved = resolver.resolveStrings(in: auth)
        guard let prepared = try? RequestBuilder(resolver: VariableResolver(), auth: resolved).build(RequestSpec(url: "http://grpc.invalid")) else { return [] }
        var result: [KeyValue] = []
        if let authorization = prepared.urlRequest.value(forHTTPHeaderField: "Authorization") {
            result.append(KeyValue(key: "authorization", value: authorization))
        }
        if resolved.type == .apiKey, resolved.apiKey.location == .header, !resolved.apiKey.key.isEmpty {
            result.append(KeyValue(key: resolved.apiKey.key.lowercased(), value: resolved.apiKey.value))
        }
        return result
    }
}
