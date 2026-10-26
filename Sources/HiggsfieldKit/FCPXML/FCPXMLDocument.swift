import Foundation

/// Pasteboard types Final Cut Pro uses for FCPXML (Apple: "Supporting Drag and
/// Drop…": the generic type plus version-specific types from FCPXML 1.8).
public enum FCPXMLPasteboard {
    public static let generic = "com.apple.finalcutpro.xml"
    /// Highest first; FCP picks the highest version it supports.
    public static let versioned = (8...13).reversed().map { "com.apple.finalcutpro.xml.v1-\($0)" }
    /// Types to read when receiving drags from FCP, preferred first.
    public static let readableTypes = versioned + [generic]
}

/// The parts of an FCPXML document the panel needs: media resources, clips
/// from the browser, and project timelines.
public struct FCPXMLDocument: Sendable {
    public struct Format: Sendable, Equatable {
        public var id: String
        public var name: String?
        public var frameDuration: RationalTime?
        public var width: Int?
        public var height: Int?

        public var frameRate: Double? {
            frameDuration.map { 1 / $0.seconds }
        }
    }

    public struct Asset: Sendable, Equatable {
        public var id: String
        public var name: String?
        public var uid: String?
        public var start: RationalTime
        public var duration: RationalTime?
        public var hasVideo: Bool
        public var hasAudio: Bool
        public var formatID: String?
        public var src: URL?

        public var kind: MediaKind {
            if let ext = src?.pathExtension, let k = MediaKind(fileExtension: ext) { return k }
            if !hasVideo && hasAudio { return .audio }
            return (duration?.value ?? 1) == 0 ? .image : .video
        }
    }

    /// A clip resolved to a media file and a file-relative source range.
    public struct ResolvedClip: Sendable, Equatable {
        public var name: String
        public var asset: Asset
        public var format: Format?
        /// Source range relative to the start of the media file, in seconds.
        public var sourceStart: Double
        public var sourceDuration: Double
        /// Position in the containing sequence (nil for browser clips).
        public var timelineStart: RationalTime?
        public var lane: Int
        /// Element the clip came from (`asset-clip`, `clip`, `video`, …).
        public var elementName: String

        public var sourceEnd: Double { sourceStart + sourceDuration }
    }

    public struct Project: Sendable {
        public var name: String
        public var formatID: String?
        public var tcStart: RationalTime
        public var duration: RationalTime?
        /// Video-bearing clips in the timeline, flattened with absolute positions.
        public var clips: [ResolvedClip]
    }

    public var version: String
    public var formats: [String: Format]
    public var assets: [String: Asset]
    /// Clips dragged from the browser (event items), in document order.
    public var clips: [ResolvedClip]
    public var projects: [Project]
    /// Items that can't be resolved to a single media file (compound, multicam).
    public var unsupported: [String]

    public init(data: Data) throws {
        let root = try MiniXMLElement.parse(data)
        guard root.name == "fcpxml" else {
            throw HiggsfieldError.invalidInput("This isn’t Final Cut Pro XML.")
        }
        version = root["version"] ?? ""
        let resources = root.firstChild(named: "resources")
        var formats: [String: Format] = [:]
        for f in resources?.children(named: "format") ?? [] {
            guard let id = f["id"] else { continue }
            formats[id] = Format(id: id, name: f["name"], frameDuration: f["frameDuration"].flatMap(RationalTime.init(fcpxml:)),
                                 width: f["width"].flatMap { Int($0) }, height: f["height"].flatMap { Int($0) })
        }
        var assets: [String: Asset] = [:]
        for a in resources?.children(named: "asset") ?? [] {
            guard let id = a["id"] else { continue }
            // FCPXML ≥ 1.9: <media-rep kind="original-media" src=…>; ≤ 1.8: src on the asset.
            let reps = a.children(named: "media-rep")
            let srcString = (reps.first { ($0["kind"] ?? "original-media") == "original-media" } ?? reps.first)?["src"] ?? a["src"]
            assets[id] = Asset(
                id: id, name: a["name"], uid: a["uid"],
                start: a["start"].flatMap(RationalTime.init(fcpxml:)) ?? .zero,
                duration: a["duration"].flatMap(RationalTime.init(fcpxml:)),
                hasVideo: a["hasVideo"] == "1", hasAudio: a["hasAudio"] == "1",
                formatID: a["format"], src: srcString.flatMap { URL(string: $0) }
            )
        }
        self.formats = formats
        self.assets = assets

        var unsupported: [String] = []
        var browserClips: [ResolvedClip] = []
        var projects: [Project] = []
        let containers = [root] + root.descendants(named: "library") + root.descendants(named: "event")
        for container in containers {
            for item in container.children {
                switch item.name {
                case "project":
                    if let p = Self.project(item, formats: formats, assets: assets, unsupported: &unsupported) { projects.append(p) }
                case "asset-clip", "clip", "video", "sync-clip":
                    if let c = Self.browserClip(item, formats: formats, assets: assets) {
                        browserClips.append(c)
                    } else {
                        unsupported.append(item["name"] ?? item.name)
                    }
                case "ref-clip", "mc-clip", "audition":
                    unsupported.append(item["name"] ?? item.name)
                default:
                    continue
                }
            }
        }
        self.clips = browserClips
        self.projects = projects
        self.unsupported = unsupported
    }

