import XCTest
@testable import HiggsfieldKit

/// Each expected body is what the official Higgsfield CLI 1.2.2 built on
/// 2026-10-26 from the live `GET /job_types/{id}` schemas (bundled in the
/// snapshot), recorded by a local proxy that answered every request itself,
/// so nothing reached Higgsfield (docs/VALIDATION.md, "CLI request
/// recordings"). Media is sent as top-level properties, not `params.medias`.
///
/// The panel's request for the same inputs must match, except for keys the
/// panel adds that the CLI command didn't pass (listed per case).
final class LiveLayoutContractTests: XCTestCase {
    let V = "11111111-1111-4111-8111-111111111111"  // uploaded video
    let I = "22222222-2222-4222-8222-222222222222"  // uploaded image
    let M = "33333333-3333-4333-8333-333333333333"  // uploaded mask

    func video(_ duration: Double) -> SourceClip {
        SourceClip(name: "clip", fileURL: URL(fileURLWithPath: "/tmp/clip.mov"), kind: .video, origin: .file,
                   info: MediaInfo(kind: .video, duration: duration, frameRate: 25, width: 1280, height: 720, hasAudio: false))
    }

    func image() -> SourceClip {
        SourceClip(name: "still", fileURL: URL(fileURLWithPath: "/tmp/still.png"), kind: .image, origin: .file,
                   info: MediaInfo(kind: .image, width: 1024, height: 768))
    }

    /// Builds the panel's submission body with fixed ids standing in for uploads.
    func body(_ draft: OperationDraft, dropping extra: Set<String> = []) throws -> JSONValue {
        let req = try RequestBuilder.prepare(draft, catalog: .snapshot)
        let refs: [MediaReference] = req.media.map { item in
            switch item.slot {
            case .mask: return MediaReference(id: M, source: .uploadedImage)
            case .sketch: return MediaReference(id: I, source: .uploadedImage)
            default: return .uploaded(id: item.kind == .video ? V : I, kind: item.kind)
            }
        }
        var params = req.submissionParams(references: refs)
        for key in extra { params[key] = nil }
        return ["params": .object(params)]
    }

