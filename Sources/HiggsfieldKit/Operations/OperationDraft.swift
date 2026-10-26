import Foundation

/// What the user has configured in one tool of the panel.
public struct OperationDraft: Codable, Equatable, Sendable {
    public var operation: OperationKind
    public var jobType: String
    public var prompt: String
    /// Values for schema parameters, keyed by parameter name.
    public var values: [String: JSONValue]
    /// Primary footage (or start frame for Generate Video / reference for Generate Image).
    public var source: SourceClip?
    public var referenceImages: [SourceClip]
    /// Draw to Edit: the frame with the user's strokes composited (PNG).
    public var sketchFile: URL?
    /// Draw to Edit on stills: white strokes on black (PNG), used as an inpainting mask.
    public var maskFile: URL?

    public init(operation: OperationKind, jobType: String? = nil, prompt: String = "", values: [String: JSONValue] = [:],
                source: SourceClip? = nil, referenceImages: [SourceClip] = [], sketchFile: URL? = nil, maskFile: URL? = nil) {
        self.operation = operation
        self.jobType = jobType ?? operation.candidateJobTypes(sourceKind: source?.kind).first ?? ""
        self.prompt = prompt
        self.values = values
        self.source = source
        self.referenceImages = referenceImages
        self.sketchFile = sketchFile
        self.maskFile = maskFile
    }
}

/// A media input waiting to be uploaded (or referenced) and attached under `role`.
public struct PendingMedia: Equatable, Sendable {
    public enum Payload: Equatable, Sendable {
        case clip(SourceClip)
        case file(URL, MediaKind)
    }

    public var slot: MediaSlot
    public var role: String
    public var payload: Payload

    public var kind: MediaKind {
        switch payload {
        case .clip(let c): return c.kind
        case .file(_, let k): return k
        }
    }
}

/// A validated request ready for upload + submission.
public struct PreparedRequest: Equatable, Sendable {
    public var operation: OperationKind
    public var jobType: String
    public var modelName: String
    public var output: MediaKind
    /// `params` without media; media is added after upload.
    public var params: [String: JSONValue]
    public var media: [PendingMedia]
    /// The job type's top-level media properties. Empty means the older
    /// `params.medias` array layout.
    public var mediaFields: [MediaField] = []
    /// Length of the selected source video, in seconds.
    public var sourceDuration: Double? = nil

    /// Params for `POST /jobs/{job_type}/cost`, which doesn't need media ids.
    ///
    /// Several job types price by the source length but take no `duration`
    /// parameter (their `cost_schema` has one): Kling Omni Edit requires it,
    /// FLUX 3 Video Edit and ByteDance Video Upscale otherwise quote a default
    /// length. Checked live 2026-10-26; extra keys are ignored by the endpoint.
    public var costParams: [String: JSONValue] {
        var p = params
        if mediaFields.isEmpty { p["medias"] = .array([]) }
        if p["duration"] == nil, let d = sourceDuration, d > 0 { p["duration"] = .number((d * 10).rounded() / 10) }
        return p
    }

    /// Params for submission once every media input has a server reference
    /// (`references[i]` belongs to `media[i]`).
    public func submissionParams(references: [MediaReference]) -> [String: JSONValue] {
        var p = params
        let attached = zip(media, references)
        if mediaFields.isEmpty {
            if !media.isEmpty { p["medias"] = .array(attached.map { $1.entry(role: $0.role) }) }
            return p
        }
        for (item, reference) in attached {
            let isArray = mediaFields.first { $0.name == item.role }?.isArray ?? item.role.hasSuffix("references")
            if isArray {
                var list = p[item.role]?.arrayValue ?? []
                list.append(reference.value)
                p[item.role] = .array(list)
            } else {
                p[item.role] = reference.value
            }
        }
        return p
    }
}

