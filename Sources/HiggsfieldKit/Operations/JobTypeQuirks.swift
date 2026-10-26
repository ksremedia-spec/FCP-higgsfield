import Foundation

/// Places where a job type's submit-time validation differs from the
/// `json_schema` that `GET /job_types/{id}` publishes. Each entry was found
/// against the live API; see docs/VALIDATION.md.
public enum JobTypeQuirks {
    /// Non-media parameters the submit endpoint accepts, when narrower than the
    /// published schema. `prompt` is always allowed; media properties are kept.
    ///
    /// `draw_to_video` (2026-10-26): the schema lists duration, resolution,
    /// aspect_ratio, generate_audio, enhancer and ref_image, but submission
    /// rejects each as "Extra inputs are not permitted" and requires
    /// `timestamp`, the time in the source video of the frame that was drawn on.
    static let submitAllowlist: [String: Set<String>] = [
        "draw_to_video": ["prompt", "timestamp"],
    ]

    /// Values the cost endpoint needs that the submission doesn't carry.
    /// `draw_to_video`'s cost requires `resolution` (and uses `duration`).
    static let costDefaults: [String: [String: JSONValue]] = [
        "draw_to_video": ["resolution": "720p"],
    ]

    /// Parameters that may be submitted, or nil when the schema is accurate.
    public static func allowedParameters(for jobType: String) -> Set<String>? {
        submitAllowlist[jobType]
    }

    public static func costDefaults(for jobType: String) -> [String: JSONValue] {
        costDefaults[jobType] ?? [:]
    }

    /// The schema with only the settings the submit endpoint accepts, so the
    /// panel doesn't show controls that would be rejected.
    public static func adjust(_ schema: ParameterSchema, jobType: String) -> ParameterSchema {
        guard let allowed = submitAllowlist[jobType] else { return schema }
        var s = schema
        s.parameters = schema.parameters.filter { allowed.contains($0.name) }
        if let refImage = s.mediaField(named: "ref_image") {
            s.mediaFields.removeAll { $0 == refImage }
            s.mediaRoles.removeAll { $0 == refImage.name }
        }
        return s
    }
}
