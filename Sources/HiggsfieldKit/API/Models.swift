import Foundation

/// Output media category of a Higgsfield job type. Determines the generation
/// endpoint segment (`/images/…`, `/videos/…`) and the upload `type` query value.
public enum MediaKind: String, Codable, CaseIterable, Sendable {
    case image
    case video
    case audio

    /// Path segment used by `POST /developer/v2alpha/{segment}/{job_type}/generations`.
    var generationSegment: String {
        switch self {
        case .image: return "images"
        case .video: return "videos"
        case .audio: return "audios"
        }
    }

    public init?(fileExtension ext: String) {
        switch ext.lowercased() {
        case "png", "jpg", "jpeg", "webp", "heic", "heif", "tif", "tiff", "bmp", "gif":
            self = .image
        case "mov", "mp4", "m4v", "webm", "mkv", "avi", "mxf":
            self = .video
        case "wav", "mp3", "m4a", "aac", "aif", "aiff", "flac", "ogg":
            self = .audio
        default:
            return nil
        }
    }
}

/// `GET /account/balance` → `{"credits": 854.14, "subscription_plan_type": "plus", "email": "…"}`
public struct AccountBalance: Codable, Equatable, Sendable {
    public var credits: Double
    public var subscriptionPlanType: String?
    public var email: String?

    public init(credits: Double, subscriptionPlanType: String? = nil, email: String? = nil) {
        self.credits = credits
        self.subscriptionPlanType = subscriptionPlanType
        self.email = email
    }

    enum CodingKeys: String, CodingKey {
        case credits
        case subscriptionPlanType = "subscription_plan_type"
        case email
    }
}

/// An entry of `GET /account/workspaces` → `{"items": [{"id", "name", "credits", …}]}`.
/// The selected workspace is sent on every request as the `hf-workspace-id` header.
public struct Workspace: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String?
    public var credits: Double?
    public var plan: String?

    public init(id: String, name: String? = nil, credits: Double? = nil, plan: String? = nil) {
        self.id = id
        self.name = name
        self.credits = credits
        self.plan = plan
    }

    enum CodingKeys: String, CodingKey {
        case id, name, credits, plan
        case subscriptionPlanType = "subscription_plan_type"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        credits = try c.decodeIfPresent(Double.self, forKey: .credits)
        plan = try c.decodeIfPresent(String.self, forKey: .plan)
            ?? c.decodeIfPresent(String.self, forKey: .subscriptionPlanType)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(credits, forKey: .credits)
        try c.encodeIfPresent(plan, forKey: .plan)
    }
}

struct ItemList<Item: Decodable>: Decodable {
    var items: [Item]
    var hasMore: Bool?

    enum CodingKeys: String, CodingKey {
        case items
        case hasMore = "has_more"
    }
}

/// A job type ("model" or "workflow") from `GET /job_types` or `GET /job_types/{job_type}`.
/// `json_schema` is a JSON Schema describing the accepted `params`.
public struct JobTypeInfo: Codable, Equatable, Sendable {
    public var jobType: String
    public var name: String?
    public var outputType: MediaKind?
    public var jsonSchema: JSONValue?

    public init(jobType: String, name: String? = nil, outputType: MediaKind? = nil, jsonSchema: JSONValue? = nil) {
        self.jobType = jobType
        self.name = name
        self.outputType = outputType
        self.jsonSchema = jsonSchema
    }

    enum CodingKeys: String, CodingKey {
        case jobType = "job_type"
        case name
        case displayName = "display_name"
        case type
        case jsonSchema = "json_schema"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobType = try c.decode(String.self, forKey: .jobType)
        let name = try c.decodeIfPresent(String.self, forKey: .name)
        let display = try c.decodeIfPresent(String.self, forKey: .displayName)
        self.name = [name, display].compactMap { $0 }.first { !$0.isEmpty }
        outputType = (try? c.decodeIfPresent(String.self, forKey: .type)).flatMap { $0.flatMap(MediaKind.init(rawValue:)) }
        jsonSchema = try c.decodeIfPresent(JSONValue.self, forKey: .jsonSchema)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jobType, forKey: .jobType)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(outputType?.rawValue, forKey: .type)
        try c.encodeIfPresent(jsonSchema, forKey: .jsonSchema)
    }
}

