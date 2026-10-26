#if os(macOS)
import AppKit
import Foundation
import HiggsfieldKit
import Network

/// OAuth authorization-code + PKCE sign-in with a loopback redirect
/// (RFC 8252 §7.3), the same flow the official CLI uses. Requires a client ID
/// issued to this app (`HiggsfieldOAuthClientID`).
public final class LoopbackSignIn {
    private let configuration: OAuthConfiguration
    private var listener: NWListener?

    public init(configuration: OAuthConfiguration) {
        self.configuration = configuration
    }

    /// Opens the browser and waits for the redirect. Returns the authorization code.
    public func authorize(pkce: PKCEPair, state: String, timeout: TimeInterval = 300) async throws -> String {
        guard let redirect = URL(string: configuration.redirectURI), let host = redirect.host,
              ["127.0.0.1", "localhost"].contains(host), let port = redirect.port.flatMap({ NWEndpoint.Port(rawValue: UInt16($0)) })
        else {
            throw HiggsfieldError.invalidInput("The OAuth redirect URI must be a loopback address with a port.")
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        defer { listener.cancel() }

        let authorizeURL = configuration.authorizationURL(pkce: pkce, state: state)
        let once = ResumeOnce()
        let timedOut = ResumeOnce()
        // Cancelling the listener (timeout or task cancellation) moves it to
        // `.cancelled`, which resumes the continuation, so the wait always ends.
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            if timedOut.claim() { listener.cancel() }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                listener.newConnectionHandler = { connection in
                    connection.start(queue: .main)
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                        let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                        let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                        let callback = URL(string: "http://\(host):\(port.rawValue)\(target)")
                        let result = Result { try OAuthConfiguration.authorizationCode(from: callback ?? redirect, expectedState: state) }
                        let ok = (try? result.get()) != nil
                        let body = ok
                            ? "<h2>Signed in to Higgsfield.</h2><p>You can close this tab and return to Final Cut Pro.</p>"
                            : "<h2>Sign-in didn’t complete.</h2><p>Return to Final Cut Pro and try again.</p>"
                        let html = "<!doctype html><meta charset=utf-8><body style=\"font:15px -apple-system;padding:40px;background:#111;color:#eee\">\(body)</body>"
                        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                        guard target.hasPrefix(redirect.path.isEmpty ? "/" : redirect.path), once.claim() else { return }
                        continuation.resume(with: result)
                    }
                }
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        DispatchQueue.main.async { NSWorkspace.shared.open(authorizeURL) }
                    case .failed(let error):
                        if once.claim() {
                            continuation.resume(throwing: HiggsfieldError.network("Couldn’t listen for the sign-in redirect: \(error)"))
                        }
                    case .cancelled:
                        if once.claim() {
                            continuation.resume(throwing: timedOut.claim()
                                ? CancellationError()  // cancelled by the user before the timeout fired
                                : HiggsfieldError.unauthorized("Sign-in timed out."))
                        }
                    default:
                        break
                    }
                }
                listener.start(queue: .main)
            }
        } onCancel: {
            listener.cancel()
        }
    }
}

/// Ensures the continuation is resumed exactly once across Network callbacks.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
#endif