    // MARK: Browser clips

    /// A browser clip's `start`/`duration` is the selected range in the
    /// clip's own timebase; map it into the referenced asset.
    static func browserClip(_ e: MiniXMLElement, formats: [String: Format], assets: [String: Asset]) -> ResolvedClip? {
        guard let (assetElement, asset) = mediaElement(e, assets: assets) else { return nil }
        let clipStart = e["start"].flatMap(RationalTime.init(fcpxml:)) ?? .zero
        let clipDuration = e["duration"].flatMap(RationalTime.init(fcpxml:)) ?? asset.duration ?? .zero
        let assetTime = mapToAsset(clipLocal: clipStart, container: e, mediaElement: assetElement)
        let format = (e["format"] ?? asset.formatID).flatMap { formats[$0] }
        return ResolvedClip(
            name: e["name"] ?? asset.name ?? asset.src?.deletingPathExtension().lastPathComponent ?? "Clip",
            asset: asset, format: format,
            sourceStart: max(0, (assetTime - asset.start).seconds),
            sourceDuration: clipDuration.seconds,
            timelineStart: nil, lane: 0, elementName: e.name
        )
    }

    /// Finds the element that references the asset: the element itself
    /// (`asset-clip ref=`, `video ref=`) or a primary child of a `clip`/`sync-clip`.
    static func mediaElement(_ e: MiniXMLElement, assets: [String: Asset]) -> (MiniXMLElement, Asset)? {
        if ["asset-clip", "video"].contains(e.name), let ref = e["ref"], let asset = assets[ref], asset.hasVideo || asset.kind == .image {
            return (e, asset)
        }
        if ["clip", "sync-clip"].contains(e.name) {
            for child in e.children where child["lane"] == nil || child["lane"] == "0" {
                if let found = mediaElement(child, assets: assets) { return found }
            }
            if let spine = e.firstChild(named: "spine") {
                for child in spine.children { if let found = mediaElement(child, assets: assets) { return found } }
            }
        }
        return nil
    }

    /// Converts a time in `container`'s local timeline to asset time, walking
    /// through any nested elements between the container and the media element.
    static func mapToAsset(clipLocal: RationalTime, container: MiniXMLElement, mediaElement: MiniXMLElement) -> RationalTime {
        if container === mediaElement { return clipLocal }
        // Path from container (exclusive) down to the media element (inclusive).
        var path: [MiniXMLElement] = []
        var node: MiniXMLElement? = mediaElement
        while let n = node, n !== container {
            path.insert(n, at: 0)
            node = n.parent
        }
        var t = clipLocal
        for n in path where n.name != "spine" {
            let offset = n["offset"].flatMap(RationalTime.init(fcpxml:)) ?? .zero
            let start = n["start"].flatMap(RationalTime.init(fcpxml:)) ?? .zero
            t = start + (t - offset)
        }
        return t
    }

    // MARK: Projects

    static func project(_ e: MiniXMLElement, formats: [String: Format], assets: [String: Asset], unsupported: inout [String]) -> Project? {
        guard let sequence = e.firstChild(named: "sequence"), let spine = sequence.firstChild(named: "spine") else { return nil }
        let tcStart = sequence["tcStart"].flatMap(RationalTime.init(fcpxml:)) ?? .zero
        var clips: [ResolvedClip] = []
        collect(spine: spine, parentTimelineOrigin: .zero, parentLocalOrigin: .zero, lane: 0,
                formats: formats, assets: assets, into: &clips, unsupported: &unsupported)
        return Project(name: e["name"] ?? "Project", formatID: sequence["format"], tcStart: tcStart,
                       duration: sequence["duration"].flatMap(RationalTime.init(fcpxml:)), clips: clips)
    }

    /// Walks a spine. For an item at `offset` in a parent whose local time
    /// `parentLocalOrigin` sits at timeline time `parentTimelineOrigin`, the
    /// item's timeline start is `parentTimelineOrigin + (offset - parentLocalOrigin)`.
    static func collect(spine: MiniXMLElement, parentTimelineOrigin: RationalTime, parentLocalOrigin: RationalTime, lane: Int,
                        formats: [String: Format], assets: [String: Asset], into clips: inout [ResolvedClip], unsupported: inout [String]) {
        for item in spine.children {
            visit(item, parentTimelineOrigin: parentTimelineOrigin, parentLocalOrigin: parentLocalOrigin, inheritedLane: lane,
                  formats: formats, assets: assets, into: &clips, unsupported: &unsupported)
        }
    }

