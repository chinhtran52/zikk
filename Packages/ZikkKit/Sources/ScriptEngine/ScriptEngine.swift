import Foundation
import JavaScriptCore
import APICore

/// Runs Postman-compatible scripts in an isolated JavaScriptCore context.
public struct ScriptEngine: Sendable {
    /// Maximum wall time for a script, including pending async work.
    public var timeout: Duration
    public var requestHandler: ScriptRequestHandler?

    public init(timeout: Duration = .seconds(30), requestHandler: ScriptRequestHandler? = nil) {
        self.timeout = timeout
        self.requestHandler = requestHandler
    }

    public func run(_ script: String, input: ScriptInput) async -> ScriptOutput {
        let timeout = timeout
        let handler = requestHandler
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            let thread = Thread {
                let session = ScriptSession(input: input, requestHandler: handler, deadline: ContinuousClock.now + timeout)
                once.resume(session.run(script))
            }
            thread.name = "ScriptEngine"
            thread.stackSize = 8 << 20
            thread.start()
            // A synchronous infinite loop cannot be interrupted; give up waiting for it.
            Task {
                try? await Task.sleep(for: timeout + .seconds(1))
                var output = ScriptSession.emptyOutput(for: input)
                output.error = "Script execution timed out after \(timeout)."
                once.resume(output)
            }
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private var continuation: CheckedContinuation<ScriptOutput, Never>?
    private let lock = NSLock()
    init(_ continuation: CheckedContinuation<ScriptOutput, Never>) { self.continuation = continuation }
    func resume(_ output: ScriptOutput) {
        lock.withLock {
            continuation?.resume(returning: output)
            continuation = nil
        }
    }
}

/// One script run. All JavaScriptCore access happens on the thread that calls `run`.
final class ScriptSession: @unchecked Sendable {
    private let input: ScriptInput
    private let requestHandler: ScriptRequestHandler?
    private let deadline: ContinuousClock.Instant
    private let context: JSContext
    private var logs: [ConsoleEntry] = []
    private var scriptError: String?

    // Event loop state (guarded by `lock` where touched from other threads).
    private let lock = NSLock()
    private let wakeup = DispatchSemaphore(value: 0)
    private var completedRequests: [(id: Int, error: String?, response: ResponseSnapshot?)] = []
    private var pendingRequests = 0
    private var timers: [Int: ContinuousClock.Instant] = [:]

    init(input: ScriptInput, requestHandler: ScriptRequestHandler?, deadline: ContinuousClock.Instant) {
        self.input = input
        self.requestHandler = requestHandler
        self.deadline = deadline
        self.context = JSContext(virtualMachine: JSVirtualMachine())
    }

    static func emptyOutput(for input: ScriptInput) -> ScriptOutput {
        ScriptOutput(globals: input.globals, collection: input.collection, environment: input.environment, local: input.local,
                     request: input.request, tests: [], logs: [], nextRequest: nil, skipRequest: false, visualizer: nil, error: nil)
    }

    func run(_ script: String) -> ScriptOutput {
        context.exceptionHandler = { [weak self] _, exception in
            guard let self, self.scriptError == nil else { return }
            self.scriptError = Self.describe(exception)
        }
        installNatives()
        guard let sandbox = ScriptResources.sandbox else {
            var output = Self.emptyOutput(for: input)
            output.error = "Script sandbox resource is missing."
            return output
        }
        context.evaluateScript(sandbox, withSourceURL: URL(string: "sandbox.js"))
        if let error = scriptError {
            var output = Self.emptyOutput(for: input)
            output.error = "Sandbox failed to load: \(error)"
            return output
        }

        // Wrap in an async function so top-level `await` works; failures surface via the promise.
        let wrapped = "(async function () {\n\(script)\n}).call(this).catch(function (e) { __reportError(e); });"
        context.evaluateScript(wrapped, withSourceURL: URL(string: "\(input.phase.rawValue).js"))
        runEventLoop()

        // Wait for async `pm.test` callbacks.
        if let pending = context.objectForKeyedSubscript("__pendingTests")?.call(withArguments: []), !pending.isNull {
            pending.invokeMethod("then", withArguments: [])
            runEventLoop()
        }
        return collectOutput()
    }

