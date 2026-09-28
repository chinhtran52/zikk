import SwiftUI
import UniformTypeIdentifiers
import APICore
import HTTPEngine

/// The app's Settings window.
public struct SettingsView: View {
    let settings: SettingsStore

    public init(settings: SettingsStore) {
        self.settings = settings
    }

    public var body: some View {
        TabView {
            GeneralSettings(settings: settings)
                .tabItem { Label(L("General"), systemImage: "gearshape") }
            ProxySettings(settings: settings)
                .tabItem { Label(L("Proxy"), systemImage: "network") }
            CertificateSettings(settings: settings)
                .tabItem { Label(L("Certificates"), systemImage: "lock.shield") }
        }
        .frame(width: 520, height: 360)
    }
}

private struct GeneralSettings: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Stepper(value: $settings.requestTimeoutSeconds, in: 1...600) {
                LabeledContent(L("Request timeout"), value: "\(settings.requestTimeoutSeconds) s")
            }
            Stepper(value: $settings.historyLimit, in: 50...10_000, step: 50) {
                LabeledContent(L("History entries to keep"), value: "\(settings.historyLimit)")
            }
            Slider(value: $settings.editorFontSize, in: 10...20, step: 1) {
                Text(L("Editor font size"))
            } minimumValueLabel: { Text(verbatim: "10") } maximumValueLabel: { Text(verbatim: "20") }
            Toggle(L("Reopen tabs from the last session"), isOn: $settings.restoresTabs)
        }
        .formStyle(.grouped)
    }
}

private struct ProxySettings: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Toggle(L("Use a custom HTTP/HTTPS proxy"), isOn: $settings.proxyEnabled)
            TextField(L("Proxy host"), text: $settings.proxyHost)
                .disabled(!settings.proxyEnabled)
            TextField(L("Proxy port"), value: $settings.proxyPort, format: .number.grouping(.never))
                .disabled(!settings.proxyEnabled)
            Text(L("When off, requests follow the system proxy configuration."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct CertificateSettings: View {
    let settings: SettingsStore
    @State private var host = ""
    @State private var passphrase = ""
    @State private var file: FileReference?
    @State private var isImporting = false

    var body: some View {
        Form {
            Section(L("Client certificates (mTLS)")) {
                if settings.certificates.isEmpty {
                    Text(L("No certificates. Add a PKCS#12 (.p12/.pfx) file for hosts that require client authentication."))
                        .foregroundStyle(.secondary)
                }
                ForEach(settings.certificates) { certificate in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(certificate.host).bold()
                            Text(certificate.file.fileName).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            settings.removeCertificate(certificate.id)
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L("Remove certificate"))
                    }
                }
            }
            Section(L("Add Certificate")) {
                TextField(L("Host (e.g. api.example.com)"), text: $host)
                HStack {
                    Button(file == nil ? L("Choose .p12 File…") : file!.fileName) { isImporting = true }
                    Spacer()
                }
                SecureField(L("Passphrase"), text: $passphrase)
                Button(L("Add")) {
                    guard let file else { return }
                    settings.addCertificate(host: host.trimmingCharacters(in: .whitespaces), file: file, passphrase: passphrase)
                    host = ""
                    passphrase = ""
                    self.file = nil
                }
                .disabled(host.isEmpty || file == nil)
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.pkcs12, .data]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            file = FileAccess.reference(for: url)
        }
    }
}
