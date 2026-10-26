#if os(macOS)
import AppKit
import Combine
import Foundation
import HiggsfieldKit
import UniformTypeIdentifiers

/// State and actions of the Higgsfield panel. One instance per window
/// (container app) or per extension session (inside Final Cut Pro).
@MainActor
public final class PanelModel: ObservableObject {
    public enum Context: Sendable {
        case containerApp
        case workflowExtension
    }

    public struct Configuration {
        public var context: Context
        public var storage: SharedStorage
        public var oauth: OAuthConfiguration?
        /// Reverse-DNS prefix for FCPXML asset uids (e.g. the bundle id).
        public var uidPrefix: String
        public var host: FinalCutHost
        /// URL scheme of the container app, used by the extension to ask it for
        /// a fresh Higgsfield CLI session token.
        public var containerURLScheme: String

        public init(context: Context, storage: SharedStorage = SharedStorage(), oauth: OAuthConfiguration? = OAuthConfiguration(infoDictionary: Bundle.main.infoDictionary),
                    uidPrefix: String = Bundle.main.bundleIdentifier ?? "higgsfield.fcp", host: FinalCutHost, containerURLScheme: String = "higgsfieldfcp") {
            self.context = context
            self.storage = storage
            self.oauth = oauth
            self.uidPrefix = uidPrefix
            self.host = host
            self.containerURLScheme = containerURLScheme
        }
    }

    public enum AuthState: Equatable {
        case checking
        case signedOut
        case signingIn(String)
        case signedIn(CredentialSource)
    }

    public enum CostState: Equatable {
        case idle
        case estimating
        case estimate(CostEstimate)
        case unavailable(String)
    }

    public struct Banner: Equatable, Identifiable {
        public enum Kind { case info, success, error }
        public let id = UUID()
        public var kind: Kind
        public var text: String
    }

    public enum SourceAccess: Equatable {
        case ok
        /// The sandboxed extension can't read the file yet (needs user consent).
        case needsPermission(URL)
        case missing(URL)
    }

    // MARK: Published state

    @Published public private(set) var authState: AuthState = .checking
    @Published public private(set) var account: AccountBalance?
    @Published public private(set) var workspaces: [Workspace] = []
    @Published public private(set) var workspaceID: String?
    @Published public var operation: OperationKind {
        didSet { operationChanged() }
    }
    @Published public var drafts: [OperationKind: OperationDraft] = [:] {
        didSet { draftsChanged() }
    }
    @Published public private(set) var catalog: ModelCatalog = .snapshot
    @Published public private(set) var costState: CostState = .idle
    @Published public private(set) var validationMessage: String?
    @Published public private(set) var jobs: [JobRecord] = []
    @Published public private(set) var timeline: TimelineState = .empty
    @Published public private(set) var timelineProject: FCPXMLDocument.Project?
    @Published public var banner: Banner?
    @Published public private(set) var inboxItems: [URL] = []
    @Published public private(set) var sourceAccess: SourceAccess = .ok
    @Published public var autoImport: Bool {
        didSet { settings.autoImport = autoImport; saveSettings() }
    }

    public let configuration: Configuration
    public var isExtension: Bool { configuration.context == .workflowExtension }
    public var isCLIInstalled: Bool { HiggsfieldCLIBridge().isInstalled }
    public var isOAuthAvailable: Bool { configuration.oauth != nil }

