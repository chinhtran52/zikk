import Foundation
import APICore

/// App-wide network settings.
public struct ClientConfiguration: Sendable {
    public struct Proxy: Sendable, Hashable {
        public var host: String
        public var port: Int
        public init(host: String, port: Int) { self.host = host; self.port = port }
    }

    public struct ClientCertificate: Sendable, Hashable {
        /// Host the certificate applies to (exact match).
        public var host: String
        public var pkcs12: FileReference
        public var passphrase: String
        public init(host: String, pkcs12: FileReference, passphrase: String) { self.host = host; self.pkcs12 = pkcs12; self.passphrase = passphrase }
    }

    public var proxy: Proxy?
    public var clientCertificates: [ClientCertificate]

    public init(proxy: Proxy? = nil, clientCertificates: [ClientCertificate] = []) {
        self.proxy = proxy
        self.clientCertificates = clientCertificates
    }
}

public enum HTTPClientError: LocalizedError {
    case notHTTPResponse
    case tooManyRedirects

    public var errorDescription: String? {
        switch self {
        case .notHTTPResponse: "The server did not return an HTTP response."
        case .tooManyRedirects: "Exceeded the maximum number of redirects."
        }
    }
}

/// Executes prepared requests with per-request redirect, TLS and cookie handling, collecting timing metrics.
public struct HTTPClient: Sendable {
    public var configuration: ClientConfiguration
    public var cookieJar: CookieJar?

    public init(configuration: ClientConfiguration = ClientConfiguration(), cookieJar: CookieJar? = nil) {
        self.configuration = configuration
        self.cookieJar = cookieJar
    }

    public func send(_ prepared: PreparedRequest) async throws -> ResponseSnapshot {
        var request = prepared.urlRequest
        let jar = prepared.settings.disableCookieJar ? nil : cookieJar
        if let jar, request.value(forHTTPHeaderField: "Cookie") == nil, let cookie = jar.headerValue(for: prepared.url) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        var snapshot = try await perform(request, settings: prepared.settings, jar: jar)

        if prepared.auth.type == .digest, snapshot.statusCode == 401,
           let header = snapshot.header("WWW-Authenticate"), let challenge = DigestAuthenticator.parseChallenge(header) {
            let authenticator = DigestAuthenticator(username: prepared.auth.digest.username, password: prepared.auth.digest.password)
            var uri = request.url?.path ?? "/"
            if uri.isEmpty { uri = "/" }
            if let query = request.url?.query { uri += "?" + query }
            request.setValue(authenticator.authorization(challenge: challenge, method: request.httpMethod ?? "GET", uri: uri, body: request.httpBody), forHTTPHeaderField: "Authorization")
            let first = snapshot.timings.total
            snapshot = try await perform(request, settings: prepared.settings, jar: jar)
            snapshot.timings.total += first
        }
        return snapshot
    }

    private func perform(_ request: URLRequest, settings: RequestSettings, jar: CookieJar?) async throws -> ResponseSnapshot {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.httpCookieAcceptPolicy = .never
        sessionConfiguration.urlCache = nil
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.timeoutIntervalForRequest = request.timeoutInterval
        if let proxy = configuration.proxy {
            sessionConfiguration.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable: true, kCFNetworkProxiesHTTPProxy: proxy.host, kCFNetworkProxiesHTTPPort: proxy.port,
                kCFNetworkProxiesHTTPSEnable: true, kCFNetworkProxiesHTTPSProxy: proxy.host, kCFNetworkProxiesHTTPSPort: proxy.port,
            ] as [AnyHashable: Any]
        }
        let delegate = TaskDelegate(settings: settings, jar: jar, clientCertificates: configuration.clientCertificates)
        let session = URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let started = Date()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HTTPClientError.notHTTPResponse }
        if let redirectError = delegate.redirectError { throw redirectError }

        let headerFields = http.allHeaderFields.compactMap { key, value -> (String, String)? in
            guard let key = key as? String else { return nil }
            return (key, "\(value)")
        }
        if let jar, let url = http.url {
            jar.store(responseHeaders: Dictionary(headerFields, uniquingKeysWith: { a, _ in a }), for: url)
        }
        let headers = headerFields.sorted { $0.0.lowercased() < $1.0.lowercased() }.map { KeyValue(key: $0.0, value: $0.1) }
        var timings = delegate.timings ?? ResponseTimings()
        if timings.total == 0 { timings.total = Date().timeIntervalSince(started) * 1000 }
        let sent = delegate.sentRequest ?? request
        let sentHeaders = (sent.allHTTPHeaderFields ?? [:]).sorted { $0.key.lowercased() < $1.key.lowercased() }.map { KeyValue(key: $0.key, value: $0.value) }
        let sentRequest = SentRequest(method: sent.httpMethod ?? "GET", url: sent.url?.absoluteString ?? "", headers: sentHeaders, bodySize: request.httpBody?.count ?? 0)
        return ResponseSnapshot(statusCode: http.statusCode, headers: headers, body: data, url: http.url?.absoluteString ?? "", httpVersion: delegate.protocolName ?? "HTTP/1.1", timings: timings, sentRequest: sentRequest)
    }
}

