import Foundation

/// Product identity read from the app's Info.plist (set in `Config/Branding.xcconfig`).
/// Falls back to the default brand when running outside the app (tests, previews).
public enum Branding {
    public static let defaultName = "Zikk"
    public static let defaultBundleIdentifier = "dev.chinhtr.zikk"
    public static let defaultURLScheme = "zikk"

    private static func info(_ key: String) -> String? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Display name, e.g. "Zikk".
    public static var appName: String { info("AppBrandName") ?? defaultName }

    /// Bundle identifier, used to namespace Keychain items and queues.
    public static var bundleIdentifier: String {
        info("AppBrandName") != nil ? (Bundle.main.bundleIdentifier ?? defaultBundleIdentifier) : defaultBundleIdentifier
    }

    /// Custom URL scheme for OAuth redirects.
    public static var urlScheme: String { info("AppURLScheme") ?? defaultURLScheme }

    public static var version: String { info("AppBrandName") != nil ? (info("CFBundleShortVersionString") ?? "0.1") : "0.1" }

    /// Default `User-Agent`, e.g. "Zikk/0.1.0".
    public static var userAgent: String { "\(appName)/\(version)" }

    /// Default OAuth 2.0 redirect URI.
    public static var oauthCallbackURL: String { "\(urlScheme)://oauth/callback" }
}
