# Feature parity: Higgsfield for Premiere Pro → Final Cut Pro edition

Reference: the official plugin at <https://higgsfield.ai/plugins/premiere-pro>. Premiere behaviour below first came from search-engine extracts of the official page, Higgsfield's help centre and blog, and third-party walkthroughs ([RESEARCH.md](RESEARCH.md)). On 2026-10-26 the official page, its panel screenshots and its demo video were reviewed directly; see [Panel layout vs the official plugin](#panel-layout-vs-the-official-plugin). **Nothing here is marked complete because its UI exists.**

## Status levels

| Level | Meaning |
|---|---|
| **L1 Built** | Code and UI exist and compile for macOS in CI (Xcode 16, app + extension). |
| **L2 Contract-verified** | Automated tests prove the requests match what the **official Higgsfield CLI** sends (captured through a proxy), or the FCPXML validates against **Apple's DTD 1.10**. |
| **L3 Backend-confirmed** | The Higgsfield backend feature, its job type and its parameters were confirmed **live** through the official Higgsfield MCP server (read-only calls, no credits spent). Not yet run through this app's client. |
| **L4 Live-verified** | Run end-to-end through this app's client against the live Higgsfield API. |
| **L5 Verified in FCP** | Exercised inside Final Cut Pro. |

Every tool has now run end to end through this app's client against the live API (L4, 2026-10-26, VALIDATION). Nothing has run inside Final Cut Pro yet (L5): the extension crashes on load without Apple's Workflow Extension SDK. On 2026-10-26 the read-only parts ran live through this app's client: sign-in through the CLI session, balance, catalog, every tool's schema and every tool's cost estimate. The same day showed that Higgsfield's job schemas now take media as top-level properties; the app was changed to send them the way the official CLI 1.2.2 does, so L2 for #1–#7 refers to those new recordings. Details and the remaining checklist: [VALIDATION.md](VALIDATION.md).

## Summary

