import Foundation
import APICore

/// Checks a real response against the operation it corresponds to in a spec.
public struct ContractValidator {
    public struct Result: Sendable {
        /// "METHOD /path/template" of the matched operation, nil when no operation matches.
        public var operation: String?
        public var issues: [String]

        public var passed: Bool { operation != nil && issues.isEmpty }
    }

    let document: SpecDocument

    public init(document: SpecDocument) {
        self.document = document
    }

    /// Finds the operation for a method + concrete URL (the server base path is stripped when present).
    public func operation(method: String, url: String) -> SpecDocument.Operation? {
        guard var path = URLComponents(string: url)?.path else { return nil }
        if let basePath = URLComponents(string: document.baseURL)?.path, !basePath.isEmpty, basePath != "/", path.hasPrefix(basePath) {
            path = String(path.dropFirst(basePath.count))
        }
        if path.isEmpty { path = "/" }
        let candidates = document.operations.filter { $0.method == method.lowercased() }
        // Prefer literal matches over templated ones (e.g. /pets/mine over /pets/{id}).
        return candidates
            .filter { Self.matches(template: $0.path, path: path) }
            .min { $0.path.filter { $0 == "{" }.count < $1.path.filter { $0 == "{" }.count }
    }

    static func matches(template: String, path: String) -> Bool {
        let templateSegments = template.split(separator: "/", omittingEmptySubsequences: true)
        let pathSegments = path.split(separator: "/", omittingEmptySubsequences: true)
        guard templateSegments.count == pathSegments.count else { return false }
        return zip(templateSegments, pathSegments).allSatisfy { template, actual in
            (template.hasPrefix("{") && template.hasSuffix("}")) || template == actual
        }
    }

    public func validate(method: String, url: String, response: ResponseSnapshot) -> Result {
        guard let operation = operation(method: method, url: url) else {
            return Result(operation: nil, issues: ["No operation in the spec matches \(method.uppercased()) \(URLComponents(string: url)?.path ?? url)"])
        }
        let label = "\(operation.method.uppercased()) \(operation.path)"
        var issues: [String] = []
        let responses = operation.node["responses"]
        let code = String(response.statusCode)
        let family = "\(code.prefix(1))XX"
        guard let entry = responses?[code] ?? responses?[family] ?? responses?[family.lowercased()] ?? responses?["default"],
              let responseSpec = document.resolve(entry) else {
            let documented = responses?.entries.map(\.key).joined(separator: ", ") ?? ""
            return Result(operation: label, issues: ["Status \(code) is not documented (documented: \(documented))"])
        }

        // Required headers (3.x).
        for header in responseSpec["headers"]?.entries ?? [] {
            let resolved = document.resolve(header.value)
            if resolved?["required"]?.bool == true, response.header(header.key) == nil {
                issues.append("Missing required response header `\(header.key)`")
            }
        }

        // Body.
        let contentType = response.contentType?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        var schema: SpecNode?
        if document.version == .swagger2 {
            schema = responseSpec["schema"]
        } else if let content = responseSpec["content"], !content.entries.isEmpty {
            let media = content[contentType] ?? content.entries.first { Self.mediaMatches($0.key, contentType) }?.value
            if media == nil {
                issues.append("Content-Type `\(contentType.isEmpty ? "none" : contentType)` is not documented (documented: \(content.entries.map(\.key).joined(separator: ", ")))")
            }
            schema = media?["schema"]
        }
        if let schema, contentType.contains("json") || contentType.isEmpty {
            if let body = try? JSONSerialization.jsonObject(with: response.body, options: [.fragmentsAllowed]) {
                issues += JSONSchemaValidator(document: document).validate(body, against: schema).map(\.description)
            } else if !response.body.isEmpty {
                issues.append("Response body is not valid JSON")
            }
        }
        return Result(operation: label, issues: issues)
    }

    static func mediaMatches(_ pattern: String, _ contentType: String) -> Bool {
        if pattern == "*/*" { return true }
        if pattern.hasSuffix("/*") { return contentType.hasPrefix(pattern.dropLast()) }
        return pattern.lowercased() == contentType
    }
}
