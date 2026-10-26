import Foundation

/// The seven tools of the Higgsfield Premiere Pro plugin, in the same order.
public enum OperationKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case generateVideo
    case generateImage
    case editVideo
    case reframe
    case removeBackground
    case upscale
    case drawToEdit

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .generateVideo: return "Generate Video"
        case .generateImage: return "Generate Image"
        case .editVideo: return "Edit Video"
        case .reframe: return "Reframe"
        case .removeBackground: return "Remove Background"
        case .upscale: return "Upscale"
        case .drawToEdit: return "Draw to Edit"
        }
    }

    public var shortTitle: String {
        switch self {
        case .generateVideo: return "Video"
        case .generateImage: return "Image"
        case .editVideo: return "Edit"
        case .reframe: return "Reframe"
        case .removeBackground: return "Remove BG"
        case .upscale: return "Upscale"
        case .drawToEdit: return "Draw"
        }
    }

    /// SF Symbol for the tool strip.
    public var symbolName: String {
        switch self {
        case .generateVideo: return "film.stack"
        case .generateImage: return "photo.on.rectangle.angled"
        case .editVideo: return "wand.and.stars"
        case .reframe: return "crop"
        case .removeBackground: return "person.crop.rectangle"
        case .upscale: return "arrow.up.left.and.arrow.down.right"
        case .drawToEdit: return "pencil.tip.crop.circle"
        }
    }

    public var tagline: String {
        switch self {
        case .generateVideo: return "Create a clip from a prompt, optionally starting from a frame."
        case .generateImage: return "Create a still from a prompt and optional references."
        case .editVideo: return "Change a clip with a prompt — restyle, replace or add elements."
        case .reframe: return "Convert a clip to another aspect ratio, keeping the subject in frame."
        case .removeBackground: return "Isolate the subject without a green screen."
        case .upscale: return "Increase resolution and detail of a clip or still."
        case .drawToEdit: return "Draw on a frame to show what should change, then describe it."
        }
    }

    public enum SourceRequirement: Equatable, Sendable {
        /// No source; an image may be supplied (start frame / reference).
        case optionalImage
        case video
        case videoOrImage
    }

    public var sourceRequirement: SourceRequirement {
        switch self {
        case .generateVideo, .generateImage: return .optionalImage
        case .editVideo, .reframe: return .video
        case .removeBackground, .upscale, .drawToEdit: return .videoOrImage
        }
    }

    public func accepts(_ kind: MediaKind) -> Bool {
        switch sourceRequirement {
        case .optionalImage: return kind == .image
        case .video: return kind == .video
        case .videoOrImage: return kind == .video || kind == .image
        }
    }

    public var requiresSource: Bool {
        sourceRequirement != .optionalImage
    }

    /// Ordered job types; the first is the default. Generation models follow
    /// the Higgsfield catalog; the editing tools map to the job types behind the
    /// matching Higgsfield features (the MCP `remove_background`, `reframe` and
    /// `upscale_*` tools and the CLI's `draw_to_video` workflow).
    public func candidateJobTypes(sourceKind: MediaKind?) -> [String] {
        switch self {
        case .generateVideo:
            return ["seedance_2_0", "kling3_0", "veo3_1", "cinematic_studio_3_0", "wan3_0", "kling4_0", "seedance1_5", "minimax_hailuo"]
        case .generateImage:
            // Live catalog 2026-10-26: "Nano Banana 2" is `nano_banana_flash`
            // (`nano_banana_2` now resolves to Nano Banana Pro); Soul 2.0 is
            // `text2image_soul_v2`.
            return ["nano_banana_flash", "nano_banana_pro", "gpt_image_2", "seedream_v4_5", "text2image_soul_v2", "flux_2"]
        case .editVideo:
            return ["seedance_2_0", "kling_video_edit", "seedance_2_5", "flux_3_video_edit"]
        case .reframe:
            return ["reframe"]
        case .removeBackground:
            return sourceKind == .image ? ["image_background_remover"] : ["video_background_remover"]
        case .upscale:
            return sourceKind == .image ? ["bytedance_image_upscale"] : ["topaz_video", "bytedance_video_upscale"]
        case .drawToEdit:
            // Masked edits need `is_inpaint` + `mask`, which `nano_banana_flash`
            // has and Nano Banana Pro does not (live schemas, 2026-10-26).
            return sourceKind == .image ? ["nano_banana_flash"] : ["draw_to_video"]
        }
    }

    public var requiresPrompt: Bool {
        switch self {
        case .generateImage, .editVideo, .drawToEdit: return true
        case .generateVideo, .reframe, .removeBackground, .upscale: return false
        }
    }

    /// Whether the panel shows a prompt field.
    public var usesPrompt: Bool {
        switch self {
        case .generateVideo, .generateImage, .editVideo, .drawToEdit: return true
        case .reframe, .removeBackground, .upscale: return false
        }
    }

    /// Parameters the tool sets itself rather than exposing.
    func forcedParameters(jobType: String, hasMask: Bool) -> [String: JSONValue] {
        switch (self, jobType) {
        case (.editVideo, "seedance_2_5"): return ["mode": "video_edit"]
        case (.editVideo, "kling4_0"): return ["mode": "video-edit"]
        case (.drawToEdit, "nano_banana_flash") where hasMask: return ["is_inpaint": true]
        default: return [:]
        }
    }

    /// Whether `duration` should follow the source clip's length.
    public var durationFollowsSource: Bool {
        switch self {
        case .editVideo, .drawToEdit, .reframe: return true
        default: return false
        }
    }

    /// Hard limits on source length (seconds) independent of model schema.
    public var maximumSourceDuration: Double? {
        switch self {
        case .reframe: return 60  // MCP reframe tool: "Maximum supported duration is 60 seconds."
        default: return nil
        }
    }
}