    // MARK: Natives

    private func installNatives() {
        let native = JSValue(newObjectIn: context)!
        let log: @convention(block) (String, String) -> Void = { [weak self] level, message in
            self?.logs.append(ConsoleEntry(level: ConsoleEntry.Level(rawValue: level) ?? .log, message: message))
        }
        let requireSource: @convention(block) (String) -> Any = { name in
            ScriptResources.module(named: name) ?? NSNull()
        }
        let dynamicVariable: @convention(block) (String) -> Any = { name in
            DynamicVariables.value(for: name) ?? NSNull()
        }
        let uuid: @convention(block) () -> String = { UUID().uuidString.lowercased() }
        let setTimer: @convention(block) (Int, Double) -> Void = { [weak self] id, milliseconds in
            guard let self else { return }
            self.lock.withLock { self.timers[id] = ContinuousClock.now + .milliseconds(Int(max(0, milliseconds))) }
        }
        let clearTimer: @convention(block) (Int) -> Void = { [weak self] id in
            guard let self else { return }
            _ = self.lock.withLock { self.timers.removeValue(forKey: id) }
        }
        let sendRequest: @convention(block) (Int, String) -> Void = { [weak self] id, json in
            self?.startRequest(id: id, json: json)
        }
        native.setObject(log, forKeyedSubscript: "log" as NSString)
        native.setObject(requireSource, forKeyedSubscript: "requireSource" as NSString)
        native.setObject(dynamicVariable, forKeyedSubscript: "dynamicVariable" as NSString)
        native.setObject(uuid, forKeyedSubscript: "uuid" as NSString)
        native.setObject(setTimer, forKeyedSubscript: "setTimer" as NSString)
        native.setObject(clearTimer, forKeyedSubscript: "clearTimer" as NSString)
        native.setObject(sendRequest, forKeyedSubscript: "sendRequest" as NSString)
        context.setObject(native, forKeyedSubscript: "__native" as NSString)

        let reportError: @convention(block) (JSValue) -> Void = { [weak self] error in
            guard let self, self.scriptError == nil else { return }
            self.scriptError = Self.describe(error)
        }
        context.setObject(reportError, forKeyedSubscript: "__reportError" as NSString)
        context.setObject(inputJSON(), forKeyedSubscript: "__inputJSON" as NSString)
        context.evaluateScript("var __input = JSON.parse(__inputJSON);")
    }

    private static func describe(_ exception: JSValue?) -> String {
        guard let exception else { return "Unknown error" }
        if exception.isObject, let message = exception.objectForKeyedSubscript("message"), !message.isUndefined {
            let name = exception.objectForKeyedSubscript("name")?.toString() ?? "Error"
            let line = exception.objectForKeyedSubscript("line")?.toString()
            return "\(name): \(message.toString() ?? "")" + (line.map { $0 == "undefined" ? "" : " (line \($0))" } ?? "")
        }
        return exception.toString() ?? "Unknown error"
    }

