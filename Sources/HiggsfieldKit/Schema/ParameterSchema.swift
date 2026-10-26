import Foundation

/// One user-adjustable generation parameter derived from a job type's JSON Schema.
public struct ParameterSpec: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case choice([JSONValue])
        case toggle
        case number(min: Double?, max: Double?, integer: Bool)
        case text
    }

    public var name: String
    public var kind: Kind
    public var defaultValue: JSONValue?
    public var isRequired: Bool
    public var summary: String?

    public var id: String { name }

    public init(name: String, kind: Kind, defaultValue: JSONValue? = nil, isRequired: Bool = false, summary: String? = nil) {
        self.name = name
        self.kind = kind
        self.defaultValue = defaultValue
        self.isRequired = isRequired
        self.summary = summary
    }

    /// Human label: `generate_audio` → "Generate audio".
    public var label: String {
        let special = ["aspect_ratio": "Aspect ratio", "fps": "Frame rate", "cfg_scale": "Guidance"]
        if let s = special[name] { return s }
        let words = name.split(separator: "_").map(String.init)
        guard let first = words.first else { return name }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }

    /// Validates and normalises a value for this parameter.
    public func validate(_ value: JSONValue) -> Result<JSONValue, HiggsfieldError> {
        switch kind {
        case .choice(let options):
            if options.contains(value) { return .success(value) }
            // Numeric enums may arrive as strings from text fields.
            if let d = value.doubleValue, let match = options.first(where: { $0.doubleValue == d }) { return .success(match) }
            return .failure(.invalidInput("\(label) must be one of: \(options.map(\.displayString).joined(separator: ", "))."))
        case .toggle:
            if case .bool = value { return .success(value) }
            return .failure(.invalidInput("\(label) must be on or off."))
        case .number(let lo, let hi, let integer):
            guard var d = value.doubleValue else { return .failure(.invalidInput("\(label) must be a number.")) }
            if integer { d = d.rounded() }
            if let lo, d < lo { return .failure(.invalidInput("\(label) must be at least \(JSONValue.number(lo).displayString).")) }
            if let hi, d > hi { return .failure(.invalidInput("\(label) must be at most \(JSONValue.number(hi).displayString).")) }
            return .success(.number(d))
        case .text:
            if case .string = value { return .success(value) }
            return .success(.string(value.displayString))
        }
    }
}

/// Parsed view of a job type's `json_schema`.
public struct ParameterSchema: Equatable, Sendable {
    /// Adjustable parameters, excluding `prompt` and `medias`, which have
    /// dedicated UI.
    public var parameters: [ParameterSpec]
    /// Media roles accepted in `params.medias` (e.g. `video`, `start_image`).
    public var mediaRoles: [String]
    public var acceptsPrompt: Bool
    public var acceptsMedias: Bool
    public var required: Set<String>
    /// Every top-level property, including hidden ones such as `width`.
    public var propertyNames: Set<String>

    public init(parameters: [ParameterSpec], mediaRoles: [String], acceptsPrompt: Bool, acceptsMedias: Bool,
                required: Set<String> = [], propertyNames: Set<String>? = nil) {
        self.parameters = parameters
        self.mediaRoles = mediaRoles
        self.acceptsPrompt = acceptsPrompt
        self.acceptsMedias = acceptsMedias
        self.required = required
        self.propertyNames = propertyNames ?? Set(parameters.map(\.name))
    }

    public func parameter(named name: String) -> ParameterSpec? {
        parameters.first { $0.name == name }
    }

    /// Parameters the panel never shows (folder placement, batch sizes, internal ids).
    static let hiddenParameters: Set<String> = [
        "prompt", "medias", "folder_id", "batch_size", "count", "get_cost", "workspace_id",
        "preset_id", "style_id", "soul_id", "custom_reference_id", "avatar_ids", "product_ids",
        "kling_element_ids", "era_id", "camera_model_id", "camera_lens_id", "camera_aperture_id",
        "pacing_id", "genre_id", "light_id", "hook_id", "setting_id", "ad_reference_id", "multi_prompt",
        // Filled automatically from the source clip.
        "width", "height", "duration_seconds",
    ]

