import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A fixed token (manual paste, tests).
public struct StaticTokenProvider: AccessTokenProvider {
    public let token: String

    public init(token: String) {
        self.token = token
    }

    public func accessToken(forceRefresh: Bool) async throws -> String {
        if forceRefresh { throw HiggsfieldError.unauthorized("The pasted access token was rejected.") }
        return token
    }
}

/// Tokens from this app's own OAuth sign-in, refreshed with the refresh token
/// when they expire or when the API answers 401.
public actor OAuthTokenProvider: AccessTokenProvider {
    private let configuration: OAuthConfiguration
    private let store: TokenStore
    private let transport: HTTPTransport
    private var cached: TokenSet?

    public init(configuration: OAuthConfiguration, store: TokenStore, transport: HTTPTransport = URLSessionTransport()) {
        self.configuration = configuration
        self.store = store
        self.transport = transport
    }

    public func accessToken(forceRefresh: Bool) async throws -> String {
        // The app and the extension share this store; another process may
        // already have refreshed (and rotated) the tokens, so re-read first.
        let stored = try store.load()
        if let stored, stored != cached { cached = stored }
        guard let tokens = cached else { throw HiggsfieldError.notSignedIn }
        if !forceRefresh && !tokens.isExpired() { return tokens.accessToken }
        if let refreshTask { return try await refreshTask.value }
        let task = Task { try await self.refresh(tokens) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private var refreshTask: Task<String, Error>?

    private func refresh(_ tokens: TokenSet) async throws -> String {
        guard let refresh = tokens.refreshToken else {
            throw HiggsfieldError.unauthorized("Session expired and cannot be refreshed.")
        }
        let (data, response) = try await transport.send(configuration.refreshRequest(refreshToken: refresh))
        guard (200..<300).contains(response.statusCode) else {
            // Only discard the shared credential if nobody replaced it meanwhile.
            if let current = try? store.load(), current.refreshToken == refresh {
                try? store.clear()
                cached = nil
            } else {
                cached = try? store.load()
            }
            throw HiggsfieldError.unauthorized(HiggsfieldError.extractMessage(from: data))
        }
        let parsed = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        var updated = TokenSet(response: parsed, source: .oauth)
        if updated.refreshToken == nil { updated.refreshToken = refresh }
        try store.save(updated)
        cached = updated
        return updated.accessToken
    }

    /// Completes the authorization-code exchange after the browser redirect.
    public func completeSignIn(code: String, pkce: PKCEPair) async throws -> TokenSet {
        let (data, response) = try await transport.send(configuration.tokenExchangeRequest(code: code, pkce: pkce))
        guard (200..<300).contains(response.statusCode) else {
            throw HiggsfieldError.unauthorized(HiggsfieldError.extractMessage(from: data))
        }
        let tokens = TokenSet(response: try JSONDecoder().decode(OAuthTokenResponse.self, from: data), source: .oauth)
        try store.save(tokens)
        cached = tokens
        return tokens
    }
}

/// Reuses the session of the official Higgsfield CLI (`npm i -g @higgsfield/cli`,
/// then `hf auth login`). `hf auth token` prints the current access token and
/// refreshes it itself when it has expired, so tokens are always obtained
/// through the CLI's own supported command rather than by reading its files.
///
/// The container app runs it freely; the sandboxed extension runs it directly
/// when its sandbox exceptions allow, and otherwise asks the container app
/// (see `FallbackTokenProvider`).
public actor CLITokenProvider: AccessTokenProvider {
    private let bridge: HiggsfieldCLIBridge
    private let store: TokenStore?
    private var cached: (token: String, fetched: Date)?
    /// Tokens are re-read after this interval even without a 401.
    private let maxAge: TimeInterval

    /// How long a token from `hf auth token` is reused before asking the CLI
    /// again. A 401 always forces a fresh one immediately.
    public static let defaultMaxAge: TimeInterval = 1800

    public init(bridge: HiggsfieldCLIBridge, store: TokenStore? = nil, maxAge: TimeInterval = CLITokenProvider.defaultMaxAge) {
        self.bridge = bridge
        self.store = store
        self.maxAge = maxAge
    }

    public func accessToken(forceRefresh: Bool) async throws -> String {
        if !forceRefresh, let cached, Date().timeIntervalSince(cached.fetched) < maxAge {
            return cached.token
        }
        let token = try await bridge.accessToken()
        cached = (token, Date())
        try? store?.save(TokenSet(accessToken: token, expiresAt: Date().addingTimeInterval(maxAge), source: .higgsfieldCLI))
        return token
    }
}

/// Reads whatever the shared store holds. Used by the sandboxed workflow
/// extension; when the token is rejected it asks `refreshHandler` (which
/// wakes the container app) for a new one.
public actor StoredTokenProvider: AccessTokenProvider {
    private let store: TokenStore
    private let refreshHandler: @Sendable () async throws -> Void

    public init(store: TokenStore, refreshHandler: @escaping @Sendable () async throws -> Void) {
        self.store = store
        self.refreshHandler = refreshHandler
    }

    private var refreshTask: Task<Void, Error>?

    public func accessToken(forceRefresh: Bool) async throws -> String {
        if !forceRefresh, let tokens = try store.load(), !tokens.isExpired(leeway: 0) {
            return tokens.accessToken
        }
        // Concurrent callers (polls, cost estimate, balance) share one refresh.
        if let refreshTask {
            try await refreshTask.value
        } else {
            let task = Task { try await refreshHandler() }
            refreshTask = task
            defer { refreshTask = nil }
            try await task.value
        }
        guard let tokens = try store.load() else { throw HiggsfieldError.notSignedIn }
        return tokens.accessToken
    }
}

/// Tries `primary` (e.g. running the CLI directly) and falls back when it
/// can't provide a token at all (CLI missing, blocked, or not signed in).
public struct FallbackTokenProvider: AccessTokenProvider {
    public let primary: AccessTokenProvider
    public let fallback: AccessTokenProvider

    public init(primary: AccessTokenProvider, fallback: AccessTokenProvider) {
        self.primary = primary
        self.fallback = fallback
    }

    public func accessToken(forceRefresh: Bool) async throws -> String {
        do {
            return try await primary.accessToken(forceRefresh: forceRefresh)
        } catch HiggsfieldError.cliUnavailable {
            return try await fallback.accessToken(forceRefresh: forceRefresh)
        } catch HiggsfieldError.notSignedIn {
            return try await fallback.accessToken(forceRefresh: forceRefresh)
        }
    }
}

/// JSON file token store with 0600 permissions (used by `hfcp`; the app uses the Keychain).
public struct FileTokenStore: TokenStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> TokenSet? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TokenSet.self, from: Data(contentsOf: url))
    }

    public func save(_ tokens: TokenSet) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(tokens).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

/// In-memory store for tests and previews.
public final class MemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: TokenSet?

    public init(_ tokens: TokenSet? = nil) {
        self.tokens = tokens
    }

    public func load() throws -> TokenSet? {
        lock.lock(); defer { lock.unlock() }
        return tokens
    }

    public func save(_ tokens: TokenSet) throws {
        lock.lock(); defer { lock.unlock() }
        self.tokens = tokens
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        tokens = nil
    }
}