/// `POST /jobs/{job_type}/cost` → `{"credits": 123, "credits_exact": 123}`
public struct CostEstimate: Codable, Equatable, Sendable {
    public var credits: Double
    public var creditsExact: Double?

    public init(credits: Double, creditsExact: Double? = nil) {
        self.credits = credits
        self.creditsExact = creditsExact
    }

    enum CodingKeys: String, CodingKey {
        case credits
        case creditsExact = "credits_exact"
    }
}

/// `POST /media?type=…&extension=…` → presigned upload ticket.
struct MediaUploadTicket: Decodable {
    var id: String
    var uploadURL: URL

    enum CodingKeys: String, CodingKey {
        case id
        case mediaID = "media_id"
        case uploadURL = "upload_url"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try c.decodeIfPresent(String.self, forKey: .id) {
            self.id = id
        } else {
            self.id = try c.decode(String.self, forKey: .mediaID)
        }
        uploadURL = try c.decode(URL.self, forKey: .uploadURL)
    }
}

/// `POST /media/{id}/confirm?type=…` → `{"id": "…", "status": "uploaded"}`.
/// The official CLI treats only `"uploaded"` as usable.
struct MediaConfirmation: Decodable {
    var id: String?
    var status: String?
}

/// `POST /{segment}/{job_type}/generations` → `{"id": "<job id>", …}`
struct GenerationSubmission: Decodable {
    var id: String
}

/// Server-side job state from `GET /jobs/{id}`.
public enum RemoteJobStatus: Equatable, Sendable {
    case queued
    case running
    case completed
    case failed
    case nsfw
    case canceled
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue.lowercased() {
        case "queued", "pending", "created": self = .queued
        case "in_progress", "processing", "running": self = .running
        case "completed", "succeeded", "success": self = .completed
        case "failed", "error": self = .failed
        case "nsfw": self = .nsfw
        case "canceled", "cancelled": self = .canceled
        default: self = .unknown(rawValue)
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .nsfw, .canceled: return true
        case .queued, .running, .unknown: return false
        }
    }
}

/// `GET /jobs/{id}` → `{"id", "job_type", "display_name", "status", "created_at", "params", "result_url", "min_result_url"}`
public struct RemoteJob: Decodable, Equatable, Sendable {
    public var id: String
    public var jobType: String?
    public var displayName: String?
    public var rawStatus: String
    public var createdAt: String?
    public var params: JSONValue?
    public var resultURL: URL?
    public var minResultURL: URL?
    public var errorMessage: String?

    public var status: RemoteJobStatus { RemoteJobStatus(rawValue: rawStatus) }

    public init(id: String, jobType: String? = nil, rawStatus: String, resultURL: URL? = nil, minResultURL: URL? = nil, errorMessage: String? = nil) {
        self.id = id
        self.jobType = jobType
        self.rawStatus = rawStatus
        self.resultURL = resultURL
        self.minResultURL = minResultURL
        self.errorMessage = errorMessage
    }

    enum CodingKeys: String, CodingKey {
        case id
        case jobType = "job_type"
        case displayName = "display_name"
        case status
        case createdAt = "created_at"
        case params
        case resultURL = "result_url"
        case minResultURL = "min_result_url"
        case error
        case errorMessage = "error_message"
        case message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        jobType = try c.decodeIfPresent(String.self, forKey: .jobType)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        rawStatus = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        params = try c.decodeIfPresent(JSONValue.self, forKey: .params)
        resultURL = Self.decodeURL(c, .resultURL)
        minResultURL = Self.decodeURL(c, .minResultURL)
        let candidates: [String?] = [
            try? c.decodeIfPresent(String.self, forKey: .errorMessage),
            try? c.decodeIfPresent(String.self, forKey: .error),
            try? c.decodeIfPresent(String.self, forKey: .message),
        ]
        errorMessage = candidates.compactMap { $0 }.first { !$0.isEmpty }
    }

    private static func decodeURL(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> URL? {
        guard let s = try? c.decodeIfPresent(String.self, forKey: key), !s.isEmpty else { return nil }
        return URL(string: s)
    }
}