    private var client: HiggsfieldClient?
    private var runner: JobRunner?
    private let store: JobStore
    private var settings: PanelSettings
    private var costTask: Task<Void, Never>?
    private var catalogTasks: Set<String> = []
    private var resultInfo: [UUID: MediaInfo] = [:]
    private var securityScopedURLs: [URL] = []
    private let probe = AVMediaProbe()
    private var draftSaveTask: Task<Void, Never>?
    private var notificationObservers: [NSObjectProtocol] = []

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.store = JobStore(url: configuration.storage.jobsFile(extension: configuration.context == .workflowExtension))
        let settings = PanelSettings.load(from: configuration.storage.settingsFile)
        self.settings = settings
        self.operation = settings.lastOperation
        self.autoImport = settings.autoImport ?? (configuration.context == .workflowExtension)
        self.drafts = Self.loadDrafts(from: configuration.storage.draftsFile) ?? [:]
        for op in OperationKind.allCases where drafts[op] == nil {
            drafts[op] = makeDraft(op, jobType: settings.lastJobTypes[op.rawValue])
        }
    }

    // MARK: Lifecycle

    public func start() {
        Task { await restoreSession() }
        Task { jobs = await store.all() }
        configuration.host.startObserving { [weak self] state in
            self?.timelineChanged(state)
        }
        refreshInbox()
        let center = DistributedNotificationCenter.default()
        notificationObservers.append(center.addObserver(forName: .higgsfieldInboxChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshInbox() }
        })
        notificationObservers.append(center.addObserver(forName: .higgsfieldSessionChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.restoreSession() }
        })
    }

    public func stop() {
        configuration.host.stopObserving()
        notificationObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        notificationObservers.removeAll()
        securityScopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        securityScopedURLs.removeAll()
        saveDraftsNow()
    }

    // MARK: Authentication

    private func restoreSession() async {
        let tokenStore = configuration.storage.tokenStore()
        guard let tokens = try? tokenStore.load() else {
            authState = .signedOut
            return
        }
        await connect(provider: provider(for: tokens.source), source: tokens.source)
    }

    private func provider(for source: CredentialSource) -> AccessTokenProvider {
        let tokenStore = configuration.storage.tokenStore()
        switch source {
        case .oauth:
            if let oauth = configuration.oauth { return OAuthTokenProvider(configuration: oauth, store: tokenStore) }
            return StoredTokenProvider(store: tokenStore) { throw HiggsfieldError.unauthorized("Sign in again.") }
        case .higgsfieldCLI:
            if isExtension {
                let scheme = configuration.containerURLScheme
                return StoredTokenProvider(store: tokenStore) { try await Self.requestCLITokenFromContainerApp(scheme: scheme, store: tokenStore) }
            }
            return CLITokenProvider(bridge: HiggsfieldCLIBridge(), store: tokenStore)
        case .manual:
            return StoredTokenProvider(store: tokenStore) { throw HiggsfieldError.unauthorized("The pasted token was rejected or expired.") }
        }
    }

    /// Sign in with this app's own OAuth client (requires `HiggsfieldOAuthClientID`).
    public func signInWithHiggsfield() async {
        guard let oauth = configuration.oauth else { return }
        authState = .signingIn("Waiting for Higgsfield sign-in in your browser…")
        do {
            let pkce = PKCEPair.generate()
            let state = OAuthConfiguration.randomState()
            let code = try await LoopbackSignIn(configuration: oauth).authorize(pkce: pkce, state: state)
            let provider = OAuthTokenProvider(configuration: oauth, store: configuration.storage.tokenStore())
            _ = try await provider.completeSignIn(code: code, pkce: pkce)
            await connect(provider: provider, source: .oauth)
            notifySessionChanged()
        } catch {
            authState = .signedOut
            show(error)
        }
    }

    /// Reuse the official Higgsfield CLI session (`hf auth login` / `hf auth token`).
    public func signInWithCLI() async {
        authState = .signingIn("Connecting to your Higgsfield CLI session…")
        let tokenStore = configuration.storage.tokenStore()
        do {
            if isExtension {
                try await Self.requestCLITokenFromContainerApp(scheme: configuration.containerURLScheme, store: tokenStore)
            } else {
                let bridge = HiggsfieldCLIBridge()
                let token: String
                do {
                    token = try await bridge.accessToken()
                } catch HiggsfieldError.notSignedIn {
                    authState = .signingIn("Finish signing in to Higgsfield in your browser…")
                    try await bridge.login()
                    token = try await bridge.accessToken()
                }
                try tokenStore.save(TokenSet(accessToken: token, expiresAt: Date().addingTimeInterval(CLITokenProvider.defaultMaxAge), source: .higgsfieldCLI))
            }
            await connect(provider: provider(for: .higgsfieldCLI), source: .higgsfieldCLI)
            notifySessionChanged()
        } catch {
            authState = .signedOut
            show(error)
        }
    }

    public func signIn(withAccessToken token: String) async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try configuration.storage.tokenStore().save(TokenSet(accessToken: trimmed, source: .manual))
            await connect(provider: provider(for: .manual), source: .manual)
            notifySessionChanged()
        } catch {
            show(error)
        }
    }

    public func signOut() {
        try? configuration.storage.tokenStore().clear()
        client = nil
        runner = nil
        account = nil
        workspaces = []
        authState = .signedOut
        costState = .idle
        notifySessionChanged()
    }

    private func connect(provider: AccessTokenProvider, source: CredentialSource) async {
        let client = HiggsfieldClient(
            configuration: HiggsfieldConfiguration(userAgent: "HiggsfieldFCP/\(Self.appVersion) (\(isExtension ? "FCP extension" : "app"))"),
            tokenProvider: provider
        )
        do {
            let spaces = try await client.workspaces()
            workspaces = spaces
            let selected = spaces.first { $0.id == settings.workspaceID } ?? spaces.first
            workspaceID = selected?.id
            await client.setWorkspace(selected?.id)
            account = try await client.balance()
            self.client = client
            let runner = JobRunner(client: client, store: store, output: OutputLocation(root: outputRoot),
                                   trimmer: AVMediaTrimmer(workDirectory: configuration.storage.workDirectory))
            await runner.setUpdateHandler { [weak self] record in
                Task { @MainActor in self?.jobUpdated(record) }
            }
            self.runner = runner
            authState = .signedIn(source)
            await runner.resumeActiveJobs()
            loadLiveSchemas()
            scheduleCostEstimate()
        } catch let error as HiggsfieldError {
            if case .notSignedIn = error { authState = .signedOut; return }
            if case .unauthorized = error { authState = .signedOut }
            else { authState = .signedIn(source); self.client = client }
            show(error)
        } catch {
            authState = .signedOut
            show(error)
        }
    }

    public func selectWorkspace(_ id: String) {
        workspaceID = id
        settings.workspaceID = id
        saveSettings()
        Task {
            await client?.setWorkspace(id)
            await refreshBalance()
            scheduleCostEstimate()
        }
    }

    public func refreshBalance() async {
        guard let client else { return }
        if let balance = try? await client.balance() { account = balance }
    }

    /// The sandboxed extension can't run the CLI; it wakes the container app,
    /// which runs `hf auth token` and writes the token to the shared Keychain.
    nonisolated static func requestCLITokenFromContainerApp(scheme: String, store: TokenStore) async throws {
        // The app stamps every token it fetches with a fresh expiry, so a
        // changed expiry means the request was served.
        let previousExpiry = (try? store.load())?.expiresAt
        guard let url = URL(string: "\(scheme)://cli-token") else { return }
        await MainActor.run {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.open(url, configuration: config, completionHandler: nil)
        }
        for _ in 0..<120 {
            try await Task.sleep(nanoseconds: 500_000_000)
            if let tokens = try? store.load(), tokens.source == .higgsfieldCLI, tokens.expiresAt != previousExpiry {
                return
            }
        }
        throw HiggsfieldError.cliUnavailable("The Higgsfield for Final Cut Pro app didn’t return a session. Open it once and choose “Use Higgsfield CLI session”.")
    }

    private func notifySessionChanged() {
        DistributedNotificationCenter.default().postNotificationName(.higgsfieldSessionChanged, object: nil, userInfo: nil, deliverImmediately: true)
    }

    // MARK: Drafts

    public var draft: OperationDraft {
        get { drafts[operation] ?? makeDraft(operation, jobType: nil) }
        set { drafts[operation] = newValue }
    }

    public var currentModel: ModelOption? { catalog.option(draft.jobType) }

    public var modelOptions: [ModelOption] {
        catalog.options(for: operation, sourceKind: draft.source?.kind)
    }

    public func selectModel(_ jobType: String) {
        var d = draft
        guard d.jobType != jobType else { return }
        d.jobType = jobType
        d.values = defaultValues(for: jobType, keeping: d.values)
        applyPreferredAspectRatio(&d, op: operation)
        draft = d
        settings.lastJobTypes[operation.rawValue] = jobType
        saveSettings()
        loadLiveSchemas()
    }

    public func setValue(_ value: JSONValue?, for parameter: String) {
        var d = draft
        d.values[parameter] = value
        draft = d
    }

    private func makeDraft(_ op: OperationKind, jobType: String?) -> OperationDraft {
        let candidates = op.candidateJobTypes(sourceKind: nil)
        let jt = jobType.flatMap { candidates.contains($0) ? $0 : nil } ?? candidates.first ?? ""
        var d = OperationDraft(operation: op, jobType: jt)
        d.values = defaultValues(for: jt, keeping: [:], operation: op)
        applyPreferredAspectRatio(&d, op: op)
        return d
    }

    /// The catalog gives no default aspect ratio. Reframe starts on 9:16 (the
    /// most common conversion), generation tools on 16:9, and tools that
    /// process existing footage keep the source shape ("auto").
    private func applyPreferredAspectRatio(_ d: inout OperationDraft, op: OperationKind) {
        guard d.values["aspect_ratio"] == nil,
              case .choice(let options)? = catalog.option(d.jobType)?.schema.parameter(named: "aspect_ratio")?.kind else { return }
        let preferred: [JSONValue]
        switch op {
        case .reframe: preferred = ["9:16", "16:9"]
        case .generateVideo, .generateImage: preferred = ["16:9", "auto"]
        case .editVideo, .removeBackground, .upscale, .drawToEdit: preferred = ["auto"]
        }
        d.values["aspect_ratio"] = preferred.first(where: options.contains) ?? options.first
    }

    /// Schema defaults, keeping compatible previous values (e.g. aspect ratio).
    private func defaultValues(for jobType: String, keeping previous: [String: JSONValue], operation op: OperationKind? = nil) -> [String: JSONValue] {
        guard let schema = catalog.option(jobType)?.schema else { return [:] }
        let tool = op ?? operation
        var values: [String: JSONValue] = [:]
        for spec in schema.parameters {
            // Edit-style tools derive the duration from the selected clip.
            if spec.name == "duration" && tool.durationFollowsSource { continue }
            if let old = previous[spec.name], case .success(let v) = spec.validate(old) {
                values[spec.name] = v
            } else if let def = spec.defaultValue, def != .null {
                values[spec.name] = def
            }
        }
        return values
    }

    private func operationChanged() {
        settings.lastOperation = operation
        saveSettings()
        loadLiveSchemas()
        scheduleCostEstimate()
    }

    private func draftsChanged() {
        scheduleCostEstimate()
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.saveDraftsNow()
        }
    }

    private func saveDraftsNow() {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(drafts) else { return }
        try? FileManager.default.createDirectory(at: configuration.storage.root, withIntermediateDirectories: true)
        try? data.write(to: configuration.storage.draftsFile, options: .atomic)
    }

    private static func loadDrafts(from url: URL) -> [OperationKind: OperationDraft]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([OperationKind: OperationDraft].self, from: data)
    }

    // MARK: Catalog

    /// Replaces snapshot schemas with live ones for the visible models.
    private func loadLiveSchemas() {
        guard let client else { return }
        for jobType in Set(modelOptions.map(\.jobType) + [draft.jobType]) where catalog.option(jobType)?.isLive != true && !catalogTasks.contains(jobType) {
            catalogTasks.insert(jobType)
            Task {
                defer { catalogTasks.remove(jobType) }
                guard let info = try? await client.jobType(jobType) else { return }
                catalog.merge(live: info)
                if draft.jobType == jobType {
                    var d = draft
                    d.values = defaultValues(for: jobType, keeping: d.values)
                    draft = d
                }
            }
        }
    }

    // MARK: Cost and validation

    private func scheduleCostEstimate() {
        costTask?.cancel()
        let d = draft
        let request: PreparedRequest
        do {
            request = try RequestBuilder.prepare(d, catalog: catalog)
            validationMessage = nil
        } catch {
            validationMessage = (error as? HiggsfieldError)?.userMessage ?? error.localizedDescription
            costState = .idle
            return
        }
        guard let client else { costState = .idle; return }
        costState = .estimating
        costTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            do {
                let estimate = try await client.estimateCost(jobType: request.jobType, params: request.costParams)
                guard !Task.isCancelled else { return }
                self?.costState = .estimate(estimate)
            } catch {
                guard !Task.isCancelled else { return }
                self?.costState = .unavailable((error as? HiggsfieldError)?.userMessage ?? "Estimate unavailable")
            }
        }
    }

    public var insufficientCredits: Bool {
        guard case .estimate(let e) = costState, let balance = account?.credits else { return false }
        return e.credits > balance + 0.0001
    }

    public var canSubmit: Bool {
        guard case .signedIn = authState, client != nil, validationMessage == nil, sourceAccess == .ok else { return false }
        return !insufficientCredits
    }

    // MARK: Submit

    public func submit() {
        guard let runner else { return show(HiggsfieldError.notSignedIn) }
        let d = draft
        let request: PreparedRequest
        do {
            request = try RequestBuilder.prepare(d, catalog: catalog)
        } catch {
            return show(error)
        }
        var estimate: Double?
        if case .estimate(let e) = costState { estimate = e.credits }
        let prompt = d.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let frameRate = timeline.frameRate
        Task {
            await runner.start(request, prompt: prompt.isEmpty ? nil : prompt, sourceName: d.source?.name,
                               estimatedCredits: estimate, targetFrameRate: frameRate)
        }
    }

    private func jobUpdated(_ record: JobRecord) {
        let previous = jobs.first { $0.id == record.id }
        if let i = jobs.firstIndex(where: { $0.id == record.id }) {
            jobs[i] = record
        } else {
            jobs.insert(record, at: 0)
        }
        if record.phase == .completed && previous?.phase != .completed {
            Task {
                await refreshBalance()
                if let file = record.localFile { resultInfo[record.id] = await probe.probe(file) }
                if autoImport, timeline.libraryURL != nil { await importToFinalCut(record) }
            }
        } else if record.phase == .submitting || record.phase == .queued, previous?.phase == .preparing || previous?.phase == .submitting {
            Task { await refreshBalance() }
        }
    }

    public func detach(_ record: JobRecord) {
        Task { await runner?.detach(record.id) }
    }

    public func retry(_ record: JobRecord) {
        Task { await runner?.retryDownload(record.id) }
    }

    public func remove(_ record: JobRecord) {
        Task {
            await store.remove(id: record.id)
            jobs.removeAll { $0.id == record.id }
        }
    }

    // MARK: Returning media to Final Cut Pro

    public func mediaInfo(for record: JobRecord) -> MediaInfo? {
        resultInfo[record.id]
    }

    public func importToFinalCut(_ record: JobRecord) async {
        guard let file = record.localFile else { return }
        var info = resultInfo[record.id]
        if info == nil { info = await probe.probe(file); resultInfo[record.id] = info }
        guard let info, info.isPlayable || info.kind == .image else {
            return show(HiggsfieldError.invalidInput("Final Cut Pro can’t import “\(file.lastPathComponent)”. Reveal it in Finder to convert it."))
        }
        guard let item = record.importItem(info: info, uidPrefix: configuration.uidPrefix) else { return }
        do {
            try await FinalCutImporter.importIntoEvent([item], eventName: settings.eventName, libraryURL: timeline.libraryURL,
                                                       staging: outputRoot.appendingPathComponent(".fcpxml", isDirectory: true))
            banner = Banner(kind: .success, text: timeline.libraryName.map { "Added to “\(settings.eventName)” in \($0)." }
                ?? "Sent to Final Cut Pro. Choose a library to finish the import.")
        } catch {
            show(error)
        }
    }

    /// FCPXML for dragging a result onto the timeline or browser.
    func dragProvider(for record: JobRecord) -> FCPXMLDragProvider? {
        guard let file = record.localFile else { return nil }
        let info = resultInfo[record.id] ?? MediaInfo(kind: record.output, frameRate: timeline.frameRate)
        guard let item = record.importItem(info: info, uidPrefix: configuration.uidPrefix) else { return nil }
        return FCPXMLDragProvider(xml: FCPXMLBuilder().document(items: [item], destination: .dragAndDrop), fileURL: file)
    }

    public func revealInFinder(_ record: JobRecord) {
        guard let file = record.localFile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    /// Feeds a finished result into a tool (e.g. Generate → Upscale) without re-uploading.
    public func useAsSource(_ record: JobRecord, in op: OperationKind) {
        guard let file = record.localFile else { return }
        let clip = SourceClip(name: record.clipName, fileURL: file, kind: record.output, origin: .higgsfieldResult,
                              info: resultInfo[record.id], remoteReference: record.remoteReference)
        operation = op
        setSource(clip)
    }

    // MARK: Sources

    public func handleDrop(_ payload: DroppedPayload) {
        switch payload {
        case .fcpxml(let data):
            ingestFCPXML(data)
        case .files(let urls):
            guard let url = urls.first else { return }
            if ["fcpxml", "fcpxmld"].contains(url.pathExtension.lowercased()) {
                let xmlURL = url.pathExtension.lowercased() == "fcpxmld" ? url.appendingPathComponent("Info.fcpxml") : url
                if let data = try? Data(contentsOf: xmlURL) { ingestFCPXML(data) } else { show(HiggsfieldError.invalidInput("Couldn’t read \(url.lastPathComponent).")) }
                return
            }
            guard let kind = MediaKind(fileExtension: url.pathExtension), kind != .audio else {
                return show(HiggsfieldError.invalidInput("Drop a video clip or an image."))
            }
            if operation.sourceRequirement == .optionalImage, kind == .image, draft.source != nil, operation == .generateImage {
                addReference(url)
                return
            }
            setSource(SourceClip(name: url.deletingPathExtension().lastPathComponent, fileURL: url, kind: kind, origin: .file))
        }
    }

    private func ingestFCPXML(_ data: Data) {
        do {
            let doc = try FCPXMLDocument(data: data)
            if let clip = doc.clips.first, let source = clip.sourceClip(origin: .finalCutBrowser) {
                setSource(source)
                if doc.clips.count > 1 {
                    banner = Banner(kind: .info, text: "Using “\(source.name)” — the first of \(doc.clips.count) clips.")
                }
            } else if let project = doc.projects.first {
                timelineProject = project
                if useTimelineClip() == false {
                    banner = Banner(kind: .info, text: "Timeline “\(project.name)” linked. Move the playhead (or set a range) in Final Cut Pro and click “Use Clip at Playhead”.")
                }
            } else if !doc.unsupported.isEmpty {
                show(HiggsfieldError.invalidInput("“\(doc.unsupported[0])” is a compound, multicam or audio-only clip. Use File ▸ Share ▸ Higgsfield to send a rendered version instead."))
            } else {
                show(HiggsfieldError.invalidInput("No usable clip was found in what you dragged."))
            }
        } catch {
            show(error)
        }
    }

    /// Resolves the clip under the playhead (or the selected range) in the
    /// linked project. Returns false when it can't.
    @discardableResult
    public func useTimelineClip() -> Bool {
        guard let project = timelineProject else { return false }
        if let range = timeline.range, range.upperBound - range.lowerBound > 0.05,
           let source = TimelineResolver.source(for: range, in: project) {
            setSource(source)
            return true
        }
        if let playhead = timeline.playhead, let clip = TimelineResolver.clip(at: playhead, in: project),
           let source = clip.sourceClip(origin: .finalCutTimeline) {
            setSource(source)
            return true
        }
        return false
    }

    public var canUseTimelineClip: Bool {
        timelineProject != nil && (timeline.playhead != nil || timeline.range != nil)
    }

    public func setSource(_ clip: SourceClip?) {
        var d = draft
        d.source = clip
        d.sketchFile = nil
        d.maskFile = nil
        let candidates = operation.candidateJobTypes(sourceKind: clip?.kind)
        if !candidates.contains(d.jobType), let first = candidates.first {
            d.jobType = first
            d.values = defaultValues(for: first, keeping: d.values)
        }
        draft = d
        loadLiveSchemas()
        guard let clip else { sourceAccess = .ok; return }
        Task { await refreshSourceAccess(clip) }
    }

    public func setTrim(inPoint: Double?, outPoint: Double?) {
        guard var source = draft.source else { return }
        source.inPoint = inPoint
        source.outPoint = outPoint
        var d = draft
        d.source = source
        draft = d
    }

    private func refreshSourceAccess(_ clip: SourceClip) async {
        let url = clip.fileURL
        if clip.remoteReference != nil { sourceAccess = .ok; return }
        if FileManager.default.isReadableFile(atPath: url.path) {
            sourceAccess = .ok
            if let info = await probe.probe(url), draft.source?.id == clip.id {
                var source = clip
                // Keep FCPXML-provided values where AVFoundation has none.
                source.info = MediaInfo(kind: info.kind, duration: info.duration ?? clip.info?.duration,
                                        frameRate: info.frameRate ?? clip.info?.frameRate, width: info.width ?? clip.info?.width,
                                        height: info.height ?? clip.info?.height, hasAudio: info.hasAudio, isPlayable: info.isPlayable)
                var d = draft
                d.source = source
                draft = d
            }
        } else if FileManager.default.fileExists(atPath: url.path) || isExtension {
            sourceAccess = .needsPermission(url)
        } else {
            sourceAccess = .missing(url)
        }
    }

    /// Asks the user to grant the sandboxed extension read access to the
    /// folder holding the source media (security-scoped).
    public func grantAccess() {
        guard case .needsPermission(let url) = sourceAccess else { return }
        let panel = NSOpenPanel()
        panel.message = "Allow Higgsfield to read “\(url.lastPathComponent)” so it can be uploaded."
        panel.prompt = "Allow"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.directoryURL = url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let granted = panel.url else { return }
        if granted.startAccessingSecurityScopedResource() { securityScopedURLs.append(granted) }
        if let clip = draft.source { Task { await refreshSourceAccess(clip) } }
    }

    public func chooseSourceFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .image]
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url { handleDrop(.files([url])) }
    }

    public func addReference(_ url: URL) {
        guard MediaKind(fileExtension: url.pathExtension) == .image else { return }
        var d = draft
        d.referenceImages.append(SourceClip(name: url.deletingPathExtension().lastPathComponent, fileURL: url, kind: .image, origin: .file))
        draft = d
    }

    public func removeReference(_ id: UUID) {
        var d = draft
        d.referenceImages.removeAll { $0.id == id }
        draft = d
    }

    public func setSketch(sketch: URL?, mask: URL?) {
        var d = draft
        d.sketchFile = sketch
        d.maskFile = mask
        draft = d
    }

    public func refreshInbox() {
        inboxItems = configuration.storage.inboxItems()
    }

    // MARK: Timeline

    private func timelineChanged(_ state: TimelineState) {
        timeline = state
    }

    /// Generate Video: match the duration to the selected timeline range.
    public func fitDurationToTimelineRange() {
        guard let length = timeline.rangeDuration, let spec = currentModel?.schema.parameter(named: "duration") else { return }
        switch spec.kind {
        case .choice(let options):
            let values = options.compactMap(\.doubleValue)
            if let best = values.min(by: { abs($0 - length) < abs($1 - length) }) { setValue(.number(best), for: "duration") }
        case .number(let lo, let hi, let integer):
            var v = integer ? length.rounded() : (length * 10).rounded() / 10
            if let lo { v = max(lo, v) }
            if let hi { v = min(hi, v) }
            setValue(.number(v), for: "duration")
        default:
            break
        }
    }

    // MARK: Helpers

    var outputRoot: URL {
        settings.outputFolder ?? OutputLocation.defaultRoot(home: Self.realHomeDirectory)
    }

    /// The user's real home folder (inside the sandbox `homeDirectoryForCurrentUser`
    /// points at the container).
    static var realHomeDirectory: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
    }

    func show(_ error: Error) {
        let text = (error as? HiggsfieldError)?.userMessage ?? error.localizedDescription
        banner = Banner(kind: .error, text: text)
    }

    private func saveSettings() {
        settings.save(to: configuration.storage.settingsFile)
    }
}

#if DEBUG
extension PanelModel {
    /// Puts the model into a given visual state without network access
    /// (snapshot tests and SwiftUI previews).
    func applyPreviewState(auth: AuthState, account: AccountBalance? = nil, jobs: [JobRecord] = [],
                           timeline: TimelineState = .empty, project: FCPXMLDocument.Project? = nil,
                           cost: CostState = .idle, banner: Banner? = nil) {
        authState = auth
        self.account = account
        self.jobs = jobs
        self.timeline = timeline
        timelineProject = project
        if validationMessage == nil { costState = cost }
        self.banner = banner
    }

    func applyPreviewResultInfo(_ info: MediaInfo, for id: UUID) {
        resultInfo[id] = info
    }
}
#endif

public extension Notification.Name {
    /// Posted by the container app when Final Cut Pro shares a file into the inbox.
    static let higgsfieldInboxChanged = Notification.Name("HiggsfieldFCP.inboxChanged")
    /// Posted when credentials change, so the app and extension stay in sync.
    static let higgsfieldSessionChanged = Notification.Name("HiggsfieldFCP.sessionChanged")
}
#endif
