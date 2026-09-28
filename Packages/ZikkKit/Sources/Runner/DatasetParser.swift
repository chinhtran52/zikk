import Foundation

/// Tabular iteration data: ordered columns and rows keyed by column.
public struct DataTable: Equatable, Sendable {
    public var columns: [String]
    public var rows: [[String: String]]

    public init(columns: [String] = [], rows: [[String: String]] = []) {
        self.columns = columns
        self.rows = rows
    }
}

public enum DatasetParser {
    public enum Failure: LocalizedError, Equatable {
        case invalidJSON
        case unterminatedQuote(line: Int)

        public var errorDescription: String? {
            switch self {
            case .invalidJSON: "JSON data files must contain an array of objects."
            case .unterminatedQuote(let line): "Unterminated quoted field starting on line \(line)."
            }
        }
    }

    /// Parses JSON (array of objects) or CSV, chosen by content.
    public static func parse(_ text: String) throws -> DataTable {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("[") ? try parseJSON(trimmed) : try parseCSV(text)
    }

    public static func parseJSON(_ text: String) throws -> DataTable {
        guard let array = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any] else { throw Failure.invalidJSON }
        var columns: [String] = []
        var rows: [[String: String]] = []
        for element in array {
            guard let object = element as? [String: Any] else { throw Failure.invalidJSON }
            var row: [String: String] = [:]
            for key in object.keys.sorted() where !columns.contains(key) { columns.append(key) }
            for (key, value) in object { row[key] = stringValue(value) }
            rows.append(row)
        }
        return DataTable(columns: columns, rows: rows)
    }

    private static func stringValue(_ value: Any) -> String {
        switch value {
        case let string as String: return string
        case is NSNull: return ""
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
        default:
            let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// RFC 4180 CSV: the first record is the header; quoted fields may contain commas, quotes and newlines.
    public static func parseCSV(_ text: String) throws -> DataTable {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        var quoteStartLine = 1
        var line = 1
        var chars = Array(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        var i = 0
        func endField() { record.append(field); field = "" }
        func endRecord() {
            endField()
            if !(record.count == 1 && record[0].isEmpty) { records.append(record) }
            record = []
        }
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false }
                } else {
                    if c == "\n" { line += 1 }
                    field.append(c)
                }
            } else {
                switch c {
                case "\"" where field.isEmpty:
                    inQuotes = true
                    quoteStartLine = line
                case ",":
                    endField()
                case "\r\n", "\n", "\r":
                    line += 1
                    endRecord()
                default:
                    field.append(c)
                }
            }
            i += 1
        }
        if inQuotes { throw Failure.unterminatedQuote(line: quoteStartLine) }
        if !field.isEmpty || !record.isEmpty { endRecord() }
        chars.removeAll()

        guard let header = records.first else { return DataTable() }
        let columns = header.map { $0.trimmingCharacters(in: .whitespaces) }
        let rows = records.dropFirst().map { values in
            var row: [String: String] = [:]
            for (index, column) in columns.enumerated() { row[column] = index < values.count ? values[index] : "" }
            return row
        }
        return DataTable(columns: columns, rows: Array(rows))
    }

    public static func csv(_ table: DataTable) -> String {
        func escape(_ value: String) -> String {
            value.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
        }
        let lines = [table.columns.map(escape).joined(separator: ",")] + table.rows.map { row in
            table.columns.map { escape(row[$0] ?? "") }.joined(separator: ",")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
