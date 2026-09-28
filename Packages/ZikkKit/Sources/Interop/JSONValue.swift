import Foundation

/// Loosely-typed accessors over `JSONSerialization` output, for tolerant parsing of third-party formats.
typealias JSONObject = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? {
        switch self[key] {
        case let string as String: string
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }

    func bool(_ key: String) -> Bool? {
        switch self[key] {
        case let bool as Bool: bool
        case let number as NSNumber: number.boolValue
        case let string as String: ["true", "1", "yes"].contains(string.lowercased())
        default: nil
        }
    }

    func int(_ key: String) -> Int? {
        switch self[key] {
        case let number as NSNumber: number.intValue
        case let string as String: Int(string)
        default: nil
        }
    }

    func object(_ key: String) -> JSONObject? { self[key] as? JSONObject }
    func array(_ key: String) -> [JSONObject] { (self[key] as? [Any])?.compactMap { $0 as? JSONObject } ?? [] }
}

enum JSONCoding {
    static func object(from data: Data) throws -> JSONObject {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? JSONObject else { throw InteropError.invalidJSON }
        return object
    }

    static func data(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }
}