    private func inputJSON() -> String {
        func pairs(_ values: ScopeValues) -> [[String]] { values.map { [$0.key, $0.value] } }
        var object: [String: Any] = [
            "variables": [
                "globals": pairs(input.globals), "collection": pairs(input.collection), "environment": pairs(input.environment),
                "data": pairs(input.data), "local": pairs(input.local),
            ],
            "request": Self.requestJSON(input.request),
            "info": [
                "eventName": input.phase.rawValue, "iteration": input.iteration, "iterationCount": input.iterationCount,
                "requestName": input.requestName, "requestId": input.requestID, "environmentName": input.environmentName,
            ],
            "cookies": input.cookies.map { ["name": $0.name, "value": $0.value] },
        ]
        if let response = input.response { object["response"] = Self.responseJSON(response) }
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static func requestJSON(_ spec: RequestSpec) -> [String: Any] {
        func rows(_ rows: [KeyValue]) -> [[String: Any]] {
            rows.filter { !$0.key.isEmpty }.map { ["key": $0.key, "value": $0.value, "disabled": !$0.isEnabled] }
        }
        let modeName: String = switch spec.body.mode {
        case .none: "none"
        case .raw: "raw"
        case .urlEncoded: "urlencoded"
        case .formData: "formdata"
        case .binary: "file"
        case .graphQL: "graphql"
        }
        return [
            "method": spec.method.rawValue,
            "url": spec.url,
            "headers": rows(spec.headers),
            "auth": ["type": spec.auth.type.rawValue],
            "body": [
                "mode": modeName,
                "raw": spec.body.raw,
                "urlencoded": rows(spec.body.urlEncoded),
                "formdata": spec.body.formData.filter { $0.kind == .text }.map { ["key": $0.key, "value": $0.value, "disabled": !$0.isEnabled] },
                "graphql": ["query": spec.body.graphQL.query, "variables": spec.body.graphQL.variables],
            ],
        ]
    }

    static func responseJSON(_ response: ResponseSnapshot) -> [String: Any] {
        var cookies: [[String: String]] = []
        if let url = URL(string: response.url) {
            let fields = Dictionary(response.headers.map { ($0.key, $0.value) }, uniquingKeysWith: { a, b in a + "," + b })
            cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url).map { ["name": $0.name, "value": $0.value] }
        }
        return [
            "code": response.statusCode,
            "status": response.statusText,
            "headers": response.headers.map { ["key": $0.key, "value": $0.value] },
            "body": response.bodyText ?? "",
            "bodySize": response.body.count,
            "responseSize": response.size,
            "responseTime": Int(response.timings.total.rounded()),
            "cookies": cookies,
        ]
    }

    // MARK: pm.sendRequest

    private func startRequest(id: Int, json: String) {
        guard let handler = requestHandler else {
            lock.withLock { completedRequests.append((id, "pm.sendRequest is not available here", nil)) }
            wakeup.signal()
            return
        }
        let spec = Self.spec(fromJSON: json)
        lock.withLock { pendingRequests += 1 }
        Task { [weak self] in
            var failure: String?
            var response: ResponseSnapshot?
            do { response = try await handler(spec) } catch { failure = error.localizedDescription }
            guard let self else { return }
            self.lock.withLock {
                self.pendingRequests -= 1
                self.completedRequests.append((id, failure, response))
            }
            self.wakeup.signal()
        }
    }

    static func spec(fromJSON json: String) -> RequestSpec {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return RequestSpec() }
        var spec = RequestSpec()
        spec.method = HTTPMethod(rawValue: object["method"] as? String ?? "GET")
        spec.url = object["url"] as? String ?? ""
        spec.headers = (object["headers"] as? [[String: Any]] ?? []).map {
            KeyValue(key: $0["key"] as? String ?? "", value: $0["value"] as? String ?? "", isEnabled: !($0["disabled"] as? Bool ?? false))
        }
        if let body = object["body"] as? [String: Any] {
            applyBody(body, to: &spec)
        }
        return spec
    }

    static func applyBody(_ body: [String: Any], to spec: inout RequestSpec) {
        func rows(_ value: Any?) -> [KeyValue] {
            (value as? [[String: Any]] ?? []).map {
                KeyValue(key: $0["key"] as? String ?? "", value: ($0["value"] as? String) ?? ($0["value"].map { "\($0)" } ?? ""), isEnabled: !($0["disabled"] as? Bool ?? false))
            }
        }
        switch body["mode"] as? String {
        case "raw":
            spec.body.mode = .raw
            spec.body.raw = body["raw"] as? String ?? ""
        case "urlencoded":
            spec.body.mode = .urlEncoded
            spec.body.urlEncoded = rows(body["urlencoded"])
        case "formdata":
            spec.body.mode = .formData
            let textFields = rows(body["formdata"]).map { FormDataField(key: $0.key, value: $0.value, isEnabled: $0.isEnabled) }
            // Keep file fields, which scripts cannot see.
            spec.body.formData = textFields + spec.body.formData.filter { $0.kind == .file }
        case "graphql":
            spec.body.mode = .graphQL
            if let graphQL = body["graphql"] as? [String: Any] {
                spec.body.graphQL.query = graphQL["query"] as? String ?? spec.body.graphQL.query
                spec.body.graphQL.variables = graphQL["variables"] as? String ?? spec.body.graphQL.variables
            }
        case "none":
            spec.body.mode = .none
        default:
            break
        }
    }

