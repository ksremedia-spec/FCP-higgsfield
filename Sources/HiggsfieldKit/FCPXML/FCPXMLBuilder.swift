import Foundation

/// A finished file to hand to Final Cut Pro.
public struct FCPXMLImportItem: Sendable, Equatable {
    public var name: String
    public var fileURL: URL
    public var info: MediaInfo
    /// Stable id so a re-import relinks instead of duplicating (reverse-DNS, per Apple).
    public var uid: String?
    /// Shown in the clip's Notes field.
    public var note: String?
    public var keywords: [String]

    public init(name: String, fileURL: URL, info: MediaInfo, uid: String? = nil, note: String? = nil, keywords: [String] = []) {
        self.name = name
        self.fileURL = fileURL
        self.info = info
        self.uid = uid
        self.note = note
        self.keywords = keywords
    }
}

/// Builds FCPXML 1.10 documents describing Higgsfield results, for the two
/// return paths Apple documents for workflow extensions:
/// - drag and drop (clips only — FCP inserts them where they're dropped), and
/// - the Open Document Apple event (an event in a given library).
public struct FCPXMLBuilder: Sendable {
    public static let version = "1.10"
    /// Default length for stills placed in the browser.
    public var stillDuration: Double = 5
    /// Used when the file reports no frame rate.
    public var fallbackFrameRate: Double = 25

    public init() {}

    public enum Destination: Sendable, Equatable {
        /// Clips only; for the drag pasteboard (dropped on the timeline or browser).
        case dragAndDrop
        /// An event, optionally in a specific library (`import-options` “library location”).
        case event(name: String, libraryURL: URL?)
    }

    public func document(items: [FCPXMLImportItem], destination: Destination) -> String {
        var resources: [String] = []
        var clips: [String] = []
        var nextID = 1
        func newID() -> String { defer { nextID += 1 }; return "r\(nextID)" }
        var formatIDs: [String: String] = [:]

        for item in items {
            let isStill = item.info.kind == .image
            let frameDuration = isStill ? nil : RationalTime.frameDuration(forFrameRate: item.info.frameRate ?? fallbackFrameRate)
            let formatKey = isStill
                ? "still-\(item.info.width ?? 0)x\(item.info.height ?? 0)"
                : "\(item.info.width ?? 0)x\(item.info.height ?? 0)@\(frameDuration!.fcpxmlString)"
            let formatID: String
            if let existing = formatIDs[formatKey] {
                formatID = existing
            } else {
                formatID = newID()
                formatIDs[formatKey] = formatID
                resources.append(formatElement(id: formatID, frameDuration: frameDuration, info: item.info))
            }

            let assetID = newID()
            let duration: RationalTime
            if isStill {
                duration = .zero
            } else if let frameDuration {
                duration = RationalTime(seconds: item.info.duration ?? 0, preferredTimescale: frameDuration.timescale * 100)
                    .conformed(toFrameDuration: frameDuration)
            } else {
                duration = .zero
            }
            var assetAttrs: [(String, String)] = [("id", assetID), ("name", item.name)]
            if let uid = item.uid { assetAttrs.append(("uid", uid)) }
            assetAttrs += [("start", "0s"), ("duration", duration.fcpxmlString), ("hasVideo", "1"), ("format", formatID)]
            if isStill { assetAttrs.append(("videoSources", "1")) }
            if item.info.hasAudio && !isStill {
                assetAttrs += [("hasAudio", "1"), ("audioSources", "1")]
            }
            resources.append(
                "    <asset\(Self.attributes(assetAttrs))>\n" +
                "      <media-rep\(Self.attributes([("kind", "original-media"), ("src", item.fileURL.absoluteString)]))/>\n" +
                "    </asset>"
            )

            let clipDuration = isStill ? RationalTime(seconds: stillDuration, preferredTimescale: 1) : duration
            var clipAttrs: [(String, String)] = [("name", item.name), ("ref", assetID)]
            if isStill { clipAttrs.append(("format", formatID)) }
            clipAttrs += [("start", "0s"), ("duration", clipDuration.fcpxmlString)]
            if item.info.hasAudio && !isStill { clipAttrs.append(("audioRole", "dialogue")) }
            var body: [String] = []
            if let note = item.note, !note.isEmpty { body.append("<note>\(Self.escape(note))</note>") }
            if !item.keywords.isEmpty {
                body.append("<keyword\(Self.attributes([("start", "0s"), ("duration", clipDuration.fcpxmlString), ("value", item.keywords.joined(separator: ", "))]))/>")
            }
            clips.append(body.isEmpty
                ? "<asset-clip\(Self.attributes(clipAttrs))/>"
                : "<asset-clip\(Self.attributes(clipAttrs))>\n" + body.map { "  " + $0 }.joined(separator: "\n") + "\n</asset-clip>")
        }

        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE fcpxml>\n<fcpxml version=\"\(Self.version)\">\n"
        if case .event(_, let libraryURL?) = destination {
            xml += "  <import-options>\n    <option\(Self.attributes([("key", "library location"), ("value", libraryURL.absoluteString)]))/>\n  </import-options>\n"
        }
        xml += "  <resources>\n" + resources.joined(separator: "\n") + "\n  </resources>\n"
        switch destination {
        case .dragAndDrop:
            xml += clips.map { Self.indent($0, by: 2) }.joined(separator: "\n") + "\n"
        case .event(let name, _):
            xml += "  <event\(Self.attributes([("name", name)]))>\n"
            xml += clips.map { Self.indent($0, by: 4) }.joined(separator: "\n") + "\n"
            xml += "  </event>\n"
        }
        xml += "</fcpxml>\n"
        return xml
    }

