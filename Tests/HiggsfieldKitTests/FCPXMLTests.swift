import XCTest
@testable import HiggsfieldKit

final class FCPXMLParsingTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "fcpxml", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testBrowserDragWithSelectedRange() throws {
        let doc = try FCPXMLDocument(data: fixture("browser-clips-1.13"))
        XCTAssertEqual(doc.version, "1.13")
        XCTAssertEqual(doc.clips.map(\.name), ["A001_C002 (selected range)", "Poster Still", ])
        XCTAssertEqual(doc.unsupported, ["Music Bed", "Compound Clip 1"])

        let video = doc.clips[0]
        XCTAssertEqual(video.asset.src?.path, "/Volumes/RAID/Shoot Day 1/A001_C002_0812XY.mov")
        // start 3612012/1001 s in a timecode track starting at 3600 s → 8.404 s into the file.
        XCTAssertEqual(video.sourceStart, 3612012.0 / 1001 - 3600, accuracy: 1e-9)
        XCTAssertEqual(video.sourceDuration, 168168.0 / 24000, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(video.format?.frameRate), 23.976, accuracy: 0.001)

        let source = try XCTUnwrap(video.sourceClip(origin: .finalCutBrowser))
        XCTAssertEqual(source.kind, .video)
        XCTAssertEqual(try XCTUnwrap(source.inPoint), 8.404, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(source.selectedDuration), 7.007, accuracy: 0.001)
        XCTAssertEqual(source.info?.width, 3840)
        XCTAssertEqual(source.info?.hasAudio, true)

        let still = try XCTUnwrap(doc.clips[1].sourceClip(origin: .finalCutBrowser))
        XCTAssertEqual(still.kind, .image)
        XCTAssertNil(still.inPoint)
        XCTAssertEqual(still.fileURL.lastPathComponent, "Poster Still.png")
    }

    func testLegacyAssetSrcAttribute() throws {
        let doc = try FCPXMLDocument(data: fixture("legacy-1.8"))
        XCTAssertEqual(doc.clips.first?.asset.src?.path, "/Volumes/Old/Legacy.mov")
        XCTAssertEqual(try XCTUnwrap(doc.clips.first?.sourceDuration), 10.01, accuracy: 1e-9)
    }

    func testProjectTimelineResolution() throws {
        let doc = try FCPXMLDocument(data: fixture("project-1.10"))
        let project = try XCTUnwrap(doc.projects.first)
        XCTAssertEqual(project.name, "Spot v3")
        XCTAssertEqual(project.tcStart.seconds, 3600)
        XCTAssertEqual(Set(project.clips.map(\.name)), ["Wide", "B-Roll", "Close (wrapped)"], "audio-only VO is skipped")

        // Primary storyline.
        let wide = try XCTUnwrap(TimelineResolver.clip(at: 3602, in: project))
        XCTAssertEqual(wide.name, "Wide")
        XCTAssertEqual(wide.sourceStart, 10)

        // Connected B-roll on lane 1 covers 3604–3607 and wins over the primary clip.
        let broll = try XCTUnwrap(TimelineResolver.clip(at: 3605, in: project))
        XCTAssertEqual(broll.name, "B-Roll")
        XCTAssertEqual(broll.timelineStart?.seconds, 3604)
        XCTAssertEqual(broll.sourceStart, 2, "asset timecode start (3600 s) is removed")

        XCTAssertNil(TimelineResolver.clip(at: 3611, in: project), "gap")

        // <clip><video/></clip> wrapper maps through the inner element.
        let close = try XCTUnwrap(TimelineResolver.clip(at: 3615, in: project))
        XCTAssertEqual(close.name, "Close (wrapped)")
        XCTAssertEqual(close.sourceStart, 5)
        XCTAssertEqual(close.asset.src?.lastPathComponent, "Close.mov")
    }

    func testTimelineRangeBecomesTrimmedSource() throws {
        let project = try XCTUnwrap(FCPXMLDocument(data: fixture("project-1.10")).projects.first)
        let source = try XCTUnwrap(TimelineResolver.source(for: 3613...3617, in: project))
        XCTAssertEqual(source.origin, .finalCutTimeline)
        XCTAssertEqual(source.fileURL.path, "/Volumes/Media/Close.mov")
        XCTAssertEqual(source.inPoint, 6)
        XCTAssertEqual(source.outPoint, 10)
        // Range extending past the clip is clipped to the clip.
        let wide = try XCTUnwrap(TimelineResolver.source(for: 3608...3615, in: project))
        XCTAssertEqual(wide.inPoint, 18)
        XCTAssertEqual(wide.outPoint, 20)
    }

    func testRejectsNonFCPXML() {
        XCTAssertThrowsError(try FCPXMLDocument(data: Data("<html/>".utf8)))
        XCTAssertThrowsError(try FCPXMLDocument(data: Data("not xml".utf8)))
    }

    func testPasteboardTypesPreferHighestVersion() {
        XCTAssertEqual(FCPXMLPasteboard.readableTypes.first, "com.apple.finalcutpro.xml.v1-13")
        XCTAssertEqual(FCPXMLPasteboard.readableTypes.last, "com.apple.finalcutpro.xml")
        XCTAssertTrue(FCPXMLPasteboard.versioned.contains("com.apple.finalcutpro.xml.v1-10"))
    }
}

