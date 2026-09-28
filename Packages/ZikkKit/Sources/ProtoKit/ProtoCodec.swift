import Foundation

public enum ProtoCodecError: Error, Equatable, LocalizedError {
    case unknownMessage(String)
    case unknownField(message: String, field: String)
    case invalidValue(field: String, expected: String)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .unknownMessage(let name): "Unknown message type `\(name)`"
        case .unknownField(let message, let field): "`\(message)` has no field `\(field)`"
        case .invalidValue(let field, let expected): "Field `\(field)` expects \(expected)"
        case .malformed(let detail): "Malformed protobuf data: \(detail)"
        }
    }
}

/// Converts between protobuf binary and JSON (proto3 JSON mapping) using a `ProtoSchema`.
public struct ProtoCodec: Sendable {
    public let schema: ProtoSchema

    public init(schema: ProtoSchema) {
        self.schema = schema
    }

    // MARK: JSON → binary

    public func encode(json: String, as typeName: String) throws -> Data {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        let object: Any = trimmed.isEmpty ? [String: Any]() : try JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed])
        guard let dictionary = object as? [String: Any] else { throw ProtoCodecError.invalidValue(field: typeName, expected: "a JSON object") }
        return try encode(dictionary, as: typeName)
    }

    public func encode(_ object: [String: Any], as typeName: String) throws -> Data {
        guard let message = schema.messages[typeName] else { throw ProtoCodecError.unknownMessage(typeName) }
        var writer = WireWriter()
        for (key, value) in object.sorted(by: { $0.key < $1.key }) {
            guard let field = message.field(named: key) else { throw ProtoCodecError.unknownField(message: typeName, field: key) }
            if value is NSNull { continue }
            if field.isRepeated {
                if let entry = field.typeName.flatMap({ schema.messages[$0] }), entry.isMapEntry {
                    guard let map = value as? [String: Any] else { throw ProtoCodecError.invalidValue(field: key, expected: "an object (map)") }
                    for (mapKey, mapValue) in map.sorted(by: { $0.key < $1.key }) {
                        let keyField = entry.fields[0]
                        let typedKey: Any = keyField.kind == .string ? mapKey : (Int64(mapKey) as Any? ?? mapKey)
                        let bytes = try encode(["key": typedKey, "value": mapValue], as: entry.fullName)
                        writer.writeTag(field.number, wireType: 2)
                        writer.writeLengthDelimited(bytes)
                    }
                    continue
                }
                guard let array = value as? [Any] else { throw ProtoCodecError.invalidValue(field: key, expected: "an array") }
                if field.isPackable {
                    var packed = WireWriter()
                    for element in array { try writeValue(element, field: field, to: &packed, tagged: false) }
                    writer.writeTag(field.number, wireType: 2)
                    writer.writeLengthDelimited(packed.data)
                } else {
                    for element in array { try writeValue(element, field: field, to: &writer, tagged: true) }
                }
            } else {
                try writeValue(value, field: field, to: &writer, tagged: true)
            }
        }
        return writer.data
    }

    private func writeValue(_ value: Any, field: ProtoField, to writer: inout WireWriter, tagged: Bool) throws {
        func tag(_ wireType: Int) { if tagged { writer.writeTag(field.number, wireType: wireType) } }
        func integer() throws -> Int64 {
            if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.int64Value }
            if let string = value as? String, let number = Int64(string) { return number }
            throw ProtoCodecError.invalidValue(field: field.name, expected: "an integer")
        }
        func unsigned() throws -> UInt64 {
            if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.uint64Value }
            if let string = value as? String, let number = UInt64(string) { return number }
            throw ProtoCodecError.invalidValue(field: field.name, expected: "an unsigned integer")
        }
        func double() throws -> Double {
            if let number = value as? NSNumber { return number.doubleValue }
            if let string = value as? String {
                switch string {
                case "NaN": return .nan
                case "Infinity": return .infinity
                case "-Infinity": return -.infinity
                default: if let number = Double(string) { return number }
                }
            }
            throw ProtoCodecError.invalidValue(field: field.name, expected: "a number")
        }
        switch field.kind {
        case .int32, .int64, .uint32, .uint64:
            tag(0)
            if field.kind == .uint32 || field.kind == .uint64 { writer.writeVarint(try unsigned()) } else { writer.writeVarint(UInt64(bitPattern: try integer())) }
        case .sint32, .sint64:
            tag(0)
            let n = try integer()
            writer.writeVarint(UInt64(bitPattern: (n << 1) ^ (n >> 63)))
        case .bool:
            tag(0)
            guard let bool = value as? Bool else { throw ProtoCodecError.invalidValue(field: field.name, expected: "a boolean") }
            writer.writeVarint(bool ? 1 : 0)
        case .fixed32, .sfixed32:
            tag(5)
            writer.writeFixed32(field.kind == .fixed32 ? UInt32(truncatingIfNeeded: try unsigned()) : UInt32(bitPattern: Int32(truncatingIfNeeded: try integer())))
        case .fixed64, .sfixed64:
            tag(1)
            writer.writeFixed64(field.kind == .fixed64 ? try unsigned() : UInt64(bitPattern: try integer()))
        case .float:
            tag(5)
            writer.writeFixed32(Float(try double()).bitPattern)
        case .double:
            tag(1)
            writer.writeFixed64(try double().bitPattern)
        case .string:
            guard let string = value as? String else { throw ProtoCodecError.invalidValue(field: field.name, expected: "a string") }
            tag(2)
            writer.writeLengthDelimited(Data(string.utf8))
        case .bytes:
            guard let string = value as? String, let data = Data(base64Encoded: string) ?? Data(base64Encoded: string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")) else {
                throw ProtoCodecError.invalidValue(field: field.name, expected: "base64 bytes")
            }
            tag(2)
            writer.writeLengthDelimited(data)
        case .enumeration:
            tag(0)
            if let name = value as? String {
                guard let enumeration = field.typeName.flatMap({ schema.enums[$0] }), let match = enumeration.values.first(where: { $0.name == name }) else {
                    throw ProtoCodecError.invalidValue(field: field.name, expected: "a value of \(field.typeName ?? "enum")")
                }
                writer.writeVarint(UInt64(bitPattern: Int64(match.number)))
            } else {
                writer.writeVarint(UInt64(bitPattern: try integer()))
            }
        case .message:
            guard let typeName = field.typeName else { throw ProtoCodecError.malformed("missing type for \(field.name)") }
            let bytes: Data
            if let special = try encodeWellKnown(value, typeName: typeName) {
                bytes = special
            } else {
                guard let object = value as? [String: Any] else { throw ProtoCodecError.invalidValue(field: field.name, expected: "an object") }
                bytes = try encode(object, as: typeName)
            }
            tag(2)
            writer.writeLengthDelimited(bytes)
        }
    }

    /// Proto3 JSON special forms: Timestamp as RFC 3339, Duration as "1.5s", wrappers as plain values.
    private func encodeWellKnown(_ value: Any, typeName: String) throws -> Data? {
        switch typeName {
        case "google.protobuf.Timestamp":
            guard let string = value as? String else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string) else {
                throw ProtoCodecError.invalidValue(field: typeName, expected: "an RFC 3339 timestamp")
            }
            let seconds = date.timeIntervalSince1970.rounded(.down)
            return try encode(["seconds": Int64(seconds), "nanos": Int32(((date.timeIntervalSince1970 - seconds) * 1e9).rounded())], as: typeName)
        case "google.protobuf.Duration":
            guard let string = value as? String, string.hasSuffix("s"), let seconds = Double(string.dropLast()) else { return nil }
            let whole = seconds.rounded(.towardZero)
            return try encode(["seconds": Int64(whole), "nanos": Int32(((seconds - whole) * 1e9).rounded())], as: typeName)
        default:
            if typeName.hasPrefix("google.protobuf."), typeName.hasSuffix("Value"), !(value is [String: Any]) {
                return try encode(["value": value], as: typeName)
            }
            return nil
        }
    }

    // MARK: binary → JSON

    public func decodeJSON(_ data: Data, as typeName: String) throws -> String {
        let object = try decode(data, as: typeName)
        let json = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        return String(decoding: json, as: UTF8.self)
    }

    public func decode(_ data: Data, as typeName: String) throws -> Any {
        guard let message = schema.messages[typeName] else { throw ProtoCodecError.unknownMessage(typeName) }
        if let special = try decodeWellKnown(data, typeName: typeName) { return special }
        var reader = WireReader(data: data)
        var result: [String: Any] = [:]
        while !reader.isAtEnd {
            let (number, wireType) = try reader.readTag()
            guard let field = message.field(number: number) else {
                try reader.skip(wireType: wireType)
                continue
            }
            let key = field.jsonName
            if field.isRepeated, let entry = field.typeName.flatMap({ schema.messages[$0] }), entry.isMapEntry {
                let entryObject = try decode(try reader.readLengthDelimited(), as: entry.fullName) as? [String: Any] ?? [:]
                var map = result[key] as? [String: Any] ?? [:]
                map["\(entryObject["key"] ?? "")"] = entryObject["value"] ?? defaultValue(entry.fields[1])
                result[key] = map
            } else if field.isRepeated {
                var values = result[key] as? [Any] ?? []
                if wireType == 2, field.isPackable {
                    var packed = WireReader(data: try reader.readLengthDelimited())
                    while !packed.isAtEnd { values.append(try readValue(field: field, wireType: field.packedWireType, from: &packed)) }
                } else {
                    values.append(try readValue(field: field, wireType: wireType, from: &reader))
                }
                result[key] = values
            } else {
                result[key] = try readValue(field: field, wireType: wireType, from: &reader)
            }
        }
        return result
    }

    private func readValue(field: ProtoField, wireType: Int, from reader: inout WireReader) throws -> Any {
        switch field.kind {
        case .int32: return Int32(truncatingIfNeeded: Int64(bitPattern: try reader.readVarint()))
        case .int64: return String(Int64(bitPattern: try reader.readVarint()))
        case .uint32: return UInt32(truncatingIfNeeded: try reader.readVarint())
        case .uint64: return String(try reader.readVarint())
        case .sint32, .sint64:
            let raw = try reader.readVarint()
            let value = Int64(bitPattern: (raw >> 1) ^ (0 &- (raw & 1)))
            return field.kind == .sint32 ? Int32(truncatingIfNeeded: value) as Any : String(value)
        case .bool: return try reader.readVarint() != 0
        case .fixed32: return try reader.readFixed32()
        case .sfixed32: return Int32(bitPattern: try reader.readFixed32())
        case .fixed64: return String(try reader.readFixed64())
        case .sfixed64: return String(Int64(bitPattern: try reader.readFixed64()))
        case .float: return Double(Float(bitPattern: try reader.readFixed32()))
        case .double: return Double(bitPattern: try reader.readFixed64())
        case .string: return String(decoding: try reader.readLengthDelimited(), as: UTF8.self)
        case .bytes: return try reader.readLengthDelimited().base64EncodedString()
        case .enumeration:
            let number = Int(Int32(truncatingIfNeeded: Int64(bitPattern: try reader.readVarint())))
            return field.typeName.flatMap { schema.enums[$0] }?.values.first { $0.number == number }?.name ?? number
        case .message:
            return try decode(try reader.readLengthDelimited(), as: field.typeName ?? "")
        }
    }

    private func decodeWellKnown(_ data: Data, typeName: String) throws -> Any? {
        switch typeName {
        case "google.protobuf.Timestamp", "google.protobuf.Duration":
            var reader = WireReader(data: data)
            var seconds: Int64 = 0
            var nanos: Int32 = 0
            while !reader.isAtEnd {
                let (number, wireType) = try reader.readTag()
                switch number {
                case 1: seconds = Int64(bitPattern: try reader.readVarint())
                case 2: nanos = Int32(truncatingIfNeeded: Int64(bitPattern: try reader.readVarint()))
                default: try reader.skip(wireType: wireType)
                }
            }
            if typeName == "google.protobuf.Duration" {
                return nanos == 0 ? "\(seconds)s" : String(format: "%.9gs", Double(seconds) + Double(nanos) / 1e9)
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = nanos == 0 ? [.withInternetDateTime] : [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1e9))
        default:
            return nil
        }
    }

    private func defaultValue(_ field: ProtoField) -> Any {
        switch field.kind {
        case .string, .bytes: ""
        case .bool: false
        case .int64, .uint64, .fixed64, .sfixed64, .sint64: "0"
        case .message: [String: Any]()
        default: 0
        }
    }

    // MARK: Templates

    /// A JSON skeleton for a message (all fields with default values), used to pre-fill the request editor.
    public func template(for typeName: String, depth: Int = 0) -> Any {
        guard depth < 5, let message = schema.messages[typeName] else { return [String: Any]() }
        switch typeName {
        case "google.protobuf.Timestamp": return "1970-01-01T00:00:00Z"
        case "google.protobuf.Duration": return "0s"
        default: break
        }
        var object: [String: Any] = [:]
        var seenOneofs: Set<String> = []
        for field in message.fields {
            if let oneof = field.oneofName {
                guard seenOneofs.insert(oneof).inserted else { continue }
            }
            let value: Any
            if field.kind == .message, let typeName = field.typeName {
                value = schema.messages[typeName]?.isMapEntry == true ? [String: Any]() : template(for: typeName, depth: depth + 1)
            } else if field.kind == .enumeration {
                value = field.typeName.flatMap { schema.enums[$0]?.values.first?.name } ?? 0
            } else {
                value = defaultValue(field)
            }
            object[field.jsonName] = field.isRepeated && schema.messages[field.typeName ?? ""]?.isMapEntry != true ? [value] : value
        }
        return object
    }

    public func templateJSON(for typeName: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: template(for: typeName), options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

extension ProtoField {
    var packedWireType: Int {
        switch kind {
        case .double, .fixed64, .sfixed64: 1
        case .float, .fixed32, .sfixed32: 5
        default: 0
        }
    }
}

struct WireWriter {
    var data = Data()

    mutating func writeVarint(_ value: UInt64) {
        var value = value
        while value >= 0x80 {
            data.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
    }

    mutating func writeTag(_ number: Int, wireType: Int) {
        writeVarint(UInt64(number << 3 | wireType))
    }

    mutating func writeLengthDelimited(_ bytes: Data) {
        writeVarint(UInt64(bytes.count))
        data.append(bytes)
    }

    mutating func writeFixed32(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func writeFixed64(_ value: UInt64) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}

public struct WireReader {
    let bytes: [UInt8]
    var position = 0

    public init(data: Data) { bytes = [UInt8](data) }

    public var isAtEnd: Bool { position >= bytes.count }

    public mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while position < bytes.count {
            let byte = bytes[position]
            position += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { throw ProtoCodecError.malformed("varint too long") }
        }
        throw ProtoCodecError.malformed("truncated varint")
    }

    public mutating func readTag() throws -> (number: Int, wireType: Int) {
        let tag = try readVarint()
        return (Int(tag >> 3), Int(tag & 7))
    }

    public mutating func readLengthDelimited() throws -> Data {
        let length = Int(try readVarint())
        guard length >= 0, position + length <= bytes.count else { throw ProtoCodecError.malformed("length out of bounds") }
        defer { position += length }
        return Data(bytes[position..<position + length])
    }

    public mutating func readFixed32() throws -> UInt32 {
        guard position + 4 <= bytes.count else { throw ProtoCodecError.malformed("truncated fixed32") }
        defer { position += 4 }
        return bytes[position..<position + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) }
    }

    public mutating func readFixed64() throws -> UInt64 {
        guard position + 8 <= bytes.count else { throw ProtoCodecError.malformed("truncated fixed64") }
        defer { position += 8 }
        return bytes[position..<position + 8].enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * $1.offset) }
    }

    public mutating func skip(wireType: Int) throws {
        switch wireType {
        case 0: _ = try readVarint()
        case 1: _ = try readFixed64()
        case 2: _ = try readLengthDelimited()
        case 5: _ = try readFixed32()
        default: throw ProtoCodecError.malformed("unsupported wire type \(wireType)")
        }
    }
}