private final class TaskDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let settings: RequestSettings
    let jar: CookieJar?
    let clientCertificates: [ClientConfiguration.ClientCertificate]
    var redirectCount = 0
    var redirectError: Error?
    var timings: ResponseTimings?
    var protocolName: String?
    var sentRequest: URLRequest?

    init(settings: RequestSettings, jar: CookieJar?, clientCertificates: [ClientConfiguration.ClientCertificate]) {
        self.settings = settings
        self.jar = jar
        self.clientCertificates = clientCertificates
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        if let jar, let url = response.url {
            let fields = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                if let key = pair.key as? String { result[key] = "\(pair.value)" }
            }
            jar.store(responseHeaders: fields, for: url)
        }
        guard settings.followRedirects else { return nil }
        redirectCount += 1
        if redirectCount > settings.maxRedirects {
            redirectError = HTTPClientError.tooManyRedirects
            return nil
        }
        var next = request
        if let jar, let url = next.url {
            next.setValue(jar.headerValue(for: url), forHTTPHeaderField: "Cookie")
        }
        return next
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            if !settings.verifySSL, let trust = challenge.protectionSpace.serverTrust {
                return (.useCredential, URLCredential(trust: trust))
            }
            return (.performDefaultHandling, nil)
        case NSURLAuthenticationMethodClientCertificate:
            let host = challenge.protectionSpace.host
            if let certificate = clientCertificates.first(where: { $0.host.caseInsensitiveCompare(host) == .orderedSame }),
               let credential = Self.credential(for: certificate) {
                return (.useCredential, credential)
            }
            return (.performDefaultHandling, nil)
        default:
            // Basic/Digest are applied explicitly; never prompt or use stored credentials.
            return (.performDefaultHandling, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let total = metrics.taskInterval.duration * 1000
        sentRequest = metrics.transactionMetrics.last?.request
        guard let transaction = metrics.transactionMetrics.last else {
            timings = ResponseTimings(total: total)
            return
        }
        func ms(_ start: Date?, _ end: Date?) -> Double? {
            guard let start, let end else { return nil }
            return end.timeIntervalSince(start) * 1000
        }
        timings = ResponseTimings(
            dns: ms(transaction.domainLookupStartDate, transaction.domainLookupEndDate),
            connect: ms(transaction.connectStartDate, transaction.secureConnectionStartDate ?? transaction.connectEndDate),
            tls: ms(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate),
            request: ms(transaction.requestStartDate, transaction.requestEndDate),
            firstByte: ms(transaction.requestEndDate, transaction.responseStartDate),
            download: ms(transaction.responseStartDate, transaction.responseEndDate),
            total: total
        )
        protocolName = transaction.networkProtocolName.map { name in
            switch name {
            case "h2": "HTTP/2"
            case "h3": "HTTP/3"
            case "http/1.0": "HTTP/1.0"
            default: "HTTP/1.1"
            }
        }
    }

    static func credential(for certificate: ClientConfiguration.ClientCertificate) -> URLCredential? {
        guard let data = try? FileAccess.read(certificate.pkcs12) else { return nil }
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: certificate.passphrase] as CFDictionary
        guard SecPKCS12Import(data as CFData, options, &items) == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let identityRef = first[kSecImportItemIdentity as String] else { return nil }
        let identity = identityRef as! SecIdentity
        return URLCredential(identity: identity, certificates: nil, persistence: .forSession)
    }
}
