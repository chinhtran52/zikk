import Foundation

/// Generates example values from JSON Schemas (used for request bodies, mock responses and docs).
public enum SchemaExample {
    public static func generate(_ schema: SpecNode?, in document: SpecDocument, depth: Int = 0) -> Any {
        guard depth < 8, let schema = document.resolve(schema) else { return NSNull() }
        if let example = schema["example"] { return example.foundation }
        if let examples = schema["examples"]?.items.first { return examples.foundation }
        if let value = schema["default"] { return value.foundation }
        if let value = schema["const"] { return value.foundation }
        if let first = schema["enum"]?.items.first { return first.foundation }
        if let allOf = schema["allOf"]?.items, !allOf.isEmpty {
            var merged: [String: Any] = [:]
            for part in allOf {
                if let object = generate(part, in: document, depth: depth + 1) as? [String: Any] { merged.merge(object) { a, _ in a } }
            }
            return merged
        }
        if let first = (schema["oneOf"] ?? schema["anyOf"])?.items.first { return generate(first, in: document, depth: depth + 1) }

        let type = schema["type"]?.string ?? schema["type"]?.items.compactMap(\.string).first { $0 != "null" }
            ?? (schema["properties"] != nil ? "object" : (schema["items"] != nil ? "array" : nil))
        switch type {
        case "object":
            var object: [String: Any] = [:]
            for property in schema["properties"]?.entries ?? [] {
                object[property.key] = generate(property.value, in: document, depth: depth + 1)
            }
            return object
        case "array":
            return [generate(schema["items"], in: document, depth: depth + 1)]
        case "integer":
            return Int(schema["minimum"]?.double ?? 0)
        case "number":
            return schema["minimum"]?.double ?? 0.0
        case "boolean":
            return true
        case "string":
            switch schema["format"]?.string {
            case "date-time": return "2024-01-01T00:00:00Z"
            case "date": return "2024-01-01"
            case "time": return "12:00:00"
            case "email": return "user@example.com"
            case "uuid": return "3fa85f64-5717-4562-b3fc-2c963f66afa6"
            case "uri", "url": return "https://example.com"
            case "hostname": return "example.com"
            case "ipv4": return "192.168.0.1"
            case "ipv6": return "::1"
            case "byte": return "U3dhZ2dlciByb2Nrcw=="
            case "binary": return "<binary>"
            case "password": return "********"
            default: return "string"
            }
        default:
            return NSNull()
        }
    }

    /// Pretty JSON text for an example value.
    public static func json(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value) || value is String || value is NSNumber || value is NSNull else { return "" }
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Example of a media type object: `example`, first of `examples`, or generated from `schema`.
    public static func example(forMediaType media: SpecNode?, in document: SpecDocument) -> Any? {
        guard let media else { return nil }
        if let example = media["example"] { return example.foundation }
        if let first = media["examples"]?.entries.first {
            let resolved = document.resolve(first.value)
            if let value = resolved?["value"] { return value.foundation }
        }
        if let schema = media["schema"] { return generate(schema, in: document) }
        return nil
    }
}
