import Foundation
import Observation
import APICore
import APIStore
import HTTPEngine

/// A client certificate configured for a host; the passphrase lives in the secret store.
public struct ClientCertificateSetting: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var host: String
    public var file: FileReference

    public init(id: UUID = UUID(), host: String, file: FileReference) {
        self.id = id
        self.host = host
        self.file = file
    }
}

/// App preferences persisted in `UserDefaults` (secrets in the `SecretStore`).
@MainActor
@Observable
public final class SettingsStore {
    private let defaults: UserDefaults
    private let secrets: any SecretStore

    public var requestTimeoutSeconds: Int { didSet { defaults.set(requestTimeoutSeconds, forKey: Keys.timeout) } }
    public var historyLimit: Int { didSet { defaults.set(historyLimit, forKey: Keys.historyLimit) } }
    public var editorFontSize: Double { didSet { defaults.set(editorFontSize, forKey: Keys.fontSize) } }
    public var proxyEnabled: Bool { didSet { defaults.set(proxyEnabled, forKey: Keys.proxyEnabled) } }
    public var proxyHost: String { didSet { defaults.set(proxyHost, forKey: Keys.proxyHost) } }
    public var proxyPort: Int { didSet { defaults.set(proxyPort, forKey: Keys.proxyPort) } }
    public var restoresTabs: Bool { didSet { defaults.set(restoresTabs, forKey: Keys.restoresTabs) } }
    public private(set) var certificates: [ClientCertificateSetting] {
        didSet { defaults.set(try? JSONEncoder().encode(certificates), forKey: Keys.certificates) }
    }

    enum Keys {
        static let timeout = "settings.requestTimeout"
        static let historyLimit = "settings.historyLimit"
        static let fontSize = "settings.editorFontSize"
        static let proxyEnabled = "settings.proxyEnabled"
        static let proxyHost = "settings.proxyHost"
        static let proxyPort = "settings.proxyPort"
        static let restoresTabs = "settings.restoresTabs"
        static let certificates = "settings.clientCertificates"
    }

    public init(defaults: UserDefaults = .standard, secrets: any SecretStore) {
        self.defaults = defaults
        self.secrets = secrets
        requestTimeoutSeconds = defaults.object(forKey: Keys.timeout) as? Int ?? 30
        historyLimit = defaults.object(forKey: Keys.historyLimit) as? Int ?? 1000
        editorFontSize = defaults.object(forKey: Keys.fontSize) as? Double ?? 12
        proxyEnabled = defaults.bool(forKey: Keys.proxyEnabled)
        proxyHost = defaults.string(forKey: Keys.proxyHost) ?? ""
        proxyPort = defaults.object(forKey: Keys.proxyPort) as? Int ?? 8080
        restoresTabs = defaults.object(forKey: Keys.restoresTabs) as? Bool ?? true
        certificates = (defaults.data(forKey: Keys.certificates)).flatMap { try? JSONDecoder().decode([ClientCertificateSetting].self, from: $0) } ?? []
    }

    // MARK: Certificates

    func addCertificate(host: String, file: FileReference, passphrase: String) {
        let setting = ClientCertificateSetting(host: host, file: file)
        secrets.setValue(passphrase, for: Self.passphraseKey(setting.id))
        certificates.append(setting)
    }

    func removeCertificate(_ id: UUID) {
        secrets.setValue(nil, for: Self.passphraseKey(id))
        certificates.removeAll { $0.id == id }
    }

    static func passphraseKey(_ id: UUID) -> String { "certificate.\(id.uuidString)" }

    /// Network configuration for `HTTPClient`.
    public var clientConfiguration: ClientConfiguration {
        let proxy = proxyEnabled && !proxyHost.isEmpty ? ClientConfiguration.Proxy(host: proxyHost, port: proxyPort) : nil
        let certificates = certificates.map {
            ClientConfiguration.ClientCertificate(host: $0.host, pkcs12: $0.file, passphrase: secrets.value(for: Self.passphraseKey($0.id)) ?? "")
        }
        return ClientConfiguration(proxy: proxy, clientCertificates: certificates)
    }
}
