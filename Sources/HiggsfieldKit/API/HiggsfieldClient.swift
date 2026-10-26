import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Supplies bearer tokens for the Higgsfield account API.
public protocol AccessTokenProvider: Sendable {
    /// Returns a usable access token. `forceRefresh` is set after the server
    /// rejected the previous token with HTTP 401.
    func accessToken(forceRefresh: Bool) async throws -> String
}

public struct HiggsfieldConfiguration: Sendable {
    /// Base URL of the account ("plan credits") API used by the official
    /// Higgsfield CLI, MCP server and Adobe plugins.
    public var baseURL: URL
    public var userAgent: String
    public var retryPolicy: RetryPolicy
    /// How long to wait for an uploaded media item to reach `uploaded`.
    public var mediaConfirmAttempts: Int
    public var mediaConfirmDelay: TimeInterval

    public static let defaultBaseURL = URL(string: "https://fnf-api-gw.higgsfield.ai/fnf/developer/v2alpha")!

    public init(
        baseURL: URL = HiggsfieldConfiguration.defaultBaseURL,
        userAgent: String = "HiggsfieldFCP/0.1",
        retryPolicy: RetryPolicy = .default,
        mediaConfirmAttempts: Int = 5,
        mediaConfirmDelay: TimeInterval = 2
    ) {
        self.baseURL = baseURL
        self.userAgent = userAgent
        self.retryPolicy = retryPolicy
        self.mediaConfirmAttempts = mediaConfirmAttempts
        self.mediaConfirmDelay = mediaConfirmDelay
    }
}

