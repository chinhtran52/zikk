import Foundation

/// Validates JSON instances against (OpenAPI-flavored) JSON Schemas.
public struct JSONSchemaValidator {
    public struct Issue: Hashable, Sendable {
        /// JSON path of the offending value, e.g. `$.items[0].id`.
        public var path: String
        public var message: String

        public var description: String { "\(path): \(message)" }
    }

    let document: SpecDocument
    /// OpenAPI 3.0 `nullable` semantics.
    let allowsNullable: Bool

    public init(document: SpecDocument) {
        self.document = document
        allowsNullable = document.version != .openAPI31
    }

    public func validate(_ value: Any, against schema: SpecNode?) -> [Issue] {
        var issues: [Issue] = []
        check(value, schema, path: "$", depth: 0, issues: &issues)
        return issues
    }

    private func check(_ value: Any, _ rawSchema: SpecNode?, path: String, depth: Int, issues: inout [Issue]) {
        guard depth < 32, let schema = document.resolve(rawSchema), schema.isObject else { return }
        func fail(_ message: String) { issues.append(Issue(path: path, message: message)) }

        if value is NSNull, schema["nullable"]?.bool == true, allowsNullable { return }

        if let allOf = schema["allOf"]?.items {
            for part in allOf { check(value, part, path: path, depth: depth + 1, issues: &issues) }
        }
        if let anyOf = schema["anyOf"]?.items, !anyOf.isEmpty {
            let passing = anyOf.contains { validate(value, against: $0, depth: depth).isEmpty }
            if !passing { fail("does not match any schema in anyOf") }
        }
        if let oneOf = schema["oneOf"]?.items, !oneOf.isEmpty {
            let count = oneOf.filter { validate(value, against: $0, depth: depth).isEmpty }.count
            if count != 1 { fail(count == 0 ? "does not match any schema in oneOf" : "matches \(count) schemas in oneOf (expected exactly one)") }
        }
        if let not = schema["not"], validate(value, against: not, depth: depth).isEmpty {
            fail("must not match the schema in `not`")
        }
        if let enumValues = schema["enum"]?.items, !enumValues.isEmpty {
            if !enumValues.contains(where: { Self.equal($0.foundation, value) }) {
                fail("must be one of \(enumValues.compactMap { $0.string ?? "null" }.joined(separator: ", "))")
            }
        }
        if let constant = schema["const"], !Self.equal(constant.foundation, value) {
            fail("must equal \(constant.string ?? "the constant value")")
        }

        let types = schema["type"].map { $0.string.map { [$0] } ?? $0.items.compactMap(\.string) } ?? []
        if !types.isEmpty {
            let actual = Self.typeName(value)
            let matches = types.contains { type in
                type == actual || (type == "number" && actual == "integer") || (type == "null" && actual == "null")
            }
            if !matches {
                fail("expected \(types.joined(separator: " or ")) but found \(actual)")
                return
            }
        }

        switch value {
        case let object as [String: Any]:
            for key in schema["required"]?.items.compactMap(\.string) ?? [] where object[key] == nil {
                fail("missing required property `\(key)`")
            }
            let properties = schema["properties"]
            for (key, child) in object {
                let childPath = path + "." + key
                if let propertySchema = properties?[key] {
                    check(child, propertySchema, path: childPath, depth: depth + 1, issues: &issues)
                } else if let additional = schema["additionalProperties"] {
                    if additional.bool == false {
                        issues.append(Issue(path: childPath, message: "is not allowed (additionalProperties: false)"))
                    } else if additional.isObject {
                        check(child, additional, path: childPath, depth: depth + 1, issues: &issues)
                    }
                }
            }
            if let min = schema["minProperties"]?.double, Double(object.count) < min { fail("must have at least \(Int(min)) properties") }
            if let max = schema["maxProperties"]?.double, Double(object.count) > max { fail("must have at most \(Int(max)) properties") }
        case let array as [Any]:
            if let min = schema["minItems"]?.double, Double(array.count) < min { fail("must have at least \(Int(min)) items") }
            if let max = schema["maxItems"]?.double, Double(array.count) > max { fail("must have at most \(Int(max)) items") }
            if schema["uniqueItems"]?.bool == true {
                for (index, item) in array.enumerated() where array[..<index].contains(where: { Self.equal($0, item) }) {
                    fail("items must be unique (duplicate at index \(index))")
                    break
                }
            }
            if let items = schema["items"] {
                for (index, item) in array.enumerated() { check(item, items, path: "\(path)[\(index)]", depth: depth + 1, issues: &issues) }
            }
        case let string as String:
            if let min = schema["minLength"]?.double, Double(string.count) < min { fail("must be at least \(Int(min)) characters") }
            if let max = schema["maxLength"]?.double, Double(string.count) > max { fail("must be at most \(Int(max)) characters") }
            if let pattern = schema["pattern"]?.string, let regex = try? NSRegularExpression(pattern: pattern),
               regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) == nil {
                fail("does not match pattern \(pattern)")
            }
            if let format = schema["format"]?.string, !Self.matchesFormat(string, format) {
                fail("is not a valid \(format)")
            }
        case let number as NSNumber where Self.typeName(number) != "boolean":
            let n = number.doubleValue
            if let min = schema["minimum"]?.double {
                let exclusive = schema["exclusiveMinimum"]?.bool == true
                if exclusive ? n <= min : n < min { fail("must be \(exclusive ? ">" : ">=") \(Self.format(min))") }
            }
            if let min = schema["exclusiveMinimum"]?.double, n <= min { fail("must be > \(Self.format(min))") }
            if let max = schema["maximum"]?.double {
                let exclusive = schema["exclusiveMaximum"]?.bool == true
                if exclusive ? n >= max : n > max { fail("must be \(exclusive ? "<" : "<=") \(Self.format(max))") }
            }
            if let max = schema["exclusiveMaximum"]?.double, n >= max { fail("must be < \(Self.format(max))") }
            if let multiple = schema["multipleOf"]?.double, multiple > 0, abs((n / multiple).rounded() - n / multiple) > 1e-9 {
                fail("must be a multiple of \(Self.format(multiple))")
            }
        default:
            break
        }
    }

    private func validate(_ value: Any, against schema: SpecNode, depth: Int) -> [Issue] {
        var issues: [Issue] = []
        check(value, schema, path: "$", depth: depth + 1, issues: &issues)
        return issues
    }

    static func typeName(_ value: Any) -> String {
        switch value {
        case is NSNull: return "null"
        case is String: return "string"
        case is [Any]: return "array"
        case is [String: Any]: return "object"
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return "boolean" }
            return number.doubleValue.rounded() == number.doubleValue && !CFNumberIsFloatType(number) ? "integer" : (number.doubleValue.rounded() == number.doubleValue ? "integer" : "number")
        default: return "unknown"
        }
    }

    static func equal(_ a: Any, _ b: Any) -> Bool {
        (a as? NSObject)?.isEqual(b) ?? false
    }

    static func format(_ number: Double) -> String {
        number.rounded() == number ? String(Int(number)) : String(number)
    }

    static func matchesFormat(_ value: String, _ format: String) -> Bool {
        switch format {
        case "date-time": return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: value.contains(".")).parse(value)) != nil
            || (try? Date.ISO8601FormatStyle().parse(value)) != nil
        case "date": return value.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil
        case "email": return value.wholeMatch(of: /[^@\s]+@[^@\s]+\.[^@\s]+/) != nil
        case "uuid": return UUID(uuidString: value) != nil
        case "uri", "url": return URL(string: value)?.scheme != nil
        case "ipv4": return value.wholeMatch(of: /(\d{1,3}\.){3}\d{1,3}/) != nil
        default: return true
        }
    }
}
