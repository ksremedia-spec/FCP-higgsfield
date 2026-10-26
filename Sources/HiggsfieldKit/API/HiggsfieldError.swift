import Foundation

public enum HiggsfieldError: Error, Equatable, Sendable {
    /// No credentials are available; the user must sign in.
    case notSignedIn
    /// The server rejected the access token (HTTP 401) even after a refresh attempt.
    case unauthorized(String)
    /// HTTP 402 or a credit-related refusal.
    case insufficientCredits(String)
    /// HTTP 403, e.g. a plan restriction such as `job_minimum_pro_plan_required`.
    case forbidden(String)
    /// HTTP 400/404/409/422: the request was understood but rejected.
    case rejected(status: Int, message: String)
    case rateLimited(String)
    case server(status: Int, message: String)
    case network(String)
    case decoding(String)
    case uploadFailed(String)
    /// The uploaded media was confirmed but never reached the `uploaded` state.
    case mediaNotReady(id: String, status: String)
    case jobFailed(id: String, status: String, message: String?)
    case invalidInput(String)
    case cliUnavailable(String)

    public var userMessage: String {
        switch self {
        case .notSignedIn:
            return "Sign in to your Higgsfield account to continue."
        case .unauthorized(let m):
            return "Your Higgsfield session has expired. Sign in again. (\(m))"
        case .insufficientCredits(let m):
            return "Not enough Higgsfield credits for this operation. \(m)"
        case .forbidden(let m):
            return "Higgsfield refused this request for your plan or workspace: \(m)"
        case .rejected(_, let m):
            return m
        case .rateLimited:
            return "Higgsfield is rate-limiting requests. Try again in a moment."
        case .server(let s, let m):
            return "Higgsfield server error (\(s)). \(m)"
        case .network(let m):
            return "Couldn’t reach Higgsfield: \(m)"
        case .decoding(let m):
            return "Unexpected response from Higgsfield: \(m)"
        case .uploadFailed(let m):
            return "Upload failed: \(m)"
        case .mediaNotReady(_, let status):
            return "Higgsfield did not accept the uploaded media (status “\(status)”)."
        case .jobFailed(_, let status, let m):
            if status == "nsfw" { return "Higgsfield’s moderation rejected this generation." }
            return m.map { "Generation failed: \($0)" } ?? "Generation \(status)."
        case .invalidInput(let m):
            return m
        case .cliUnavailable(let m):
            return m
        }
    }

    /// Mirrors the official SDKs: prefer `detail`, then `details`, `message`, `error`, then the raw body.
    static func extractMessage(from data: Data) -> String {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return String(decoding: data.prefix(500), as: UTF8.self)
        }
        for key in ["detail", "details", "message", "error"] {
            guard let v = value[key] else { continue }
            switch v {
            case .string(let s) where !s.isEmpty:
                return s
            case .array(let items):
                // FastAPI-style validation errors: [{"loc": [...], "msg": "..."}]
                let msgs = items.compactMap { item -> String? in
                    if let msg = item["msg"]?.stringValue {
                        let loc = item["loc"]?.arrayValue?.map(\.displayString).joined(separator: ".")
                        return loc.map { "\($0): \(msg)" } ?? msg
                    }
                    return item.stringValue
                }
                if !msgs.isEmpty { return msgs.joined(separator: "; ") }
            case .object(let o):
                if let m = o["message"]?.stringValue { return m }
            default:
                continue
            }
        }
        return String(decoding: data.prefix(500), as: UTF8.self)
    }

    static func from(status: Int, data: Data) -> HiggsfieldError {
        let message = extractMessage(from: data)
        switch status {
        case 401: return .unauthorized(message)
        case 402: return .insufficientCredits(message)
        case 403:
            if message.lowercased().contains("credit") { return .insufficientCredits(message) }
            return .forbidden(message)
        case 429: return .rateLimited(message)
        case 400..<500:
            if message.lowercased().contains("insufficient") && message.lowercased().contains("credit") {
                return .insufficientCredits(message)
            }
            return .rejected(status: status, message: message)
        default: return .server(status: status, message: message)
        }
    }
}

extension HiggsfieldError: LocalizedError {
    public var errorDescription: String? { userMessage }
}
