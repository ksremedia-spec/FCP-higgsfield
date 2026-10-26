import Foundation

/// The semantic purpose of a media input. Each job type names its roles
/// differently (`video`, `video_references`, `input_video`, …); a slot is
/// mapped to whichever role the job type's live schema accepts.
public enum MediaSlot: String, CaseIterable, Sendable, Codable {
    case sourceVideo
    case sourceImage
    case startImage
    case endImage
    case referenceImage
    case sketch
    case mask

    /// Role names to try, most specific first. Gathered from the Higgsfield
    /// catalog and the official CLI/MCP tool definitions.
    public var candidateRoles: [String] {
        switch self {
        case .sourceVideo: return ["video", "video_references", "input_video", "video_reference"]
        case .sourceImage: return ["image", "image_references", "input_images", "image_reference"]
        case .startImage: return ["start_image", "image"]
        case .endImage: return ["end_image"]
        case .referenceImage: return ["image_references", "image", "ref_image"]
        // draw_to_video (live schema, 2026-10-26): `image_references` is
        // "the sketch image to animate"; `ref_image` is an optional style reference.
        case .sketch: return ["sketch", "image_references"]
        case .mask: return ["mask"]
        }
    }

    /// Picks the role for this slot. With a known role list only listed roles
    /// are used; without one (schema unavailable) the first candidate is used.
    public func role(available: [String], excluding used: Set<String> = []) -> String? {
        if available.isEmpty { return candidateRoles.first }
        return candidateRoles.first { available.contains($0) && !used.contains($0) }
            ?? candidateRoles.first { available.contains($0) }
    }
}
