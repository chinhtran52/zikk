import Foundation

/// Protobuf type information needed to encode/decode messages dynamically.
public struct ProtoSchema: Sendable, Hashable {
    public var messages: [String: ProtoMessage]
    public var enums: [String: ProtoEnum]
    public var services: [ProtoService]

    public init(messages: [String: ProtoMessage] = [:], enums: [String: ProtoEnum] = [:], services: [ProtoService] = []) {
        self.messages = messages
        self.enums = enums
        self.services = services
    }

    public mutating func merge(_ other: ProtoSchema) {
        messages.merge(other.messages) { a, _ in a }
        enums.merge(other.enums) { a, _ in a }
        for service in other.services where !services.contains(where: { $0.fullName == service.fullName }) {
            services.append(service)
        }
    }

    public func method(_ path: String) -> (ProtoService, ProtoMethod)? {
        // Accepts `pkg.Service/Method` or `/pkg.Service/Method`.
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let parts = trimmed.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let service = services.first(where: { $0.fullName == parts[0] }),
              let method = service.methods.first(where: { $0.name == parts[1] }) else { return nil }
        return (service, method)
    }

    /// All `Service/Method` paths.
    public var methodPaths: [String] {
        services.flatMap { service in service.methods.map { "\(service.fullName)/\($0.name)" } }
    }
}

public struct ProtoMessage: Sendable, Hashable {
    public var fullName: String
    public var fields: [ProtoField]
    /// True for synthesized `map<K, V>` entry messages.
    public var isMapEntry: Bool

    public init(fullName: String, fields: [ProtoField], isMapEntry: Bool = false) {
        self.fullName = fullName
        self.fields = fields
        self.isMapEntry = isMapEntry
    }

    public func field(named name: String) -> ProtoField? {
        fields.first { $0.name == name || $0.jsonName == name }
    }

    public func field(number: Int) -> ProtoField? {
        fields.first { $0.number == number }
    }
}

public struct ProtoField: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case double, float, int64, uint64, int32, fixed64, fixed32, bool, string, bytes, uint32, sfixed32, sfixed64, sint32, sint64
        case message, enumeration
    }

    public var name: String
    public var number: Int
    public var kind: Kind
    /// Fully-qualified type name for messages and enums (without leading dot).
    public var typeName: String?
    public var isRepeated: Bool
    public var oneofName: String?

    public init(name: String, number: Int, kind: Kind, typeName: String? = nil, isRepeated: Bool = false, oneofName: String? = nil) {
        self.name = name
        self.number = number
        self.kind = kind
        self.typeName = typeName
        self.isRepeated = isRepeated
        self.oneofName = oneofName
    }

    /// lowerCamelCase JSON name.
    public var jsonName: String {
        var result = ""
        var upperNext = false
        for character in name {
            if character == "_" { upperNext = true; continue }
            result.append(upperNext ? Character(character.uppercased()) : character)
            upperNext = false
        }
        return result
    }

    /// Whether repeated values of this kind are packed by default (proto3).
    var isPackable: Bool {
        switch kind {
        case .string, .bytes, .message: false
        default: true
        }
    }
}

public struct ProtoEnum: Sendable, Hashable {
    public var fullName: String
    public var values: [(name: String, number: Int)]

    public init(fullName: String, values: [(name: String, number: Int)]) {
        self.fullName = fullName
        self.values = values
    }

    public static func == (lhs: ProtoEnum, rhs: ProtoEnum) -> Bool {
        lhs.fullName == rhs.fullName && lhs.values.map(\.name) == rhs.values.map(\.name) && lhs.values.map(\.number) == rhs.values.map(\.number)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(fullName)
        for value in values { hasher.combine(value.name); hasher.combine(value.number) }
    }
}

public struct ProtoService: Sendable, Hashable {
    public var fullName: String
    public var methods: [ProtoMethod]

    public init(fullName: String, methods: [ProtoMethod]) {
        self.fullName = fullName
        self.methods = methods
    }
}

public struct ProtoMethod: Sendable, Hashable {
    public var name: String
    public var inputType: String
    public var outputType: String
    public var clientStreaming: Bool
    public var serverStreaming: Bool

    public init(name: String, inputType: String, outputType: String, clientStreaming: Bool = false, serverStreaming: Bool = false) {
        self.name = name
        self.inputType = inputType
        self.outputType = outputType
        self.clientStreaming = clientStreaming
        self.serverStreaming = serverStreaming
    }

    public var kindLabel: String {
        switch (clientStreaming, serverStreaming) {
        case (false, false): "Unary"
        case (false, true): "Server streaming"
        case (true, false): "Client streaming"
        case (true, true): "Bidirectional streaming"
        }
    }
}

/// Well-known types commonly imported by `.proto` files.
public enum WellKnownTypes {
    public static let schema: ProtoSchema = {
        var messages: [String: ProtoMessage] = [:]
        func add(_ name: String, _ fields: [ProtoField]) { messages["google.protobuf.\(name)"] = ProtoMessage(fullName: "google.protobuf.\(name)", fields: fields) }
        add("Empty", [])
        add("Timestamp", [ProtoField(name: "seconds", number: 1, kind: .int64), ProtoField(name: "nanos", number: 2, kind: .int32)])
        add("Duration", [ProtoField(name: "seconds", number: 1, kind: .int64), ProtoField(name: "nanos", number: 2, kind: .int32)])
        for (name, kind) in [("DoubleValue", ProtoField.Kind.double), ("FloatValue", .float), ("Int64Value", .int64), ("UInt64Value", .uint64),
                             ("Int32Value", .int32), ("UInt32Value", .uint32), ("BoolValue", .bool), ("StringValue", .string), ("BytesValue", .bytes)] {
            add(name, [ProtoField(name: "value", number: 1, kind: kind)])
        }
        add("FieldMask", [ProtoField(name: "paths", number: 1, kind: .string, isRepeated: true)])
        add("Any", [ProtoField(name: "type_url", number: 1, kind: .string), ProtoField(name: "value", number: 2, kind: .bytes)])
        return ProtoSchema(messages: messages)
    }()
}
