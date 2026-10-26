import Foundation

/// Local record of one operation run, persisted so jobs survive Final Cut Pro
/// closing the extension window (Apple: "Final Cut Pro terminates a workflow
/// extension soon after a user closes the extension window").
public struct JobRecord: Codable, Equatable, Identifiable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case preparing      // trimming / uploading inputs
        case submitting
        case queued
        case running
        case downloading
        case completed
        case failed
        case moderated      // nsfw
        case canceled
        /// Stopped tracking locally; the server job may still finish.
        case detached

        public var isActive: Bool {
            switch self {
            case .preparing, .submitting, .queued, .running, .downloading: return true
            default: return false
            }
        }

        public var label: String {
            switch self {
            case .preparing: return "Uploading"
            case .submitting: return "Submitting"
            case .queued: return "Queued"
            case .running: return "Generating"
            case .downloading: return "Downloading"
            case .completed: return "Ready"
            case .failed: return "Failed"
            case .moderated: return "Blocked by moderation"
            case .canceled: return "Canceled"
            case .detached: return "Stopped tracking"
            }
        }
    }

    public var id: UUID
    public var remoteID: String?
    public var operation: OperationKind
    public var jobType: String
    public var modelName: String
    public var output: MediaKind
    public var prompt: String?
    /// Short "key: value" summary of the settings, for the activity list.
    public var settingsSummary: [String]
    public var sourceName: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var phase: Phase
    public var message: String?
    public var estimatedCredits: Double?
    public var resultURL: URL?
    public var previewURL: URL?
    /// Downloaded result, ready for Final Cut Pro.
    public var localFile: URL?
    /// Timeline frame rate to conform the clip to on import, when known.
    public var targetFrameRate: Double?

    public init(id: UUID = UUID(), operation: OperationKind, jobType: String, modelName: String, output: MediaKind,
                prompt: String? = nil, settingsSummary: [String] = [], sourceName: String? = nil,
                createdAt: Date = Date(), phase: Phase = .preparing, estimatedCredits: Double? = nil) {
        self.id = id
        self.operation = operation
        self.jobType = jobType
        self.modelName = modelName
        self.output = output
        self.prompt = prompt
        self.settingsSummary = settingsSummary
        self.sourceName = sourceName
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.phase = phase
        self.estimatedCredits = estimatedCredits
    }

    /// Display name used for the downloaded file and the Final Cut Pro clip.
    public var clipName: String {
        let base = sourceName.map { "\($0) – \(operation.title)" } ?? operation.title
        let suffix = remoteID.map { " \($0.prefix(8))" } ?? ""
        return base + suffix
    }

    /// A finished job's output can feed another tool without re-uploading.
    public var remoteReference: MediaReference? {
        guard phase == .completed, let remoteID else { return nil }
        return .jobOutput(id: remoteID, kind: output)
    }
}

/// JSON-file persistence for job records (in the shared App Group container).
public actor JobStore {
    private let url: URL
    private var records: [JobRecord] = []
    private var loaded = false
    public let maximumRecords: Int

    public init(url: URL, maximumRecords: Int = 200) {
        self.url = url
        self.maximumRecords = maximumRecords
    }

    public func all() -> [JobRecord] {
        loadIfNeeded()
        return records
    }

    public func upsert(_ record: JobRecord) {
        loadIfNeeded()
        if let i = records.firstIndex(where: { $0.id == record.id }) {
            records[i] = record
        } else {
            records.insert(record, at: 0)
            if records.count > maximumRecords { records.removeLast(records.count - maximumRecords) }
        }
        persist()
    }

    public func remove(id: UUID) {
        loadIfNeeded()
        records.removeAll { $0.id == id }
        persist()
    }

    public func record(id: UUID) -> JobRecord? {
        loadIfNeeded()
        return records.first { $0.id == id }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        records = (try? decoder.decode([JobRecord].self, from: data)) ?? []
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