final class FCPXMLBuilderTests: XCTestCase {
    let video = FCPXMLImportItem(
        name: "A001 – Reframe 66666666", fileURL: URL(fileURLWithPath: "/Users/editor/Movies/Higgsfield/2026-10-26/A001 – Reframe 66666666.mp4"),
        info: MediaInfo(kind: .video, duration: 7.13, frameRate: 25, width: 1080, height: 1920, hasAudio: true),
        uid: "com.example.higgsfield.66666666-6666-4666-8666-666666666666",
        note: "Higgsfield Reframe · Reframe\nPrompt: \"quotes\" & <brackets>", keywords: ["Higgsfield", "Reframe"]
    )
    let hd = FCPXMLImportItem(
        name: "Generated", fileURL: URL(fileURLWithPath: "/Users/editor/Movies/Higgsfield/gen.mp4"),
        info: MediaInfo(kind: .video, duration: 5, frameRate: 23.976, width: 1920, height: 1080, hasAudio: false)
    )
    let still = FCPXMLImportItem(
        name: "Still", fileURL: URL(fileURLWithPath: "/Users/editor/Movies/Higgsfield/still.png"),
        info: MediaInfo(kind: .image, width: 2048, height: 2048)
    )

    func testEventDocumentForOpenDocumentImport() throws {
        let library = URL(fileURLWithPath: "/Users/editor/Movies/Spot.fcpbundle", isDirectory: true)
        let xml = FCPXMLBuilder().document(items: [video, hd, still], destination: .event(name: "Higgsfield AI", libraryURL: library))
        XCTAssertTrue(xml.contains(#"<fcpxml version="1.10">"#))
        XCTAssertTrue(xml.contains(#"<option key="library location" value="file:///Users/editor/Movies/Spot.fcpbundle/"/>"#))
        XCTAssertTrue(xml.contains(#"<event name="Higgsfield AI">"#))
        // Vertical 1080×1920 has no predefined format name → explicit attributes.
        XCTAssertTrue(xml.contains(#"<format id="r1" frameDuration="1/25s" width="1080" height="1920"/>"#))
        XCTAssertTrue(xml.contains(#"name="FFVideoFormat1080p2398" frameDuration="1001/24000s""#))
        XCTAssertTrue(xml.contains(#"name="FFVideoFormatRateUndefined" width="2048" height="2048""#))
        // 7.13 s conformed down to whole frames at 25 fps = 178 frames.
        XCTAssertTrue(xml.contains(#"duration="178/25s""#))
        XCTAssertTrue(xml.contains("src=\"file:///Users/editor/Movies/Higgsfield/2026-10-26/A001%20%E2%80%93%20Reframe%2066666666.mp4\""))
        XCTAssertTrue(xml.contains("<note>Higgsfield Reframe · Reframe&#10;Prompt: &quot;quotes&quot; &amp; &lt;brackets&gt;</note>"))
        XCTAssertTrue(xml.contains(#"<keyword start="0s" duration="178/25s" value="Higgsfield, Reframe"/>"#))
        XCTAssertTrue(xml.contains(#"uid="com.example.higgsfield.66666666-6666-4666-8666-666666666666""#))
        try validateAgainstDTD(xml, name: "event")
        // Round-trip through our own parser.
        let parsed = try FCPXMLDocument(data: Data(xml.utf8))
        XCTAssertEqual(parsed.clips.count, 3)
        XCTAssertEqual(parsed.clips.first?.asset.src?.path, video.fileURL.path)
        XCTAssertEqual(parsed.clips.last?.asset.kind, .image)
    }

    func testDragDocumentHasOnlyClips() throws {
        let xml = FCPXMLBuilder().document(items: [hd], destination: .dragAndDrop)
        XCTAssertFalse(xml.contains("<event"))
        XCTAssertFalse(xml.contains("import-options"))
        XCTAssertTrue(xml.contains(#"<asset-clip name="Generated" ref="r2" start="0s" duration="119119/24000s"/>"#))
        try validateAgainstDTD(xml, name: "drag")
    }

    func testDurationConformsToFrameBoundaries() throws {
        let xml = FCPXMLBuilder().document(items: [hd], destination: .dragAndDrop)
        let doc = try FCPXMLDocument(data: Data(xml.utf8))
        let asset = try XCTUnwrap(doc.assets.values.first)
        let frames = try XCTUnwrap(asset.duration) / RationalTime(value: 1001, timescale: 24000)
        XCTAssertEqual(frames, frames.rounded(), "duration must be a whole number of frames")
        XCTAssertEqual(frames, 119) // 5 s at 23.976 → 119 whole frames
    }

    func testEventWithoutLibraryOmitsImportOptions() throws {
        let xml = FCPXMLBuilder().document(items: [still], destination: .event(name: "Higgsfield AI", libraryURL: nil))
        XCTAssertFalse(xml.contains("import-options"))
        try validateAgainstDTD(xml, name: "event-nolibrary")
    }

    func testJobRecordImportItem() {
        var record = JobRecord(operation: .editVideo, jobType: "seedance_2_0", modelName: "Seedance 2.0", output: .video,
                               prompt: "make it snow", settingsSummary: ["Resolution: 1080p"], sourceName: "A001")
        XCTAssertNil(record.importItem(info: MediaInfo(kind: .video), uidPrefix: "com.example"))
        record.remoteID = "abcdef12-0000-4000-8000-000000000000"
        record.localFile = URL(fileURLWithPath: "/tmp/x.mp4")
        let item = record.importItem(info: MediaInfo(kind: .video, duration: 5), uidPrefix: "com.example.hf")
        XCTAssertEqual(item?.name, "A001 – Edit Video abcdef12")
        XCTAssertEqual(item?.uid, "com.example.hf.abcdef12-0000-4000-8000-000000000000")
        XCTAssertEqual(item?.note, "Higgsfield Edit Video · Seedance 2.0\nPrompt: make it snow\nResolution: 1080p\nJob abcdef12-0000-4000-8000-000000000000")
        XCTAssertEqual(item?.keywords, ["Higgsfield", "Edit Video"])
    }

    func testEscapingStripsIllegalControlCharacters() {
        XCTAssertEqual(FCPXMLBuilder.escape("a\u{0001}b\tc"), "ab&#9;c")
    }

    /// Validates with `xmllint --dtdvalid` when `FCPXML_DTD` points at Apple's
    /// DTD (CI fetches it with tools/fetch_fcpxml_dtd.py). Also writes the
    /// document to `FCPXML_OUT` when set.
    func validateAgainstDTD(_ xml: String, name: String) throws {
        let env = ProcessInfo.processInfo.environment
        if let out = env["FCPXML_OUT"] {
            let dir = URL(fileURLWithPath: out, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(xml.utf8).write(to: dir.appendingPathComponent("\(name).fcpxml"))
        }
        guard let dtd = env["FCPXML_DTD"] else { return }
        let xmllint = ["/usr/bin/xmllint", "/opt/homebrew/bin/xmllint", "/usr/local/bin/xmllint"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let xmllint else { return XCTFail("FCPXML_DTD is set but xmllint is not installed") }
        let file = try temporaryFile(named: "\(name).fcpxml", contents: xml)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: xmllint)
        process.arguments = ["--noout", "--dtdvalid", dtd, file.path]
        let err = Pipe()
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let messages = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, "FCPXML \(name) failed DTD validation:\n\(messages)\n\(xml)")
    }
}
