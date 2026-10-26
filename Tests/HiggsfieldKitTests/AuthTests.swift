import XCTest
@testable import HiggsfieldKit

final class AuthTests: XCTestCase {
    func testSHA256Vectors() {
        func hex(_ s: String) -> String { SHA256.hash(Array(s.utf8)).map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(hex(String(repeating: "a", count: 1000)),
                       "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    func testPKCEChallengeMatchesRFC7636AppendixB() {
        let pair = PKCEPair(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(pair.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testGeneratedVerifierHasCLILength() {
        let pair = PKCEPair.generate()
        XCTAssertEqual(pair.verifier.count, 43)
        XCTAssertFalse(pair.verifier.contains("="))
        XCTAssertNotEqual(pair.verifier, PKCEPair.generate().verifier)
    }

    func testAuthorizationURLHasCapturedParameters() throws {
        let config = OAuthConfiguration(clientID: "APP_CLIENT", redirectURI: "http://127.0.0.1:8765/callback")
        let pkce = PKCEPair(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = config.authorizationURL(pkce: pkce, state: "STATE")
        let c = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(c.host, "clerk.higgsfield.ai")
        XCTAssertEqual(c.path, "/oauth/authorize")
        let q = Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["client_id"], "APP_CLIENT")
        XCTAssertEqual(q["code_challenge"], "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["redirect_uri"], "http://127.0.0.1:8765/callback")
        XCTAssertEqual(q["response_type"], "code")
        XCTAssertEqual(q["scope"], "email profile offline_access user:org:read")
        XCTAssertEqual(q["state"], "STATE")
    }

    func testTokenRequestsMatchCLIFormBodies() {
        let config = OAuthConfiguration(clientID: "APP_CLIENT", redirectURI: "http://localhost:8765/callback")
        let pkce = PKCEPair(verifier: "i7z5TAkna2ofPBTpSpTdyjiJk-EK9TkDJ5BSEWT3V3g")
        let exchange = config.tokenExchangeRequest(code: "FAKECODE", pkce: pkce)
        XCTAssertEqual(exchange.url?.absoluteString, "https://clerk.higgsfield.ai/oauth/token")
        XCTAssertEqual(exchange.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        // Captured from `hf auth login` (only client_id differs):
        XCTAssertEqual(String(decoding: exchange.httpBody!, as: UTF8.self),
                       "client_id=APP_CLIENT&code=FAKECODE&code_verifier=i7z5TAkna2ofPBTpSpTdyjiJk-EK9TkDJ5BSEWT3V3g&grant_type=authorization_code&redirect_uri=http%3A%2F%2Flocalhost%3A8765%2Fcallback")
        let refresh = config.refreshRequest(refreshToken: "MOCK_REFRESH")
        // Captured from `hf auth token` with an expired session:
        XCTAssertEqual(String(decoding: refresh.httpBody!, as: UTF8.self),
                       "client_id=APP_CLIENT&grant_type=refresh_token&refresh_token=MOCK_REFRESH")
    }

    func testCallbackParsing() throws {
        let ok = URL(string: "http://127.0.0.1:8765/callback?code=abc&state=S1")!
        XCTAssertEqual(try OAuthConfiguration.authorizationCode(from: ok, expectedState: "S1"), "abc")
        XCTAssertThrowsError(try OAuthConfiguration.authorizationCode(from: ok, expectedState: "OTHER"))
        let denied = URL(string: "http://127.0.0.1:8765/callback?error=access_denied&state=S1")!
        XCTAssertThrowsError(try OAuthConfiguration.authorizationCode(from: denied, expectedState: "S1"))
    }

    func testOAuthConfigurationFromInfoPlist() {
        XCTAssertNil(OAuthConfiguration(infoDictionary: [:]))
        XCTAssertNil(OAuthConfiguration(infoDictionary: ["HiggsfieldOAuthClientID": "$(HIGGSFIELD_OAUTH_CLIENT_ID)"]))
        XCTAssertNil(OAuthConfiguration(infoDictionary: ["HiggsfieldOAuthClientID": "  "]))
        let c = OAuthConfiguration(infoDictionary: ["HiggsfieldOAuthClientID": "abc", "HiggsfieldOAuthRedirectURI": "hffcp://oauth"])
        XCTAssertEqual(c?.clientID, "abc")
        XCTAssertEqual(c?.redirectURI, "hffcp://oauth")
    }

    func testOAuthProviderRefreshesExpiredTokens() async throws {
        let t = MockTransport()
        t.on("POST", "clerk.higgsfield.ai/oauth/token", json: #"{"access_token":"NEW","token_type":"Bearer","expires_in":3600}"#)
        let store = MemoryTokenStore(TokenSet(accessToken: "OLD", refreshToken: "R1", expiresAt: Date(timeIntervalSinceNow: -10), source: .oauth))
        let provider = OAuthTokenProvider(configuration: OAuthConfiguration(clientID: "C", redirectURI: "http://127.0.0.1/cb"), store: store, transport: t)
        let token = try await provider.accessToken(forceRefresh: false)
        XCTAssertEqual(token, "NEW")
        XCTAssertEqual(try store.load()?.refreshToken, "R1", "refresh token is kept when the server doesn't rotate it")
        XCTAssertEqual(t.requests.first?.bodyString, "client_id=C&grant_type=refresh_token&refresh_token=R1")
        let again = try await provider.accessToken(forceRefresh: false)
        XCTAssertEqual(again, "NEW")
        XCTAssertEqual(t.requests.count, 1)
    }

    func testStoredProviderCoalescesConcurrentRefreshes() async throws {
        let store = MemoryTokenStore(TokenSet(accessToken: "OLD", expiresAt: Date(timeIntervalSinceNow: -5), source: .higgsfieldCLI))
        let counter = Counter()
        let provider = StoredTokenProvider(store: store) {
            await counter.increment()
            try await Task.sleep(nanoseconds: 50_000_000)
            try store.save(TokenSet(accessToken: "NEW", expiresAt: Date(timeIntervalSinceNow: 600), source: .higgsfieldCLI))
        }
        let tokens = try await withThrowingTaskGroup(of: String.self) { group -> [String] in
            for _ in 0..<5 { group.addTask { try await provider.accessToken(forceRefresh: false) } }
            var out: [String] = []
            for try await t in group { out.append(t) }
            return out
        }
        XCTAssertEqual(tokens, Array(repeating: "NEW", count: 5))
        let calls = await counter.value
        XCTAssertEqual(calls, 1, "one refresh for concurrent callers")
    }

    func testOAuthProviderUsesTokensRotatedByAnotherProcess() async throws {
        let t = MockTransport()
        let store = MemoryTokenStore(TokenSet(accessToken: "A1", refreshToken: "R1", expiresAt: Date(timeIntervalSinceNow: 600), source: .oauth))
        let provider = OAuthTokenProvider(configuration: OAuthConfiguration(clientID: "C", redirectURI: "x"), store: store, transport: t)
        let first = try await provider.accessToken(forceRefresh: false)
        XCTAssertEqual(first, "A1")
        // The other process refreshed and rotated the shared credential.
        try store.save(TokenSet(accessToken: "A2", refreshToken: "R2", expiresAt: Date(timeIntervalSinceNow: 600), source: .oauth))
        let second = try await provider.accessToken(forceRefresh: false)
        XCTAssertEqual(second, "A2")
        XCTAssertTrue(t.requests.isEmpty, "no refresh needed")
    }

    func testFailedRefreshDoesNotClearACredentialReplacedMeanwhile() async throws {
        let t = MockTransport()
        let store = MemoryTokenStore(TokenSet(accessToken: "A1", refreshToken: "R1", expiresAt: Date(timeIntervalSinceNow: -5), source: .oauth))
        t.on("POST", "oauth/token", status: 400, json: #"{"error":"invalid_grant"}"#)
        let provider = OAuthTokenProvider(configuration: OAuthConfiguration(clientID: "C", redirectURI: "x"), store: store, transport: t)
        do { _ = try await provider.accessToken(forceRefresh: false); XCTFail() } catch {}
        XCTAssertNil(try store.load(), "our own stale credential is cleared")

        let store2 = ReplacingStore(initial: TokenSet(accessToken: "A1", refreshToken: "R1", expiresAt: Date(timeIntervalSinceNow: -5), source: .oauth),
                                    replacement: TokenSet(accessToken: "B", refreshToken: "R9", expiresAt: Date(timeIntervalSinceNow: 600), source: .oauth))
        let provider2 = OAuthTokenProvider(configuration: OAuthConfiguration(clientID: "C", redirectURI: "x"), store: store2, transport: t)
        do { _ = try await provider2.accessToken(forceRefresh: false); XCTFail() } catch {}
        XCTAssertEqual(try store2.load()?.accessToken, "B", "a credential written by the other process survives")
    }

    func testFallbackProviderUsesAppWhenCLIUnavailable() async throws {
        struct Failing: AccessTokenProvider {
            let error: HiggsfieldError
            func accessToken(forceRefresh: Bool) async throws -> String { throw error }
        }
        let viaApp = StaticTokenProvider(token: "FROM_APP")
        let blocked = FallbackTokenProvider(primary: Failing(error: .cliUnavailable("sandbox")), fallback: viaApp)
        let blockedToken = try await blocked.accessToken(forceRefresh: false)
        XCTAssertEqual(blockedToken, "FROM_APP")
        let loggedOut = FallbackTokenProvider(primary: Failing(error: .notSignedIn), fallback: viaApp)
        let loggedOutToken = try await loggedOut.accessToken(forceRefresh: false)
        XCTAssertEqual(loggedOutToken, "FROM_APP")
        let direct = FallbackTokenProvider(primary: StaticTokenProvider(token: "DIRECT"), fallback: viaApp)
        let directToken = try await direct.accessToken(forceRefresh: false)
        XCTAssertEqual(directToken, "DIRECT")
        // Other failures (e.g. a rejected token) are not hidden by the fallback.
        let rejected = FallbackTokenProvider(primary: Failing(error: .unauthorized("bad")), fallback: viaApp)
        do { _ = try await rejected.accessToken(forceRefresh: true); XCTFail() } catch let e as HiggsfieldError {
            XCTAssertEqual(e, .unauthorized("bad"))
        }
    }

    func testOAuthProviderWithoutTokensRequiresSignIn() async {
        let provider = OAuthTokenProvider(configuration: OAuthConfiguration(clientID: "C", redirectURI: "x"), store: MemoryTokenStore(), transport: MockTransport())
        do {
            _ = try await provider.accessToken(forceRefresh: false)
            XCTFail()
        } catch let e as HiggsfieldError {
            XCTAssertEqual(e, .notSignedIn)
        } catch { XCTFail("\(error)") }
    }

    func testFileTokenStoreRoundTripWithPrivatePermissions() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hfcp-\(UUID().uuidString)/credentials.json")
        let store = FileTokenStore(url: url)
        XCTAssertNil(try store.load())
        let tokens = TokenSet(accessToken: "A", refreshToken: "R", expiresAt: Date(timeIntervalSince1970: 1_800_000_000), source: .manual)
        try store.save(tokens)
        XCTAssertEqual(try store.load(), tokens)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        try store.clear()
        XCTAssertNil(try store.load())
    }

    #if !os(Windows)
    func testCLIBridgeDrainsLargeOutputWithoutBlocking() async throws {
        // > 64 KB on stderr would block a CLI whose pipes are read only at exit.
        let script = try temporaryFile(named: "hf", contents: """
        #!/bin/sh
        i=0; while [ $i -lt 3000 ]; do echo "log line $i padding padding padding padding padding" >&2; i=$((i+1)); done
        echo "BIG_OUTPUT_TOKEN"
        """)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let start = Date()
        let token = try await HiggsfieldCLIBridge(executableURL: script, environment: [:]).accessToken()
        XCTAssertEqual(token, "BIG_OUTPUT_TOKEN")
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testCLIBridgeReadsTokenFromOfficialCommand() async throws {
        let script = try temporaryFile(named: "hf", contents: """
        #!/bin/sh
        if [ "$1 $2" = "auth token" ]; then echo "TOKEN_FROM_CLI"; exit 0; fi
        exit 3
        """)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let bridge = HiggsfieldCLIBridge(executableURL: script, environment: [:])
        let token = try await bridge.accessToken()
        XCTAssertEqual(token, "TOKEN_FROM_CLI")
    }

    func testCLIBridgeMapsNotAuthenticated() async throws {
        let script = try temporaryFile(named: "hf", contents: """
        #!/bin/sh
        echo "Error: Not authenticated." >&2
        echo "Hint: Run: hf auth login" >&2
        exit 1
        """)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        do {
            _ = try await HiggsfieldCLIBridge(executableURL: script, environment: [:]).accessToken()
            XCTFail()
        } catch let e as HiggsfieldError {
            XCTAssertEqual(e, .notSignedIn)
        }
    }

    func testCLIBridgeResolvesNpmShimToNativeBinary() throws {
        // Layout of `npm install -g @higgsfield/cli`:
        //   <prefix>/bin/higgsfield -> ../lib/node_modules/@higgsfield/cli/bin/higgsfield.js
        //   <prefix>/lib/node_modules/@higgsfield/cli/vendor/hf
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent("npm-\(UUID().uuidString)")
        let pkg = prefix.appendingPathComponent("lib/node_modules/@higgsfield/cli")
        let fm = FileManager.default
        try fm.createDirectory(at: pkg.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: pkg.appendingPathComponent("vendor"), withIntermediateDirectories: true)
        try fm.createDirectory(at: prefix.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let shim = pkg.appendingPathComponent("bin/higgsfield.js")
        try Data("#!/usr/bin/env node\nrequire('./run.js')();\n".utf8).write(to: shim)
        let native = pkg.appendingPathComponent("vendor/hf")
        try Data("#!/bin/sh\necho NATIVE_TOKEN\n".utf8).write(to: native)
        for f in [shim, native] { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path) }
        try fm.createSymbolicLink(atPath: prefix.appendingPathComponent("bin/higgsfield").path,
                                  withDestinationPath: "../lib/node_modules/@higgsfield/cli/bin/higgsfield.js")

        let found = HiggsfieldCLIBridge.locate(environment: ["PATH": prefix.appendingPathComponent("bin").path, "HOME": "/nonexistent"])
        XCTAssertEqual(found?.path, native.standardizedFileURL.path, "the Node shim is bypassed in favour of vendor/hf")
        let token = try XCTUnwrap(found)
        XCTAssertEqual(HiggsfieldCLIBridge(executableURL: token, environment: [:]).executableURL, token)
    }

    func testCLIBridgeLocatesExecutableOnPath() throws {
        let script = try temporaryFile(named: "hf", contents: "#!/bin/sh\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let found = HiggsfieldCLIBridge.locate(environment: ["PATH": script.deletingLastPathComponent().path, "HOME": "/nonexistent"])
        XCTAssertEqual(found?.standardizedFileURL, script.standardizedFileURL)
        XCTAssertNil(HiggsfieldCLIBridge(executableURL: nil, environment: ["PATH": "/nonexistent", "HOME": "/nonexistent"]).executableURL.flatMap { $0.path.hasPrefix("/nonexistent") ? $0 : nil })
    }
    #endif
}

actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// Simulates the other process replacing the credential right after we read it.
final class ReplacingStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: TokenSet?
    private var replacement: TokenSet?
    private var reads = 0

    init(initial: TokenSet, replacement: TokenSet) {
        tokens = initial
        self.replacement = replacement
    }

    func load() throws -> TokenSet? {
        lock.lock(); defer { lock.unlock() }
        reads += 1
        if reads == 2, let r = replacement { tokens = r; replacement = nil }
        return tokens
    }

    func save(_ tokens: TokenSet) throws { lock.lock(); self.tokens = tokens; lock.unlock() }
    func clear() throws { lock.lock(); tokens = nil; lock.unlock() }
}
