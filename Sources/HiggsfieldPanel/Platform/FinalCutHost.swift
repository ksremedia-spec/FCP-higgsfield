#if os(macOS)
import AVFoundation
import CoreMedia
import Foundation
import ObjectiveC

/// Snapshot of the Final Cut Pro timeline as exposed to workflow extensions
/// (Apple: "Interacting with the Final Cut Pro Timeline"). Workflow
/// extensions get the active sequence, playhead and selected time range —
/// never the selected clips themselves.
public struct TimelineState: Equatable, Sendable {
    public var sequenceName: String?
    public var projectName: String?
    public var eventName: String?
    public var libraryName: String?
    public var libraryURL: URL?
    public var frameDuration: Double?
    public var sequenceStart: Double?
    public var sequenceDuration: Double?
    public var playhead: Double?
    /// `FCPXTimeline.sequenceTimeRange` (start…end, sequence time).
    public var range: ClosedRange<Double>?

    public static let empty = TimelineState()

    public var frameRate: Double? {
        frameDuration.flatMap { $0 > 0 ? 1 / $0 : nil }
    }

    public var rangeDuration: Double? {
        range.map { $0.upperBound - $0.lowerBound }
    }

    /// Timecode for display, e.g. `01:00:12:03`.
    public func timecode(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "—" }
        let fps = max(1, Int((frameRate ?? 25).rounded()))
        let totalFrames = Int((seconds * Double(fps)).rounded(.down))
        let f = totalFrames % fps
        let s = (totalFrames / fps) % 60
        let m = (totalFrames / fps / 60) % 60
        let h = totalFrames / fps / 3600
        return String(format: "%02d:%02d:%02d:%02d", h, m, s, f)
    }
}

/// Access to the host timeline. `ProExtensionHostBridge` inside Final Cut Pro,
/// `StandaloneHost` in the container app.
public protocol FinalCutHost: AnyObject {
    var isConnected: Bool { get }
    var hostDescription: String { get }
    func currentState() -> TimelineState
    /// Called on the main queue whenever the sequence, playhead or range changes.
    func startObserving(_ onChange: @escaping (TimelineState) -> Void)
    func stopObserving()
    @discardableResult func movePlayhead(to seconds: Double) -> Bool
}

public final class StandaloneHost: FinalCutHost {
    public init() {}
    public var isConnected: Bool { false }
    public var hostDescription: String { "Standalone" }
    public func currentState() -> TimelineState { .empty }
    public func startObserving(_ onChange: @escaping (TimelineState) -> Void) {}
    public func stopObserving() {}
    public func movePlayhead(to seconds: Double) -> Bool { false }
}

/// Binds to the Workflow Extension SDK at run time instead of link time:
/// `ProExtensionHostSingleton()` is looked up with `dlsym`, and the documented
/// Objective-C selectors are sent to the proxies:
///
///     FCPXHost.timeline
///     FCPXTimeline: activeSequence, sequenceTimeRange, playheadTime,
///                   movePlayheadTo:, addTimelineObserver:, removeTimelineObserver:
///     FCPXSequence: name, startTime, duration, frameDuration
///     FCPXObject.container, FCPXLibrary.url
///     FCPXTimelineObserver: activeSequenceChanged, playheadTimeChanged,
///                           sequenceTimeRangeChanged
///
/// This keeps the extension buildable without the SDK installed (CI), while
/// a build made with the SDK embeds and loads `ProExtensionHost.framework`
/// (see scripts/configure-workflow-sdk.sh).
public final class ProExtensionHostBridge: NSObject, FinalCutHost {
    private let host: NSObject?
    private var observer: TimelineObserver?

    public override init() {
        host = Self.loadHost()
        super.init()
    }

    public var isConnected: Bool { timeline != nil }

    public var hostDescription: String {
        guard let host else { return "Final Cut Pro (timeline API unavailable)" }
        let name = host.safeValue(forKey: "name") as? String ?? "Final Cut Pro"
        let version = host.safeValue(forKey: "versionString") as? String
        return [name, version].compactMap { $0 }.joined(separator: " ")
    }

    private var timeline: NSObject? {
        host?.safeValue(forKey: "timeline") as? NSObject
    }

