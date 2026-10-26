import XCTest
@testable import HiggsfieldKit

/// Each expectation here is a request the official Higgsfield CLI 1.2.2 sent
/// through a capture proxy (docs/API-CONTRACT.md). The Swift client must
/// produce the same method, path, query, headers and JSON body.
final class ClientContractTests: XCTestCase {
    let base = "https://fnf-api-gw.higgsfield.ai/fnf/developer/v2alpha"
    let workspace = "11111111-1111-4111-8111-111111111111"

    func testReframeSubmissionMatchesCLICapture() async throws {
        let t = MockTransport()
        t.on("POST", "/videos/reframe/generations", json: #"{"id":"66666666-6666-4666-8666-666666666666"}"#)
        let client = makeClient(t)
        let media = MediaReference.uploaded(id: "55555555-5555-4555-8555-555555555555", kind: .video)
        let id = try await client.submit(jobType: "reframe", output: .video,
                                         params: ["aspect_ratio": "9:16", "medias": [media.entry(role: "video")]])
        XCTAssertEqual(id, "66666666-6666-4666-8666-666666666666")

        let r = try XCTUnwrap(t.requests.first)
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.url.absoluteString, "\(base)/videos/reframe/generations")
        XCTAssertEqual(r.headers["authorization"], "Bearer TOKEN")
        XCTAssertEqual(r.headers["hf-workspace-id"], workspace)
        // Captured CLI body:
        XCTAssertEqual(r.bodyJSON, json(#"{"params":{"aspect_ratio":"9:16","medias":[{"data":{"id":"55555555-5555-4555-8555-555555555555","type":"video_input"},"role":"video"}]}}"#))
    }

    func testImageGenerationWithUploadedImageMatchesCLICapture() async throws {
        let t = MockTransport()
        t.on("POST", "/images/nano_banana_2/generations", json: #"{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}"#)
        let client = makeClient(t)
        let media = MediaReference.uploaded(id: "88888888-8888-4888-8888-888888888888", kind: .image)
        _ = try await client.submit(jobType: "nano_banana_2", output: .image,
                                    params: ["aspect_ratio": "16:9", "prompt": "add a hat", "medias": [media.entry(role: "image")]])
        let r = try XCTUnwrap(t.requests.first)
        XCTAssertEqual(r.url.absoluteString, "\(base)/images/nano_banana_2/generations")
        XCTAssertEqual(r.bodyJSON, json(#"{"params":{"aspect_ratio":"16:9","medias":[{"data":{"id":"88888888-8888-4888-8888-888888888888","type":"media_input"},"role":"image"}],"prompt":"add a hat"}}"#))
    }

    func testVideoModelSubmissionEncodesWholeNumbersLikeCLI() async throws {
        let t = MockTransport()
        t.on("POST", "/videos/seedance_2_0/generations", json: #"{"id":"x"}"#)
        let client = makeClient(t)
        let media = MediaReference.uploaded(id: "55555555-5555-4555-8555-555555555555", kind: .video)
        _ = try await client.submit(jobType: "seedance_2_0", output: .video,
                                    params: ["aspect_ratio": "16:9", "duration": 5, "prompt": "neon city", "medias": [media.entry(role: "video")]])
        XCTAssertEqual(t.requests.first?.bodyString,
                       #"{"params":{"aspect_ratio":"16:9","duration":5,"medias":[{"data":{"id":"55555555-5555-4555-8555-555555555555","type":"video_input"},"role":"video"}],"prompt":"neon city"}}"#)
    }

    func testCostEstimateMatchesCLICapture() async throws {
        let t = MockTransport()
        t.on("POST", "/jobs/seedance_2_0/cost", json: #"{"credits":42.5,"credits_exact":42.5}"#)
        let client = makeClient(t)
        let cost = try await client.estimateCost(jobType: "seedance_2_0",
                                                 params: ["duration": 5, "medias": [], "prompt": "neon city", "resolution": "720p"])
        XCTAssertEqual(cost, CostEstimate(credits: 42.5, creditsExact: 42.5))
        let r = try XCTUnwrap(t.requests.first)
        XCTAssertEqual(r.url.absoluteString, "\(base)/jobs/seedance_2_0/cost")
        XCTAssertEqual(r.bodyJSON, json(#"{"params":{"duration":5,"medias":[],"prompt":"neon city","resolution":"720p"}}"#))
    }

    func testMediaUploadHandshakeMatchesCLICapture() async throws {
        let t = MockTransport()
        t.on("POST", "/media?type=video", json: #"{"id":"55555555-5555-4555-8555-555555555555","upload_url":"https://uploads.example.com/put/abc?sig=1"}"#)
        t.on("PUT", "uploads.example.com", json: "")
        t.on("POST", "/confirm", json: #"{"id":"55555555-5555-4555-8555-555555555555","status":"uploaded"}"#)
        let client = makeClient(t)
        let file = try temporaryFile(named: "src.mp4", contents: "fakevideo")
        let ref = try await client.uploadMedia(fileURL: file, kind: .video)
        XCTAssertEqual(ref, MediaReference(id: "55555555-5555-4555-8555-555555555555", source: .uploadedVideo))

        XCTAssertEqual(t.requests.map(\.method), ["POST", "PUT", "POST"])
        XCTAssertEqual(t.requests[0].url.absoluteString, "\(base)/media?type=video&extension=mp4")
        XCTAssertNil(t.requests[0].body)
        XCTAssertEqual(t.requests[1].url.absoluteString, "https://uploads.example.com/put/abc?sig=1")
        XCTAssertEqual(t.requests[1].uploadedFile, file)
        XCTAssertNil(t.requests[1].headers["authorization"], "Presigned PUT must not carry the bearer token")
        XCTAssertEqual(t.requests[2].url.absoluteString, "\(base)/media/55555555-5555-4555-8555-555555555555/confirm?type=video")
    }

    func testMediaUploadFailsWhenNeverUploaded() async throws {
        let t = MockTransport()
        t.on("POST", "/media?type=image", json: #"{"id":"m1","upload_url":"https://uploads.example.com/p"}"#)
        t.on("PUT", "uploads.example.com", json: "")
        t.on("POST", "/confirm", json: #"{"id":"m1","status":"processing"}"#)
        let client = makeClient(t)
        let file = try temporaryFile(named: "frame.png")
        do {
            _ = try await client.uploadMedia(fileURL: file, kind: .image)
            XCTFail("expected mediaNotReady")
        } catch let error as HiggsfieldError {
            XCTAssertEqual(error, .mediaNotReady(id: "m1", status: "processing"))
        }
        XCTAssertEqual(t.requests("POST", "/confirm").count, 3)
    }

    func testJobDecodesCLIShapeAndStatus() async throws {
        let t = MockTransport()
        t.on("GET", "/jobs/6666", json: #"{"id":"66666666-6666-4666-8666-666666666666","job_type":"reframe","display_name":"","status":"completed","created_at":"2026-10-26T03:00:00Z","params":{"prompt":"x"},"result_url":"https://cdn.example.com/out.mp4","min_result_url":"https://cdn.example.com/out.jpg"}"#)
        let client = makeClient(t)
        let job = try await client.job(id: "66666666-6666-4666-8666-666666666666")
        XCTAssertEqual(job.status, .completed)
        XCTAssertEqual(job.resultURL?.absoluteString, "https://cdn.example.com/out.mp4")
        XCTAssertEqual(job.minResultURL?.absoluteString, "https://cdn.example.com/out.jpg")
        XCTAssertEqual(t.requests.first?.url.absoluteString, "\(base)/jobs/66666666-6666-4666-8666-666666666666")
    }

    func testStatusMapping() {
        XCTAssertEqual(RemoteJobStatus(rawValue: "queued"), .queued)
        XCTAssertEqual(RemoteJobStatus(rawValue: "pending"), .queued)
        XCTAssertEqual(RemoteJobStatus(rawValue: "in_progress"), .running)
        XCTAssertEqual(RemoteJobStatus(rawValue: "processing"), .running)
        XCTAssertEqual(RemoteJobStatus(rawValue: "nsfw"), .nsfw)
        XCTAssertEqual(RemoteJobStatus(rawValue: "cancelled"), .canceled)
        XCTAssertTrue(RemoteJobStatus(rawValue: "failed").isTerminal)
        XCTAssertFalse(RemoteJobStatus(rawValue: "something_new").isTerminal)
    }

    func testAccountEndpoints() async throws {
        let t = MockTransport()
        // Shapes confirmed against the CLI's renderers and the MCP balance tool.
        t.on("GET", "/account/balance", json: #"{"credits":854.14,"subscription_plan_type":"plus","email":"x@example.com"}"#)
        t.on("GET", "/account/workspaces", json: #"{"items":[{"id":"11111111-1111-4111-8111-111111111111","name":"Personal","plan":"plus","credits":854.14}]}"#)
        let client = makeClient(t, workspace: nil)
        let balance = try await client.balance()
        XCTAssertEqual(balance, AccountBalance(credits: 854.14, subscriptionPlanType: "plus", email: "x@example.com"))
        let spaces = try await client.workspaces()
        XCTAssertEqual(spaces, [Workspace(id: workspace, name: "Personal", credits: 854.14, plan: "plus")])
        XCTAssertNil(t.requests.first?.headers["hf-workspace-id"])
    }

    func testCatalogQueriesMatchCLI() async throws {
        let t = MockTransport()
        t.on("GET", "/job_types?", json: #"{"items":[{"job_type":"reframe","name":"Reframe","type":"video","json_schema":{"type":"object","properties":{"aspect_ratio":{"enum":["16:9","9:16"]}}}}],"has_more":false}"#)
        t.on("GET", "/job_types/reframe", json: #"{"job_type":"reframe","type":"video","json_schema":{"type":"object","properties":{}}}"#)
        let client = makeClient(t)
        let models = try await client.jobTypes(outputType: .video, labels: ["model", "app"])
        XCTAssertEqual(models.first?.jobType, "reframe")
        XCTAssertEqual(models.first?.outputType, .video)
        _ = try await client.jobTypes(labels: ["chain"])
        _ = try await client.jobType("reframe")
        XCTAssertEqual(t.requests.map(\.url.absoluteString), [
            "\(base)/job_types?type=video&label=model&label=app&limit=200",
            "\(base)/job_types?label=chain&limit=200",
            "\(base)/job_types/reframe",
        ])
    }

    func testUnauthorizedTriggersSingleRefresh() async throws {
        let t = MockTransport()
        t.on("GET", "/account/balance", responses: [(401, #"{"detail":"expired"}"#), (200, #"{"credits":1}"#)])
        let tokens = CountingTokenProvider(tokens: ["OLD", "NEW"])
        let client = makeClient(t, tokens: tokens)
        let balance = try await client.balance()
        XCTAssertEqual(balance.credits, 1)
        XCTAssertEqual(tokens.calls, [false, true])
        XCTAssertEqual(t.requests.map { $0.headers["authorization"] }, ["Bearer OLD", "Bearer NEW"])
    }

    func testRepeatedUnauthorizedSurfacesError() async throws {
        let t = MockTransport()
        t.on("GET", "/account/balance", status: 401, json: #"{"detail":"Invalid token"}"#)
        let client = makeClient(t)
        do {
            _ = try await client.balance()
            XCTFail("expected unauthorized")
        } catch let error as HiggsfieldError {
            XCTAssertEqual(error, .unauthorized("Invalid token"))
        }
        XCTAssertEqual(t.requests.count, 2)
    }

    func testGetRetriesTransientErrorsButSubmissionDoesNotRetry500() async throws {
        let t = MockTransport()
        t.on("GET", "/jobs/j1", responses: [(503, "{}"), (502, "{}"), (200, #"{"id":"j1","status":"queued"}"#)])
        t.on("POST", "/videos/reframe/generations", status: 500, json: #"{"message":"boom"}"#)
        let client = makeClient(t)
        let job = try await client.job(id: "j1")
        XCTAssertEqual(job.status, .queued)
        XCTAssertEqual(t.requests("GET", "/jobs/j1").count, 3)
        do {
            _ = try await client.submit(jobType: "reframe", output: .video, params: [:])
            XCTFail("expected server error")
        } catch let error as HiggsfieldError {
            XCTAssertEqual(error, .server(status: 500, message: "boom"))
        }
        XCTAssertEqual(t.requests("POST", "/generations").count, 1, "a 500 on submission must not be retried")
    }

    func testErrorMessageExtraction() {
        XCTAssertEqual(HiggsfieldError.extractMessage(from: Data(#"{"detail":"Not enough credits"}"#.utf8)), "Not enough credits")
        XCTAssertEqual(HiggsfieldError.extractMessage(from: Data(#"{"detail":[{"loc":["body","params","duration"],"msg":"must be <= 15"}]}"#.utf8)),
                       "body.params.duration: must be <= 15")
        XCTAssertEqual(HiggsfieldError.extractMessage(from: Data("plain text".utf8)), "plain text")
        XCTAssertEqual(HiggsfieldError.from(status: 402, data: Data("{}".utf8)), .insufficientCredits("{}"))
        XCTAssertEqual(HiggsfieldError.from(status: 403, data: Data(#"{"detail":"job_minimum_pro_plan_required"}"#.utf8)),
                       .forbidden("job_minimum_pro_plan_required"))
        XCTAssertEqual(HiggsfieldError.from(status: 422, data: Data(#"{"message":"insufficient credits"}"#.utf8)),
                       .insufficientCredits("insufficient credits"))
    }
}