/// Client for the Higgsfield account API (`/developer/v2alpha`).
///
/// Every endpoint, header and body shape here was captured from the official
/// Higgsfield CLI (`@higgsfield/cli` 1.2.2) talking to a local intercepting
/// proxy; see docs/API-CONTRACT.md for the recorded exchanges.
public actor HiggsfieldClient {
    public let configuration: HiggsfieldConfiguration
    private let tokenProvider: AccessTokenProvider
    private let transport: HTTPTransport
    private let sleeper: @Sendable (TimeInterval) async -> Void

    /// Sent as `hf-workspace-id`. The account API requires a workspace for most calls.
    public private(set) var workspaceID: String?

    public init(
        configuration: HiggsfieldConfiguration = HiggsfieldConfiguration(),
        tokenProvider: AccessTokenProvider,
        transport: HTTPTransport = URLSessionTransport(),
        workspaceID: String? = nil,
        sleeper: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.configuration = configuration
        self.tokenProvider = tokenProvider
        self.transport = transport
        self.workspaceID = workspaceID
        self.sleeper = sleeper
    }

    public func setWorkspace(_ id: String?) {
        workspaceID = id
    }

    // MARK: Account

    public func balance() async throws -> AccountBalance {
        try await get("account/balance")
    }

    public func workspaces() async throws -> [Workspace] {
        let list: ItemList<Workspace> = try await get("account/workspaces")
        return list.items
    }

    // MARK: Catalog

    /// Lists job types. The CLI uses `label=model&label=app` for models and
    /// `label=chain` for workflows such as `reframe` and `draw_to_video`.
    public func jobTypes(outputType: MediaKind? = nil, labels: [String]) async throws -> [JobTypeInfo] {
        var query: [URLQueryItem] = []
        if let outputType { query.append(URLQueryItem(name: "type", value: outputType.rawValue)) }
        query += labels.map { URLQueryItem(name: "label", value: $0) }
        query.append(URLQueryItem(name: "limit", value: "200"))
        let list: ItemList<JobTypeInfo> = try await get("job_types", query: query)
        return list.items
    }

    public func jobType(_ jobType: String) async throws -> JobTypeInfo {
        try await get("job_types/\(Self.escapePath(jobType))")
    }

    // MARK: Generation

    /// Estimates credits without creating a job.
    public func estimateCost(jobType: String, params: [String: JSONValue]) async throws -> CostEstimate {
        try await send(
            method: "POST", path: "jobs/\(Self.escapePath(jobType))/cost",
            body: ["params": .object(params)], idempotent: true
        )
    }

    /// Submits a generation and returns the job id.
    public func submit(jobType: String, output: MediaKind, params: [String: JSONValue]) async throws -> String {
        let response: GenerationSubmission = try await send(
            method: "POST", path: "\(output.generationSegment)/\(Self.escapePath(jobType))/generations",
            body: ["params": .object(params)], idempotent: false
        )
        return response.id
    }

    public func job(id: String) async throws -> RemoteJob {
        try await get("jobs/\(Self.escapePath(id))")
    }

    // MARK: Media upload

    /// Uploads a local file: `POST /media` for a presigned URL, `PUT` the bytes,
    /// then `POST /media/{id}/confirm` until the media reports `uploaded`.
    public func uploadMedia(fileURL: URL, kind: MediaKind) async throws -> MediaReference {
        let ext = fileURL.pathExtension.lowercased()
        guard !ext.isEmpty else { throw HiggsfieldError.invalidInput("The file has no extension: \(fileURL.lastPathComponent)") }
        let ticket: MediaUploadTicket = try await send(
            method: "POST", path: "media",
            query: [URLQueryItem(name: "type", value: kind.rawValue), URLQueryItem(name: "extension", value: ext)],
            body: nil, idempotent: false
        )

        var put = URLRequest(url: ticket.uploadURL)
        put.httpMethod = "PUT"
        // Same as the official CLI 1.2.2: the Content-Type the upload slot names
        // (empty only if the server names none). Live URLs sign this header.
        put.setValue(ticket.contentType ?? "", forHTTPHeaderField: "Content-Type")
        let (putData, putResponse) = try await transport.upload(put, fromFile: fileURL)
        guard (200..<300).contains(putResponse.statusCode) else {
            throw HiggsfieldError.uploadFailed("Storage returned HTTP \(putResponse.statusCode): \(HiggsfieldError.extractMessage(from: putData))")
        }

        var lastStatus = ""
        for attempt in 1...max(1, configuration.mediaConfirmAttempts) {
            let confirmation: MediaConfirmation = try await send(
                method: "POST", path: "media/\(Self.escapePath(ticket.id))/confirm",
                query: [URLQueryItem(name: "type", value: kind.rawValue)],
                body: nil, idempotent: true
            )
            lastStatus = confirmation.status ?? ""
            if lastStatus.lowercased() == "uploaded" {
                return .uploaded(id: confirmation.id ?? ticket.id, kind: kind)
            }
            if attempt < configuration.mediaConfirmAttempts {
                await sleeper(configuration.mediaConfirmDelay)
            }
        }
        throw HiggsfieldError.mediaNotReady(id: ticket.id, status: lastStatus)
    }

    // MARK: Plumbing

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await send(method: "GET", path: path, query: query, body: nil, idempotent: true)
    }

    private func send<T: Decodable>(
        method: String, path: String, query: [URLQueryItem] = [],
        body: JSONValue?, idempotent: Bool
    ) async throws -> T {
        let data = try await sendRaw(method: method, path: path, query: query, body: body, idempotent: idempotent)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw HiggsfieldError.decoding("\(T.self): \(error)")
        }
    }

    func makeRequest(method: String, path: String, query: [URLQueryItem], body: JSONValue?, token: String) throws -> URLRequest {
        // Paths are pre-escaped by `escapePath`, so join strings instead of
        // `appendingPathComponent`, which would escape the `%` a second time.
        let base = configuration.baseURL.absoluteString.hasSuffix("/")
            ? String(configuration.baseURL.absoluteString.dropLast()) : configuration.baseURL.absoluteString
        guard var components = URLComponents(string: base + "/" + path) else {
            throw HiggsfieldError.invalidInput("Invalid path \(path)")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw HiggsfieldError.invalidInput("Invalid path \(path)") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 90
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        if let workspaceID { request.setValue(workspaceID, forHTTPHeaderField: "hf-workspace-id") }
        if let body {
            request.httpBody = try body.encodedData()
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func sendRaw(method: String, path: String, query: [URLQueryItem], body: JSONValue?, idempotent: Bool) async throws -> Data {
        var forceRefresh = false
        var attempt = 0
        while true {
            attempt += 1
            let token = try await tokenProvider.accessToken(forceRefresh: forceRefresh)
            let request = try makeRequest(method: method, path: path, query: query, body: body, token: token)
            let (data, response) = try await transport.send(request)
            let status = response.statusCode
            if (200..<300).contains(status) { return data }
            if status == 401 && !forceRefresh {
                // One retry with a refreshed token, as the CLI does.
                forceRefresh = true
                continue
            }
            if configuration.retryPolicy.shouldRetry(attempt: attempt, status: status, idempotent: idempotent) {
                await sleeper(configuration.retryPolicy.delay(forAttempt: attempt))
                continue
            }
            throw HiggsfieldError.from(status: status, data: data)
        }
    }

    static func escapePath(_ component: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return component.addingPercentEncoding(withAllowedCharacters: allowed) ?? component
    }
}
