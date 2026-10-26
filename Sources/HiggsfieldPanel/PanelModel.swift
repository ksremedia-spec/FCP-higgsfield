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
    public var isCLIInstalled: Bool { Self.cliBridge().isInstalled }
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
    /// Incremented per connect; results of superseded connects are ignored.
    private var connectGeneration = 0
    /// The "interrupted before submission" sweep runs once per launch only.
    private var didSweepInterrupted = false
    private var signInTask: Task<Void, Never>?
    private var cliRefreshTask: Task<Void, Never>?

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.store = JobStore(url: configuration.storage.jobsFile(extension: configuration.context == .workflowExtension))
        let isExt = configuration.context == .workflowExtension
        let settings = PanelSettings.load(from: configuration.storage.settingsFile(extension: isExt))
        self.settings = settings
        self.operation = settings.lastOperation
        self.autoImport = settings.autoImport ?? (configuration.context == .workflowExtension)
        var restored = Self.loadDrafts(from: configuration.storage.draftsFile(extension: isExt)) ?? [:]
        // Drawings live in a temp folder that may have been emptied.
        for (op, d) in restored {
            var d = d
            if let f = d.sketchFile, !FileManager.default.fileExists(atPath: f.path) { d.sketchFile = nil }
            if let f = d.maskFile, !FileManager.default.fileExists(atPath: f.path) { d.maskFile = nil }
            restored[op] = d
        }
        self.drafts = restored
        for op in OperationKind.allCases where drafts[op] == nil {
            drafts[op] = makeDraft(op, jobType: settings.lastJobTypes[op.rawValue])
        }
    }

    // MARK: Lifecycle

    public func start() {
        restoreSecurityScopedAccess()
        Task { await restoreSession(reconnect: false) }
        Task {
            jobs = await store.all()
            // Drag and import need each result's duration/size; probe finished files.
            for job in jobs.prefix(50) where job.phase == .completed && resultInfo[job.id] == nil {
                if let file = job.localFile, FileManager.default.fileExists(atPath: file.path) {
                    resultInfo[job.id] = await probe.probe(file)
                }
            }
        }
        configuration.host.startObserving { [weak self] state in
            self?.timelineChanged(state)
        }
        refreshInbox()
        let center = DistributedNotificationCenter.default()
        notificationObservers.append(center.addObserver(forName: .higgsfieldInboxChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshInbox() }
        })
        // Only react to sign-in changes made by the other process (app ⟷ extension).
        let me = Self.processTag
        notificationObservers.append(center.addObserver(forName: .higgsfieldSessionChanged, object: nil, queue: .main) { [weak self] note in
            guard (note.object as? String) != me else { return }
            Task { @MainActor in await self?.restoreSession(reconnect: true) }
        })
        Task { await refreshSourceAccess(draft.source) }
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

    /// `reconnect: false` keeps an existing session (the extension window was
    /// just hidden and shown again); `true` rebuilds it because the other
    /// process changed the credentials.
    private func restoreSession(reconnect: Bool) async {
        if !reconnect, case .signedIn = authState, client != nil {
            await refreshBalance()
            return
        }
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
                // Run the CLI directly when the sandbox allows it; otherwise ask
                // the container app, which can always run it (and sign in).
                let scheme = configuration.containerURLScheme
                let status = configuration.storage.cliStatusFile
                let viaApp = StoredTokenProvider(store: tokenStore) {
                    try await Self.requestCLITokenFromContainerApp(scheme: scheme, store: tokenStore, statusFile: status)
                }
                return FallbackTokenProvider(primary: CLITokenProvider(bridge: Self.cliBridge(), store: tokenStore), fallback: viaApp)
            }
            return CLITokenProvider(bridge: Self.cliBridge(), store: tokenStore)
        case .manual:
            return StoredTokenProvider(store: tokenStore) { throw HiggsfieldError.unauthorized("The pasted token was rejected or expired.") }
        }
    }

    public enum SignInMethod {
        case higgsfield
        case cli
        case token(String)
    }

    /// Starts a sign-in that the user can cancel from the panel.
    public func startSignIn(_ method: SignInMethod) {
        signInTask?.cancel()
        signInTask = Task {
            switch method {
            case .higgsfield: await signInWithHiggsfield()
            case .cli: await signInWithCLI()
            case .token(let t): await signIn(withAccessToken: t)
            }
        }
    }

    public func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        if case .signingIn = authState { authState = .signedOut }
    }

    /// Sign in with this app's own OAuth client (requires `HiggsfieldOAuthClientID`).
    func signInWithHiggsfield() async {
        guard let oauth = configuration.oauth else { return }
        authState = .signingIn("Waiting for Higgsfield sign-in in your browser…")
        do {
            let pkce = PKCEPair.generate()
            let state = OAuthConfiguration.randomState()
            let code = try await LoopbackSignIn(configuration: oauth).authorize(pkce: pkce, state: state)
            try Task.checkCancellation()
            let provider = OAuthTokenProvider(configuration: oauth, store: configuration.storage.tokenStore())
            _ = try await provider.completeSignIn(code: code, pkce: pkce)
            await connect(provider: provider, source: .oauth)
            notifySessionChangedIfSignedIn()
        } catch is CancellationError {
            return
        } catch {
            if case .signingIn = authState { authState = .signedOut }
            if !Task.isCancelled { show(error) }
        }
    }

    /// Reuse the official Higgsfield CLI session (`hf auth login` / `hf auth token`).
    func signInWithCLI() async {
        authState = .signingIn("Connecting to your Higgsfield CLI session…")
        let tokenStore = configuration.storage.tokenStore()
        do {
            if isExtension {
                do {
                    try await fetchCLIToken(loginIfNeeded: false)
                } catch {
                    // Sandbox blocked the CLI, or it needs a browser sign-in: the app handles it.
                    try await Self.requestCLITokenFromContainerApp(scheme: configuration.containerURLScheme, store: tokenStore,
                                                                   statusFile: configuration.storage.cliStatusFile)
                }
            } else {
                try await fetchCLIToken(loginIfNeeded: true)
            }
            try Task.checkCancellation()
            await connect(provider: provider(for: .higgsfieldCLI), source: .higgsfieldCLI)
            notifySessionChangedIfSignedIn()
        } catch is CancellationError {
            return
        } catch {
            if case .signingIn = authState { authState = .signedOut }
            if !Task.isCancelled { show(error) }
        }
    }

    /// The official CLI, run with the real home folder so it finds its own
    /// login (inside the sandbox HOME points at the container).
    nonisolated static func cliBridge() -> HiggsfieldCLIBridge {
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = SharedStorage.realHomeDirectory.path
        return HiggsfieldCLIBridge(environment: env)
    }

    /// Runs the official CLI and stores its token.
    private func fetchCLIToken(loginIfNeeded: Bool) async throws {
        let bridge = Self.cliBridge()
        let token: String
        do {
            token = try await bridge.accessToken()
        } catch HiggsfieldError.notSignedIn where loginIfNeeded {
            if case .signingIn = authState { authState = .signingIn("Finish signing in to Higgsfield in your browser…") }
            try await bridge.login()
            token = try await bridge.accessToken()
        }
        try configuration.storage.tokenStore().save(
            TokenSet(accessToken: token, expiresAt: Date().addingTimeInterval(CLITokenProvider.defaultMaxAge), source: .higgsfieldCLI))
    }

    /// Container app: serves `higgsfieldfcp://cli-token` from the extension.
    /// Refreshes the stored CLI token without disturbing this window's state;
    /// concurrent requests share one run. The outcome is written to the shared
    /// status file so the extension can report CLI failures promptly.
    public func refreshCLISessionForExtension() {
        guard cliRefreshTask == nil else { return }
        cliRefreshTask = Task {
            defer { cliRefreshTask = nil }
            do {
                try await fetchCLIToken(loginIfNeeded: true)
                CLIStatus(ok: true, message: nil).write(to: configuration.storage.cliStatusFile)
                if case .signedOut = authState { await restoreSession(reconnect: true) }
            } catch {
                let message = (error as? HiggsfieldError)?.userMessage ?? error.localizedDescription
                CLIStatus(ok: false, message: message).write(to: configuration.storage.cliStatusFile)
                show(error)
            }
        }
    }

    func signIn(withAccessToken token: String) async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try configuration.storage.tokenStore().save(TokenSet(accessToken: trimmed, source: .manual))
            await connect(provider: provider(for: .manual), source: .manual)
            notifySessionChangedIfSignedIn()
        } catch {
            show(error)
        }
    }

    public func signOut() {
        try? configuration.storage.tokenStore().clear()
        client = nil
        connectGeneration += 1
        // Keep the runner (uploads already in progress finish); stop polling.
        if let runner { Task { await runner.stopAll() } }
        account = nil
        workspaces = []
        authState = .signedOut
        costState = .idle
        notifySessionChanged()
    }

    private func connect(provider: AccessTokenProvider, source: CredentialSource) async {
        connectGeneration += 1
        let generation = connectGeneration
        let client = HiggsfieldClient(
            configuration: HiggsfieldConfiguration(userAgent: "HiggsfieldFCP/\(Self.appVersion) (\(isExtension ? "FCP extension" : "app"))"),
            tokenProvider: provider
        )
        do {
            let spaces = try await client.workspaces()
            let selected = spaces.first { $0.id == settings.workspaceID } ?? spaces.first
            await client.setWorkspace(selected?.id)
            let balance = try await client.balance()
            guard generation == connectGeneration else { return }
            workspaces = spaces
            workspaceID = selected?.id
            account = balance
            authState = .signedIn(source)
        } catch let error as HiggsfieldError {
            guard generation == connectGeneration else { return }
            switch error {
            case .notSignedIn, .unauthorized:
                self.client = nil
                authState = .signedOut
                if case .unauthorized = error { show(error) }
                return
            default:
                // Network or server trouble: stay signed in so the user can retry.
                authState = .signedIn(source)
                show(error)
            }
        } catch {
            guard generation == connectGeneration else { return }
            authState = .signedIn(source)
            show(error)
        }
        self.client = client
        // One runner for the panel's lifetime: swap credentials in place so
        // in-flight uploads and polls are never duplicated or marked failed.
        let runner: JobRunner
        if let existing = self.runner {
            runner = existing
            await runner.setClient(client)
        } else {
            runner = JobRunner(client: client, store: store, output: OutputLocation(root: outputRoot),
                               trimmer: AVMediaTrimmer(workDirectory: configuration.storage.workDirectory))
            await runner.setUpdateHandler { [weak self] record in
                Task { @MainActor in self?.jobUpdated(record) }
            }
            self.runner = runner
        }
        await runner.resumeActiveJobs(markInterrupted: !didSweepInterrupted)
        didSweepInterrupted = true
        loadLiveSchemas()
        scheduleCostEstimate()
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
    /// which runs `hf auth token` and writes the token to the shared credential store.
    nonisolated static func requestCLITokenFromContainerApp(scheme: String, store: TokenStore, statusFile: URL) async throws {
        // The app stamps every token it fetches with a fresh expiry, so a
        // changed expiry means the request was served. Failures are reported
        // through the shared status file.
        let previousExpiry = (try? store.load())?.expiresAt
        let requestedAt = Date()
        guard let url = URL(string: "\(scheme)://cli-token") else { return }
        await MainActor.run {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.open(url, configuration: config, completionHandler: nil)
        }
        // `hf auth login` may wait up to 5 minutes for the browser sign-in.
        for _ in 0..<660 {
            try await Task.sleep(nanoseconds: 500_000_000)
            if let tokens = try? store.load(), tokens.source == .higgsfieldCLI, tokens.expiresAt != previousExpiry {
                return
            }
            if let status = CLIStatus.read(from: statusFile), status.date > requestedAt, !status.ok {
                throw HiggsfieldError.cliUnavailable(status.message ?? "The Higgsfield CLI couldn’t provide a session.")
            }
        }
        throw HiggsfieldError.cliUnavailable("The Higgsfield for Final Cut Pro app didn’t return a session. Open it once and choose “Use Higgsfield CLI Session”.")
    }

    /// Identifies this process in distributed notifications.
    nonisolated static let processTag = "pid-\(ProcessInfo.processInfo.processIdentifier)"

    private func notifySessionChangedIfSignedIn() {
        if case .signedIn = authState { notifySessionChanged() }
    }

    private func notifySessionChanged() {
        DistributedNotificationCenter.default().postNotificationName(.higgsfieldSessionChanged, object: Self.processTag,
                                                                     userInfo: nil, deliverImmediately: true)
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

    /// Reframe starts on 9:16 (the most common conversion; its schema has no
    /// default), generation tools on 16:9, and tools that process existing
    /// footage keep the source shape ("auto") even when the model's schema
    /// defaults to something else.
    private func applyPreferredAspectRatio(_ d: inout OperationDraft, op: OperationKind) {
        guard d.values["aspect_ratio"] == nil,
              case .choice(let options)? = catalog.option(d.jobType)?.schema.parameter(named: "aspect_ratio")?.kind else { return }
        let preferred: [JSONValue]
        switch op {
        case .reframe: preferred = ["9:16", "16:9"]
        case .generateVideo, .generateImage: preferred = ["16:9", "auto"]
        case .editVideo, .removeBackground, .upscale, .drawToEdit: preferred = ["auto"]
        }
        // Without "auto", a processing tool sends no ratio rather than an invented one.
        if Self.keepsSourceShape(op) && !options.contains("auto") { return }
        d.values["aspect_ratio"] = preferred.first(where: options.contains) ?? options.first
    }

    static func keepsSourceShape(_ op: OperationKind) -> Bool {
        switch op {
        case .editVideo, .removeBackground, .upscale, .drawToEdit: return true
        case .reframe, .generateVideo, .generateImage: return false
        }
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
            } else if spec.name == "aspect_ratio" && Self.keepsSourceShape(tool) {
                // Live schemas give a default (Seedance: 16:9), but tools that
                // process existing footage keep its shape; see applyPreferredAspectRatio.
                continue
            } else if let def = spec.defaultValue, def != .null {
                values[spec.name] = def
            }
        }
        return values
    }

    private func operationChanged() {
        settings.lastOperation = operation
        saveSettings()
        Task { await refreshSourceAccess(draft.source) }
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
        try? data.write(to: configuration.storage.draftsFile(extension: isExtension), options: .atomic)
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
                    applyPreferredAspectRatio(&d, op: operation)
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

    /// Probes a finished result's file once (needed for drag, import and reuse).
    public func ensureResultInfo(_ record: JobRecord) async {
        guard resultInfo[record.id] == nil, let file = record.localFile,
              FileManager.default.fileExists(atPath: file.path) else { return }
        resultInfo[record.id] = await probe.probe(file)
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
        guard let file = record.localFile, let info = resultInfo[record.id] else { return nil }
        // Without a duration FCP would import a zero-length clip.
        if info.kind == .video && (info.duration ?? 0) <= 0 { return nil }
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
        // Media info (duration, size) drives limits, duration and trimming;
        // refreshSourceAccess probes it if it isn't known yet.
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
        guard timelineProjectMatchesActiveSequence else {
            banner = Banner(kind: .info, text: "“\(project.name)” isn’t the timeline open in Final Cut Pro. Drag the open project here to link it.")
            return false
        }
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
        timelineProject != nil && timelineProjectMatchesActiveSequence && (timeline.playhead != nil || timeline.range != nil)
    }

    /// The linked project must be the one open in FCP, otherwise the playhead
    /// would be resolved against the wrong timeline. Without host info (no
    /// SDK) the link can't be checked and is trusted.
    var timelineProjectMatchesActiveSequence: Bool {
        guard let project = timelineProject else { return false }
        let open = [timeline.projectName, timeline.sequenceName].compactMap { $0 }
        return open.isEmpty || open.contains(project.name)
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
            applyPreferredAspectRatio(&d, op: operation)
        }
        draft = d
        loadLiveSchemas()
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

    private func refreshSourceAccess(_ clip: SourceClip?) async {
        guard let clip else { sourceAccess = .ok; return }
        let url = clip.fileURL
        let readable = FileManager.default.isReadableFile(atPath: url.path)
        let access: SourceAccess
        if clip.remoteReference != nil && !clip.needsTrim {
            access = .ok  // passed by job id; the local file is only for preview/info
        } else if readable {
            access = .ok
        } else if FileManager.default.fileExists(atPath: url.path) || isExtension {
            access = .needsPermission(url)
        } else {
            access = .missing(url)
        }
        guard draft.source?.id == clip.id else { return }
        sourceAccess = access
        guard readable else { return }
        guard let info = await probe.probe(url), draft.source?.id == clip.id else { return }
        var source = draft.source ?? clip
        // Keep FCPXML-provided values where AVFoundation has none.
        source.info = MediaInfo(kind: info.kind, duration: info.duration ?? clip.info?.duration,
                                frameRate: info.frameRate ?? clip.info?.frameRate, width: info.width ?? clip.info?.width,
                                height: info.height ?? clip.info?.height, hasAudio: info.hasAudio, isPlayable: info.isPlayable)
        var d = draft
        d.source = source
        draft = d
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
        // Remember the grant so it survives the extension being relaunched.
        if let bookmark = try? granted.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            settings.securityBookmarks = Array((settings.securityBookmarks + [bookmark]).suffix(20))
            saveSettings()
        }
        Task { await refreshSourceAccess(draft.source) }
    }

    /// Re-opens folders the user granted earlier (security-scoped bookmarks).
    private func restoreSecurityScopedAccess() {
        for data in settings.securityBookmarks {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale),
                  !securityScopedURLs.contains(url), url.startAccessingSecurityScopedResource() else { continue }
            securityScopedURLs.append(url)
        }
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
        let previous = timeline
        timeline = state
        // Opening another project in FCP invalidates the linked timeline.
        if timelineProject != nil, state.sequenceName != previous.sequenceName || state.projectName != previous.projectName,
           !timelineProjectMatchesActiveSequence {
            timelineProject = nil
        }
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
        settings.outputFolder ?? OutputLocation.defaultRoot(home: SharedStorage.realHomeDirectory)
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
    }

    func show(_ error: Error) {
        let text = (error as? HiggsfieldError)?.userMessage ?? error.localizedDescription
        banner = Banner(kind: .error, text: text)
    }

    private func saveSettings() {
        settings.save(to: configuration.storage.settingsFile(extension: isExtension))
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
