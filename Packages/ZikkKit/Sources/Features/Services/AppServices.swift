import Foundation
import APIStore
import HTTPEngine
import APICore

/// Long-lived services shared by all windows.
@MainActor
public final class AppServices {
    public let secrets: any SecretStore
    public let cookieJar: CookieJar
    public let settings: SettingsStore
    public let console = ConsoleStore()
    public let mocks = MockRegistry()

    public init(secrets: any SecretStore = KeychainSecretStore(), cookieJar: CookieJar = CookieJar(), defaults: UserDefaults = .standard) {
        self.secrets = secrets
        self.cookieJar = cookieJar
        self.settings = SettingsStore(defaults: defaults, secrets: secrets)
    }

    public var httpClient: HTTPClient {
        HTTPClient(configuration: settings.clientConfiguration, cookieJar: cookieJar)
    }

    /// Applies the default timeout to requests that do not set one.
    func applyDefaults(to spec: RequestSpec) -> RequestSpec {
        guard spec.settings.timeoutMilliseconds == 0 else { return spec }
        var spec = spec
        spec.settings.timeoutMilliseconds = settings.requestTimeoutSeconds * 1000
        return spec
    }
}