    public func currentState() -> TimelineState {
        guard let timeline else { return .empty }
        var state = TimelineState()
        if let sequence = timeline.safeValue(forKey: "activeSequence") as? NSObject {
            state.sequenceName = sequence.safeValue(forKey: "name") as? String
            state.frameDuration = (sequence.safeValue(forKey: "frameDuration") as? NSValue)?.timeValue.finiteSeconds
            state.sequenceStart = (sequence.safeValue(forKey: "startTime") as? NSValue)?.timeValue.finiteSeconds
            state.sequenceDuration = (sequence.safeValue(forKey: "duration") as? NSValue)?.timeValue.finiteSeconds
            // sequence → project → event → library
            var container = sequence.safeValue(forKey: "container") as? NSObject
            var depth = 0
            while let c = container, depth < 4 {
                if let url = c.safeValue(forKey: "url") as? URL {
                    state.libraryURL = url
                    state.libraryName = c.safeValue(forKey: "name") as? String
                } else if c.responds(to: NSSelectorFromString("sequence")) {
                    state.projectName = c.safeValue(forKey: "name") as? String
                } else if state.eventName == nil, state.projectName != nil {
                    state.eventName = c.safeValue(forKey: "name") as? String
                }
                container = c.safeValue(forKey: "container") as? NSObject
                depth += 1
            }
        }
        state.playhead = Self.callCMTime(timeline, "playheadTime")?.finiteSeconds
        if let rangeValue = timeline.safeValue(forKey: "sequenceTimeRange") as? NSValue {
            let r = rangeValue.timeRangeValue
            if let start = r.start.finiteSeconds, let duration = r.duration.finiteSeconds, duration > 0 {
                state.range = start...(start + duration)
            }
        }
        return state
    }

    public func startObserving(_ onChange: @escaping (TimelineState) -> Void) {
        guard let timeline, observer == nil else { return }
        let observer = TimelineObserver { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { onChange(self.currentState()) }
        }
        Self.declareObserverConformance()
        let selector = NSSelectorFromString("addTimelineObserver:")
        guard timeline.responds(to: selector) else { return }
        timeline.perform(selector, with: observer)
        self.observer = observer
        DispatchQueue.main.async { onChange(self.currentState()) }
    }

    public func stopObserving() {
        guard let observer, let timeline else { return }
        let selector = NSSelectorFromString("removeTimelineObserver:")
        if timeline.responds(to: selector) { timeline.perform(selector, with: observer) }
        self.observer = nil
    }

    @discardableResult
    public func movePlayhead(to seconds: Double) -> Bool {
        guard let timeline else { return false }
        let selector = NSSelectorFromString("movePlayheadTo:")
        guard timeline.responds(to: selector) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, CMTime) -> CMTime
        let fn = unsafeBitCast(timeline.method(for: selector), to: Fn.self)
        _ = fn(timeline, selector, CMTime(seconds: seconds, preferredTimescale: 240_000))
        return true
    }

    // MARK: Runtime binding

    private static func loadHost() -> NSObject? {
        var candidates: [String] = []
        if let frameworks = Bundle.main.privateFrameworksPath {
            candidates.append("\(frameworks)/ProExtensionHost.framework/ProExtensionHost")
        }
        candidates += [
            "/Library/Frameworks/ProExtensionHost.framework/ProExtensionHost",
            "/Library/Developer/Frameworks/ProExtensionHost.framework/ProExtensionHost",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            _ = dlopen(path, RTLD_NOW | RTLD_GLOBAL)
        }
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(rtldDefault, "ProExtensionHostSingleton") else { return nil }
        typealias Singleton = @convention(c) () -> Unmanaged<AnyObject>?
        let singleton = unsafeBitCast(symbol, to: Singleton.self)
        guard let object = singleton()?.takeUnretainedValue() as? NSObject else { return nil }
        // Apple: "validate that the object conforms to the FCPXHost protocol".
        if let proto = objc_getProtocol("FCPXHost"), !object.conforms(to: proto) { return nil }
        return object
    }

    private static var didDeclareConformance = false

    /// The SDK may check `conformsToProtocol:` before accepting an observer;
    /// add the runtime protocol to our observer class once the framework is loaded.
    private static func declareObserverConformance() {
        guard !didDeclareConformance, let proto = objc_getProtocol("FCPXTimelineObserver") else { return }
        class_addProtocol(TimelineObserver.self, proto)
        didDeclareConformance = true
    }

    private static func callCMTime(_ object: NSObject, _ name: String) -> CMTime? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector) -> CMTime
        let fn = unsafeBitCast(object.method(for: selector), to: Fn.self)
        return fn(object, selector)
    }
}

/// Receives `FCPXTimelineObserver` callbacks.
@objc(HiggsfieldTimelineObserver)
final class TimelineObserver: NSObject {
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    @objc func activeSequenceChanged() { onChange() }
    @objc func playheadTimeChanged() { onChange() }
    @objc func sequenceTimeRangeChanged() { onChange() }
}

private extension NSObject {
    /// KVC that returns nil instead of raising for unknown keys.
    func safeValue(forKey key: String) -> Any? {
        guard responds(to: NSSelectorFromString(key)) else { return nil }
        return value(forKey: key)
    }
}

private extension CMTime {
    var finiteSeconds: Double? {
        guard isValid, !isIndefinite else { return nil }
        let s = seconds
        return s.isFinite ? s : nil
    }
}
#endif