    func testReframe() throws {
        let b = try body(OperationDraft(operation: .reframe, values: ["aspect_ratio": "9:16"], source: video(7)), dropping: ["duration"])
        XCTAssertEqual(b, json(#"{"params":{"aspect_ratio":"9:16","video_references":[{"id":"11111111-1111-4111-8111-111111111111","type":"video_input"}]}}"#))
    }

    func testDrawToVideoSketchGoesToImageReferences() throws {
        let b = try body(OperationDraft(operation: .drawToEdit, prompt: "make the jacket red", values: ["resolution": "720p"],
                                        source: video(5), sketchFile: URL(fileURLWithPath: "/tmp/sketch.png")))
        XCTAssertEqual(b, json(#"{"params":{"duration":5,"image_references":[{"id":"22222222-2222-4222-8222-222222222222","type":"media_input"}],"prompt":"make the jacket red","resolution":"720p","video":{"id":"11111111-1111-4111-8111-111111111111","type":"video_input"}}}"#))
    }

    func testDrawToEditStillUsesNanoBanana2MaskInpainting() throws {
        let draft = OperationDraft(operation: .drawToEdit, prompt: "make it red", source: image(), maskFile: URL(fileURLWithPath: "/tmp/mask.png"))
        XCTAssertEqual(try RequestBuilder.prepare(draft, catalog: .snapshot).jobType, "nano_banana_flash")
        XCTAssertEqual(try body(draft), json(#"{"params":{"image_references":[{"id":"22222222-2222-4222-8222-222222222222","type":"media_input"}],"is_inpaint":true,"mask":{"id":"33333333-3333-4333-8333-333333333333","type":"media_input"},"prompt":"make it red"}}"#))
    }

    func testEditVideoModels() throws {
        let expected = json(#"{"params":{"prompt":"make it snow","video_references":[{"id":"11111111-1111-4111-8111-111111111111","type":"video_input"}]}}"#)
        XCTAssertEqual(try body(OperationDraft(operation: .editVideo, jobType: "seedance_2_0", prompt: "make it snow", source: video(6)), dropping: ["duration"]), expected)
        XCTAssertEqual(try body(OperationDraft(operation: .editVideo, jobType: "kling_video_edit", prompt: "make it snow", source: video(6))), expected)
        XCTAssertEqual(try body(OperationDraft(operation: .editVideo, jobType: "flux_3_video_edit", prompt: "make it snow", source: video(6))), expected)
        XCTAssertEqual(try body(OperationDraft(operation: .editVideo, jobType: "seedance_2_5", prompt: "make it snow", source: video(6)), dropping: ["duration"]),
                       json(#"{"params":{"mode":"video_edit","prompt":"make it snow","video_references":[{"id":"11111111-1111-4111-8111-111111111111","type":"video_input"}]}}"#))
    }

    func testRemoveBackgroundAndUpscale() throws {
        let videoOnly = json(#"{"params":{"video_references":[{"id":"11111111-1111-4111-8111-111111111111","type":"video_input"}]}}"#)
        let imageOnly = json(#"{"params":{"image_references":[{"id":"22222222-2222-4222-8222-222222222222","type":"media_input"}]}}"#)
        XCTAssertEqual(try body(OperationDraft(operation: .removeBackground, source: video(5))), videoOnly)
        XCTAssertEqual(try body(OperationDraft(operation: .removeBackground, source: image())), imageOnly)
        XCTAssertEqual(try body(OperationDraft(operation: .upscale, jobType: "topaz_video", source: video(5))), videoOnly)
        XCTAssertEqual(try body(OperationDraft(operation: .upscale, jobType: "bytedance_video_upscale", source: video(5))), videoOnly)
        XCTAssertEqual(try body(OperationDraft(operation: .upscale, source: image())), imageOnly)
    }

    func testGenerateVideoStartFrame() throws {
        XCTAssertEqual(try body(OperationDraft(operation: .generateVideo, jobType: "seedance_2_0", prompt: "slow dolly in", source: image())),
                       json(#"{"params":{"prompt":"slow dolly in","start_image":{"id":"22222222-2222-4222-8222-222222222222","type":"media_input"}}}"#))
        XCTAssertEqual(try body(OperationDraft(operation: .generateVideo, jobType: "kling3_0", prompt: "slow dolly in", source: image())),
                       json(#"{"params":{"prompt":"slow dolly in","start_image":{"id":"22222222-2222-4222-8222-222222222222","type":"media_input"}}}"#))
    }

    func testChainedEarlierResultUsesJobType() throws {
        // CLI: `--video-references <id of a finished video job>` → type "video_job".
        let previous = SourceClip(name: "Gen", fileURL: URL(fileURLWithPath: "/tmp/gen.mp4"), kind: .video, origin: .higgsfieldResult,
                                  info: MediaInfo(kind: .video, duration: 5), remoteReference: .jobOutput(id: V, kind: .video))
        let req = try RequestBuilder.prepare(OperationDraft(operation: .reframe, values: ["aspect_ratio": "9:16"], source: previous), catalog: .snapshot)
        var params = req.submissionParams(references: [try XCTUnwrap(previous.remoteReference)])
        params["duration"] = nil
        XCTAssertEqual(JSONValue.object(params), json(#"{"aspect_ratio":"9:16","video_references":[{"id":"11111111-1111-4111-8111-111111111111","type":"video_job"}]}"#))
    }

    func testDrawToVideoReferenceImageGoesToRefImageNotTheSketchSlot() throws {
        let req = try RequestBuilder.prepare(OperationDraft(operation: .drawToEdit, prompt: "x", source: video(5), referenceImages: [image()],
                                                            sketchFile: URL(fileURLWithPath: "/tmp/sketch.png")), catalog: .snapshot)
        XCTAssertEqual(req.media.map(\.role), ["video", "image_references", "ref_image"])
    }

    func testLiveDrawToVideoSchemaParsing() throws {
        let schema = try XCTUnwrap(ModelCatalog.snapshot.option("draw_to_video")).schema
        XCTAssertEqual(schema.mediaFields.sorted { $0.name < $1.name },
                       [MediaField(name: "image_references", isArray: true), MediaField(name: "ref_image", isArray: false), MediaField(name: "video", isArray: false)])
        XCTAssertTrue(schema.acceptsMedias)
        XCTAssertNil(schema.parameter(named: "ref_image"))
        XCTAssertEqual(schema.parameter(named: "resolution")?.defaultValue, "720p")
    }

    func testLegacyMediasLayoutStillSupported() throws {
        var catalog = ModelCatalog.snapshot
        catalog.merge(live: JobTypeInfo(jobType: "reframe", outputType: .video, jsonSchema: json(#"""
        {"type":"object","properties":{"aspect_ratio":{"enum":["9:16"]},"medias":{"type":"array","items":{"properties":{"role":{"enum":["video"]}}}}}}
        """#)))
        let req = try RequestBuilder.prepare(OperationDraft(operation: .reframe, values: ["aspect_ratio": "9:16"], source: video(6)), catalog: catalog)
        XCTAssertEqual(req.costParams["medias"], [])
        XCTAssertEqual(JSONValue.object(req.submissionParams(references: [.uploaded(id: V, kind: .video)])),
                       json(#"{"aspect_ratio":"9:16","medias":[{"data":{"id":"11111111-1111-4111-8111-111111111111","type":"video_input"},"role":"video"}]}"#))
    }

    func testCatalogHasNoStaleModelIDs() {
        // Checked against the live catalog on 2026-10-26.
        for op in OperationKind.allCases {
            for kind in [MediaKind.video, .image, nil] as [MediaKind?] {
                for jobType in op.candidateJobTypes(sourceKind: kind) {
                    XCTAssertFalse(["nano_banana_2", "soul_2"].contains(jobType), "\(op) still offers \(jobType)")
                }
            }
        }
    }
}

final class CostParamsTests: XCTestCase {
    func clip(_ d: Double) -> SourceClip {
        SourceClip(name: "c", fileURL: URL(fileURLWithPath: "/tmp/c.mov"), kind: .video, origin: .file, info: MediaInfo(kind: .video, duration: d))
    }

    func testCostIncludesSourceLengthWhenTheJobHasNoDurationParameter() throws {
        // Live 2026-10-26: kling_video_edit's cost requires duration (6 s → 12 credits, 12 s → 24).
        let kling = try RequestBuilder.prepare(OperationDraft(operation: .editVideo, jobType: "kling_video_edit", prompt: "x", source: clip(6)), catalog: .snapshot)
        XCTAssertNil(kling.params["duration"], "not a generation parameter")
        XCTAssertEqual(kling.costParams["duration"], 6)
        let upscale = try RequestBuilder.prepare(OperationDraft(operation: .upscale, jobType: "bytedance_video_upscale", source: clip(10)), catalog: .snapshot)
        XCTAssertEqual(upscale.costParams["duration"], 10)
        // A model's own duration value is left alone.
        let seedance = try RequestBuilder.prepare(OperationDraft(operation: .editVideo, prompt: "x", source: clip(8.6)), catalog: .snapshot)
        XCTAssertEqual(seedance.costParams["duration"], 9)
    }
}