public enum RequestBuilder {
    /// Validates a draft against the operation's rules and the model schema and
    /// builds the request. Throws `HiggsfieldError.invalidInput` with a message
    /// suitable for display next to the Generate button.
    public static func prepare(_ draft: OperationDraft, catalog: ModelCatalog) throws -> PreparedRequest {
        let op = draft.operation
        guard let model = catalog.option(draft.jobType) else {
            throw HiggsfieldError.invalidInput("Unknown model “\(draft.jobType)”.")
        }
        let schema = model.schema

        // Source checks
        if op.requiresSource {
            guard let source = draft.source else {
                throw HiggsfieldError.invalidInput(op.sourceRequirement == .video
                    ? "Add a video clip: drag it from the Final Cut Pro browser, or drop a file."
                    : "Add a clip or still: drag it from the Final Cut Pro browser, or drop a file.")
            }
            guard op.accepts(source.kind) else {
                throw HiggsfieldError.invalidInput("\(op.title) needs a \(op.sourceRequirement == .video ? "video" : "video or image") source.")
            }
            if source.info?.isPlayable == false {
                throw HiggsfieldError.invalidInput("“\(source.name)” can’t be read on this Mac.")
            }
        } else if let source = draft.source, !op.accepts(source.kind) {
            throw HiggsfieldError.invalidInput("\(op.title) can use a still image as a starting point, not a \(source.kind.rawValue).")
        }

        let prompt = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if op.requiresPrompt && prompt.isEmpty {
            throw HiggsfieldError.invalidInput("Describe the change you want in the prompt.")
        }
        if op == .generateVideo && prompt.isEmpty && draft.source == nil {
            throw HiggsfieldError.invalidInput("Enter a prompt or add a start frame.")
        }
        if op == .drawToEdit, draft.source?.kind == .video, draft.sketchFile == nil {
            throw HiggsfieldError.invalidInput("Draw on the frame to mark what should change.")
        }
        if op == .drawToEdit, draft.source?.kind == .image, draft.maskFile == nil {
            throw HiggsfieldError.invalidInput("Paint over the area you want to change.")
        }

        var params: [String: JSONValue] = [:]
        if schema.acceptsPrompt && !prompt.isEmpty && op.usesPrompt { params["prompt"] = .string(prompt) }

        // User-chosen schema values, validated.
        for (name, value) in draft.values {
            guard let spec = schema.parameter(named: name) else { continue }
            if value == .null { continue }
            switch spec.validate(value) {
            case .success(let v): params[name] = v
            case .failure(let e): throw e
            }
        }

        // Duration follows the source for edit-style tools.
        if op.durationFollowsSource, let duration = draft.source?.selectedDuration, draft.source?.kind == .video {
            if let maxSource = op.maximumSourceDuration, duration > maxSource + 0.001 {
                throw HiggsfieldError.invalidInput("\(op.title) supports clips up to \(Int(maxSource)) s. Set In/Out points to shorten the selection (currently \(formatDuration(duration))).")
            }
            if let spec = schema.parameter(named: "duration"), draft.values["duration"] == nil {
                params["duration"] = try durationValue(for: duration, spec: spec, operation: op)
            }
        }

        // Source dimensions for job types that ask for them (ByteDance upscale).
        if let info = draft.source?.info {
            if schema.propertyNames.contains("width"), let w = info.width { params["width"] = .number(Double(w)) }
            if schema.propertyNames.contains("height"), let h = info.height { params["height"] = .number(Double(h)) }
        }

        for (k, v) in op.forcedParameters(jobType: model.jobType, hasMask: draft.maskFile != nil) where schema.propertyNames.contains(k) {
            params[k] = v
        }

        if op == .reframe && params["aspect_ratio"] == nil {
            throw HiggsfieldError.invalidInput("Choose a target aspect ratio.")
        }

        // Media inputs → roles.
        var media: [PendingMedia] = []
        var used: Set<String> = []
        // Roles taken by a single-purpose input (the source, the sketch, the
        // mask). Reusable inputs such as reference images may share a role
        // with each other, but never with one of these.
        var exclusive: Set<String> = []
        func attach(_ slot: MediaSlot, _ payload: PendingMedia.Payload, reusable: Bool = false) throws {
            guard let role = slot.role(available: schema.mediaRoles, excluding: reusable ? exclusive : used) else {
                throw HiggsfieldError.invalidInput("\(model.name) doesn’t accept this kind of input.")
            }
            if reusable, exclusive.contains(role) {
                throw HiggsfieldError.invalidInput("\(model.name) doesn’t accept this kind of input.")
            }
            // A single-value property (`ref_image`, `start_image`, `mask`) holds one input.
            if let field = schema.mediaField(named: role), !field.isArray, used.contains(role) {
                throw HiggsfieldError.invalidInput("\(model.name) accepts only one input of this kind.")
            }
            used.insert(role)
            if !reusable { exclusive.insert(role) }
            media.append(PendingMedia(slot: slot, role: role, payload: payload))
        }

        if let source = draft.source {
            switch (op, source.kind) {
            case (.generateVideo, _): try attach(.startImage, .clip(source))
            case (.generateImage, _): try attach(.referenceImage, .clip(source), reusable: true)
            case (_, .video): try attach(.sourceVideo, .clip(source))
            case (_, .image): try attach(.sourceImage, .clip(source), reusable: true)
            case (_, .audio): throw HiggsfieldError.invalidInput("Audio sources aren’t supported.")
            }
        }
        if let sketch = draft.sketchFile, draft.source?.kind == .video {
            try attach(.sketch, .file(sketch, .image))
        }
        if let mask = draft.maskFile, draft.source?.kind == .image {
            try attach(.mask, .file(mask, .image))
        }
        for ref in draft.referenceImages where ref.kind == .image {
            try attach(.referenceImage, .clip(ref), reusable: true)
        }
        if !media.isEmpty && !schema.acceptsMedias && !schema.mediaRoles.isEmpty {
            throw HiggsfieldError.invalidInput("\(model.name) doesn’t accept media inputs.")
        }

        let output: MediaKind
        switch op {
        case .removeBackground, .upscale, .drawToEdit: output = draft.source?.kind ?? model.output
        default: output = model.output
        }

        return PreparedRequest(operation: op, jobType: model.jobType, modelName: model.name, output: output, params: params, media: media,
                               mediaFields: schema.mediaFields,
                               sourceDuration: draft.source?.kind == .video ? draft.source?.selectedDuration : nil)
    }