| # | Feature | FCP mechanism | Level | Main open item |
|---|---|---|---|---|
| 1 | Generate Video | `POST /videos/{model}/generations`; result dragged or imported via FCPXML | **L4** (Seedance 2.0) | Verify inside FCP |
| 2 | Generate Image | `POST /images/{model}/generations` | **L4** (Nano Banana 2) | Verify inside FCP |
| 3 | Edit Video | Source from FCP browser/timeline/Share → Seedance 2.0 / Kling Omni Edit with video reference | **L4** (Kling Omni Edit; Seedance's run was blocked by Higgsfield as `ip_detected`) | Verify inside FCP |
| 4 | Reframe | `reframe` job type; target-format grid | **L4** | Verify inside FCP |
| 5 | Remove Background | `video_background_remover` / `image_background_remover` | **L4** (video) | **Result has no alpha** (subject on black, H.264) |
| 6 | Upscale | `topaz_video` (1080p/4K), `bytedance_video_upscale` (1080p/2K/4K), `bytedance_image_upscale` (2K/4K) | **L4** (ByteDance video) | Topaz not run (no cost estimate) |
| 7 | Draw to Edit | Sketch canvas → `draw_to_video` (video) / `nano_banana_flash` mask inpainting (stills) | **L4** (video) | Stills not run |
| 8 | Model selection & settings | Live JSON Schema from `GET /job_types/{id}` → native controls; bundled snapshot fallback | **L4** (live schemas read and parsed through the app's client) | Check the controls in the panel |
| 9 | Progress, previews, errors, jobs | Persistent job runner, polling, previews, typed errors | L2 (unit-tested) + L1 (UI) | Live run |
| 10 | Account auth & credits | Official CLI session / own OAuth (PKCE) / token; balance + cost preflight | **L4** for CLI-session sign-in, balance and cost preflight | Higgsfield-issued OAuth client ID for built-in sign-in |
| 11 | Return media to the project | Drag FCPXML onto the timeline; Open Document import into the open library | L2 (DTD-valid) + L1 | Verify inside FCP |
| — | Open from the editing workflow | Workflow extension (Extensions button / Window ▸ Extensions) | L1 (bundle layout checked in CI) | FCP listing with the SDK embedded |
| — | Work with the intended footage | Browser drag with range, timeline link + playhead/range, Share render | L2 (FCPXML parsing and timeline resolution tested) | Verify inside FCP |

---

## 1. Generate Video

**Premiere** (official page; walkthroughs): "Generate AI Video" inside the panel. A prompt, optionally from a start image, generates a clip that lands in or is dragged to the timeline. Walkthroughs feature Seedance 2.0 and Kling 3.0.

**FCP edition:**
- Prompt plus an optional **start frame**: drop a still, or a frame grab of an earlier result.
- Model menu: Seedance 2.0 (default), Kling v3.0, Veo 3.1, Cinema Studio 3.0, Wan 3.0, Kling 4.0, Seedance 1.5, Minimax Hailuo.
- Each model's own settings (aspect ratio, duration, resolution, audio, …).
- **Match Timeline Range** sets the duration to the selected range in FCP, so the clip fits the gap being filled.

**Mechanism:** `POST /videos/{job_type}/generations` with `{"params":{prompt, aspect_ratio, duration, …, medias:[start_image]}}`. The cost preflight shows on the button. The result is downloaded to `~/Movies/Higgsfield` and returned through #11.

**Implementation:** `OperationKind.generateVideo`, `RequestBuilder`, `ToolFormView`, `SettingsCard`.

**Evidence:**
- The body for `seedance_2_0` is byte-identical to the CLI capture (`ClientContractTests.testVideoModelSubmissionEncodesWholeNumbersLikeCLI`).
- Request building and validation (`RequestBuilderTests.testGenerateVideoWithStartFrame`, `testInvalidParameterValueIsRejected`).
- Model list and parameters come from the live catalog (2026-10-26).

**Difference:** FCP has no "generate into the timeline" hook. The editor drags the finished clip where it should go (one gesture), or it is added to the library automatically.

## 2. Generate Image

**Premiere:** "Generate AI Image" from a prompt; results usable in the timeline.

**FCP edition:**
- Prompt plus optional reference images.
- Models: Nano Banana 2 (default, job type `nano_banana_flash`), Nano Banana Pro, GPT Image 2, Seedream 4.5, Higgsfield Soul 2.0 (`text2image_soul_v2`), FLUX.2. The old `nano_banana_2` id now resolves to Nano Banana Pro and `soul_2` no longer exists (live catalog, 2026-10-26).
- Per-model resolution, quality and aspect ratio.
- Stills import into FCP as 5-second clips with a `FFVideoFormatRateUndefined` format, so FCP applies its still handling.

**Mechanism:** `POST /images/{job_type}/generations`. Uploaded references are `media_input`.

**Evidence:**
- References go in `image_references`, as the official CLI 1.2.2 sends them (recorded 2026-10-26; `testGenerateImageReferencesShareRole`).
- Still FCPXML is DTD-valid (`FCPXMLBuilderTests`).

## 3. Edit Video

**Premiere** (tutorials, medium confidence): "takes a clip already sitting on your timeline and runs a prompt-based AI pass on it". Reported limits: clip under 30 s, only the first 15 s are edited, many edits need at least 4 s. Seedance 2.0 is featured.

**FCP edition:**
- The source comes from the FCP browser (the selected range is respected), from the linked timeline (**Use Clip at Playhead / Use Range**), or from a Share render.
- Prompt, plus optional reference images.
- Models: Seedance 2.0 (default), Kling 3.0 Omni Edit, Seedance 2.5 (forced `mode: video_edit`), FLUX 3 Video Edit.
- Duration follows the In/Out selection and is checked against the model's limits. Seedance 2.0 accepts 4–15 s, which matches the Premiere limits; the panel explains how to trim when out of range. Only the selected range is trimmed (AVFoundation) and uploaded.

**Mechanism:** upload (`POST /media` → PUT → confirm) → `POST /videos/{model}/generations` with the source in `video_references` as `{id, type: video_input}`. All four models take that property (live schemas, 2026-10-26), and the bodies match the official CLI's (`LiveLayoutContractTests.testEditVideoModels`).

**Evidence:**
- Duration limits and roles: `RequestBuilderTests.testEditVideoEnforcesModelDurationLimits`, `testEditVideoWithSeedance25ForcesEditMode`.
- The upload handshake matches the official CLI's, including the signed Content-Type (`testMediaUploadHandshakeMatchesCLICapture`), and **uploads succeed live through the app's client** (`hfcp upload`, 2026-10-26).
- Browser range → In/Out: `FCPXMLParsingTests.testBrowserDragWithSelectedRange`, `PanelTests.testBrowserClipDropBecomesTrimmedSource`.

**Difference:** the result can't replace the clip in place. FCP extensions have no timeline-editing API. The result is dropped over the original (connected clip or replace edit), or comes back via #11.

## 4. Reframe

**Premiere** (official page): "Crop any clip to 9:16, 16:9, 4:3, 3:4, 21:9, or 1:1 with one click. Smart subject tracking keeps the focal point perfectly centered."

**FCP edition:**
- A **Target format** grid with the same six ratios, each with platform hints (Reels/Shorts/TikTok, YouTube, …).
- Resolution choice (480p/720p/1080p).
- Clips up to 60 s; duration is sent automatically for pricing.

**Mechanism:** `POST /videos/reframe/generations` with `{"params":{"aspect_ratio","resolution","duration","video_references":[{"id","type":"video_input"}]}}`.

**Evidence:**
- **The submission body matches the official CLI 1.2.2** as recorded on 2026-10-26 (`LiveLayoutContractTests.testReframe`); the app adds `duration` for pricing.
- **Live cost preflight through this app's client** (2026-10-26): 123 credits for 10 s at 1080p, 138 for 30 s at 720p (140 earlier via the MCP).
- 60 s limit and required aspect ratio are enforced (`testReframeRequiresAspectRatioAndLimitsLength`).

**Difference:** Higgsfield's reframe is generative. It can extend the frame rather than only crop, and the panel says so. FCP's built-in *Smart Conform* is a free crop-only alternative; this tool is for when outpainting or tracking quality matters.

## 5. Remove Background

**Premiere** (official page): "AI detects subjects with pixel-level precision", a key without a green screen, with alpha for compositing.

**FCP edition:** one click on a clip or still. The job type follows the source kind: `video_background_remover` or `image_background_remover`, the same pairing the official MCP `remove_background` tool uses.

**Evidence:**
- Job selection, roles and params (`testRemoveBackgroundPicksRemoverBySourceKind`, `PanelTests.testSourceKindSwitchesJobType`).
- Both job types exist in the live catalog.

**Open item:** the **output container and alpha format** is unverified. FCP composites alpha from ProRes 4444, HEVC with alpha or PNG; it can't import WebM. On download the panel probes the file with AVFoundation and refuses to send FCP something it can't import, offering *Reveal in Finder* instead. A live run is needed to confirm the format; see VALIDATION.md.

## 6. Upscale

**Premiere:** "upscale to 4K/8K"; a Higgsfield post says "Upscale to 4K on export".

**FCP edition:**
- **Target resolution** control up front.
- Video providers: Topaz (1080p / 4K, default) or ByteDance (1080p / 2K / 4K, plus preset, model tier and fps). Stills: ByteDance 2K/4K.
- Source width and height are filled in automatically when the live schema asks for them. The official MCP notes ByteDance video upscale needs them.

**Evidence:** `testUpscaleFillsSourceDimensionsOnlyWhenSchemaAsks`; all three job types and their resolution options are in the live catalog. Request bodies match the official CLI's (`LiveLayoutContractTests.testRemoveBackgroundAndUpscale`). Live cost through the app: ByteDance video 2 credits for 5 s, 4 for 10 s; ByteDance image 2. **Topaz has no cost estimate**: the server answers that `topaz_video` doesn't support cost estimation, so the panel shows "estimate unavailable" for it.

**Differences:**
- No 8K option exists in the current Higgsfield catalog, so none is offered.
- "On export" has no FCP equivalent, because FCP's export pipeline can't call extensions. The closest is **File ▸ Share ▸ Higgsfield** to render the finished timeline, then Upscale, then import.

## 7. Draw to Edit

**Premiere** (official page; users): "Remove unwanted objects, add new elements, or replace entire areas with a single brush stroke"; "just circle the area you want to change".

**FCP edition:**
- **Draw on Frame…** opens a canvas on the first frame of the selection, with colours, brush size, undo and clear. Add a prompt.
- **Video:** strokes are composited on the frame at full resolution and sent to `draw_to_video` in `image_references`, which the live schema describes as "the sketch image to animate". The source goes in `video`; `ref_image` is only an optional style reference, used for any reference image.
- **Stills:** strokes become a white-on-black mask for `nano_banana_flash` ("Nano Banana 2") inpainting (`is_inpaint: true`, `mask`). Nano Banana Pro has no mask input.

**Evidence:**
- The rendered mask and sketch are pixel-checked (`PanelTests.testSketchAndMaskRendering`).
- Roles and params: `testDrawToEditVideoUsesSketchRole`, `testDrawToEditImageUsesMaskInpainting`; bodies match the official CLI's (`LiveLayoutContractTests.testDrawToVideoSketchGoesToImageReferences`, `testDrawToEditStillUsesNanoBanana2MaskInpainting`).
- Live cost through the app: 26 credits for 5 s at 720p (video), 1.5 (still).

**Settled 2026-10-26:** the sketch role. The earlier guess (`sketch`, else `ref_image`) was wrong: it would have sent the drawing as a style reference.

## 8. Model selection & generation settings

**Premiere:** a model choice per tool (walkthroughs switch between Seedance 2.0 and Kling 3.0); details of the dropdown weren't found.

**FCP edition:**
- Each tool lists its candidate models.
- Settings are generated from the model's **live JSON Schema** (`GET /job_types/{id}`):
  - enums → segmented control or menu
  - booleans → toggle
  - bounded numbers → slider
  - other numbers → field
- Plan-gated or irrelevant fields (folder ids, presets, batch sizes) are hidden.
- Tool-specific fields (aspect ratio for Reframe, resolution for Upscale, duration for edit tools) get dedicated controls.
- A bundled snapshot of the catalog (2026-10-26) keeps the panel usable before sign-in. A badge shows when settings come from it.

**Evidence:**
- `SchemaTests` cover `$ref`, `anyOf`, `oneOf`/`const` roles, nullable numbers, top-level media properties and live-overrides-snapshot behaviour.
- **Live through this app's client (2026-10-26):** `hfcp schema` read and parsed every job type the tools use. The bundled snapshot is now those exact responses (`tools/catalog-snapshot-2026-10-26.json`), so the offline fallback matches what the panel reads live.

## 9. Progress, previews, errors and job handling

**Premiere:** runs on Higgsfield servers and needs an internet connection; progress UI details weren't found. One write-up says failed runs can still cost credits (low confidence).

**FCP edition — the Activity list:**
- **Phases:** Uploading → Submitting → Queued → Generating → Downloading → Ready / Failed / Blocked by moderation / Canceled / Stopped tracking.
- **Several jobs run at once.**
- Jobs are **persisted** in the shared container. When FCP closes and reopens the extension window (which Apple says terminates the extension), polling resumes.
- **Previews:** a thumbnail from `min_result_url` while running, a frame of the downloaded file when done, and in-panel playback (AVKit).
- **Errors** are mapped to plain messages: sign-in expired, not enough credits, plan restriction (e.g. `job_minimum_pro_plan_required`), validation errors with the offending field, moderation, network.
- Download failures can be retried without regenerating.

**Cancellation:** the account API exposes no cancel endpoint (none exists in the official CLI). *Stop Tracking* says plainly that the job continues and is billed.

**Evidence:** `JobRunnerTests` run upload → submit → queued → in_progress → completed → download end to end against a scripted transport. They also cover failure messages, credit refusals, persistence across instances and resume.

## 10. Account authentication & Higgsfield credits

**Premiere** (help centre, high confidence): sign in to the Higgsfield account from the panel. Generations use the user's **plan credits**, "the same as MCP and CLI".

**FCP edition:**
- **Sign in** in one of three ways:
  - **Use Higgsfield CLI session.** The panel runs the official `hf auth token`, which refreshes itself. If not logged in, `hf auth login` opens Higgsfield's own browser sign-in. The extension runs the CLI itself where its sandbox allows. Otherwise it asks the container app (`higgsfieldfcp://cli-token`), which stores the token in the shared folder.
  - **Sign in with Higgsfield.** The app's own OAuth 2.0 + PKCE flow against `clerk.higgsfield.ai` with a loopback redirect, the same flow as the CLI. It is enabled when the build has a Higgsfield-issued `HiggsfieldOAuthClientID`.
  - **Paste access token.**
- Header shows the **credit balance** and plan; workspace switcher; **cost preflight** on every change, displayed on the Generate button. Submission is disabled when the estimate exceeds the balance. The balance refreshes after each job.

**Evidence:**
- PKCE (RFC 7636 vector), authorize URL and token and refresh form bodies are identical to the CLI captures.
- CLI bridge tested with a stand-in `hf`; that the real CLI refreshes expired sessions was verified through the capture proxy.
- 401 → single refresh → retry.
- **Live through this app's client (2026-10-26):** sign-in through the official CLI session, `balance` → 854.14 credits, plan "plus", workspaces, and a cost estimate for every tool (VALIDATION.md). 60 sign-ins in a row succeeded after fixing a rare empty-token read in the CLI bridge.
- Several job types price by the source length without taking a `duration` parameter (Kling Omni Edit requires it for the estimate). The panel now sends the selected length with every estimate; checked live: Kling Omni Edit 12 credits for 6 s, 24 for 12 s.

**Difference from Premiere:** the plugin has its own sign-in button. Here, sign-in goes through the official Higgsfield CLI (one-time `npm install -g @higgsfield/cli`). A built-in button would need an OAuth client that only Higgsfield can issue; the CLI's own client ID is deliberately not reused.

## 11. Returning generated or processed media to the project

**Premiere:** "results drop straight into your Adobe timeline"; users drag generated videos onto the timeline.

**FCP edition:**
1. **Drag** a finished job's thumbnail onto the FCP timeline or browser. The pasteboard offers FCPXML 1.10 under FCP's versioned and generic types (Apple's promise pattern), and FCP inserts it at the drop point.
2. **Add to Final Cut Pro**, or automatic on completion: an FCPXML event "Higgsfield AI" opened via the Open Document event, with `library location` = the open library (`FCPXLibrary.url`). No library dialog.

Clips carry prompt, model, settings and job ID in Notes, the keywords "Higgsfield" and the tool name, and a stable `uid`.

**Evidence:**
- Generated FCPXML validates against **Apple's FCPXML 1.10 DTD with `xmllint`** in CI on Linux and macOS (`FCPXMLBuilderTests`). The validator rejects a deliberately invalid attribute, so the check is real.
- The pasteboard item's types and lazily provided data are tested (`PanelTests.testDragPayloadOffersFCPXMLAndFileURL`).
- Durations are conformed to frame boundaries.

**Difference:** no programmatic insert at the playhead or replace-in-place, because FCP has no extension editing API.

## UX flow vs the brief

| Brief | FCP edition |
|---|---|
| Open Higgsfield from the editing workflow | Extensions toolbar button / **Window ▸ Extensions ▸ Higgsfield**. The panel docks as a floating window over the FCP UI. The container app offers the same panel with *Keep Panel on Top*. |
| Same core AI operations in one compact panel | Seven-tool strip; minimum 360×560 pt (`ProExtensionAttributes`); Dark Mode as Apple's guidelines recommend. **The official panel is organised differently**; see below. |
| Work with the intended source footage | Drag from the FCP browser (range kept), **Use Clip at Playhead / Use Range** on a linked timeline, or Share render. The source card shows origin, resolution, frame rate and In/Out with a trim slider. |
| Configure and submit | Prompt, tool controls, model and schema-driven settings; validation message and credit estimate beside **Generate** (⌘↩). |
| Monitor progress and inspect | Activity list with phases, previews and playback; persists across extension restarts. |
| Bring the asset into FCP with few steps | One drag to the timeline, or zero clicks with auto-import into the open library. |

## Panel layout vs the official plugin

Reviewed on 2026-10-26 from the official page, two panel screenshots on it (labelled v0.4) and its hero demo video (panel labelled v1). The video is a stylised marketing cut, so it shows the layout and labels reliably but not every screen.

**What the official panel looks like:**
- **Header:** "Higgsfield", a lime **PLUGINS** badge, the version, and the account avatar. No credit balance is visible.
- **Home screen, not a tool strip:**
  - **Last generations** ("Recent images and videos"): a horizontal row of thumbnails, with a **+** tile first.
  - **Apps** ("Create high-quality videos in"): a two-column grid of cards with an icon, a title and a one-line description. Visible in v1: **Draw to video** (NEW badge), **Remove background**, **Image generation**, **Video generation**; more cards continue below. v0.4 also had a promo card at the top (REFRAME, "Try now") and a **Supercomputer** card ("One chat for everything").
- **Prompting:** a floating, rounded prompt bar with a **+** button (add a reference) and a round lime **↑** send button.
- **Draw to video:** the brush strokes are painted straight over the video in the program monitor.
- **Gallery:** an **Image | Video** segmented switch above a grid of results.
- The page lists the tools as Generate AI Video, Generate AI Image, Reframe, Remove Background, Draw to edit and Upscale; Edit Video appears only in the FAQ. The page also says "five plugins".

**How this edition differs:**

| Official | This edition | Note |
|---|---|---|
| Home screen with Last generations row and an Apps grid | Seven-tab tool strip; the active tool's form fills the panel | The main visual-hierarchy difference. Not changed yet: it's a redesign of the panel's top level, so it waits for the owner's decision. |
| Floating prompt bar with **+** and a lime **↑** | Prompt box inside the form; **Generate** button at the bottom | Same decision as above. |
| Labels "Draw to video", "Remove background", "Image generation", "Video generation" | "Draw to Edit", "Remove BG", "Image", "Video" (tabs) and "Generate Video" etc. (titles) | Would change with the layout. |
| Credits not shown in the header | Credit balance shown in the header | Kept: estimates and balance are useful in FCP, where the web app isn't open. |
| Strokes painted over the program monitor | **Draw on Frame…** opens a canvas in the panel | FCP extensions can't draw over the viewer, so a canvas is the closest equivalent. |
| Gallery with an Image / Video switch | Activity list of jobs, newest first | Activity also shows progress; a gallery view would be an addition. |
| Supercomputer chat card | Not offered | Not part of the brief's seven tools. |
| Not shown: progress UI, Upscale and Edit Video screens | — | Still unknown. |

## Things the Premiere plugin may do that this edition does not

- **After Effects variant.** Out of scope.
- **8K upscale, "upscale on export".** See #6.
- **Insert or replace on the timeline programmatically.** Not possible in FCP; see #3 and #11.
