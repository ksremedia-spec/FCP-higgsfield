import XCTest
@testable import HiggsfieldKit

final class SchemaTests: XCTestCase {
    func testSnapshotLoadsEveryCandidateJobType() {
        let catalog = ModelCatalog.snapshot
        for op in OperationKind.allCases {
            for kind in [MediaKind.video, .image, nil] as [MediaKind?] {
                for jobType in op.candidateJobTypes(sourceKind: kind) {
                    XCTAssertNotNil(catalog.option(jobType), "\(op) → \(jobType) missing from snapshot")
                }
            }
        }
    }

    func testSeedanceSchemaParameters() throws {
        let model = try XCTUnwrap(ModelCatalog.snapshot.option("seedance_2_0"))
        let schema = model.schema
        XCTAssertTrue(schema.acceptsPrompt)
        XCTAssertEqual(schema.parameters.first?.name, "aspect_ratio")
        let duration = try XCTUnwrap(schema.parameter(named: "duration"))
        XCTAssertEqual(duration.kind, .number(min: 4, max: 15, integer: false))
        XCTAssertEqual(duration.defaultValue, 5)
        XCTAssertEqual(schema.parameter(named: "resolution")?.kind, .choice(["480p", "720p", "1080p", "4k"]))
        XCTAssertEqual(schema.parameter(named: "generate_audio")?.kind, .toggle)
        XCTAssertEqual(schema.mediaRoles, ["start_image", "end_image", "image_references", "video_references", "audio_references"])
        XCTAssertNil(schema.parameter(named: "prompt"))
    }

    func testUtilityModelsHaveNoPrompt() {
        for id in ["reframe", "video_background_remover", "topaz_video", "bytedance_image_upscale"] {
            XCTAssertEqual(ModelCatalog.snapshot.option(id)?.schema.acceptsPrompt, false, id)
        }
    }

