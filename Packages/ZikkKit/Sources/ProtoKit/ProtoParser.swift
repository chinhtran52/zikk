import Foundation

public struct ProtoParseError: Error, Equatable, LocalizedError {
    public var message: String
    public var line: Int
    public var errorDescription: String? { "Line \(line): \(message)" }
}

/// Parser for `.proto` files (proto2/proto3 subset: messages, enums, oneofs, maps, services).
public enum ProtoParser {
    public static func parse(_ source: String) throws -> ProtoSchema {
        var parser = Parser(tokens: try Tokenizer.tokenize(source))
        try parser.parseFile()
        return try parser.resolve()
    }

    struct Token: Equatable {
        enum Kind: Equatable { case identifier, number, string, symbol }
        var kind: Kind
        var text: String
        var line: Int
    }

    enum Tokenizer {
        static func tokenize(_ source: String) throws -> [Token] {
            var tokens: [Token] = []
            let chars = Array(source)
            var i = 0
            var line = 1
            while i < chars.count {
                let c = chars[i]
                if c == "\n" { line += 1; i += 1; continue }
                if c.isWhitespace { i += 1; continue }
                if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                    while i < chars.count, chars[i] != "\n" { i += 1 }
                    continue
                }
                if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                    i += 2
                    while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { if chars[i] == "\n" { line += 1 }; i += 1 }
                    i += 2
                    continue
                }
                if c == "\"" || c == "'" {
                    var value = ""
                    i += 1
                    while i < chars.count, chars[i] != c {
                        if chars[i] == "\\", i + 1 < chars.count { i += 1 }
                        value.append(chars[i])
                        i += 1
                    }
                    guard i < chars.count else { throw ProtoParseError(message: "Unterminated string", line: line) }
                    i += 1
                    tokens.append(Token(kind: .string, text: value, line: line))
                    continue
                }
                if c.isLetter || c == "_" || c == "." && i + 1 < chars.count && (chars[i + 1].isLetter || chars[i + 1] == "_") {
                    var value = String(c)
                    i += 1
                    while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" || chars[i] == "." { value.append(chars[i]); i += 1 }
                    tokens.append(Token(kind: .identifier, text: value, line: line))
                    continue
                }
                if c.isNumber || (c == "-" && i + 1 < chars.count && chars[i + 1].isNumber) {
                    var value = String(c)
                    i += 1
                    while i < chars.count, chars[i].isNumber || chars[i].isLetter || chars[i] == "." { value.append(chars[i]); i += 1 }
                    tokens.append(Token(kind: .number, text: value, line: line))
                    continue
                }
                tokens.append(Token(kind: .symbol, text: String(c), line: line))
                i += 1
            }
            return tokens
        }
    }

    struct PendingField {
        var name: String
        var number: Int
        var type: String
        var isRepeated: Bool
        var oneof: String?
        var scope: String
        var line: Int
    }

    struct Parser {
        let tokens: [Token]
        var index = 0
        var package = ""
        var messages: [String: [PendingField]] = [:]
        var messageOrder: [String] = []
        var mapEntries: Set<String> = []
        var enums: [String: ProtoEnum] = [:]
        var services: [(name: String, methods: [(name: String, input: String, output: String, clientStreaming: Bool, serverStreaming: Bool, scope: String, line: Int)])] = []

        init(tokens: [Token]) { self.tokens = tokens }

        var current: Token? { index < tokens.count ? tokens[index] : nil }
        var line: Int { current?.line ?? tokens.last?.line ?? 1 }

        mutating func next() throws -> Token {
            guard let token = current else { throw ProtoParseError(message: "Unexpected end of file", line: line) }
            index += 1
            return token
        }

        mutating func expect(_ text: String) throws {
            let token = try next()
            guard token.text == text else { throw ProtoParseError(message: "Expected `\(text)` but found `\(token.text)`", line: token.line) }
        }

        mutating func accept(_ text: String) -> Bool {
            if current?.text == text { index += 1; return true }
            return false
        }

        mutating func identifier() throws -> String {
            let token = try next()
            guard token.kind == .identifier else { throw ProtoParseError(message: "Expected identifier but found `\(token.text)`", line: token.line) }
            return token.text
        }

        /// Skips a balanced `{ … }`, `[ … ]` or a statement up to `;`.
        mutating func skipStatement() throws {
            var depth = 0
            while let token = current {
                index += 1
                if token.text == "{" || token.text == "[" || token.text == "(" { depth += 1 }
                if token.text == "}" || token.text == "]" || token.text == ")" {
                    depth -= 1
                    if depth == 0, token.text == "}" { return }
                }
                if token.text == ";", depth == 0 { return }
            }
        }

        func qualified(_ name: String, in scope: String) -> String {
            scope.isEmpty ? name : scope + "." + name
        }

        mutating func parseFile() throws {
            while let token = current {
                switch token.text {
                case "syntax", "edition", "import", "option":
                    try skipStatement()
                case "package":
                    index += 1
                    package = try identifier()
                    try expect(";")
                case "message":
                    index += 1
                    try parseMessage(scope: package)
                case "enum":
                    index += 1
                    try parseEnum(scope: package)
                case "service":
                    index += 1
                    try parseService()
                case "extend":
                    try skipStatement()
                case ";":
                    index += 1
                default:
                    throw ProtoParseError(message: "Unexpected `\(token.text)`", line: token.line)
                }
            }
        }

        mutating func parseMessage(scope: String) throws {
            let name = try identifier()
            let fullName = qualified(name, in: scope)
            messages[fullName] = []
            messageOrder.append(fullName)
            try expect("{")
            try parseMessageBody(fullName: fullName, oneof: nil)
        }

        mutating func parseMessageBody(fullName: String, oneof: String?) throws {
            while let token = current {
                switch token.text {
                case "}":
                    index += 1
                    return
                case ";":
                    index += 1
                case "message":
                    index += 1
                    try parseMessage(scope: fullName)
                case "enum":
                    index += 1
                    try parseEnum(scope: fullName)
                case "option", "reserved", "extensions", "extend":
                    try skipStatement()
                case "oneof":
                    index += 1
                    let oneofName = try identifier()
                    try expect("{")
                    try parseMessageBody(fullName: fullName, oneof: oneofName)
                case "map":
                    index += 1
                    try expect("<")
                    let keyType = try identifier()
                    try expect(",")
                    let valueType = try identifier()
                    try expect(">")
                    let fieldName = try identifier()
                    try expect("=")
                    let number = try fieldNumber()
                    try skipOptionsAndSemicolon()
                    let entryName = fullName + "." + Self.mapEntryName(fieldName)
                    messages[entryName] = [
                        PendingField(name: "key", number: 1, type: keyType, isRepeated: false, oneof: nil, scope: fullName, line: token.line),
                        PendingField(name: "value", number: 2, type: valueType, isRepeated: false, oneof: nil, scope: fullName, line: token.line),
                    ]
                    messageOrder.append(entryName)
                    mapEntries.insert(entryName)
                    messages[fullName, default: []].append(PendingField(name: fieldName, number: number, type: "." + entryName, isRepeated: true, oneof: oneof, scope: fullName, line: token.line))
                default:
                    var isRepeated = false
                    if token.text == "repeated" { isRepeated = true; index += 1 } else if token.text == "optional" || token.text == "required" { index += 1 }
                    if current?.text == "group" { throw ProtoParseError(message: "Groups are not supported", line: token.line) }
                    let type = try identifier()
                    let fieldName = try identifier()
                    try expect("=")
                    let number = try fieldNumber()
                    try skipOptionsAndSemicolon()
                    messages[fullName, default: []].append(PendingField(name: fieldName, number: number, type: type, isRepeated: isRepeated, oneof: oneof, scope: fullName, line: token.line))
                }
            }
            throw ProtoParseError(message: "Missing `}`", line: line)
        }

        static func mapEntryName(_ field: String) -> String {
            field.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined() + "Entry"
        }

        mutating func fieldNumber() throws -> Int {
            let token = try next()
            guard let number = Int(token.text) ?? (token.text.hasPrefix("0x") ? Int(token.text.dropFirst(2), radix: 16) : nil) else {
                throw ProtoParseError(message: "Invalid field number `\(token.text)`", line: token.line)
            }
            return number
        }

        mutating func skipOptionsAndSemicolon() throws {
            if current?.text == "[" {
                var depth = 0
                while let token = current {
                    index += 1
                    if token.text == "[" { depth += 1 }
                    if token.text == "]" { depth -= 1; if depth == 0 { break } }
                }
            }
            try expect(";")
        }

        mutating func parseEnum(scope: String) throws {
            let name = try identifier()
            let fullName = qualified(name, in: scope)
            try expect("{")
            var values: [(String, Int)] = []
            while let token = current, token.text != "}" {
                if token.text == "option" || token.text == "reserved" { try skipStatement(); continue }
                if token.text == ";" { index += 1; continue }
                let valueName = try identifier()
                try expect("=")
                let number = try fieldNumber()
                try skipOptionsAndSemicolon()
                values.append((valueName, number))
            }
            try expect("}")
            enums[fullName] = ProtoEnum(fullName: fullName, values: values)
        }

        mutating func parseService() throws {
            let name = try identifier()
            try expect("{")
            var methods: [(String, String, String, Bool, Bool, String, Int)] = []
            while let token = current, token.text != "}" {
                if token.text == "option" { try skipStatement(); continue }
                if token.text == ";" { index += 1; continue }
                guard token.text == "rpc" else { throw ProtoParseError(message: "Unexpected `\(token.text)` in service", line: token.line) }
                index += 1
                let methodName = try identifier()
                try expect("(")
                let clientStreaming = accept("stream")
                let input = try identifier()
                try expect(")")
                try expect("returns")
                try expect("(")
                let serverStreaming = accept("stream")
                let output = try identifier()
                try expect(")")
                if current?.text == "{" { try skipStatement() } else { try expect(";") }
                methods.append((methodName, input, output, clientStreaming, serverStreaming, package, token.line))
            }
            try expect("}")
            services.append((qualified(name, in: package), methods.map { (name: $0.0, input: $0.1, output: $0.2, clientStreaming: $0.3, serverStreaming: $0.4, scope: $0.5, line: $0.6) }))
        }

        static let scalarKinds: [String: ProtoField.Kind] = [
            "double": .double, "float": .float, "int64": .int64, "uint64": .uint64, "int32": .int32, "fixed64": .fixed64, "fixed32": .fixed32,
            "bool": .bool, "string": .string, "bytes": .bytes, "uint32": .uint32, "sfixed32": .sfixed32, "sfixed64": .sfixed64, "sint32": .sint32, "sint64": .sint64,
        ]

        /// Resolves a type reference using protobuf scoping rules (innermost scope first).
        func resolveType(_ name: String, scope: String, line: Int, known: ProtoSchema) throws -> String {
            if name.hasPrefix(".") { return String(name.dropFirst()) }
            var candidates: [String] = []
            var parts = scope.split(separator: ".").map(String.init)
            while true {
                candidates.append((parts + [name]).joined(separator: "."))
                if parts.isEmpty { break }
                parts.removeLast()
            }
            for candidate in candidates where messages[candidate] != nil || enums[candidate] != nil || known.messages[candidate] != nil || known.enums[candidate] != nil {
                return candidate
            }
            throw ProtoParseError(message: "Unknown type `\(name)`", line: line)
        }

        func resolve() throws -> ProtoSchema {
            let wellKnown = WellKnownTypes.schema
            var schema = ProtoSchema()
            for name in messageOrder {
                let fields = try (messages[name] ?? []).map { pending -> ProtoField in
                    if let kind = Self.scalarKinds[pending.type] {
                        return ProtoField(name: pending.name, number: pending.number, kind: kind, isRepeated: pending.isRepeated, oneofName: pending.oneof)
                    }
                    let typeName = try resolveType(pending.type, scope: pending.scope, line: pending.line, known: wellKnown)
                    let isEnum = enums[typeName] != nil || wellKnown.enums[typeName] != nil
                    return ProtoField(name: pending.name, number: pending.number, kind: isEnum ? .enumeration : .message, typeName: typeName, isRepeated: pending.isRepeated, oneofName: pending.oneof)
                }
                schema.messages[name] = ProtoMessage(fullName: name, fields: fields, isMapEntry: mapEntries.contains(name))
            }
            schema.enums = enums
            schema.services = try services.map { service in
                ProtoService(fullName: service.name, methods: try service.methods.map { method in
                    ProtoMethod(name: method.name,
                                inputType: try resolveType(method.input, scope: method.scope, line: method.line, known: wellKnown),
                                outputType: try resolveType(method.output, scope: method.scope, line: method.line, known: wellKnown),
                                clientStreaming: method.clientStreaming, serverStreaming: method.serverStreaming)
                })
            }
            schema.merge(wellKnown)
            return schema
        }
    }
}
