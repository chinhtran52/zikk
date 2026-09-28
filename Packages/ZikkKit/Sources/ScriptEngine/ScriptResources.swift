import Foundation

/// Bundled JavaScript: the sandbox prelude and `require()`-able libraries.
enum ScriptResources {
    static let sandbox: String? = load("sandbox", subdirectory: nil)

    private static let modules: [String: String] = [
        "chai": "chai", "lodash": "lodash", "crypto-js": "crypto-js", "moment": "moment",
    ]

    private static let cache = ModuleCache()

    static func module(named name: String) -> String? {
        guard let file = modules[name] else { return nil }
        return cache.value(for: file) { load(file, subdirectory: "js") }
    }

    private static func load(_ name: String, subdirectory: String?) -> String? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "js", subdirectory: subdirectory) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

private final class ModuleCache: @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    func value(for key: String, load: () -> String?) -> String? {
        if let cached = lock.withLock({ storage[key] }) { return cached }
        guard let loaded = load() else { return nil }
        lock.withLock { storage[key] = loaded }
        return loaded
    }
}
