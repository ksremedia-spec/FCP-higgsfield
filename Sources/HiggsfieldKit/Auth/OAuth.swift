import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// PKCE (RFC 7636) verifier/challenge pair with the S256 method.
public struct PKCEPair: Sendable, Equatable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = Data(SHA256.hash(Array(verifier.utf8))).base64URLEncodedString()
    }

    /// 32 random bytes → 43-character verifier, the same length the official CLI uses.
    public static func generate() -> PKCEPair {
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        return PKCEPair(verifier: Data(bytes).base64URLEncodedString())
    }
}

/// Higgsfield account sign-in: OAuth 2.0 authorization code + PKCE against
/// Higgsfield's Clerk instance. Endpoints, scopes and the form body were
/// captured from the official CLI's `hf auth login`.
///
/// `clientID` must be an OAuth client issued to this app by Higgsfield. The
/// app never borrows the official CLI's client ID; when no client ID is
/// configured, sign-in goes through the official CLI instead (see
/// `HiggsfieldCLIBridge`).
public struct OAuthConfiguration: Sendable, Equatable {
    public var clientID: String
    public var redirectURI: String
    public var authorizeURL: URL
    public var tokenURL: URL
    public var scopes: [String]

    public static let higgsfieldAuthorizeURL = URL(string: "https://clerk.higgsfield.ai/oauth/authorize")!
    public static let higgsfieldTokenURL = URL(string: "https://clerk.higgsfield.ai/oauth/token")!
    public static let defaultScopes = ["email", "profile", "offline_access", "user:org:read"]

    public init(
        clientID: String,
        redirectURI: String,
        authorizeURL: URL = OAuthConfiguration.higgsfieldAuthorizeURL,
        tokenURL: URL = OAuthConfiguration.higgsfieldTokenURL,
        scopes: [String] = OAuthConfiguration.defaultScopes
    ) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.authorizeURL = authorizeURL
        self.tokenURL = tokenURL
        self.scopes = scopes
    }

    /// Reads `HiggsfieldOAuthClientID` / `HiggsfieldOAuthRedirectURI` from an
    /// Info.plist dictionary. Returns nil when the app has no client ID.
    public init?(infoDictionary: [String: Any]?) {
        guard let id = infoDictionary?["HiggsfieldOAuthClientID"] as? String,
              !id.trimmingCharacters(in: .whitespaces).isEmpty,
              !id.hasPrefix("$(")
        else { return nil }
        let redirect = (infoDictionary?["HiggsfieldOAuthRedirectURI"] as? String) ?? "http://127.0.0.1:8765/callback"
        self.init(clientID: id, redirectURI: redirect)
    }

    public func authorizationURL(pkce: PKCEPair, state: String) -> URL {
        var c = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
        ]
        return c.url!
    }

    public func tokenExchangeRequest(code: String, pkce: PKCEPair) -> URLRequest {
        formRequest([
            ("client_id", clientID),
            ("code", code),
            ("code_verifier", pkce.verifier),
            ("grant_type", "authorization_code"),
            ("redirect_uri", redirectURI),
        ])
    }

    public func refreshRequest(refreshToken: String) -> URLRequest {
        formRequest([
            ("client_id", clientID),
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
        ])
    }

    private func formRequest(_ fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncode(fields).utf8)
        return request
    }

    static func formEncode(_ fields: [(String, String)]) -> String {
        // application/x-www-form-urlencoded: unreserved characters stay literal.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
    }

    /// Parses the redirect the browser delivered and validates `state`.
    public static func authorizationCode(from callbackURL: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            throw HiggsfieldError.unauthorized(value("error_description") ?? error)
        }
        guard value("state") == expectedState else {
            throw HiggsfieldError.unauthorized("Sign-in response did not match this request (state mismatch).")
        }
        guard let code = value("code"), !code.isEmpty else {
            throw HiggsfieldError.unauthorized("Sign-in response contained no authorization code.")
        }
        return code
    }

    public static func randomState() -> String {
        PKCEPair.generate().verifier
    }
}

/// OAuth token endpoint response.
public struct OAuthTokenResponse: Decodable, Sendable {
    public var accessToken: String
    public var tokenType: String?
    public var expiresIn: Double?
    public var refreshToken: String?
    public var scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
    }
}

/// Where the current credentials came from; shown in the account menu.
public enum CredentialSource: String, Codable, Sendable {
    /// This app's own OAuth sign-in.
    case oauth
    /// Borrowed from the official Higgsfield CLI via `hf auth token`.
    case higgsfieldCLI
    /// Pasted by the user (e.g. the output of `hf auth token`).
    case manual
}

public struct TokenSet: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var source: CredentialSource

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil, source: CredentialSource) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.source = source
    }

    public init(response: OAuthTokenResponse, now: Date = Date(), source: CredentialSource = .oauth) {
        self.accessToken = response.accessToken
        self.refreshToken = response.refreshToken
        self.expiresAt = response.expiresIn.map { now.addingTimeInterval($0) }
        self.source = source
    }

    /// True when the token expires within `leeway` seconds.
    public func isExpired(now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= leeway
    }
}

/// Persists the signed-in credentials (Keychain in the app, a 0600 file for `hfcp`).
public protocol TokenStore: Sendable {
    func load() throws -> TokenSet?
    func save(_ tokens: TokenSet) throws
    func clear() throws
}