    /// Maps a source length to the model's duration parameter.
    static func durationValue(for seconds: Double, spec: ParameterSpec, operation: OperationKind) throws -> JSONValue {
        switch spec.kind {
        case .choice(let options):
            // Pick the smallest allowed duration that covers the clip.
            let numeric = options.compactMap(\.doubleValue).sorted()
            if let fit = numeric.first(where: { $0 >= seconds - 0.05 }) ?? numeric.last { return .number(fit) }
            return options.first ?? .number(seconds.rounded())
        case .number(let lo, let hi, let integer):
            var value = integer ? seconds.rounded() : (seconds * 10).rounded() / 10
            // Check the real length (within a frame or so), not the rounded value:
            // a 15.3 s clip must not pass a 15 s limit because it rounds to 15.
            if let lo, seconds < lo - 0.05, operation != .reframe {
                throw HiggsfieldError.invalidInput("This model needs at least \(JSONValue.number(lo).displayString) s of footage; the selection is \(formatDuration(seconds)).")
            }
            if let hi, seconds > hi + 0.05 {
                throw HiggsfieldError.invalidInput("This model accepts up to \(JSONValue.number(hi).displayString) s; the selection is \(formatDuration(seconds)). Set In/Out points to shorten it.")
            }
            if let lo, value < lo { value = lo }
            if let hi, value > hi { value = hi }
            return .number(value)
        default:
            return .number((seconds * 10).rounded() / 10)
        }
    }
}
