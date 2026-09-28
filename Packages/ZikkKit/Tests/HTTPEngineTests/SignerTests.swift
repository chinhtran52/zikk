import Testing
import Foundation
import APICore
@testable import HTTPEngine

@Suite struct SignerTests {
    /// Example from Twitter's "Creating a signature" documentation.
    @Test func oauth1Signature() {
        let signature = OAuth1Signer.signature(
            method: "POST",
            baseURL: "https://api.twitter.com/1.1/statuses/update.json",
            params: [
                ("status", "Hello Ladies + Gentlemen, a signed OAuth request!"),
                ("include_entities", "true"),
                ("oauth_consumer_key", "xvz1evFS4wEEPTGEFPHBog"),
                ("oauth_nonce", "kYjzVBB8Y0ZFabxSWbWovY3uYSQ2pTgmZeNu2VS4cg"),
                ("oauth_signature_method", "HMAC-SHA1"),
                ("oauth_timestamp", "1318622958"),
                ("oauth_token", "370773112-GmHxMAgYyLbNEtIKZeRNFsMKPR9EyMZeS9weJAEb"),
                ("oauth_version", "1.0"),
            ],
            consumerSecret: "kAcSOqF21Fu85e7zjz7ZN2U4ZRhfV3WpwPAoE3Z7kBw",
            tokenSecret: "LswwdoUaIvS8ltyTt5jkRh4J50vUPVVHtR2YPi5kE",
            method: .hmacSHA1
        )
        #expect(signature == "hCtSmYh+iHYCEqBWrE7C7hYmtUk=")
    }

    /// AWS SigV4 test suite: get-vanilla.
    @Test func awsSigV4GetVanilla() throws {
        var config = AWSSigV4Auth()
        config.accessKey = "AKIDEXAMPLE"
        config.secretKey = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
        config.region = "us-east-1"
        config.service = "service"
        var request = URLRequest(url: URL(string: "https://example.amazonaws.com/")!)
        request.httpMethod = "GET"
        let date = try #require(ISO8601DateFormatter().date(from: "2015-08-30T12:36:00Z"))
        AWSSigV4Signer(config: config, date: date).sign(&request)
        #expect(request.value(forHTTPHeaderField: "Authorization") ==
            "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
    }

    /// RFC 2617 section 3.5 example.
    @Test func digestResponse() throws {
        let challenge = try #require(DigestAuthenticator.parseChallenge(#"Digest realm="testrealm@host.com", qop="auth,auth-int", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque="5ccc069c403ebaf9f0171e9517f40e41""#))
        #expect(challenge["realm"] == "testrealm@host.com")
        var authenticator = DigestAuthenticator(username: "Mufasa", password: "Circle Of Life")
        authenticator.cnonce = { "0a4f113b" }
        let header = authenticator.authorization(challenge: challenge, method: "GET", uri: "/dir/index.html", body: nil)
        #expect(header.contains(#"response="6629fae49393a05397450978507c4ef1""#))
        #expect(header.contains(#"opaque="5ccc069c403ebaf9f0171e9517f40e41""#))
    }

    @Test func pkceChallenge() {
        // RFC 7636 Appendix B.
        #expect(OAuth2Client.codeChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func parsesFormEncodedToken() throws {
        let token = try OAuth2Client.parseToken(Data("access_token=abc&token_type=bearer&expires_in=60".utf8))
        #expect(token.accessToken == "abc")
        #expect(token.expiresAt != nil)
    }

    @Test func cookieMatching() {
        #expect(CookieJar.domainMatches(host: "api.example.com", cookieDomain: ".example.com"))
        #expect(!CookieJar.domainMatches(host: "badexample.com", cookieDomain: "example.com"))
        #expect(CookieJar.pathMatches(requestPath: "/a/b", cookiePath: "/a"))
        #expect(!CookieJar.pathMatches(requestPath: "/ab", cookiePath: "/a"))
    }
}

@Suite struct RequestBuilderTests {
    @Test func resolvesVariablesAndEncodesURL() throws {
        let resolver = VariableResolver(scopes: [["base": "http://localhost:1", "q": "a b"]])
        let spec = RequestSpec(method: .get, url: "{{base}}/users/:id?search={{q}}", pathVariables: [KeyValue(key: "id", value: "42")],
                               headers: [KeyValue(key: "X-Token", value: "{{q}}"), KeyValue(key: "Off", value: "1", isEnabled: false)])
        let prepared = try RequestBuilder(resolver: resolver, auth: .none).build(spec)
        #expect(prepared.url.absoluteString == "http://localhost:1/users/42?search=a%20b")
        #expect(prepared.urlRequest.value(forHTTPHeaderField: "X-Token") == "a b")
        #expect(prepared.urlRequest.value(forHTTPHeaderField: "Off") == nil)
    }

    @Test func addsSchemeWhenMissing() throws {
        let prepared = try RequestBuilder(resolver: VariableResolver(), auth: .none).build(RequestSpec(url: "example.com/x"))
        #expect(prepared.url.absoluteString == "http://example.com/x")
    }

    @Test func rejectsEmptyURL() {
        #expect(throws: RequestBuildError.emptyURL) {
            try RequestBuilder(resolver: VariableResolver(), auth: .none).build(RequestSpec(url: "  "))
        }
    }

    @Test func urlEncodedBodyAndBasicAuth() throws {
        var auth = AuthConfig(type: .basic)
        auth.basic = BasicAuth(username: "{{user}}", password: "p")
        let body = RequestBody(mode: .urlEncoded, urlEncoded: [KeyValue(key: "a", value: "1 2"), KeyValue(key: "b&", value: "x=y")])
        let prepared = try RequestBuilder(resolver: VariableResolver(scopes: [["user": "u"]]), auth: auth)
            .build(RequestSpec(method: .post, url: "http://h/", body: body))
        #expect(String(data: prepared.urlRequest.httpBody!, encoding: .utf8) == "a=1+2&b%26=x%3Dy")
        #expect(prepared.urlRequest.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(prepared.urlRequest.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("u:p".utf8).base64EncodedString())
    }

    @Test func explicitContentTypeWins() throws {
        let spec = RequestSpec(method: .post, url: "http://h/", headers: [KeyValue(key: "Content-Type", value: "application/vnd.api+json")],
                               body: RequestBody(mode: .raw, raw: "{}", rawLanguage: .json))
        let prepared = try RequestBuilder(resolver: VariableResolver(), auth: .none).build(spec)
        #expect(prepared.urlRequest.value(forHTTPHeaderField: "Content-Type") == "application/vnd.api+json")
    }

    @Test func apiKeyInQuery() throws {
        var auth = AuthConfig(type: .apiKey)
        auth.apiKey = APIKeyAuth(key: "api_key", value: "s e", location: .query)
        let prepared = try RequestBuilder(resolver: VariableResolver(), auth: auth).build(RequestSpec(url: "http://h/p?x=1"))
        #expect(prepared.url.absoluteString == "http://h/p?x=1&api_key=s%20e")
    }

    @Test func effectiveAuthInheritance() {
        var bearer = AuthConfig(type: .bearer)
        bearer.bearer.token = "t"
        #expect(AuthConfig.effective(chain: [bearer, .inherit, .inherit]).type == .bearer)
        #expect(AuthConfig.effective(chain: [bearer, .none, .inherit]).type == .none)
        #expect(AuthConfig.effective(chain: [.inherit]).type == .none)
    }
}
