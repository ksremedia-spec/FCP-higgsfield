import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal HTTP abstraction so the client can be exercised against recorded
/// fixtures in tests and against `URLSession` in the app.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Streams a file as the request body (used for presigned media uploads).
    func upload(_ request: URLRequest, fromFile fileURL: URL) async throws -> (Data, HTTPURLResponse)
    /// Downloads to a temporary file and moves it to `destination`.
    func download(_ request: URLRequest, to destination: URL) async throws -> HTTPURLResponse
}

public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                Self.complete(continuation, data, response, error)
            }
            task.resume()
        }
    }

    public func upload(_ request: URLRequest, fromFile fileURL: URL) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.uploadTask(with: request, fromFile: fileURL) { data, response, error in
                Self.complete(continuation, data, response, error)
            }
            task.resume()
        }
    }

    public func download(_ request: URLRequest, to destination: URL) async throws -> HTTPURLResponse {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.downloadTask(with: request) { tempURL, response, error in
                if let error {
                    continuation.resume(throwing: HiggsfieldError.network(error.localizedDescription))
                    return
                }
                guard let http = response as? HTTPURLResponse, let tempURL else {
                    continuation.resume(throwing: HiggsfieldError.network("No HTTP response"))
                    return
                }
                guard (200..<300).contains(http.statusCode) else {
                    continuation.resume(throwing: HiggsfieldError.server(status: http.statusCode, message: "Download failed"))
                    return
                }
                do {
                    let fm = FileManager.default
                    try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                    try fm.moveItem(at: tempURL, to: destination)
                    continuation.resume(returning: http)
                } catch {
                    continuation.resume(throwing: HiggsfieldError.network("Couldn’t save download: \(error.localizedDescription)"))
                }
            }
            task.resume()
        }
    }

    private static func complete(
        _ continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>,
        _ data: Data?, _ response: URLResponse?, _ error: Error?
    ) {
        if let error {
            continuation.resume(throwing: HiggsfieldError.network(error.localizedDescription))
        } else if let http = response as? HTTPURLResponse {
            continuation.resume(returning: (data ?? Data(), http))
        } else {
            continuation.resume(throwing: HiggsfieldError.network("No HTTP response"))
        }
    }
}

/// Retry policy modelled on the official Higgsfield SDKs: exponential backoff on
/// 408/429/500/502/503/504. Non-idempotent requests (job submission) are only
/// retried on statuses that mean the request was not processed (408, 429, 503),
/// so a transient 500 can never silently submit — and bill — a job twice.
public struct RetryPolicy: Sendable {
    public var maxAttempts: Int
    public var initialDelay: TimeInterval
    public var backoffFactor: Double
    public var maxDelay: TimeInterval

    public static let `default` = RetryPolicy(maxAttempts: 3, initialDelay: 0.5, backoffFactor: 2, maxDelay: 8)
    public static let none = RetryPolicy(maxAttempts: 1, initialDelay: 0, backoffFactor: 1, maxDelay: 0)

    public init(maxAttempts: Int, initialDelay: TimeInterval, backoffFactor: Double, maxDelay: TimeInterval) {
        self.maxAttempts = maxAttempts
        self.initialDelay = initialDelay
        self.backoffFactor = backoffFactor
        self.maxDelay = maxDelay
    }

    func shouldRetry(attempt: Int, status: Int, idempotent: Bool) -> Bool {
        guard attempt < maxAttempts else { return false }
        let retryable: Set<Int> = idempotent ? [408, 429, 500, 502, 503, 504] : [408, 429, 503]
        return retryable.contains(status)
    }

    func delay(forAttempt attempt: Int) -> TimeInterval {
        min(initialDelay * pow(backoffFactor, Double(attempt - 1)), maxDelay)
    }
}
