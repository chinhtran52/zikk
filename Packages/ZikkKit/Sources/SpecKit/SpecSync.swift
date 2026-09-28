import Foundation
import APICore
import Interop

/// Differences between a collection generated from a spec and an existing collection.
public enum SpecSync {
    public struct Change: Identifiable, Hashable, Sendable {
        public enum Kind: String, Hashable, Sendable { case added, removed, modified }
        public var id: String { "\(kind.rawValue):\(key)" }
        public var kind: Kind
        /// Endpoint key: `METHOD /path/{param}`.
        public var key: String
        public var name: String
        /// Folder (tag) the request belongs to in the spec.
        public var folder: String?
        public var details: [String]
        /// The request as generated from the spec (added/modified).
        public var request: InteropRequest?
    }

    /// Endpoint key of a request URL, e.g. `GET /pets/{id}`.
    /// `basePath` (the server URL path, like `/v1`) is stripped when the URL uses a literal host.
    public static func key(method: HTTPMethod, url: String, basePath: String = "") -> String {
        "\(method.rawValue) \(endpointPath(url, basePath: basePath))"
    }

    static func endpointPath(_ url: String, basePath: String) -> String {
        let path = OpenAPIExporter.openAPIPath(url)
        let base = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
        if !base.isEmpty, !url.hasPrefix("{{"), path.hasPrefix(base + "/") { return String(path.dropFirst(base.count)) }
        return path
    }

    /// Path component of the spec collection's `baseUrl` variable.
    public static func basePath(of spec: InteropCollection) -> String {
        let base = spec.variables.first { $0.key == OpenAPIImporter.baseURLVariable }?.value ?? ""
        return URLComponents(string: base)?.path ?? ""
    }

    public static func diff(spec: InteropCollection, collection: InteropCollection) -> [Change] {
        let basePath = basePath(of: spec)
        let specRequests = flatten(spec.items, folder: nil)
        let existing = Dictionary(flatten(collection.items, folder: nil).map { (key(method: $0.request.spec.method, url: $0.request.spec.url, basePath: basePath), $0) },
                                  uniquingKeysWith: { a, _ in a })
        var changes: [Change] = []
        var seen: Set<String> = []
        for (request, folder) in specRequests {
            let endpoint = key(method: request.spec.method, url: request.spec.url)
            seen.insert(endpoint)
            guard let current = existing[endpoint] else {
                changes.append(Change(kind: .added, key: endpoint, name: request.name, folder: folder, details: [], request: request))
                continue
            }
            let details = differences(from: current.request, to: request)
            if !details.isEmpty {
                changes.append(Change(kind: .modified, key: endpoint, name: current.request.name, folder: folder, details: details, request: request))
            }
        }
        for (endpoint, current) in existing where !seen.contains(endpoint) {
            changes.append(Change(kind: .removed, key: endpoint, name: current.request.name, folder: current.folder, details: [], request: nil))
        }
        return changes.sorted { ($0.kind.rawValue, $0.key) < ($1.kind.rawValue, $1.key) }
    }

    static func flatten(_ items: [InteropItem], folder: String?) -> [(request: InteropRequest, folder: String?)] {
        items.flatMap { item -> [(request: InteropRequest, folder: String?)] in
            switch item {
            case .folder(let child): flatten(child.items, folder: folder ?? child.name)
            case .request(let request): [(request, folder)]
            }
        }
    }

    static func differences(from current: InteropRequest, to target: InteropRequest) -> [String] {
        var details: [String] = []
        func compare(_ label: String, _ old: [String], _ new: [String]) {
            let added = new.filter { !old.contains($0) }
            let removed = old.filter { !new.contains($0) }
            guard !added.isEmpty || !removed.isEmpty else { return }
            details.append("\(label): " + (added.map { "+\($0)" } + removed.map { "−\($0)" }).joined(separator: " "))
        }
        compare("Query params", current.spec.params.map(\.key), target.spec.params.map(\.key))
        compare("Path variables", current.spec.pathVariables.map(\.key), target.spec.pathVariables.map(\.key))
        let ignoredHeaders: Set<String> = ["content-type", "authorization", "accept"]
        compare("Headers", current.spec.headers.map(\.key).filter { !ignoredHeaders.contains($0.lowercased()) },
                target.spec.headers.map(\.key).filter { !ignoredHeaders.contains($0.lowercased()) })
        if current.spec.body.mode != target.spec.body.mode {
            details.append("Body: \(current.spec.body.mode.rawValue) → \(target.spec.body.mode.rawValue)")
        } else if target.spec.body.mode == .urlEncoded || target.spec.body.mode == .formData {
            let oldKeys = target.spec.body.mode == .urlEncoded ? current.spec.body.urlEncoded.map(\.key) : current.spec.body.formData.map(\.key)
            let newKeys = target.spec.body.mode == .urlEncoded ? target.spec.body.urlEncoded.map(\.key) : target.spec.body.formData.map(\.key)
            compare("Body fields", oldKeys, newKeys)
        }
        if current.description != target.description, !target.description.isEmpty {
            details.append("Description updated")
        }
        return details
    }

    /// Updates `current` to match the spec's request while keeping user values, scripts and auth.
    public static func merge(_ current: RequestSpec, with target: RequestSpec, basePath: String = "") -> RequestSpec {
        var merged = current
        func mergeRows(_ old: [KeyValue], _ new: [KeyValue]) -> [KeyValue] {
            new.map { row in
                guard let existing = old.first(where: { $0.key == row.key }) else { return row }
                var kept = row
                kept.id = existing.id
                kept.value = existing.value.isEmpty ? row.value : existing.value
                kept.isEnabled = existing.isEnabled
                return kept
            }
        }
        merged.params = mergeRows(current.params, target.params)
        merged.pathVariables = mergeRows(current.pathVariables, target.pathVariables)
        let userHeaders = current.headers.filter { header in !target.headers.contains { $0.key.caseInsensitiveCompare(header.key) == .orderedSame } && header.key.caseInsensitiveCompare("Content-Type") != .orderedSame }
        merged.headers = mergeRows(current.headers, target.headers) + userHeaders.filter { ["authorization", "accept"].contains($0.key.lowercased()) }
        // Keep the user's host/base part; rebuild path + query from the spec.
        let currentBase = RawURL.split(current.url).base
        let targetBase = RawURL.split(target.url).base
        let currentEndpoint = endpointPath(current.url, basePath: basePath).replacing(/\{([^}]+)\}/) { ":" + $0.output.1 }
        let prefixEnd = currentBase.range(of: currentEndpoint, options: .backwards)?.lowerBound
        let prefix = prefixEnd.map { String(currentBase[..<$0]) } ?? String(targetBase.prefix { $0 != "/" })
        let targetPath = String(targetBase[(targetBase.range(of: "}}")?.upperBound ?? targetBase.startIndex)...])
        merged.url = RawURL.replacingQuery(of: prefix + targetPath, with: merged.params.filter(\.isEnabled))
        if current.body.mode != target.body.mode {
            merged.body = target.body
        } else if target.body.mode == .urlEncoded {
            merged.body.urlEncoded = mergeRows(current.body.urlEncoded, target.body.urlEncoded)
        } else if target.body.mode == .formData {
            merged.body.formData = target.body.formData.map { field in current.body.formData.first { $0.key == field.key } ?? field }
        }
        return merged
    }
}
