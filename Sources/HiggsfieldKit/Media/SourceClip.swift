import Foundation

/// Technical facts about a local media file (read with AVFoundation in the app).
public struct MediaInfo: Codable, Equatable, Sendable {
    public var kind: MediaKind
    public var duration: Double?
    public var frameRate: Double?
    public var width: Int?
    public var height: Int?
    public var hasAudio: Bool
    /// False when AVFoundation cannot play the file — Final Cut Pro will not
    /// import it either (e.g. WebM).
    public var isPlayable: Bool

    public init(kind: MediaKind, duration: Double? = nil, frameRate: Double? = nil, width: Int? = nil, height: Int? = nil, hasAudio: Bool = false, isPlayable: Bool = true) {
        self.kind = kind
        self.duration = duration
        self.frameRate = frameRate
        self.width = width
        self.height = height
        self.hasAudio = hasAudio
        self.isPlayable = isPlayable
    }
}

public protocol MediaProbing: Sendable {
    func probe(_ url: URL) async -> MediaInfo?
}

/// The footage an operation works on.
public struct SourceClip: Codable, Equatable, Identifiable, Sendable {
    /// How the footage reached the panel.
    public enum Origin: String, Codable, Sendable {
        /// Dragged from the Final Cut Pro browser/sidebar (FCPXML on the pasteboard).
        case finalCutBrowser
        /// Resolved under the playhead from a dragged project.
        case finalCutTimeline
        /// Rendered by File ▸ Share ▸ (Higgsfield destination).
        case finalCutShare
        /// Dropped from Finder or chosen in an Open panel.
        case file
        /// A previous Higgsfield result (chaining, e.g. Generate → Upscale).
        case higgsfieldResult
    }

    public var id: UUID
    public var name: String
    public var fileURL: URL
    public var kind: MediaKind
    public var origin: Origin
    /// Portion of the file to use, in file-relative seconds. Nil = whole file.
    public var inPoint: Double?
    public var outPoint: Double?
    public var info: MediaInfo?
    /// When the source is an earlier Higgsfield job output, it can be passed
    /// by reference without re-uploading.
    public var remoteReference: MediaReference?

    public init(id: UUID = UUID(), name: String, fileURL: URL, kind: MediaKind, origin: Origin,
                inPoint: Double? = nil, outPoint: Double? = nil, info: MediaInfo? = nil, remoteReference: MediaReference? = nil) {
        self.id = id
        self.name = name
        self.fileURL = fileURL
        self.kind = kind
        self.origin = origin
        self.inPoint = inPoint
        self.outPoint = outPoint
        self.info = info
        self.remoteReference = remoteReference
    }

    /// Duration of the selected range (or of the whole file).
    public var selectedDuration: Double? {
        let start = inPoint ?? 0
        guard let end = outPoint ?? info?.duration else { return nil }
        return max(0, end - start)
    }

    /// True when only part of the file is selected, so it must be trimmed before upload.
    public var needsTrim: Bool {
        guard kind == .video else { return false }
        if let i = inPoint, i > 0.001 { return true }
        if let o = outPoint, let d = info?.duration, o < d - 0.001 { return true }
        return false
    }
}

/// Trims video to a range before upload (AVFoundation in the app).
public protocol MediaTrimming: Sendable {
    func trim(_ source: URL, start: Double, end: Double) async throws -> URL
}
