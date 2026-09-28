import Foundation
import Observation
import APICore
import ScriptEngine

/// App-wide log of sent requests and script console output (like Postman's console).
@MainActor
@Observable
public final class ConsoleStore {
    public struct Entry: Identifiable, Hashable {
        public enum Kind: Hashable {
            case request(method: String, url: String, status: Int?, duration: Double, error: String?)
            case log(ConsoleEntry.Level, String)
        }
        public let id = UUID()
        public let date: Date
        public let kind: Kind
        public let requestName: String
    }

    public private(set) var entries: [Entry] = []
    public static let limit = 2000

    public init() {}

    func record(requestName: String, method: String, url: String, response: ResponseSnapshot?, error: String?, logs: [ConsoleEntry]) {
        for log in logs {
            entries.append(Entry(date: log.date, kind: .log(log.level, log.message), requestName: requestName))
        }
        entries.append(Entry(date: .now, kind: .request(method: method, url: url, status: response?.statusCode, duration: response?.timings.total ?? 0, error: error), requestName: requestName))
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    public func clear() { entries.removeAll() }
}