    // MARK: Event loop

    private func runEventLoop() {
        while true {
            // Deliver completed requests.
            let completed = lock.withLock { () -> [(id: Int, error: String?, response: ResponseSnapshot?)] in
                defer { completedRequests.removeAll() }
                return completedRequests
            }
            for item in completed {
                let data: Any = item.response.map(Self.responseJSON) ?? NSNull()
                context.objectForKeyedSubscript("__completeRequest")?.call(withArguments: [item.id, item.error ?? NSNull(), data])
            }
            // Fire due timers.
            let now = ContinuousClock.now
            let due = lock.withLock { () -> [Int] in
                let ids = timers.filter { $0.value <= now }.sorted { $0.value < $1.value }.map(\.key)
                ids.forEach { timers.removeValue(forKey: $0) }
                return ids
            }
            for id in due {
                context.objectForKeyedSubscript("__fireTimer")?.call(withArguments: [id])
            }
            if !completed.isEmpty || !due.isEmpty { continue }

            // Read everything under one lock: a request may complete between the drain above and this check,
            // and exiting then would drop its callback.
            let (pending, nextTimer, hasCompleted) = lock.withLock { (pendingRequests, timers.values.min(), !completedRequests.isEmpty) }
            if hasCompleted { continue }
            if pending == 0 && nextTimer == nil { return }
            if ContinuousClock.now >= deadline {
                if scriptError == nil { scriptError = "Script timed out waiting for asynchronous work." }
                return
            }
            let waitUntil = min(nextTimer ?? deadline, deadline)
            let interval = ContinuousClock.now.duration(to: waitUntil)
            let seconds = Double(interval.components.seconds) + Double(interval.components.attoseconds) / 1e18
            _ = wakeup.wait(timeout: .now() + max(0, seconds))
        }
    }

    // MARK: Output

    private func collectOutput() -> ScriptOutput {
        var output = Self.emptyOutput(for: input)
        output.logs = logs
        output.error = scriptError
        guard let json = context.objectForKeyedSubscript("__collectOutput")?.call(withArguments: [])?.toString(),
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return output }

        func scope(_ name: String) -> ScopeValues {
            ((object["variables"] as? [String: Any])?[name] as? [[String]] ?? []).compactMap { pair in
                pair.count == 2 ? (key: pair[0], value: pair[1]) : nil
            }
        }
        output.globals = scope("globals")
        output.collection = scope("collection")
        output.environment = scope("environment")
        output.local = scope("local")
        output.tests = (object["tests"] as? [[String: Any]] ?? []).map {
            TestResult(name: $0["name"] as? String ?? "", passed: $0["passed"] as? Bool ?? false, skipped: $0["skipped"] as? Bool ?? false, error: $0["error"] as? String)
        }
        if object["nextRequestSet"] as? Bool == true {
            output.nextRequest = (object["nextRequest"] as? String).map(NextRequest.named) ?? .stop
        }
        output.skipRequest = object["skipRequest"] as? Bool ?? false
        if let visualizer = object["visualizer"] as? [String: Any], let template = visualizer["template"] as? String {
            output.visualizer = (template, visualizer["data"] as? String ?? "null")
        }
        if input.phase == .preRequest, let request = object["request"] as? [String: Any] {
            output.request = Self.mergeRequest(request, into: input.request)
        }
        return output
    }

    /// Applies script mutations of `pm.request` onto the original spec.
    static func mergeRequest(_ object: [String: Any], into original: RequestSpec) -> RequestSpec {
        var spec = original
        if let method = object["method"] as? String { spec.method = HTTPMethod(rawValue: method) }
        if let url = object["url"] as? String, url != original.url {
            spec.url = url
            let disabled = original.params.filter { !$0.isEnabled }
            spec.params = RawURL.queryParams(of: url) + disabled
        }
        if let headers = object["headers"] as? [[String: Any]] {
            spec.headers = headers.map {
                KeyValue(key: $0["key"] as? String ?? "", value: $0["value"] as? String ?? "", isEnabled: !($0["disabled"] as? Bool ?? false))
            }
        }
        if let body = object["body"] as? [String: Any] {
            applyBody(body, to: &spec)
        }
        return spec
    }
}