    public init(jsonSchema: JSONValue) {
        let root = Self.resolve(jsonSchema, root: jsonSchema)
        let properties = root["properties"]?.objectValue ?? [:]
        let required = Set(root["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        var specs: [ParameterSpec] = []
        for name in properties.keys.sorted() where !Self.hiddenParameters.contains(name) {
            guard let prop = properties[name] else { continue }
            if let spec = Self.spec(name: name, schema: Self.resolve(prop, root: jsonSchema), required: required.contains(name)) {
                specs.append(spec)
            }
        }
        let medias = properties["medias"].map { Self.resolve($0, root: jsonSchema) }
        self.init(
            parameters: specs.sorted { Self.order($0.name) < Self.order($1.name) },
            mediaRoles: medias.map { Self.roles(inMediasSchema: $0, root: jsonSchema) } ?? [],
            acceptsPrompt: properties["prompt"] != nil,
            acceptsMedias: medias != nil,
            required: required,
            propertyNames: Set(properties.keys)
        )
    }

    /// Common parameters first, matching the order of the Higgsfield web UI.
    private static func order(_ name: String) -> Int {
        let preferred = ["aspect_ratio", "duration", "resolution", "quality", "mode", "generate_audio", "sound", "fps", "preset", "provider"]
        return preferred.firstIndex(of: name) ?? preferred.count
    }

    private static func spec(name: String, schema: JSONValue, required: Bool) -> ParameterSpec? {
        let summary = schema["description"]?.stringValue
        let def = schema["default"]
        if let options = enumValues(schema), !options.isEmpty {
            return ParameterSpec(name: name, kind: .choice(options), defaultValue: def, isRequired: required, summary: summary)
        }
        let types = typeNames(schema)
        if types.contains("boolean") {
            return ParameterSpec(name: name, kind: .toggle, defaultValue: def, isRequired: required, summary: summary)
        }
        if types.contains("integer") || types.contains("number") {
            // Bounds may sit on the schema itself or on a numeric anyOf/oneOf branch.
            let numericBranches = [schema] + ["anyOf", "oneOf"].flatMap { schema[$0]?.arrayValue ?? [] }
                .filter { !typeNames($0).isDisjoint(with: ["integer", "number"]) }
            let lo = numericBranches.lazy.compactMap { $0["minimum"]?.doubleValue ?? $0["exclusiveMinimum"]?.doubleValue }.first
            let hi = numericBranches.lazy.compactMap { $0["maximum"]?.doubleValue ?? $0["exclusiveMaximum"]?.doubleValue }.first
            return ParameterSpec(name: name, kind: .number(min: lo, max: hi, integer: types.contains("integer")),
                                 defaultValue: def, isRequired: required, summary: summary)
        }
        if types.contains("string") {
            return ParameterSpec(name: name, kind: .text, defaultValue: def, isRequired: required, summary: summary)
        }
        return nil
    }

    /// `enum`, `const`, or `anyOf`/`oneOf` of consts.
    static func enumValues(_ schema: JSONValue) -> [JSONValue]? {
        if let e = schema["enum"]?.arrayValue { return e.filter { $0 != .null } }
        if let c = schema["const"] { return [c] }
        for key in ["anyOf", "oneOf"] {
            if let alternatives = schema[key]?.arrayValue {
                let values = alternatives.compactMap { alt -> [JSONValue]? in
                    if let c = alt["const"] { return [c] }
                    return alt["enum"]?.arrayValue
                }
                if values.count == alternatives.filter({ $0["type"]?.stringValue != "null" }).count, !values.isEmpty {
                    return values.flatMap { $0 }.filter { $0 != .null }
                }
            }
        }
        return nil
    }

    static func typeNames(_ schema: JSONValue) -> Set<String> {
        var names = Set<String>()
        if let t = schema["type"]?.stringValue { names.insert(t) }
        if let ts = schema["type"]?.arrayValue { names.formUnion(ts.compactMap(\.stringValue)) }
        for key in ["anyOf", "oneOf"] {
            for alt in schema[key]?.arrayValue ?? [] { names.formUnion(typeNames(alt)) }
        }
        names.remove("null")
        return names
    }

    /// Collects every role named in a `medias` array schema, wherever it lives:
    /// `items.properties.role.enum`, `items.oneOf[].properties.role.const`, …
    static func roles(inMediasSchema schema: JSONValue, root: JSONValue) -> [String] {
        var found: [String] = []
        func visit(_ node: JSONValue, depth: Int) {
            guard depth < 8 else { return }
            let node = resolve(node, root: root)
            if let role = node["properties"]?["role"] {
                for value in enumValues(resolve(role, root: root)) ?? [] {
                    if let s = value.stringValue, !found.contains(s) { found.append(s) }
                }
            }
            if let items = node["items"] { visit(items, depth: depth + 1) }
            for key in ["oneOf", "anyOf", "allOf"] {
                for alt in node[key]?.arrayValue ?? [] { visit(alt, depth: depth + 1) }
            }
        }
        visit(schema, depth: 0)
        return found
    }

    /// Resolves a local `$ref` (`#/$defs/x` or `#/definitions/x`).
    static func resolve(_ node: JSONValue, root: JSONValue) -> JSONValue {
        guard let ref = node["$ref"]?.stringValue, ref.hasPrefix("#/") else { return node }
        var current: JSONValue? = root
        for part in ref.dropFirst(2).split(separator: "/") {
            current = current?[String(part).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")]
        }
        return current ?? node
    }
}
