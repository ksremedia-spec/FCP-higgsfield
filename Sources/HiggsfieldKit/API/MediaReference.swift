import Foundation

/// A media input as referenced inside `params.medias`:
/// `{"data": {"id": "<uuid>", "type": "video_input"}, "role": "video"}`.
///
/// Types observed from the official Higgsfield CLI:
/// - uploaded video → `video_input`
/// - uploaded image → `media_input`
/// - output of a previous video job → `video_job`
/// - output of a previous image job → `image_job`
public struct MediaReference: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable {
        case uploadedImage = "media_input"
        case uploadedVideo = "video_input"
        /// Not observed in a capture; inferred from the naming scheme.
        case uploadedAudio = "audio_input"
        case imageJob = "image_job"
        case videoJob = "video_job"
    }

    public var id: String
    public var source: Source

    public init(id: String, source: Source) {
        self.id = id
        self.source = source
    }

    public static func uploaded(id: String, kind: MediaKind) -> MediaReference {
        switch kind {
        case .image: return MediaReference(id: id, source: .uploadedImage)
        case .video: return MediaReference(id: id, source: .uploadedVideo)
        case .audio: return MediaReference(id: id, source: .uploadedAudio)
        }
    }

    public static func jobOutput(id: String, kind: MediaKind) -> MediaReference? {
        switch kind {
        case .image: return MediaReference(id: id, source: .imageJob)
        case .video: return MediaReference(id: id, source: .videoJob)
        case .audio: return nil
        }
    }

    public var kind: MediaKind {
        switch source {
        case .uploadedImage, .imageJob: return .image
        case .uploadedVideo, .videoJob: return .video
        case .uploadedAudio: return .audio
        }
    }

    /// The `medias[]` entry for the given role.
    public func entry(role: String) -> JSONValue {
        ["data": ["id": .string(id), "type": .string(source.rawValue)], "role": .string(role)]
    }
}
