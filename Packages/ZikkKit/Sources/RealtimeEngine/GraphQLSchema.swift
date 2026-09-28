import Foundation

/// Simplified GraphQL schema from an introspection result.
public struct GraphQLSchema: Sendable, Hashable {
    public struct TypeRef: Sendable, Hashable {
        public var kind: String
        public var name: String?
        public indirect enum Wrapped: Sendable, Hashable { case none, some(TypeRef) }
        public var ofType: Wrapped

        /// SDL notation, e.g. `[User!]!`.
        public var display: String {
            switch kind {
            case "NON_NULL": if case .some(let inner) = ofType { return inner.display + "!" }
            case "LIST": if case .some(let inner) = ofType { return "[" + inner.display + "]" }
            default: break
            }
            return name ?? "?"
        }

        /// Innermost named type.
        public var namedType: String? {
            if let name { return name }
            if case .some(let inner) = ofType { return inner.namedType }
            return nil
        }
    }

    public struct Argument: Sendable, Hashable {
        public var name: String
        public var type: TypeRef
        public var description: String?
    }

    public struct Field: Sendable, Hashable, Identifiable {
        public var id: String { name }
        public var name: String
        public var type: TypeRef
        public var arguments: [Argument]
        public var description: String?
        public var isDeprecated: Bool
    }

    public struct NamedType: Sendable, Hashable, Identifiable {
        public var id: String { name }
        public var kind: String
        public var name: String
        public var description: String?
        public var fields: [Field]
        public var inputFields: [Argument]
        public var enumValues: [String]
    }

    public var queryType: String?
    public var mutationType: String?
    public var subscriptionType: String?
    public var types: [NamedType]

    public func type(named name: String?) -> NamedType? {
        guard let name else { return nil }
        return types.first { $0.name == name }
    }

    /// User-defined types (introspection types starting with `__` are hidden).
    public var visibleTypes: [NamedType] {
        types.filter { !$0.name.hasPrefix("__") }.sorted { $0.name < $1.name }
    }

    public static let introspectionQuery = """
    query IntrospectionQuery {
      __schema {
        queryType { name }
        mutationType { name }
        subscriptionType { name }
        types {
          kind name description
          fields(includeDeprecated: true) { name description isDeprecated args { name description type { ...TypeRef } } type { ...TypeRef } }
          inputFields { name description type { ...TypeRef } }
          enumValues(includeDeprecated: true) { name }
        }
      }
    }
    fragment TypeRef on __Type {
      kind name
      ofType { kind name ofType { kind name ofType { kind name ofType { kind name ofType { kind name } } } } }
    }
    """

    public enum ParseError: LocalizedError {
        case invalid(String)
        public var errorDescription: String? {
            switch self { case .invalid(let message): "Invalid introspection response: \(message)" }
        }
    }

    public static func parse(_ data: Data) throws -> GraphQLSchema {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ParseError.invalid("not JSON") }
        if let errors = root["errors"] as? [[String: Any]], root["data"] == nil {
            throw ParseError.invalid(errors.compactMap { $0["message"] as? String }.joined(separator: "; "))
        }
        guard let schema = (root["data"] as? [String: Any])?["__schema"] as? [String: Any] else { throw ParseError.invalid("missing data.__schema") }
        func name(_ key: String) -> String? { (schema[key] as? [String: Any])?["name"] as? String }
        func typeRef(_ any: Any?) -> TypeRef {
            let object = any as? [String: Any] ?? [:]
            let inner = object["ofType"].flatMap { $0 is NSNull ? nil : $0 }
            return TypeRef(kind: object["kind"] as? String ?? "", name: object["name"] as? String, ofType: inner.map { .some(typeRef($0)) } ?? .none)
        }
        func argument(_ any: [String: Any]) -> Argument {
            Argument(name: any["name"] as? String ?? "", type: typeRef(any["type"]), description: any["description"] as? String)
        }
        let types = (schema["types"] as? [[String: Any]] ?? []).map { type in
            NamedType(
                kind: type["kind"] as? String ?? "",
                name: type["name"] as? String ?? "",
                description: type["description"] as? String,
                fields: (type["fields"] as? [[String: Any]] ?? []).map { field in
                    Field(name: field["name"] as? String ?? "", type: typeRef(field["type"]),
                          arguments: (field["args"] as? [[String: Any]] ?? []).map(argument),
                          description: field["description"] as? String, isDeprecated: field["isDeprecated"] as? Bool ?? false)
                },
                inputFields: (type["inputFields"] as? [[String: Any]] ?? []).map(argument),
                enumValues: (type["enumValues"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            )
        }
        return GraphQLSchema(queryType: name("queryType"), mutationType: name("mutationType"), subscriptionType: name("subscriptionType"), types: types)
    }

    /// A query selecting the scalar fields of `field` (one level deep), used by "insert" in the schema explorer.
    public func sampleOperation(for field: Field, operation: String) -> String {
        let arguments = field.arguments.map { "\($0.name): $\($0.name)" }.joined(separator: ", ")
        let variableDefinitions = field.arguments.map { "$\($0.name): \($0.type.display)" }.joined(separator: ", ")
        var selection = ""
        if let type = type(named: field.type.namedType), !type.fields.isEmpty {
            let scalars = type.fields.filter { self.type(named: $0.type.namedType)?.fields.isEmpty ?? true }.prefix(8)
            selection = " {\n    " + scalars.map(\.name).joined(separator: "\n    ") + "\n  }"
        }
        let header = variableDefinitions.isEmpty ? operation : "\(operation)(\(variableDefinitions))"
        let call = arguments.isEmpty ? field.name : "\(field.name)(\(arguments))"
        return "\(header) {\n  \(call)\(selection)\n}\n"
    }
}
