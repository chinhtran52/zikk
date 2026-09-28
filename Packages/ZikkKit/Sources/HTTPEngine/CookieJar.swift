import Foundation

/// Cookie storage used by `HTTPClient`. The app persists changes via `onChange`.
public final class CookieJar: @unchecked Sendable {
    private var cookies: [HTTPCookie] = []
    private let lock = NSLock()
    /// Called after cookies are added from a response.
    public var onChange: (@Sendable ([HTTPCookie]) -> Void)?

    public init(cookies: [HTTPCookie] = []) {
        self.cookies = cookies
    }

    public var all: [HTTPCookie] {
        lock.withLock { purgeExpired(); return cookies }
    }

    public func replaceAll(_ newCookies: [HTTPCookie]) {
        lock.withLock { cookies = newCookies }
    }

    public func cookies(for url: URL) -> [HTTPCookie] {
        guard let host = url.host?.lowercased() else { return [] }
        let path = url.path.isEmpty ? "/" : url.path
        let secure = url.scheme?.lowercased() == "https"
        return lock.withLock {
            purgeExpired()
            return cookies.filter { cookie in
                Self.domainMatches(host: host, cookieDomain: cookie.domain)
                    && Self.pathMatches(requestPath: path, cookiePath: cookie.path)
                    && (!cookie.isSecure || secure)
            }
        }
    }

    public func store(responseHeaders: [String: String], for url: URL) {
        let received = HTTPCookie.cookies(withResponseHeaderFields: responseHeaders, for: url)
        guard !received.isEmpty else { return }
        let snapshot = lock.withLock { () -> [HTTPCookie] in
            for cookie in received {
                cookies.removeAll { $0.name == cookie.name && $0.domain.lowercased() == cookie.domain.lowercased() && $0.path == cookie.path }
                if let expires = cookie.expiresDate, expires < Date() { continue }
                cookies.append(cookie)
            }
            return cookies
        }
        onChange?(snapshot)
    }

    public func remove(_ cookie: HTTPCookie) {
        lock.withLock { cookies.removeAll { $0 == cookie } }
    }

    public func headerValue(for url: URL) -> String? {
        let matching = cookies(for: url)
        guard !matching.isEmpty else { return nil }
        return matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private func purgeExpired() {
        let now = Date()
        cookies.removeAll { ($0.expiresDate ?? .distantFuture) < now }
    }

    static func domainMatches(host: String, cookieDomain: String) -> Bool {
        var domain = cookieDomain.lowercased()
        if domain.hasPrefix(".") { domain.removeFirst() }
        return host == domain || host.hasSuffix("." + domain)
    }

    static func pathMatches(requestPath: String, cookiePath: String) -> Bool {
        if cookiePath.isEmpty || cookiePath == "/" { return true }
        if requestPath == cookiePath { return true }
        return requestPath.hasPrefix(cookiePath.hasSuffix("/") ? cookiePath : cookiePath + "/")
    }
}
