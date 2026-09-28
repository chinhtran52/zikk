import SwiftUI
import AuthenticationServices
import APICore
import HTTPEngine

extension AuthType {
    var title: String {
        switch self {
        case .inherit: L("Inherit auth from parent")
        case .none: L("No Auth")
        case .basic: L("Basic Auth")
        case .bearer: L("Bearer Token")
        case .apiKey: L("API Key")
        case .digest: L("Digest Auth")
        case .oauth1: L("OAuth 1.0")
        case .oauth2: L("OAuth 2.0")
        case .awsSigV4: L("AWS Signature")
        }
    }
}

/// Editor for an `AuthConfig`, used by requests, folders and collections.
struct AuthEditor: View {
    @Binding var auth: AuthConfig
    let allowsInherit: Bool
    /// Resolver for `{{variables}}` used when fetching OAuth 2.0 tokens.
    let resolver: () -> VariableResolver

    var body: some View {
        Form {
            Picker(L("Type"), selection: $auth.type) {
                ForEach(AuthType.allCases.filter { allowsInherit || $0 != .inherit }, id: \.self) { type in
                    Text(type.title).tag(type)
                }
            }
            switch auth.type {
            case .inherit:
                Text(L("This request uses the authorization of its parent folder or collection."))
                    .foregroundStyle(.secondary)
            case .none:
                Text(L("This request does not use any authorization."))
                    .foregroundStyle(.secondary)
            case .basic:
                TextField(L("Username"), text: $auth.basic.username)
                SecureField(L("Password"), text: $auth.basic.password)
            case .bearer:
                TextField(L("Token"), text: $auth.bearer.token)
                TextField(L("Prefix"), text: $auth.bearer.prefix)
            case .apiKey:
                TextField(L("Key"), text: $auth.apiKey.key)
                TextField(L("Value"), text: $auth.apiKey.value)
                Picker(L("Add to"), selection: $auth.apiKey.location) {
                    Text(L("Header")).tag(APIKeyAuth.Location.header)
                    Text(L("Query Params")).tag(APIKeyAuth.Location.query)
                }
            case .digest:
                TextField(L("Username"), text: $auth.digest.username)
                SecureField(L("Password"), text: $auth.digest.password)
            case .oauth1:
                OAuth1Fields(config: $auth.oauth1)
            case .oauth2:
                OAuth2Fields(config: $auth.oauth2, resolver: resolver)
            case .awsSigV4:
                TextField(L("Access Key"), text: $auth.awsSigV4.accessKey)
                SecureField(L("Secret Key"), text: $auth.awsSigV4.secretKey)
                TextField(L("AWS Region"), text: $auth.awsSigV4.region)
                TextField(L("Service Name"), text: $auth.awsSigV4.service)
                TextField(L("Session Token"), text: $auth.awsSigV4.sessionToken)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .font(.body)
    }
}

private struct OAuth1Fields: View {
    @Binding var config: OAuth1Auth

    var body: some View {
        Picker(L("Signature Method"), selection: $config.signatureMethod) {
            ForEach(OAuth1Auth.SignatureMethod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        TextField(L("Consumer Key"), text: $config.consumerKey)
        SecureField(L("Consumer Secret"), text: $config.consumerSecret)
        TextField(L("Access Token"), text: $config.token)
        SecureField(L("Token Secret"), text: $config.tokenSecret)
        TextField(L("Realm"), text: $config.realm)
        Toggle(L("Add parameters to URL instead of header"), isOn: $config.addToQuery)
    }
}

extension OAuth2Auth.GrantType {
    var title: String {
        switch self {
        case .authorizationCode: L("Authorization Code")
        case .authorizationCodePKCE: L("Authorization Code (With PKCE)")
        case .clientCredentials: L("Client Credentials")
        case .password: L("Password Credentials")
        }
    }
}

private struct OAuth2Fields: View {
    @Binding var config: OAuth2Auth
    let resolver: () -> VariableResolver
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var isFetching = false
    @State private var errorMessage: String?

    var body: some View {
        Section(L("Current Token")) {
            TextField(L("Access Token"), text: $config.accessToken)
                .font(.system(.body, design: .monospaced))
            TextField(L("Header Prefix"), text: $config.headerPrefix)
            if let expiresAt = config.expiresAt {
                LabeledContent(L("Expires"), value: expiresAt.formatted(date: .abbreviated, time: .standard))
                    .foregroundStyle(expiresAt < .now ? .red : .secondary)
            }
        }
        Section(L("Configure New Token")) {
            Picker(L("Grant Type"), selection: $config.grantType) {
                ForEach(OAuth2Auth.GrantType.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if config.grantType == .authorizationCode || config.grantType == .authorizationCodePKCE {
                TextField(L("Callback URL"), text: $config.callbackURL)
                TextField(L("Auth URL"), text: $config.authURL)
            }
            TextField(L("Access Token URL"), text: $config.accessTokenURL)
            TextField(L("Client ID"), text: $config.clientID)
            SecureField(L("Client Secret"), text: $config.clientSecret)
            if config.grantType == .password {
                TextField(L("Username"), text: $config.username)
                SecureField(L("Password"), text: $config.password)
            }
            TextField(L("Scope"), text: $config.scope)
            if config.grantType == .authorizationCode || config.grantType == .authorizationCodePKCE {
                TextField(L("State"), text: $config.state)
            }
            Picker(L("Client Authentication"), selection: $config.clientAuthentication) {
                Text(L("Send as Basic Auth header")).tag(OAuth2Auth.ClientAuthentication.basicHeader)
                Text(L("Send client credentials in body")).tag(OAuth2Auth.ClientAuthentication.body)
            }
            HStack {
                Button(L("Get New Access Token"), action: fetchToken)
                    .disabled(isFetching)
                if !config.refreshToken.isEmpty {
                    Button(L("Refresh Token"), action: refresh)
                        .disabled(isFetching)
                }
                if isFetching { ProgressView().controlSize(.small) }
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.caption)
            }
        }
    }

    private func apply(_ token: OAuth2Client.TokenResponse) {
        config.accessToken = token.accessToken
        config.refreshToken = token.refreshToken ?? config.refreshToken
        config.expiresAt = token.expiresAt
    }

    private func refresh() {
        run { client, resolved in try await client.refresh(resolved) }
    }

    private func fetchToken() {
        let session = webAuthenticationSession
        run { client, resolved in
            switch resolved.grantType {
            case .clientCredentials:
                return try await client.clientCredentials(resolved)
            case .password:
                return try await client.password(resolved)
            case .authorizationCode, .authorizationCodePKCE:
                let verifier = resolved.grantType == .authorizationCodePKCE ? OAuth2Client.makeCodeVerifier() : nil
                guard let url = OAuth2Client.authorizationURL(config: resolved, codeChallenge: verifier.map(OAuth2Client.codeChallenge)),
                      let scheme = URL(string: resolved.callbackURL)?.scheme else { throw OAuth2Client.Failure.missingURL }
                let callback = try await session.authenticate(using: url, callbackURLScheme: scheme, preferredBrowserSession: .ephemeral)
                guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value else {
                    throw OAuth2Client.Failure.invalidResponse
                }
                return try await client.exchangeCode(code, config: resolved, codeVerifier: verifier)
            }
        }
    }

    private func run(_ operation: @escaping @MainActor (OAuth2Client, OAuth2Auth) async throws -> OAuth2Client.TokenResponse) {
        let resolved = resolver().resolveStrings(in: config)
        isFetching = true
        errorMessage = nil
        Task {
            do {
                apply(try await operation(OAuth2Client(), resolved))
            } catch {
                errorMessage = error.localizedDescription
            }
            isFetching = false
        }
    }
}