    static func visit(_ item: MiniXMLElement, parentTimelineOrigin: RationalTime, parentLocalOrigin: RationalTime, inheritedLane: Int,
                      formats: [String: Format], assets: [String: Asset], into clips: inout [ResolvedClip], unsupported: inout [String]) {
        let storyElements: Set<String> = ["asset-clip", "clip", "video", "sync-clip", "gap", "ref-clip", "mc-clip", "title", "audition", "spine", "audio"]
        guard storyElements.contains(item.name) else { return }
        let offset = item["offset"].flatMap(RationalTime.init(fcpxml:)) ?? parentLocalOrigin
        let start = item["start"].flatMap(RationalTime.init(fcpxml:)) ?? .zero
        let lane = item["lane"].flatMap { Int($0) }.map { inheritedLane + $0 } ?? inheritedLane
        let timelineStart = parentTimelineOrigin + (offset - parentLocalOrigin)

        switch item.name {
        case "asset-clip", "video", "clip", "sync-clip":
            if let (mediaEl, asset) = mediaElement(item, assets: assets), let duration = item["duration"].flatMap(RationalTime.init(fcpxml:)) {
                let assetTime = mapToAsset(clipLocal: start, container: item, mediaElement: mediaEl)
                clips.append(ResolvedClip(
                    name: item["name"] ?? asset.name ?? "Clip", asset: asset,
                    format: (item["format"] ?? asset.formatID).flatMap { formats[$0] },
                    sourceStart: max(0, (assetTime - asset.start).seconds), sourceDuration: duration.seconds,
                    timelineStart: timelineStart, lane: lane, elementName: item.name
                ))
            }
        case "ref-clip", "mc-clip":
            if lane >= 0 { unsupported.append(item["name"] ?? item.name) }
        default:
            break
        }

        // Connected (anchored) items and nested storylines use this item's local timeline.
        for child in item.children {
            if child.name == "spine" {
                let spineOffset = child["offset"].flatMap(RationalTime.init(fcpxml:)) ?? start
                let spineLane = child["lane"].flatMap { Int($0) }.map { lane + $0 } ?? lane
                let spineOrigin = timelineStart + (spineOffset - start)
                collect(spine: child, parentTimelineOrigin: spineOrigin, parentLocalOrigin: .zero, lane: spineLane,
                        formats: formats, assets: assets, into: &clips, unsupported: &unsupported)
            } else if child["lane"] != nil {
                visit(child, parentTimelineOrigin: timelineStart, parentLocalOrigin: start, inheritedLane: lane,
                      formats: formats, assets: assets, into: &clips, unsupported: &unsupported)
            }
        }
    }
}

extension FCPXMLDocument.ResolvedClip {
    /// Converts to a panel source. `timelineRange` (sequence time) narrows the
    /// source to the part of the clip inside the range.
    public func sourceClip(origin: SourceClip.Origin, timelineRange: ClosedRange<Double>? = nil) -> SourceClip? {
        guard let url = asset.src, url.isFileURL else { return nil }
        var inPoint = sourceStart
        var outPoint = sourceEnd
        if let range = timelineRange, let start = timelineStart?.seconds {
            inPoint = sourceStart + max(0, range.lowerBound - start)
            outPoint = sourceStart + min(sourceDuration, range.upperBound - start)
        }
        let kind = asset.kind
        return SourceClip(
            name: name, fileURL: url, kind: kind, origin: origin,
            inPoint: kind == .video ? inPoint : nil,
            outPoint: kind == .video ? outPoint : nil,
            info: MediaInfo(kind: kind, duration: asset.duration?.seconds, frameRate: format?.frameRate,
                            width: format?.width, height: format?.height, hasAudio: asset.hasAudio)
        )
    }
}

/// Finds which clip of a project is visible at a timeline time.
public enum TimelineResolver {
    /// The topmost video clip covering `time` (sequence time, as reported by
    /// `FCPXTimeline.playheadTime()`). Audio-only and negative-lane items are skipped.
    public static func clip(at time: Double, in project: FCPXMLDocument.Project) -> FCPXMLDocument.ResolvedClip? {
        project.clips
            .filter { c in
                guard let start = c.timelineStart?.seconds, c.lane >= 0, c.asset.hasVideo || c.asset.kind == .image else { return false }
                return time >= start - 1e-6 && time < start + c.sourceDuration - 1e-6
            }
            .max { $0.lane < $1.lane }
    }

    /// The clip to use for a selected timeline range: the topmost clip under the
    /// range start, limited to the part of it inside the range.
    public static func source(for range: ClosedRange<Double>, in project: FCPXMLDocument.Project) -> SourceClip? {
        guard let clip = clip(at: range.lowerBound, in: project) else { return nil }
        return clip.sourceClip(origin: .finalCutTimeline, timelineRange: range)
    }
}
