import Foundation

/// A selectable Higgsfield job type with its parameter schema.
public struct ModelOption: Identifiable, Equatable, Sendable {
    public var jobType: String
    public var name: String
    public var provider: String
    public var output: MediaKind
    public var schema: ParameterSchema
    /// True when `schema` came from the live API rather than the bundled snapshot.
    public var isLive: Bool

    public var id: String { jobType }

    public init(jobType: String, name: String, provider: String = "", output: MediaKind, schema: ParameterSchema, isLive: Bool) {
        self.jobType = jobType
        self.name = name
        self.provider = provider
        self.output = output
        self.schema = schema
        self.isLive = isLive
    }
}

/// Job types and schemas known to the panel. Starts from the bundled snapshot
/// of the Higgsfield catalog and is updated in place from `GET /job_types/{id}`.
public struct ModelCatalog: Sendable {
    public private(set) var options: [String: ModelOption]
    public static let snapshotDate = CatalogSnapshot.captured

    public init(options: [String: ModelOption]) {
        self.options = options
    }

    /// The bundled snapshot (captured 2026-10-26).
    public static let snapshot: ModelCatalog = {
        struct Entry: Decodable {
            var job_type: String
            var name: String
            var provider: String
            var type: String
            var json_schema: JSONValue
        }
        let entries = (try? JSONDecoder().decode([Entry].self, from: Data(CatalogSnapshot.json.utf8))) ?? []
        var options: [String: ModelOption] = [:]
        for e in entries {
            options[e.job_type] = ModelOption(
                jobType: e.job_type, name: e.name, provider: e.provider,
                output: MediaKind(rawValue: e.type) ?? .video,
                schema: JobTypeQuirks.adjust(ParameterSchema(jsonSchema: e.json_schema), jobType: e.job_type), isLive: false
            )
        }
        return ModelCatalog(options: options)
    }()

    public func option(_ jobType: String) -> ModelOption? {
        options[jobType]
    }

    /// Replaces the snapshot entry with live catalog data.
    public mutating func merge(live info: JobTypeInfo) {
        let existing = options[info.jobType]
        let schema = info.jsonSchema.map { JobTypeQuirks.adjust(ParameterSchema(jsonSchema: $0), jobType: info.jobType) } ?? existing?.schema
        guard let schema else { return }
        options[info.jobType] = ModelOption(
            jobType: info.jobType,
            name: info.name ?? existing?.name ?? info.jobType,
            provider: existing?.provider ?? "",
            output: info.outputType ?? existing?.output ?? .video,
            schema: schema,
            isLive: info.jsonSchema != nil
        )
    }

    /// Options for an operation, in the operation's preferred order.
    public func options(for operation: OperationKind, sourceKind: MediaKind?) -> [ModelOption] {
        operation.candidateJobTypes(sourceKind: sourceKind).compactMap { options[$0] }
    }
}
