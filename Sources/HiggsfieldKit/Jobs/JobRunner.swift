import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Runs operations end to end: trim → upload → submit → poll → download.
/// Progress is reported by updating the record in the `JobStore` and calling
/// `onUpdate`, so the UI only needs to observe records.
public actor JobRunner {
    public typealias UpdateHandler = @Sendable (JobRecord) -> Void

    private let client: HiggsfieldClient
    private let store: JobStore
    private let transport: HTTPTransport
    private let output: OutputLocation
    private let trimmer: MediaTrimming?
    private let sleeper: @Sendable (TimeInterval) async -> Void
    private var onUpdate: UpdateHandler?
    private var pollTasks: [UUID: Task<Void, Never>] = [:]

    public var pollInterval: TimeInterval = 3
    public var maxPollInterval: TimeInterval = 10

    public init(client: HiggsfieldClient, store: JobStore, transport: HTTPTransport = URLSessionTransport(),
                output: OutputLocation, trimmer: MediaTrimming? = nil,
                sleeper: @escaping @Sendable (TimeInterval) async -> Void = { s in
                    try? await Task.sleep(nanoseconds: UInt64(max(0, s) * 1_000_000_000))
                }) {
        self.client = client
        self.store = store
        self.transport = transport
        self.output = output
        self.trimmer = trimmer
        self.sleeper = sleeper
    }

    public func setUpdateHandler(_ handler: UpdateHandler?) {
        onUpdate = handler
    }

    public func setPollInterval(_ seconds: TimeInterval) {
        pollInterval = seconds
    }

    /// Starts a prepared request. Returns once the job is submitted (or failed
    /// to submit); polling and download continue in the background.
    @discardableResult
    public func start(_ request: PreparedRequest, prompt: String?, sourceName: String?, estimatedCredits: Double?,
                      targetFrameRate: Double? = nil) async -> JobRecord {
        var record = JobRecord(
            operation: request.operation, jobType: request.jobType, modelName: request.modelName,
            output: request.output, prompt: prompt,
            settingsSummary: Self.summary(request.params),
            sourceName: sourceName, estimatedCredits: estimatedCredits
        )
        record.targetFrameRate = targetFrameRate
        await save(record)

        do {
            var entries: [JSONValue] = []
            for item in request.media {
                let reference = try await reference(for: item)
                entries.append(reference.entry(role: item.role))
            }
            record.phase = .submitting
            await save(record)
            let id = try await client.submit(jobType: request.jobType, output: request.output,
                                             params: request.submissionParams(mediaEntries: entries))
            record.remoteID = id
            record.phase = .queued
            await save(record)
            beginPolling(record)
        } catch {
            record.phase = .failed
            record.message = (error as? HiggsfieldError)?.userMessage ?? error.localizedDescription
            await save(record)
        }
        return record
    }

    /// Resumes polling for records that were in flight when the panel closed.
    public func resumeActiveJobs() async {
        for record in await store.all() where record.phase.isActive {
            if record.remoteID != nil {
                beginPolling(record)
            } else {
                // Interrupted before submission: nothing was created server-side.
                var r = record
                r.phase = .failed
                r.message = "Interrupted before it was submitted. Try again."
                await save(r)
            }
        }
    }

    /// Stops tracking locally. The account API exposes no cancel endpoint
    /// (none is used by the official CLI), so the server job keeps running and
    /// is still billed; its result stays available in the Higgsfield web app.
    public func detach(_ id: UUID) async {
        pollTasks[id]?.cancel()
        pollTasks[id] = nil
        guard var record = await store.record(id: id), record.phase.isActive else { return }
        record.phase = .detached
        record.message = "Stopped tracking. The job may still complete on Higgsfield."
        await save(record)
    }

    /// Cancels all local polling (used when the panel reconnects with a new runner).
    public func stopAll() {
        pollTasks.values.forEach { $0.cancel() }
        pollTasks.removeAll()
    }

    public func retryDownload(_ id: UUID) async {
        guard let record = await store.record(id: id), record.remoteID != nil else { return }
        beginPolling(record)
    }

    // MARK: Internals

    private func reference(for item: PendingMedia) async throws -> MediaReference {
        switch item.payload {
        case .file(let url, let kind):
            return try await client.uploadMedia(fileURL: url, kind: kind)
        case .clip(let clip):
            if let ref = clip.remoteReference, !clip.needsTrim { return ref }
            var file = clip.fileURL
            if clip.needsTrim {
                guard let trimmer else { throw HiggsfieldError.invalidInput("Trimming isn’t available.") }
                file = try await trimmer.trim(clip.fileURL, start: clip.inPoint ?? 0, end: clip.outPoint ?? clip.info?.duration ?? 0)
            }
            return try await client.uploadMedia(fileURL: file, kind: clip.kind)
        }
    }

    private func beginPolling(_ record: JobRecord) {
        pollTasks[record.id]?.cancel()
        let id = record.id
        pollTasks[id] = Task { [weak self] in
            await self?.poll(id)
        }
    }

    private func poll(_ id: UUID) async {
        var interval = pollInterval
        var consecutiveErrors = 0
        while !Task.isCancelled {
            guard var record = await store.record(id: id), let remoteID = record.remoteID else { return }
            do {
                let job = try await client.job(id: remoteID)
                consecutiveErrors = 0
                record.previewURL = job.minResultURL ?? record.previewURL
                switch job.status {
                case .queued:
                    if record.phase != .queued { record.phase = .queued; await save(record) }
                case .running, .unknown:
                    if record.phase != .running { record.phase = .running; await save(record) }
                case .completed:
                    guard let url = job.resultURL else {
                        record.phase = .failed
                        record.message = "Higgsfield reported completion without a result URL."
                        await save(record)
                        return
                    }
                    record.resultURL = url
                    await finish(record)
                    return
                case .failed:
                    record.phase = .failed
                    record.message = job.errorMessage ?? "Higgsfield couldn’t complete this generation."
                    await save(record)
                    return
                case .nsfw:
                    record.phase = .moderated
                    record.message = "Higgsfield’s moderation rejected this result."
                    await save(record)
                    return
                case .canceled:
                    record.phase = .canceled
                    await save(record)
                    return
                }
            } catch {
                consecutiveErrors += 1
                if case HiggsfieldError.unauthorized = error {
                    record.message = (error as? HiggsfieldError)?.userMessage
                    await save(record)
                }
                if consecutiveErrors >= 20 {
                    record.phase = .detached
                    record.message = "Lost contact with Higgsfield. Use Retry to check again."
                    await save(record)
                    return
                }
            }
            await sleeper(interval)
            interval = min(interval * 1.25, maxPollInterval)
        }
    }

    private func finish(_ record: JobRecord) async {
        var record = record
        guard let resultURL = record.resultURL else { return }
        if let existing = record.localFile, FileManager.default.fileExists(atPath: existing.path) {
            record.phase = .completed
            await save(record)
            return
        }
        record.phase = .downloading
        await save(record)
        do {
            let destination = output.fileURL(for: record, resultURL: resultURL, contentType: nil)
            _ = try await transport.download(URLRequest(url: resultURL), to: destination)
            record.localFile = destination
            record.phase = .completed
            record.message = nil
        } catch {
            record.phase = .failed
            record.message = "Generated, but the download failed: \((error as? HiggsfieldError)?.userMessage ?? error.localizedDescription). Use Retry."
        }
        await save(record)
    }

    private func save(_ record: JobRecord) async {
        var r = record
        r.updatedAt = Date()
        await store.upsert(r)
        onUpdate?(r)
    }

    static func summary(_ params: [String: JSONValue]) -> [String] {
        params.keys.sorted().compactMap { key in
            guard key != "prompt", key != "medias", let v = params[key] else { return nil }
            let label = ParameterSpec(name: key, kind: .text).label
            return "\(label): \(v.displayString)"
        }
    }
}
