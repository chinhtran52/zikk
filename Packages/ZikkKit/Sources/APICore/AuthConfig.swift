import Foundation

public enum AuthType: String, Codable, CaseIterable, Sendable {
    case inherit, none, basic, bearer, apiKey, digest, oauth1, oauth2, awsSigV4
}

public struct BasicAuth: Codable, Hashable, Sendable {
    public var username = ""
    public var password = ""
    public init(username: String = "", password: String = "") { self.username = username; self.password = password }
}

public struct BearerAuth: Codable, Hashable, Sendable {
    public var token = ""
    public var prefix = "Bearer"
    public init(token: String = "", prefix: String = "Bearer") { self.token = token; self.prefix = prefix }
}

public struct APIKeyAuth: Codable, Hashable, Sendable {
    public enum Location: String, Codable, CaseIterable, Sendable { case header, query }
    public var key = ""
    public var value = ""
    public var location: Location = .header
    public init(key: String = "", value: String = "", location: Location = .header) { self.key = key; self.value = value; self.location = location }
}

public struct DigestAuth: Codable, Hashable, Sendable {
    public var username = ""
    public var password = ""
    public init(username: String = "", password: String = "") { self.username = username; self.password = password }
}

public struct OAuth1Auth: Codable, Hashable, Sendable {
    public enum SignatureMethod: String, Codable, CaseIterable, Sendable {
        case hmacSHA1 = "HMAC-SHA1", hmacSHA256 = "HMAC-SHA256", plaintext = "PLAINTEXT"
    }
    public var consumerKey = ""
    public var consumerSecret = ""
    public var token = ""
    public var tokenSecret = ""
    public var signatureMethod: SignatureMethod = .hmacSHA1
    public var realm = ""
    public var addToQuery = false
    public init() {}
}

public struct OAuth2Auth: Codable, Hashable, Sendable {
    public enum GrantType: String, Codable, CaseIterable, Sendable {
        case authorizationCode, authorizationCodePKCE, clientCredentials, password
    }
    public enum ClientAuthentication: String, Codable, CaseIterable, Sendable { case basicHeader, body }

    public var grantType: GrantType = .authorizationCodePKCE
    public var authURL = ""
    public var accessTokenURL = ""
    public var callbackURL = Branding.oauthCallbackURL
    public var clientID = ""
    public var clientSecret = ""
    public var scope = ""
    public var state = ""
    public var username = ""
    public var password = ""
    public var clientAuthentication: ClientAuthentication = .basicHeader
    public var headerPrefix = "Bearer"
    /// Currently obtained token (cached).
    public var accessToken = ""
    public var refreshToken = ""
    public var expiresAt: Date?
    public init() {}
}

public struct AWSSigV4Auth: Codable, Hashable, Sendable {
    public var accessKey = ""
    public var secretKey = ""
    public var sessionToken = ""
    public var region = "us-east-1"
    public var service = ""
    public init() {}
}

/// Auth configuration. Each auth type keeps its own settings so switching types does not lose data.
public struct AuthConfig: Codable, Hashable, Sendable {
    public var type: AuthType
    public var basic = BasicAuth()
    public var bearer = BearerAuth()
    public var apiKey = APIKeyAuth()
    public var digest = DigestAuth()
    public var oauth1 = OAuth1Auth()
    public var oauth2 = OAuth2Auth()
    public var awsSigV4 = AWSSigV4Auth()

    public init(type: AuthType = .inherit) { self.type = type }

    public static let inherit = AuthConfig(type: .inherit)
    public static let none = AuthConfig(type: .none)
}
