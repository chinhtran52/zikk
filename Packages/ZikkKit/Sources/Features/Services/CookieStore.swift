import Foundation
import SwiftData
import APIStore
import HTTPEngine

/// Persists the in-memory `CookieJar` to SwiftData `CookieRecord`s.
@MainActor
enum CookieStore {
    static func load(into jar: CookieJar, context: ModelContext) {
        let records = (try? context.fetch(FetchDescriptor<CookieRecord>())) ?? []
        jar.replaceAll(records.compactMap(cookie(from:)))
    }

    static func save(_ jar: CookieJar, context: ModelContext) {
        let records = (try? context.fetch(FetchDescriptor<CookieRecord>())) ?? []
        records.forEach(context.delete)
        for cookie in jar.all {
            context.insert(CookieRecord(domain: cookie.domain, path: cookie.path, name: cookie.name, value: cookie.value,
                                        expiresAt: cookie.expiresDate, isSecure: cookie.isSecure, isHTTPOnly: cookie.isHTTPOnly,
                                        sameSite: cookie.sameSitePolicy?.rawValue))
        }
        try? context.save()
    }

    static func cookie(from record: CookieRecord) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: record.domain, .path: record.path, .name: record.name, .value: record.value,
        ]
        if let expires = record.expiresAt { properties[.expires] = expires }
        if record.isSecure { properties[.secure] = "TRUE" }
        if record.isHTTPOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let sameSite = record.sameSite { properties[.sameSitePolicy] = sameSite }
        return HTTPCookie(properties: properties)
    }
}
