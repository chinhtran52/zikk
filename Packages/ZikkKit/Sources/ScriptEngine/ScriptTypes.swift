import Foundation
import APICore

public enum ScriptPhase: String, Sendable {
    case preRequest = "prerequest"
    case test
}

/// Ordered key/value pairs for one variable scope.
public typealias ScopeValues = [(key: String, value: String)]

/// Input to a script run.
public struct ScriptInput: Sendable {
    public var phase: ScriptPhase
    public var globals: ScopeValues
    public var collection: ScopeValues
    public var environment: ScopeValues
    public var data: ScopeValues
    public var local: ScopeValues
    public var request: RequestSpec
    public var response: ResponseSnapshot?
    public var cookies: [(name: String, value: String)]
    public var requestName: String
    public var requestID: String
    public var environmentName: String
    public var iteration: Int
    public var iterationCount: Int

    public init(phase: ScriptPhase, globals: ScopeValues = [], collection: ScopeValues = [], environment: ScopeValues = [], data: ScopeValues = [], local: ScopeValues = [],
                request: RequestSpec, response: ResponseSnapshot? = nil, cookies: [(name: String, value: String)] = [], requestName: String = "", requestID: String = "",
                environmentName: String = "", iteration: Int = 0, iterationCount: Int = 1) {
        self.phase = phase
        self.globals = globals
        self.collection = collection
        self.environment = environment
        self.data = data
        self.local = local
        self.request = request
        self.response = response
        self.cookies = cookies
        self.requestName = requestName
        self.requestID = requestID
        self.environmentName = environmentName
        self.iteration = iteration
        self.iterationCount = iterationCount
    }
}

public struct TestResult: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var name: String
    public var passed: Bool
    public var skipped: Bool
    public var error: String?

    public init(name: String, passed: Bool, skipped: Bool = false, error: String? = nil) {
        self.name = name
        self.passed = passed
        self.skipped = skipped
        self.error = error
    }

    enum CodingKeys: String, CodingKey { case name, passed, skipped, error }
}

public struct ConsoleEntry: Codable, Hashable, Sendable, Identifiable {
    public enum Level: String, Codable, Sendable { case log, info, warn, error, debug }
    public var id = UUID()
    public var level: Level
    public var message: String
    public var date: Date

    public init(level: Level, message: String, date: Date = Date()) {
        self.level = level
        self.message = message
        self.date = date
    }

    enum CodingKeys: String, CodingKey { case level, message, date }
}

/// Where the collection runner should go next, as set by `postman.setNextRequest`.
public enum NextRequest: Hashable, Sendable {
    case named(String)
    case stop
}

public struct ScriptOutput: Sendable {
    public var globals: ScopeValues
    public var collection: ScopeValues
    public var environment: ScopeValues
    public var local: ScopeValues
    /// The request after pre-request mutations.
    public var request: RequestSpec
    public var tests: [TestResult]
    public var logs: [ConsoleEntry]
    public var nextRequest: NextRequest?
    public var skipRequest: Bool
    public var visualizer: (template: String, dataJSON: String)?
    /// Uncaught exception or timeout.
    public var error: String?
}

/// Performs `pm.sendRequest` calls on behalf of scripts.
public typealias ScriptRequestHandler = @Sendable (RequestSpec) async throws -> ResponseSnapshot