    private func formatElement(id: String, frameDuration: RationalTime?, info: MediaInfo) -> String {
        var attrs: [(String, String)] = [("id", id)]
        if let frameDuration {
            if let name = Self.predefinedFormatName(width: info.width, height: info.height, frameDuration: frameDuration) {
                attrs.append(("name", name))
            }
            attrs.append(("frameDuration", frameDuration.fcpxmlString))
        } else {
            attrs.append(("name", "FFVideoFormatRateUndefined"))
        }
        if let w = info.width { attrs.append(("width", String(w))) }
        if let h = info.height { attrs.append(("height", String(h))) }
        return "    <format\(Self.attributes(attrs))/>"
    }

    /// Names of FCP's predefined progressive formats for common sizes
    /// (e.g. `FFVideoFormat1080p25`). Custom sizes (vertical video) get explicit
    /// width/height/frameDuration only, which FCPXML 1.7+ honours.
    static func predefinedFormatName(width: Int?, height: Int?, frameDuration: RationalTime) -> String? {
        let rates: [(RationalTime, String)] = [
            (RationalTime(value: 1001, timescale: 24000), "2398"), (RationalTime(value: 1, timescale: 24), "24"),
            (RationalTime(value: 1, timescale: 25), "25"), (RationalTime(value: 1001, timescale: 30000), "2997"),
            (RationalTime(value: 1, timescale: 30), "30"), (RationalTime(value: 1, timescale: 50), "50"),
            (RationalTime(value: 1001, timescale: 60000), "5994"), (RationalTime(value: 1, timescale: 60), "60"),
        ]
        guard let rate = rates.first(where: { $0.0 == frameDuration })?.1 else { return nil }
        switch (width, height) {
        case (1920, 1080): return "FFVideoFormat1080p\(rate)"
        case (1280, 720): return "FFVideoFormat720p\(rate)"
        case (3840, 2160): return "FFVideoFormat3840x2160p\(rate)"
        case (4096, 2160): return "FFVideoFormat4096x2160p\(rate)"
        default: return nil
        }
    }

    static func attributes(_ pairs: [(String, String)]) -> String {
        pairs.map { " \($0.0)=\"\(escape($0.1))\"" }.joined()
    }

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "\n": out += "&#10;"
            case "\t": out += "&#9;"
            default:
                // Drop control characters that are illegal in XML 1.0.
                if ch.value < 0x20 && ch != "\r" { continue }
                out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    static func indent(_ block: String, by spaces: Int) -> String {
        let pad = String(repeating: " ", count: spaces)
        return block.split(separator: "\n", omittingEmptySubsequences: false).map { pad + $0 }.joined(separator: "\n")
    }
}

extension JobRecord {
    /// The import item for a finished job, with prompt/model in the clip notes.
    public func importItem(info: MediaInfo, uidPrefix: String) -> FCPXMLImportItem? {
        guard let localFile else { return nil }
        var noteParts = ["Higgsfield \(operation.title) · \(modelName)"]
        if let prompt, !prompt.isEmpty { noteParts.append("Prompt: \(prompt)") }
        if !settingsSummary.isEmpty { noteParts.append(settingsSummary.joined(separator: ", ")) }
        if let remoteID { noteParts.append("Job \(remoteID)") }
        return FCPXMLImportItem(
            name: clipName, fileURL: localFile, info: info,
            uid: remoteID.map { "\(uidPrefix).\($0)" },
            note: noteParts.joined(separator: "\n"),
            keywords: ["Higgsfield", operation.title]
        )
    }
}
