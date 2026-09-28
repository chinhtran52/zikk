import Foundation
import Yams

/// A JSON/YAML value with its source line, preserving mapping key order.
public indirect enum SpecValue: Hashable, Sendable {
    case string(String)
    case number(Double)
    case integer(Int)
    case bool(Bool)
    case null
    case object([SpecEntry])
    case array([SpecNode])
}

public struct SpecEntry: Hashable, Sendable {
    public var key: String
    public var keyLine: Int
    public var value: SpecNode

    public init(key: String, keyLine: Int = 0, value: SpecNode) {
        self.key = key
        self.keyLine = keyLine
        self.value = value
    }
}

public struct SpecNode: Hashable, Sendable {
    public var value: SpecValue
    /// 1-based source line (0 when unknown).
    public var line: Int

    public init(_ value: SpecValue, line: Int = 0) {
        self.value = value
        self.line = line
    }

    public subscript(key: String) -> SpecNode? {
        if case .object(let entries) = value { return entries.first { $0.key == key }?.value }
        return nil
    }

    public var entries: [SpecEntry] {
        if case .object(let entries) = value { return entries }
        return []
    }

    public var items: [SpecNode] {
        if case .array(let items) = value { return items }
        return []
    }

    public var isObject: Bool { if case .object = value { true } else { false } }
    public var isArray: Bool { if case .array = value { true } else { false } }

    public var string: String? {
        switch value {
        case .string(let s): s
        case .integer(let i): String(i)
        case .number(let d): String(d)
        case .bool(let b): String(b)
        default: nil
        }
    }

    public var bool: Bool? { if case .bool(let b) = value { b } else { nil } }

    public var double: Double? {
        switch value {
        case .integer(let i): Double(i)
        case .number(let d): d
        default: nil
        }
    }

    /// Line of `key` inside this mapping, or this node's line.
    public func line(of key: String) -> Int {
        entries.first { $0.key == key }?.keyLine ?? line
    }

    /// Foundation representation (`[String: Any]`, `[Any]`, `String`, `NSNumber`, `NSNull`).
    public var foundation: Any {
        switch value {
        case .string(let s): s
        case .number(let d): d
        case .integer(let i): i
        case .bool(let b): b
        case .null: NSNull()
        case .object(let entries): Dictionary(entries.map { ($0.key, $0.value.foundation) }, uniquingKeysWith: { a, _ in a })
        case .array(let items): items.map(\.foundation)
        }
    }

    /// Builds a node from a Foundation value (no line information).
    public static func from(_ any: Any?) -> SpecNode {
        switch any {
        case nil, is NSNull: return SpecNode(.null)
        case let bool as Bool where type(of: bool) == Bool.self: return SpecNode(.bool(bool))
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return SpecNode(.bool(number.boolValue)) }
            return number.doubleValue == Double(number.intValue) && !"\(number)".contains(".") ? SpecNode(.integer(number.intValue)) : SpecNode(.number(number.doubleValue))
        case let int as Int: return SpecNode(.integer(int))
        case let double as Double: return SpecNode(.number(double))
        case let string as String: return SpecNode(.string(string))
        case let array as [Any]: return SpecNode(.array(array.map { from($0) }))
        case let dictionary as [String: Any]:
            return SpecNode(.object(dictionary.keys.sorted().map { SpecEntry(key: $0, keyLine: 0, value: from(dictionary[$0])) }))
        default: return SpecNode(.string("\(any!)"))
        }
    }
}

public struct SpecSyntaxError: Error, Equatable, LocalizedError {
    public var message: String
    public var line: Int
    public var column: Int

    public var errorDescription: String? { "Line \(line): \(message)" }
}

public enum SpecParser {
    /// Parses YAML or JSON into a line-annotated tree.
    public static func parse(_ text: String) throws -> SpecNode {
        do {
            guard let node = try Yams.compose(yaml: text) else { return SpecNode(.null, line: 1) }
            return convert(node)
        } catch let error as YamlError {
            switch error {
            case .scanner(let context, let problem, let mark, _), .parser(let context, let problem, let mark, _), .composer(let context, let problem, let mark, _):
                let message = [context?.text, problem].compactMap { $0 }.joined(separator: " ")
                throw SpecSyntaxError(message: message, line: mark.line, column: mark.column)
            case .duplicatedKeysInMapping(let duplicates, let context):
                throw SpecSyntaxError(message: "Duplicated keys: \(duplicates.joined(separator: ", "))", line: context.mark.line, column: context.mark.column)
            default:
                throw SpecSyntaxError(message: "\(error)", line: 1, column: 1)
            }
        }
    }

    static func convert(_ node: Node) -> SpecNode {
        let line = node.mark?.line ?? 0
        switch node {
        case .scalar(let scalar):
            return SpecNode(scalarValue(scalar, node: node), line: line)
        case .mapping(let mapping):
            var entries: [SpecEntry] = []
            for (key, value) in mapping {
                entries.append(SpecEntry(key: key.scalar?.string ?? "\(key)", keyLine: key.mark?.line ?? line, value: convert(value)))
            }
            return SpecNode(.object(entries), line: line)
        case .sequence(let sequence):
            return SpecNode(.array(sequence.map(convert)), line: line)
        case .alias:
            return SpecNode(.null, line: line)
        }
    }

    private static func scalarValue(_ scalar: Node.Scalar, node: Node) -> SpecValue {
        // Quoted and block scalars are always strings.
        if scalar.style == .singleQuoted || scalar.style == .doubleQuoted || scalar.style == .literal || scalar.style == .folded {
            return .string(scalar.string)
        }
        switch node.tag.description {
        case "tag:yaml.org,2002:null": return .null
        case "tag:yaml.org,2002:bool": return node.bool.map(SpecValue.bool) ?? .string(scalar.string)
        case "tag:yaml.org,2002:int": return node.int.map(SpecValue.integer) ?? .string(scalar.string)
        case "tag:yaml.org,2002:float": return node.float.map(SpecValue.number) ?? .string(scalar.string)
        default: return .string(scalar.string)
        }
    }
}