    func testRolesFromOneOfConstSchema() {
        // Shape of the official MCP `reframe` tool schema.
        let schema = json(#"""
        {"type":"object","properties":{
          "aspect_ratio":{"type":"string","enum":["16:9","9:16","4:3","3:4","1:1","21:9"]},
          "duration_seconds":{"type":"number","exclusiveMinimum":0,"maximum":60},
          "resolution":{"type":"string","enum":["480p","720p","1080p"]},
          "medias":{"type":"array","maxItems":4,"items":{"oneOf":[
             {"type":"object","properties":{"role":{"const":"video"},"value":{"type":"string"}},"required":["value","role"]},
             {"type":"object","properties":{"role":{"enum":["start_image","image"]},"value":{"type":"string"}}}]}}}}
        """#)
        let parsed = ParameterSchema(jsonSchema: schema)
        XCTAssertEqual(parsed.mediaRoles, ["video", "start_image", "image"])
        XCTAssertFalse(parsed.acceptsPrompt)
        XCTAssertTrue(parsed.propertyNames.contains("duration_seconds"))
        XCTAssertNil(parsed.parameter(named: "duration_seconds"), "auto-filled parameters are hidden")
        XCTAssertEqual(parsed.parameter(named: "aspect_ratio")?.kind, .choice(["16:9", "9:16", "4:3", "3:4", "1:1", "21:9"]))
    }

    func testRefsAnyOfAndNullable() {
        let schema = json(#"""
        {"$defs":{"Res":{"type":"string","enum":["720p","1080p"]}},
         "type":"object","required":["resolution"],
         "properties":{
           "resolution":{"$ref":"#/$defs/Res"},
           "duration":{"anyOf":[{"type":"integer","minimum":3,"maximum":10},{"type":"null"}],"default":null},
           "sound":{"anyOf":[{"const":"on"},{"const":"off"}]},
           "folder_id":{"type":"string"}}}
        """#)
        let p = ParameterSchema(jsonSchema: schema)
        XCTAssertEqual(p.parameter(named: "resolution")?.kind, .choice(["720p", "1080p"]))
        XCTAssertEqual(p.parameter(named: "resolution")?.isRequired, true)
        XCTAssertEqual(p.parameter(named: "duration")?.kind, .number(min: 3, max: 10, integer: true))
        XCTAssertEqual(p.parameter(named: "sound")?.kind, .choice(["on", "off"]))
        XCTAssertNil(p.parameter(named: "folder_id"))
    }

    func testParameterValidation() {
        let d = ParameterSpec(name: "duration", kind: .number(min: 4, max: 15, integer: true))
        XCTAssertEqual(try d.validate(7.4).get(), 7)
        XCTAssertThrowsError(try d.validate(20).get())
        let c = ParameterSpec(name: "duration", kind: .choice([4, 6, 8]))
        XCTAssertEqual(try c.validate("6").get(), 6)
        XCTAssertThrowsError(try c.validate(5).get())
        XCTAssertEqual(ParameterSpec(name: "generate_audio", kind: .toggle).label, "Generate audio")
        XCTAssertEqual(ParameterSpec(name: "aspect_ratio", kind: .text).label, "Aspect ratio")
    }

    func testMediaSlotRoleResolution() {
        XCTAssertEqual(MediaSlot.sourceVideo.role(available: ["video", "start_image", "image"]), "video")
        XCTAssertEqual(MediaSlot.sourceVideo.role(available: ["video_references"]), "video_references")
        XCTAssertEqual(MediaSlot.sketch.role(available: ["video", "sketch", "image_references"]), "sketch")
        XCTAssertEqual(MediaSlot.sketch.role(available: ["video", "image_references", "ref_image"]), "ref_image")
        XCTAssertEqual(MediaSlot.mask.role(available: ["image_references", "mask"]), "mask")
        XCTAssertNil(MediaSlot.mask.role(available: ["image_references"]))
        XCTAssertEqual(MediaSlot.sourceVideo.role(available: []), "video", "falls back to the first candidate without a schema")
    }

    func testLiveSchemaReplacesSnapshot() {
        var catalog = ModelCatalog.snapshot
        XCTAssertEqual(catalog.option("draw_to_video")?.isLive, false)
        catalog.merge(live: JobTypeInfo(jobType: "draw_to_video", name: "Draw To Video", outputType: .video, jsonSchema: json(#"""
        {"type":"object","properties":{"prompt":{"type":"string"},"medias":{"type":"array","items":{"type":"object","properties":{"role":{"enum":["video","sketch"]}}}}}}
        """#)))
        XCTAssertEqual(catalog.option("draw_to_video")?.isLive, true)
        XCTAssertEqual(catalog.option("draw_to_video")?.schema.mediaRoles, ["video", "sketch"])
    }
}

final class RequestBuilderTests: XCTestCase {
    func video(_ duration: Double, inPoint: Double? = nil, outPoint: Double? = nil, width: Int = 1920, height: Int = 1080) -> SourceClip {
        SourceClip(name: "A001_C002", fileURL: URL(fileURLWithPath: "/Volumes/Media/A001_C002.mov"), kind: .video, origin: .finalCutBrowser,
                   inPoint: inPoint, outPoint: outPoint,
                   info: MediaInfo(kind: .video, duration: duration, frameRate: 25, width: width, height: height, hasAudio: true))
    }

    func image() -> SourceClip {
        SourceClip(name: "Still", fileURL: URL(fileURLWithPath: "/tmp/still.png"), kind: .image, origin: .file,
                   info: MediaInfo(kind: .image, width: 1024, height: 768))
    }

    func testReframeBuildsCLIEquivalentParams() throws {
        let draft = OperationDraft(operation: .reframe, values: ["aspect_ratio": "9:16", "resolution": "720p"], source: video(7.08))
        let req = try RequestBuilder.prepare(draft, catalog: .snapshot)
        XCTAssertEqual(req.jobType, "reframe")
        XCTAssertEqual(req.output, .video)
        XCTAssertEqual(req.params, ["aspect_ratio": "9:16", "resolution": "720p", "duration": 7.1])
        XCTAssertEqual(req.media.map(\.role), ["video"])
        let ref = MediaReference.uploaded(id: "55555555-5555-4555-8555-555555555555", kind: .video)
        XCTAssertEqual(try JSONValue.object(req.submissionParams(mediaEntries: [ref.entry(role: "video")])).encodedData(),
                       try json(#"{"aspect_ratio":"9:16","duration":7.1,"medias":[{"data":{"id":"55555555-5555-4555-8555-555555555555","type":"video_input"},"role":"video"}],"resolution":"720p"}"#).encodedData())
    }

    func testReframeRequiresAspectRatioAndLimitsLength() {
        XCTAssertThrowsError(try RequestBuilder.prepare(OperationDraft(operation: .reframe, source: video(10)), catalog: .snapshot))
        XCTAssertThrowsError(try RequestBuilder.prepare(OperationDraft(operation: .reframe, values: ["aspect_ratio": "1:1"], source: video(75)), catalog: .snapshot)) { e in
            XCTAssertTrue((e as? HiggsfieldError)?.userMessage.contains("60 s") == true)
        }
        // A 75 s clip trimmed to 30 s is fine.
        XCTAssertNoThrow(try RequestBuilder.prepare(OperationDraft(operation: .reframe, values: ["aspect_ratio": "1:1"], source: video(75, inPoint: 10, outPoint: 40)), catalog: .snapshot))
    }

    func testEditVideoEnforcesModelDurationLimits() throws {
        // Seedance 2.0 accepts 4–15 s, matching the Premiere plugin's reported limits.
        let ok = try RequestBuilder.prepare(OperationDraft(operation: .editVideo, prompt: "make it snow", source: video(8.6)), catalog: .snapshot)
        XCTAssertEqual(ok.jobType, "seedance_2_0")
        XCTAssertEqual(ok.params["duration"], 8.6)
        XCTAssertEqual(ok.params["prompt"], "make it snow")
        XCTAssertEqual(ok.media.map(\.role), ["video_references"])

        XCTAssertThrowsError(try RequestBuilder.prepare(OperationDraft(operation: .editVideo, prompt: "x", source: video(22)), catalog: .snapshot)) { e in
            XCTAssertTrue((e as? HiggsfieldError)?.userMessage.contains("up to 15") == true)
        }
        XCTAssertThrowsError(try RequestBuilder.prepare(OperationDraft(operation: .editVideo, prompt: "x", source: video(2)), catalog: .snapshot))
        XCTAssertThrowsError(try RequestBuilder.prepare(OperationDraft(operation: .editVideo, prompt: "  ", source: video(6)), catalog: .snapshot))
        // In/Out selection inside a long clip.
        let trimmed = try RequestBuilder.prepare(OperationDraft(operation: .editVideo, prompt: "x", source: video(40, inPoint: 12, outPoint: 18)), catalog: .snapshot)
        XCTAssertEqual(trimmed.params["duration"], 6)
    }

    func testEditVideoWithSeedance25ForcesEditMode() throws {
        let req = try RequestBuilder.prepare(OperationDraft(operation: .editVideo, jobType: "seedance_2_5", prompt: "x", source: video(6)), catalog: .snapshot)
        XCTAssertEqual(req.params["mode"], "video_edit")
        let kling = try RequestBuilder.prepare(OperationDraft(operation: .editVideo, jobType: "kling_video_edit", prompt: "x", source: video(20)), catalog: .snapshot)
        XCTAssertNil(kling.params["duration"], "Kling Omni Edit has no duration parameter")
        XCTAssertEqual(kling.media.map(\.role), ["video_references"])
    }

    func testDrawToEditVideoUsesSketchRole() throws {
        let sketch = URL(fileURLWithPath: "/tmp/sketch.png")
        XCTAssertThrowsError(try RequestBuilder.prepare(OperationDraft(operation: .drawToEdit, prompt: "make the jacket red", source: video(5)), catalog: .snapshot))
        let req = try RequestBuilder.prepare(OperationDraft(operation: .drawToEdit, prompt: "make the jacket red", source: video(5), sketchFile: sketch), catalog: .snapshot)
        XCTAssertEqual(req.jobType, "draw_to_video")
        XCTAssertEqual(req.params["duration"], 5)
        // Snapshot roles are video/image_references/ref_image, so the sketch maps to ref_image;
        // a live schema exposing `sketch` (as the CLI example implies) maps to `sketch`.
        XCTAssertEqual(req.media.map(\.role), ["video", "ref_image"])
        XCTAssertEqual(req.media.last?.payload, .file(sketch, .image))
    }

    func testDrawToEditImageUsesMaskInpainting() throws {
        let mask = URL(fileURLWithPath: "/tmp/mask.png")
        let req = try RequestBuilder.prepare(OperationDraft(operation: .drawToEdit, prompt: "replace with a lamp", source: image(), maskFile: mask), catalog: .snapshot)
        XCTAssertEqual(req.jobType, "nano_banana_2")
        XCTAssertEqual(req.output, .image)
        XCTAssertEqual(req.params["is_inpaint"], true)
        XCTAssertEqual(req.media.map(\.role), ["image_references", "mask"])
    }

    func testRemoveBackgroundPicksRemoverBySourceKind() throws {
        let v = try RequestBuilder.prepare(OperationDraft(operation: .removeBackground, source: video(4)), catalog: .snapshot)
        XCTAssertEqual(v.jobType, "video_background_remover")
        XCTAssertEqual(v.media.map(\.role), ["video_references"])
        XCTAssertEqual(v.params, [:])
        let i = try RequestBuilder.prepare(OperationDraft(operation: .removeBackground, source: image()), catalog: .snapshot)
        XCTAssertEqual(i.jobType, "image_background_remover")
        XCTAssertEqual(i.output, .image)
    }

    func testUpscaleFillsSourceDimensionsOnlyWhenSchemaAsks() throws {
        let topaz = try RequestBuilder.prepare(OperationDraft(operation: .upscale, values: ["resolution": "2160p"], source: video(4)), catalog: .snapshot)
        XCTAssertEqual(topaz.jobType, "topaz_video")
        XCTAssertEqual(topaz.params, ["resolution": "2160p"])

        var catalog = ModelCatalog.snapshot
        catalog.merge(live: JobTypeInfo(jobType: "bytedance_video_upscale", outputType: .video, jsonSchema: json(#"""
        {"type":"object","properties":{"width":{"type":"integer"},"height":{"type":"integer"},"resolution":{"enum":["1080p","2k","4k"]},"medias":{"type":"array","items":{"properties":{"role":{"enum":["video_references"]}}}}}}
        """#)))
        let bd = try RequestBuilder.prepare(OperationDraft(operation: .upscale, jobType: "bytedance_video_upscale", values: ["resolution": "4k"], source: video(4, width: 1280, height: 720)), catalog: catalog)
        XCTAssertEqual(bd.params, ["resolution": "4k", "width": 1280, "height": 720])
    }

    func testGenerateVideoWithStartFrame() throws {
        XCTAssertThrowsError(try RequestBuilder.prepare(OperationDraft(operation: .generateVideo), catalog: .snapshot))
        let req = try RequestBuilder.prepare(OperationDraft(operation: .generateVideo, prompt: "slow push in", values: ["duration": 8, "aspect_ratio": "16:9"], source: image()), catalog: .snapshot)
        XCTAssertEqual(req.jobType, "seedance_2_0")
        XCTAssertEqual(req.params, ["prompt": "slow push in", "duration": 8, "aspect_ratio": "16:9"])
        XCTAssertEqual(req.media.map(\.role), ["start_image"])
        XCTAssertEqual(req.costParams["medias"], [])
        XCTAssertThrowsError(try RequestBuilder.prepare(OperationDraft(operation: .generateVideo, prompt: "x", source: video(3)), catalog: .snapshot))
    }

    func testInvalidParameterValueIsRejected() {
        XCTAssertThrowsError(try RequestBuilder.prepare(OperationDraft(operation: .generateVideo, jobType: "veo3_1", prompt: "x", values: ["duration": 5]), catalog: .snapshot)) { e in
            XCTAssertTrue((e as? HiggsfieldError)?.userMessage.contains("4, 6, 8") == true)
        }
    }

    func testGenerateImageReferencesShareRole() throws {
        let draft = OperationDraft(operation: .generateImage, prompt: "poster", source: image(), referenceImages: [image(), image()])
        let req = try RequestBuilder.prepare(draft, catalog: .snapshot)
        XCTAssertEqual(req.media.map(\.role), ["image_references", "image_references", "image_references"])
    }

    func testMissingSourceMessage() {
        XCTAssertThrowsError(try RequestBuilder.prepare(OperationDraft(operation: .upscale), catalog: .snapshot)) { e in
            XCTAssertTrue((e as? HiggsfieldError)?.userMessage.contains("Final Cut Pro browser") == true)
        }
    }
}

final class JobRunnerTests: XCTestCase {
    func testEndToEndUploadSubmitPollDownload() async throws {
        let t = MockTransport()
        t.on("POST", "/media?type=video", json: #"{"id":"m-1","upload_url":"https://uploads.example.com/p1"}"#)
        t.on("PUT", "uploads.example.com", json: "")
        t.on("POST", "/media/m-1/confirm", json: #"{"id":"m-1","status":"uploaded"}"#)
        t.on("POST", "/videos/reframe/generations", json: #"{"id":"job-1"}"#)
        t.on("GET", "/jobs/job-1", responses: [
            (200, #"{"id":"job-1","status":"queued"}"#),
            (200, #"{"id":"job-1","status":"in_progress"}"#),
            (200, #"{"id":"job-1","status":"completed","result_url":"https://cdn.example.com/r/out.mp4","min_result_url":"https://cdn.example.com/r/out.jpg"}"#),
        ])
        t.on("GET", "cdn.example.com/r/out.mp4", json: "")

        let file = try temporaryFile(named: "A001.mov")
        let root = file.deletingLastPathComponent().appendingPathComponent("out")
        let store = JobStore(url: root.appendingPathComponent("jobs.json"))
        let runner = JobRunner(client: makeClient(t), store: store, transport: t, output: OutputLocation(root: root), sleeper: { _ in })

        let source = SourceClip(name: "A001", fileURL: file, kind: .video, origin: .file, info: MediaInfo(kind: .video, duration: 6))
        let req = try RequestBuilder.prepare(OperationDraft(operation: .reframe, values: ["aspect_ratio": "9:16"], source: source), catalog: .snapshot)
        let started = await runner.start(req, prompt: nil, sourceName: "A001", estimatedCredits: 70)
        XCTAssertEqual(started.remoteID, "job-1")

        let done = try await waitFor(store, id: started.id) { $0.phase == .completed }
        XCTAssertEqual(done.localFile?.lastPathComponent, "A001 – Reframe job-1.mp4")
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(done.localFile)), "FAKE-MEDIA")
        XCTAssertEqual(done.previewURL?.absoluteString, "https://cdn.example.com/r/out.jpg")
        XCTAssertEqual(done.remoteReference, MediaReference(id: "job-1", source: .videoJob))
        XCTAssertEqual(done.estimatedCredits, 70)

        let submit = try XCTUnwrap(t.requests("POST", "/generations").first)
        XCTAssertEqual(submit.bodyJSON, json(#"{"params":{"aspect_ratio":"9:16","duration":6,"medias":[{"data":{"id":"m-1","type":"video_input"},"role":"video"}]}}"#))
    }

    func testChainedResultIsReferencedWithoutReupload() async throws {
        let t = MockTransport()
        t.on("POST", "/videos/topaz_video/generations", json: #"{"id":"job-2"}"#)
        t.on("GET", "/jobs/job-2", json: #"{"id":"job-2","status":"failed","error":"Provider timeout"}"#)
        let dir = try temporaryFile(named: "x").deletingLastPathComponent()
        let store = JobStore(url: dir.appendingPathComponent("jobs.json"))
        let runner = JobRunner(client: makeClient(t), store: store, transport: t, output: OutputLocation(root: dir), sleeper: { _ in })
        let previous = SourceClip(name: "Gen", fileURL: dir.appendingPathComponent("gen.mp4"), kind: .video, origin: .higgsfieldResult,
                                  info: MediaInfo(kind: .video, duration: 5), remoteReference: .jobOutput(id: "job-1", kind: .video))
        let req = try RequestBuilder.prepare(OperationDraft(operation: .upscale, source: previous), catalog: .snapshot)
        let started = await runner.start(req, prompt: nil, sourceName: "Gen", estimatedCredits: nil)
        let failed = try await waitFor(store, id: started.id) { $0.phase == .failed }
        XCTAssertEqual(failed.message, "Provider timeout")
        XCTAssertTrue(t.requests("POST", "/media").isEmpty)
        XCTAssertEqual(t.requests("POST", "/generations").first?.bodyJSON,
                       json(#"{"params":{"medias":[{"data":{"id":"job-1","type":"video_job"},"role":"video_references"}]}}"#))
    }

    func testSubmissionFailureIsRecorded() async throws {
        let t = MockTransport()
        t.on("POST", "/videos/video_background_remover/generations", status: 402, json: #"{"detail":"Not enough credits"}"#)
        let dir = try temporaryFile(named: "x").deletingLastPathComponent()
        let store = JobStore(url: dir.appendingPathComponent("jobs.json"))
        let runner = JobRunner(client: makeClient(t), store: store, transport: t, output: OutputLocation(root: dir), sleeper: { _ in })
        let src = SourceClip(name: "C", fileURL: dir.appendingPathComponent("c.mp4"), kind: .video, origin: .higgsfieldResult,
                             info: MediaInfo(kind: .video, duration: 4), remoteReference: .jobOutput(id: "j0", kind: .video))
        let req = try RequestBuilder.prepare(OperationDraft(operation: .removeBackground, source: src), catalog: .snapshot)
        let record = await runner.start(req, prompt: nil, sourceName: "C", estimatedCredits: nil)
        XCTAssertEqual(record.phase, .failed)
        XCTAssertTrue(record.message?.contains("Not enough Higgsfield credits") == true)
        let persisted = await store.all()
        XCTAssertEqual(persisted.first?.phase, .failed)
    }

    func testResumeMarksUnsubmittedJobsFailedAndPersistsAcrossInstances() async throws {
        let dir = try temporaryFile(named: "x").deletingLastPathComponent()
        let url = dir.appendingPathComponent("jobs.json")
        let first = JobStore(url: url)
        await first.upsert(JobRecord(operation: .upscale, jobType: "topaz_video", modelName: "Topaz", output: .video, phase: .preparing))
        let second = JobStore(url: url)
        let runner = JobRunner(client: makeClient(MockTransport()), store: second, transport: MockTransport(), output: OutputLocation(root: dir), sleeper: { _ in })
        await runner.resumeActiveJobs()
        let all = await second.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.phase, .failed)
    }

    func testLaterResumeLeavesInFlightUploadsAlone() async throws {
        let dir = try temporaryFile(named: "x").deletingLastPathComponent()
        let store = JobStore(url: dir.appendingPathComponent("jobs.json"))
        let uploading = JobRecord(operation: .reframe, jobType: "reframe", modelName: "Reframe", output: .video, phase: .preparing)
        await store.upsert(uploading)
        let runner = JobRunner(client: makeClient(MockTransport()), store: store, transport: MockTransport(), output: OutputLocation(root: dir), sleeper: { _ in })
        await runner.resumeActiveJobs(markInterrupted: false)
        let phase = await store.record(id: uploading.id)?.phase
        XCTAssertEqual(phase, .preparing, "a reconnect must not fail an upload that is still running")
    }

    func testStopAllHaltsPolling() async throws {
        let t = MockTransport()
        t.on("GET", "/jobs/job-9", json: #"{"id":"job-9","status":"in_progress"}"#)
        let dir = try temporaryFile(named: "x").deletingLastPathComponent()
        let store = JobStore(url: dir.appendingPathComponent("jobs.json"))
        var record = JobRecord(operation: .upscale, jobType: "topaz_video", modelName: "Topaz", output: .video, phase: .queued)
        record.remoteID = "job-9"
        await store.upsert(record)
        let runner = JobRunner(client: makeClient(t), store: store, transport: t, output: OutputLocation(root: dir),
                               sleeper: { _ in try? await Task.sleep(nanoseconds: 5_000_000) })
        await runner.resumeActiveJobs()
        try await Task.sleep(nanoseconds: 60_000_000)
        await runner.stopAll()
        try await Task.sleep(nanoseconds: 20_000_000)
        let countAfterStop = t.requests("GET", "/jobs/job-9").count
        XCTAssertGreaterThan(countAfterStop, 0)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(t.requests("GET", "/jobs/job-9").count, countAfterStop, "no polling after stopAll")
    }

    private func waitFor(_ store: JobStore, id: UUID, timeout: TimeInterval = 5, _ predicate: (JobRecord) -> Bool) async throws -> JobRecord {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let r = await store.record(id: id), predicate(r) { return r }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let last = await store.record(id: id)
        XCTFail("timed out; last phase \(String(describing: last?.phase)) message \(last?.message ?? "")")
        throw HiggsfieldError.network("timeout")
    }
}

final class TimeTests: XCTestCase {
    func testParseAndFormat() {
        XCTAssertEqual(RationalTime(fcpxml: "1001/30000s"), RationalTime(value: 1001, timescale: 30000))
        XCTAssertEqual(RationalTime(fcpxml: "5s")?.seconds, 5)
        XCTAssertEqual(RationalTime(fcpxml: "3600/2400s")?.fcpxmlString, "3/2s")
        XCTAssertEqual(RationalTime(fcpxml: "2.5s")?.seconds, 2.5)
        XCTAssertNil(RationalTime(fcpxml: "abc"))
        XCTAssertNil(RationalTime(fcpxml: "5"))
        XCTAssertEqual((RationalTime(value: 1, timescale: 2) + RationalTime(value: 1, timescale: 3)).fcpxmlString, "5/6s")
        XCTAssertTrue(RationalTime(value: 1, timescale: 3) < RationalTime(value: 1, timescale: 2))
    }

    func testFrameDurationsAndConforming() {
        XCTAssertEqual(RationalTime.frameDuration(forFrameRate: 29.97), RationalTime(value: 1001, timescale: 30000))
        XCTAssertEqual(RationalTime.frameDuration(forFrameRate: 23.976), RationalTime(value: 1001, timescale: 24000))
        XCTAssertEqual(RationalTime.frameDuration(forFrameRate: 25), RationalTime(value: 1, timescale: 25))
        let frame = RationalTime.frameDuration(forFrameRate: 24)
        let conformed = RationalTime(seconds: 5.03).conformed(toFrameDuration: frame)
        XCTAssertEqual(conformed, RationalTime(value: 120, timescale: 24))
        XCTAssertEqual(formatDuration(65.25), "1:05.2")
    }
}
