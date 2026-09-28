import Foundation

/// JSON coding for Codable values stored as `Data` columns.
enum Codec {
    static func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(value)) ?? Data()
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, default fallback: @autoclosure () -> T) -> T {
        guard !data.isEmpty else { return fallback() }
        return (try? JSONDecoder().decode(type, from: data)) ?? fallback()
    }
}
