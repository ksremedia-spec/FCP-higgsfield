#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import HiggsfieldKit
@testable import HiggsfieldPanel

@MainActor
final class PanelTests: XCTestCase {
    var tempRoot: URL!

    override func setUp() async throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("panel-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    func makeModel(_ context: PanelModel.Context = .workflowExtension) -> PanelModel {
        PanelModel(configuration: .init(context: context, storage: SharedStorage(root: tempRoot), oauth: nil,
                                        uidPrefix: "com.example.test", host: StandaloneHost()))
    }

    // MARK: Draw to Edit rendering

    func testSketchAndMaskRendering() throws {
        let frame = try XCTUnwrap(Self.gradientImage(width: 200, height: 100))
        let strokes = [SketchStroke(points: [CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.9, y: 0.5)], width: 0.1, color: .systemRed)]
        let mask = try XCTUnwrap(SketchRenderer.render(frame: frame, strokes: strokes, asMask: true))
        XCTAssertEqual(mask.width, 200)
        XCTAssertEqual(mask.height, 100)
        XCTAssertEqual(Self.pixel(mask, x: 100, y: 50).r, 255, "stroke centre is white in the mask")
        XCTAssertEqual(Self.pixel(mask, x: 100, y: 5).r, 0, "untouched area is black in the mask")
        let sketch = try XCTUnwrap(SketchRenderer.render(frame: frame, strokes: strokes, asMask: false))
        let p = Self.pixel(sketch, x: 100, y: 50)
        XCTAssertGreaterThan(p.r, 200)
        XCTAssertLessThan(p.g, 120, "stroke is drawn in red over the frame")
        XCTAssertNotNil(FrameGrabber.pngData(sketch))
    }

    // MARK: Returning media to Final Cut Pro

    func testDragPayloadOffersFCPXMLAndFileURL() throws {
        let model = makeModel()
        let file = tempRoot.appendingPathComponent("Result.mp4")
        try Data("x".utf8).write(to: file)
        var job = JobRecord(operation: .reframe, jobType: "reframe", modelName: "Reframe", output: .video, sourceName: "A001", phase: .completed)
        job.remoteID = "66666666-6666-4666-8666-666666666666"
        job.localFile = file
        model.applyPreviewState(auth: .signedIn(.manual), jobs: [job])
        model.applyPreviewResultInfo(MediaInfo(kind: .video, duration: 4, frameRate: 25, width: 1080, height: 1920, hasAudio: false), for: job.id)

        let provider = try XCTUnwrap(model.dragProvider(for: job))
        XCTAssertTrue(provider.xml.contains(#"<fcpxml version="1.10">"#))
        XCTAssertTrue(provider.xml.contains(#"uid="com.example.test.66666666-6666-4666-8666-666666666666""#))
        XCTAssertFalse(provider.xml.contains("<event"), "drag payload carries clips only")
        let item = provider.pasteboardItem()
        XCTAssertTrue(item.types.contains(NSPasteboard.PasteboardType("com.apple.finalcutpro.xml.v1-10")))
        XCTAssertTrue(item.types.contains(NSPasteboard.PasteboardType("com.apple.finalcutpro.xml")))
        XCTAssertEqual(item.string(forType: .fileURL), file.absoluteString)
        provider.pasteboard(nil, item: item, provideDataForType: NSPasteboard.PasteboardType("com.apple.finalcutpro.xml.v1-10"))
        XCTAssertEqual(item.data(forType: NSPasteboard.PasteboardType("com.apple.finalcutpro.xml.v1-10")), Data(provider.xml.utf8))
    }

    // MARK: Receiving footage from Final Cut Pro

    func testBrowserClipDropBecomesTrimmedSource() throws {
        let model = makeModel()
        model.operation = .editVideo
        model.handleDrop(.fcpxml(Data(Self.browserClipXML.utf8)))
        let source = try XCTUnwrap(model.draft.source)
        XCTAssertEqual(source.origin, .finalCutBrowser)
        XCTAssertEqual(source.fileURL.path, "/Volumes/RAID/Shoot Day 1/A001.mov")
        XCTAssertEqual(try XCTUnwrap(source.inPoint), 12, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(source.selectedDuration), 6, accuracy: 0.001)
        XCTAssertEqual(model.draft.jobType, "seedance_2_0")
    }

    func testProjectDropResolvesClipUnderPlayhead() throws {
        let model = makeModel()
        model.operation = .reframe
        model.applyPreviewState(auth: .signedIn(.manual), timeline: TimelineState(sequenceName: "Spot v3", frameDuration: 0.04, playhead: 3605))
        model.handleDrop(.fcpxml(Data(Self.projectXML.utf8)))
        let source = try XCTUnwrap(model.draft.source)
        XCTAssertEqual(source.origin, .finalCutTimeline)
        XCTAssertEqual(source.name, "B-Roll")
        XCTAssertEqual(source.inPoint, 2)
        XCTAssertEqual(source.outPoint, 5)
    }

    func testSourceKindSwitchesJobType() throws {
        let model = makeModel()
        model.operation = .removeBackground
        model.setSource(SourceClip(name: "Still", fileURL: tempRoot.appendingPathComponent("s.png"), kind: .image, origin: .file))
        XCTAssertEqual(model.draft.jobType, "image_background_remover")
        model.setSource(SourceClip(name: "Clip", fileURL: tempRoot.appendingPathComponent("c.mov"), kind: .video, origin: .file,
                                   info: MediaInfo(kind: .video, duration: 4)))
        XCTAssertEqual(model.draft.jobType, "video_background_remover")
    }

    func testValidationGuidesTheUser() {
        let model = makeModel()
        model.operation = .editVideo
        model.setSource(nil)
        XCTAssertEqual(model.validationMessage, "Add a video clip: drag it from the Final Cut Pro browser, or drop a file.")
        XCTAssertFalse(model.canSubmit)
    }

    func testTimecodeFormatting() {
        let state = TimelineState(frameDuration: 0.04, playhead: 3605.5)
        XCTAssertEqual(state.timecode(state.playhead), "01:00:05:12")
        XCTAssertEqual(state.timecode(nil), "—")
    }

    func testStandaloneHostReportsNoTimeline() {
        let host = StandaloneHost()
        XCTAssertFalse(host.isConnected)
        XCTAssertEqual(host.currentState(), .empty)
    }

    func testProExtensionHostBridgeOutsideFinalCutIsUnavailable() {
        // Without Final Cut Pro (and the SDK) the bridge must degrade, not crash.
        let bridge = ProExtensionHostBridge()
        XCTAssertFalse(bridge.isConnected)
        XCTAssertEqual(bridge.currentState(), .empty)
    }

    // MARK: Snapshots

    /// Renders each screen offscreen. With PANEL_SNAPSHOTS=<dir> the PNGs are
    /// written there (CI uploads them as an artifact for visual review).
    func testRenderPanelSnapshots() throws {
        let still = tempRoot.appendingPathComponent("frame.png")
        try XCTUnwrap(Self.gradientImage(width: 640, height: 360).flatMap(FrameGrabber.pngData)).write(to: still)

        let timeline = TimelineState(sequenceName: "Spot v3", projectName: "Spot v3", libraryName: "Client Spots",
                                     frameDuration: 0.04, playhead: 3605.48, range: 3604...3610)
        var done = JobRecord(operation: .generateImage, jobType: "nano_banana_2", modelName: "Nano Banana 2", output: .image,
                             prompt: "Neon-lit alley at night, rain, cinematic", phase: .completed, estimatedCredits: 2)
        done.remoteID = "a1b2c3d4-0000-4000-8000-000000000000"
        done.localFile = still
        var running = JobRecord(operation: .reframe, jobType: "reframe", modelName: "Reframe", output: .video,
                                sourceName: "A001_C002", phase: .running, estimatedCredits: 123)
        running.remoteID = "b1"
        var failed = JobRecord(operation: .editVideo, jobType: "seedance_2_0", modelName: "Seedance 2.0", output: .video,
                               prompt: "turn day into a snowy night", phase: .failed)
        failed.message = "Not enough Higgsfield credits for this operation."
        let jobs = [running, done, failed]
        let account = AccountBalance(credits: 854.14, subscriptionPlanType: "plus", email: "editor@example.com")
        let clip = SourceClip(name: "A001_C002", fileURL: still, kind: .video, origin: .finalCutBrowser, inPoint: 2, outPoint: 9.5,
                              info: MediaInfo(kind: .video, duration: 20, frameRate: 23.976, width: 3840, height: 2160, hasAudio: true))
        let image = SourceClip(name: "Poster", fileURL: still, kind: .image, origin: .file, info: MediaInfo(kind: .image, width: 640, height: 360))

        let signedOut = makeModel()
        signedOut.applyPreviewState(auth: .signedOut)
        try render(PanelRootView(model: signedOut), name: "01-sign-in")

        let scenarios: [(String, OperationKind, SourceClip?, String)] = [
            ("02-generate-video", .generateVideo, nil, "Slow dolly in on a lighthouse at dusk, waves crashing, volumetric fog"),
            ("03-generate-image", .generateImage, nil, "Product shot of a matte black camera on wet stone"),
            ("04-edit-video", .editVideo, clip, "Turn day into a snowy night"),
            ("05-reframe", .reframe, clip, ""),
            ("06-remove-background", .removeBackground, clip, ""),
            ("07-upscale", .upscale, clip, ""),
            ("08-draw-to-edit", .drawToEdit, image, "Replace the circled lamp with a neon sign"),
        ]
        for (name, op, source, prompt) in scenarios {
            let model = makeModel()
            model.operation = op
            model.setSource(source)
            var d = model.draft
            d.prompt = prompt
            model.draft = d
            model.applyPreviewState(auth: .signedIn(.higgsfieldCLI), account: account, jobs: jobs, timeline: timeline,
                                    cost: .estimate(CostEstimate(credits: op == .reframe ? 123 : 42)))
            try render(PanelRootView(model: model), name: name)
        }
    }

    private func render<V: View>(_ view: V, name: String, size: CGSize = CGSize(width: 400, height: 860)) throws {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            window.orderOut(nil)
            throw XCTSkip("No window server available for rendering")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 5_000, "\(name) rendered nearly empty")
        if let dir = ProcessInfo.processInfo.environment["PANEL_SNAPSHOTS"] {
            let url = URL(fileURLWithPath: dir, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try png.write(to: url.appendingPathComponent("\(name).png"))
        }
    }

    // MARK: Fixtures

    static let browserClipXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE fcpxml>
    <fcpxml version="1.11">
      <resources>
        <format id="r1" name="FFVideoFormat1080p25" frameDuration="100/2500s" width="1920" height="1080"/>
        <asset id="r2" name="A001" start="0s" duration="60s" hasVideo="1" hasAudio="1" format="r1">
          <media-rep kind="original-media" src="file:///Volumes/RAID/Shoot%20Day%201/A001.mov"/>
        </asset>
      </resources>
      <asset-clip ref="r2" name="A001" start="12s" duration="6s" format="r1"/>
    </fcpxml>
    """

    static let projectXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE fcpxml>
    <fcpxml version="1.10">
      <resources>
        <format id="r1" name="FFVideoFormat1080p25" frameDuration="100/2500s" width="1920" height="1080"/>
        <asset id="r2" name="Wide" start="0s" duration="60s" hasVideo="1" format="r1"><media-rep kind="original-media" src="file:///Volumes/Media/Wide.mov"/></asset>
        <asset id="r4" name="B-Roll" start="3600s" duration="20s" hasVideo="1" format="r1"><media-rep kind="original-media" src="file:///Volumes/Media/BRoll.mov"/></asset>
      </resources>
      <event name="Edit">
        <project name="Spot v3">
          <sequence format="r1" duration="10s" tcStart="3600s">
            <spine>
              <asset-clip ref="r2" offset="3600s" name="Wide" start="10s" duration="10s">
                <asset-clip ref="r4" lane="1" offset="14s" name="B-Roll" start="3602s" duration="3s"/>
              </asset-clip>
            </spine>
          </sequence>
        </project>
      </event>
    </fcpxml>
    """

    static func gradientImage(width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: [NSColor.systemTeal.cgColor, NSColor.systemIndigo.cgColor] as CFArray, locations: [0, 1])
        else { return nil }
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        return ctx.makeImage()
    }

    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return (0, 0, 0) }
        return (Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
}
#endif
