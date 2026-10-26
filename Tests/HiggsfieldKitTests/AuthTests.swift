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

    func testCLIBridgeLocatesExecutableOnPath() throws {
        let script = try temporaryFile(named: "hf", contents: "#!/bin/sh\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let found = HiggsfieldCLIBridge.locate(environment: ["PATH": script.deletingLastPathComponent().path, "HOME": "/nonexistent"])
        XCTAssertEqual(found?.standardizedFileURL, script.standardizedFileURL)
        XCTAssertNil(HiggsfieldCLIBridge(executableURL: nil, environment: ["PATH": "/nonexistent", "HOME": "/nonexistent"]).executableURL.flatMap { $0.path.hasPrefix("/nonexistent") ? $0 : nil })
    }
    #endif
}
