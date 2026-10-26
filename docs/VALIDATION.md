# Validation

This page lists what has been verified and how, what has not been verified yet, and how to close each remaining gap.

## Verified automatically (every push, GitHub Actions)

| Check | Where | What it proves |
|---|---|---|
| **HiggsfieldKit tests on Linux** (Swift 5.10) and **macOS** (Xcode 16) | `swift test` | 85 tests (see below) |
| **Panel tests on macOS** | `Tests/HiggsfieldPanelTests` | Draw-to-Edit sketch and mask pixels, FCPXML drag pasteboard types and data, FCP browser/project drops → sources, timeline playhead resolution, validation messages, tool defaults, graceful behaviour with no FCP host, personal storage, and the one-time move into an App Group |
| **FCPXML ⟷ Apple DTD 1.10** | `FCPXMLBuilderTests` with `FCPXML_DTD` (fetched from developer.apple.com by `tools/fetch_fcpxml_dtd.py`) | Every generated import/drag document validates with `xmllint --dtdvalid`. A deliberately broken document is rejected, so the check is real. |
| **Container app + workflow extension build** | `xcodegen` + `xcodebuild` | Both targets compile and link against the package. The `.appex` is embedded under `PlugIns/` with `NSExtensionPointIdentifier = com.apple.FinalCut.WorkflowExtension` and the principal view controller key. |
| **Paid-team signing config** | second `xcodebuild` with `App/Config/Local.xcconfig.example`, ad-hoc signed | Both targets embed the App Group and Keychain group entitlements and Info.plist keys from the Team ID, and the extension stays sandboxed. The default build carries neither. |
| **UI snapshots** | `PanelTests.testRenderPanelSnapshots` → branch `ci/panel-snapshots` (latest copy in [docs/screenshots](screenshots)) | Every tool screen renders. Reviewed visually; issues found and fixed: aspect-ratio default, frame-rate label, free-text parameters moved under *Advanced*. |

### What the HiggsfieldKit tests cover

- **API contract** (`ClientContractTests`): reframe, image and video submissions, cost preflight, upload handshake, job polling and catalog queries. Each is byte-identical, or JSON-equal, to requests captured from the official Higgsfield CLI.
- **Today's request layout** (`LiveLayoutContractTests`): for every tool, the panel's submission for the same inputs equals what the official CLI 1.2.2 built from the live schemas on 2026-10-26 (media as top-level properties, Draw to Edit sketch in `image_references`, masks, chained results as `video_job`/`image_job`). The older `params.medias` layout is still supported. Also: cost estimates carry the clip length (`CostParamsTests`). Also covered: headers (`Authorization: Bearer`, `hf-workspace-id`), single 401 refresh, retry policy (a submission is never retried on a 500), and error-message extraction.
- **Auth** (`AuthTests`):
  - SHA-256 standard vectors and the PKCE RFC 7636 appendix B vector
  - authorize URL and token-exchange/refresh form bodies, identical to the CLI capture
  - OAuth refresh behaviour and file token store permissions
  - CLI bridge against a stand-in `hf`, including the "Not authenticated" mapping
- **Schema** (`SchemaTests`): catalog snapshot integrity; JSON Schema parsing (`$ref`, `anyOf`, `oneOf`/`const` roles, nullable numbers); live schema overriding the snapshot; media-role resolution.
- **Operations** (`RequestBuilderTests`): every tool's request building and validation, including model duration limits (Seedance 2.0 at 4–15 s), the 60 s reframe limit, forced modes, Draw to Edit roles, and source-dimension filling for upscalers.
- **Jobs** (`JobRunnerTests`): end-to-end upload → submit → queued → in progress → completed → download; chaining an earlier result without re-upload; failure and credit-refusal recording; persistence and resume; `stopAll` halting polling (used when the panel reconnects, so jobs are never polled twice).
- **FCPXML** (`FCPXMLParsingTests`, `FCPXMLBuilderTests`):
  - FCPXML 1.8/1.10/1.13 parsing, including browser ranges with timecode starts, `<clip><video>` wrappers, connected clips and gaps
  - playhead and range resolution
  - frame-boundary conforming, escaping, and import metadata (notes, keywords, uid)

## Independent code review

A separate reviewer read the macOS layer for runtime bugs that compiling and tests miss, and reported 12. All 12 were confirmed and fixed, with regression tests where they are testable:

| Finding | Fix | Test |
|---|---|---|
| A reconnect during an upload marked the job failed while the old runner kept going (risking a double charge on resubmit) | One runner per panel; reconnects swap the client in place; the interrupted sweep runs once per launch; stale connects are ignored | `testLaterResumeLeavesInFlightUploadsAlone`, `testStopAllHaltsPolling` |
| Concurrent token refreshes each triggered a full CLI sign-in in the app | Refreshes coalesced; the app serves the extension with a lightweight `hf auth token` and reports failures through a status file | `testStoredProviderCoalescesConcurrentRefreshes` |
| OAuth sign-in never ended on timeout | The listener is cancelled on timeout or cancel, which always ends the wait; a Cancel button was added | — (needs a Higgsfield OAuth client) |
| Source permission state leaked between tools; grants were lost on relaunch | Re-evaluated per tool and on start; security-scoped bookmarks are persisted | `testSourceAccessFollowsTheActiveTool` |
| A linked timeline could be resolved against a different open project | The link must match the active sequence and is cleared when FCP switches project | `testLinkedTimelineMustMatchOpenSequence` |
| AppKit overlays swallowed the remove-source click and the double-click preview | Controls moved above the drop view; the drag source forwards double-clicks | snapshots |
| Reused or old results lacked media info (no duration, drag did nothing) | Probed on demand | `testDragPayloadOffersFCPXMLAndFileURL` |
| Shared OAuth refresh token was cached forever and cleared on any failure | Re-read before use; cleared only if unchanged | `testOAuthProviderUsesTokensRotatedByAnotherProcess`, `testFailedRefreshDoesNotClearACredentialReplacedMeanwhile` |
| App and extension overwrote each other's settings and drafts | Separate files per process; stale drawings dropped | `testAppAndExtensionKeepSeparateSettings` |
| Stale thumbnails could win races | Results discarded when the load task is cancelled | — |
| A chatty CLI could block on a full pipe | Pipes drained while the process runs | `testCLIBridgeDrainsLargeOutputWithoutBlocking` |
| Sign-in reported success to the other process even when it failed | Notification sent only after a successful connect | — |

## Verified live through this app's client (2026-10-26, no credits spent)

Run from a cloud workspace with `hfcp --cli …`, signed in through the official CLI (`hf auth login`, approved by the owner). Balance before and after: 854.14 credits.

| Check | Result |
|---|---|
| Sign-in through the CLI session (`hf auth token`) | Works. 60 sign-ins in a row succeeded after the pipe-read fix below. |
| `balance`, `workspaces` | 854.14 credits, plan "plus", one workspace |
| `catalog --type video/image`, `catalog --chain` | Listed. `reframe` and `draw_to_video` are under `--chain` (label "chain"), not the model list. |
| `schema` for every job type the tools use | Read and parsed. Media are **top-level properties** now (see below). |
| Cost, Reframe 10 s at 1080p / 30 s at 720p | 123 / 138 credits |
| Cost, Generate Video (Seedance 2.0) / Generate Image (Nano Banana 2) | 22.5 / 1.5 credits |
| Cost, Edit Video 6 s: Seedance 2.0 / Kling Omni Edit / FLUX 3 Video Edit | 27 / 12 / 6 credits |
| Cost, Remove Background video 5 s / still | 1 / 1 credit |
| Cost, Upscale: ByteDance video 5 s / 10 s, ByteDance image | 2 / 4 / 2 credits |
| Cost, Upscale with Topaz | No estimate: the server says `topaz_video` doesn't support cost estimation. Per the panel code, the reason replaces the estimate and the run is still allowed (read in code, not yet seen in the panel). |
| Cost, Draw to Edit video 5 s at 720p / still | 26 / 1.5 credits |
| `hfcp preview <tool>` for all seven tools | The body the panel would submit, with placeholder ids. Matches the CLI recordings below. |

**What these checks changed** (commits `a07d7a5`, `9b2f279`):

1. **Media layout.** Live schemas declare media as top-level properties (`video`, `video_references`, `image_references`, `start_image`, `end_image`, `ref_image`, `mask`) instead of a `params.medias` array. The app parsed none of them and would have sent `medias:[{data, role}]` for every tool that takes a clip or image. It now sends what the official CLI sends.
2. **Draw to Edit sketch.** `draw_to_video` takes the source in `video` and the sketch in `image_references` ("the sketch image to animate"). The app would have put the sketch in `ref_image`, a style reference.
3. **Model ids.** `nano_banana_2` now resolves to Nano Banana Pro, which has no mask input; "Nano Banana 2" is `nano_banana_flash`. `soul_2` no longer exists (`text2image_soul_v2`). Generate Image and Draw to Edit on stills use the current ids.
4. **Estimates.** Kling Omni Edit's estimate failed without `duration`, and FLUX 3 Video Edit and ByteDance video upscale quoted a default length. Estimates now include the selected clip length.
5. **Aspect ratio.** Live schemas carry a default (Seedance 2.0: 16:9) that overrode "keep the source shape" for Edit Video. Fixed; caught by the macOS panel tests.
6. **CLI sign-in read.** Once, `hf auth token` returned nothing although it succeeded. The bridge now reads the CLI's output to the end before returning.
7. The bundled catalog is now the live `GET /job_types` responses, so the offline fallback matches.

### CLI request recordings (2026-10-26)

To see exactly what the official CLI 1.2.2 sends today, it was run through a local proxy that answered every request itself: job schemas from the live responses saved earlier, `404` for unknown ids, and a refusal for anything else. **Nothing reached Higgsfield and nothing was charged.** Recorded for `reframe`, `draw_to_video`, `kling_video_edit`, `seedance_2_0` (edit and start frame), `seedance_2_5`, `flux_3_video_edit`, both background removers, `topaz_video`, both ByteDance upscalers, `kling3_0`, `nano_banana_pro` and `nano_banana_flash` with a mask, plus chaining an earlier job and the first upload step. Examples:

```
POST /videos/draw_to_video/generations
{"params":{"duration":5,"image_references":[{"id":"…","type":"media_input"}],"prompt":"make the jacket red","resolution":"720p","video":{"id":"…","type":"video_input"}}}
POST /videos/reframe/generations
{"params":{"aspect_ratio":"9:16","video_references":[{"id":"…","type":"video_input"}]}}
POST /images/nano_banana_flash/generations
{"params":{"image_references":[{"id":"…","type":"media_input"}],"is_inpaint":true,"mask":{"id":"…","type":"media_input"},"prompt":"make it red"}}
```

What this does **not** prove: that Higgsfield accepts these bodies and produces the right result. Only a paid run shows that (below).

## Verified live earlier (read-only, official Higgsfield MCP server, this account)

| Call | Result |
|---|---|
| `balance` | `{"credits":854.14,"subscription_plan_type":"plus"}` |
| reframe cost preflight, 10 s at 1080p | 123 credits |
| reframe cost preflight, 30 s at 720p | 140 credits (138 on 2026-10-26) |
| image upscale cost preflight with a placeholder id | Rejected: the server needs an uploaded image for this estimate. The panel shows "estimate unavailable" in that case. |
| `models_explore` list/get | The job types and parameters used by every tool exist (snapshot in `tools/`) |

The official CLI's behaviour was also verified through a capture proxy, with no credits spent:

- `hf auth token` refreshes an expired session through the standard refresh-token grant.
- Uploads become usable only at `status: "uploaded"`.
- The CLI reads `result_url` / `min_result_url` from `GET /jobs/{id}`.

## Not yet verified, and why

| Item | Blocker in the build environment | How to verify |
|---|---|---|
| A **paid generation per tool** through the app (L4) | Spends credits; not done without your go-ahead | `hfcp run …` (below) or the panel. This is also the first proof that the top-level media layout is accepted. |
| **Remove Background output format** (alpha? container?) | Needs a live run | `hfcp run removeBackground --file clip.mov --yes`, then check the file in FCP |
| **Anything inside Final Cut Pro** (L5) | Needs the Mac: building the app needs Xcode, and FCP can't be driven from the cloud workspace | The acceptance checklist below |
| **Panel layout vs the official plugin** | Needs the owner's decision (PARITY, *Panel layout vs the official plugin*) | — |
| **The extension running the CLI inside its sandbox** | Needs a Mac | Sign in from the extension. If the sandbox blocks the CLI, the panel falls back to the container app automatically; either way it should connect. |
| **Built-in "Sign in with Higgsfield"** (optional) | Needs an OAuth client ID issued by Higgsfield | Set `HIGGSFIELD_OAUTH_CLIENT_ID` in `App/project.yml` |
| **App Group and Keychain with a real team** (optional) | Needs your Team ID and a Mac; CI can only ad-hoc sign | Follow README, *Paid developer team*, then the checklist |
| **Timeline API binding** (`ProExtensionHost`) | Needs Apple's Workflow Extension SDK and FCP | `scripts/configure-workflow-sdk.sh`, then the checklist |

## Live API check in CI (no credits spent)

1. On your Mac: `npm install -g @higgsfield/cli && hf auth login && hf auth token`.
2. In GitHub: **Settings ▸ Secrets and variables ▸ Actions**, add `HIGGSFIELD_ACCESS_TOKEN` with that token. It expires, so refresh it when needed.
3. **Actions ▸ CI ▸ Run workflow.** The `live-api` job runs, through this repo's Swift client:
   - `hfcp balance`, `workspaces` and `catalog`
   - `hfcp schema` for every job type the tools use
   - `hfcp cost` for all seven tools

The same checks also run anywhere with `hfcp --cli …` after `hf auth login`; that is how they were run on 2026-10-26.

## Paid end-to-end checks with `hfcp` (spend credits)

```sh
swift build -c release --product hfcp
H=.build/release/hfcp            # uses $HIGGSFIELD_ACCESS_TOKEN or --cli (official CLI session)
$H --cli cost reframe --duration 6 --set aspect_ratio=9:16          # free
$H --cli preview reframe --file clip.mov --duration 6 --set aspect_ratio=9:16   # free: shows the exact request
$H --cli run reframe --file clip.mov --set aspect_ratio=9:16 --yes  # paid
$H --cli run removeBackground --file clip.mov --yes
$H --cli run upscale --file clip.mov --set resolution=2160p --yes
$H --cli run editVideo --file clip.mov --prompt "make it snow" --yes
$H --cli run drawToEdit --file clip.mov --sketch frame-with-strokes.png --prompt "make the jacket red" --yes
$H --cli run generateVideo --prompt "slow dolly in on a lighthouse" --yes
$H --cli run generateImage --prompt "product shot on wet stone" --yes
```

Each run prints the phases (`Uploading`, `Queued`, `Generating`, `Downloading`, `Ready`) and the saved file path, using the same job runner as the panel.

## Acceptance checklist in Final Cut Pro (L5)

Setup:

- [ ] Optional SDK step: `scripts/configure-workflow-sdk.sh`.
- [ ] `xcodegen generate --spec App/project.yml`, open the project, sign both targets with your Apple ID (Personal Team), build **HiggsfieldFCP**.
- [ ] Optional, paid team: copy `App/Config/Local.xcconfig.example` to `Local.xcconfig`, set your Team ID, build. Xcode signs both targets with your team without errors.
- [ ] Copy the app to `/Applications` and launch it once.
- [ ] FCP shows **Higgsfield** in the toolbar Extensions menu and under **Window ▸ Extensions**.

Account:

- [ ] The panel opens in a floating window.
- [ ] With the official CLI signed in, **Use Higgsfield CLI Session** connects. Credits and plan appear in the header.
- [ ] Paid team only: after switching from the personal build, the panel opens still signed in, Activity shows the earlier jobs, and `~/Library/Application Support/HiggsfieldFCP/credentials.json` is gone (the token is in the Keychain).

Sources:

- [ ] Drag a clip from the FCP browser. Name, resolution, fps and In/Out appear; a range selected in the browser is kept.
- [ ] Drag the open project from the browser. **Use Clip at Playhead** picks the clip under the playhead, and a connected clip wins over the primary storyline.
- [ ] With the SDK embedded: the header shows the sequence name, and the timeline row shows the live playhead and range.

Tools, each with a cost estimate on the button:

- [ ] **Reframe** to 9:16. Result appears in Activity with a preview.
- [ ] **Edit Video**, **Remove Background**, **Upscale**, **Draw to Edit** (video and still), **Generate Video**, **Generate Image**.

Returning results:

- [ ] Drag a finished result onto the timeline. It is inserted at the drop point and appears in the project's event.
- [ ] **Add to Final Cut Pro**. The clip appears in event "Higgsfield AI" of the open library without a library dialog, with prompt, model and job ID in Notes and the "Higgsfield" keyword.

Persistence and errors:

- [ ] Close the extension window mid-job and reopen it. The job resumes and completes.
- [ ] With too few credits, the button is disabled with an explanation. With a bad token, the panel asks you to sign in again.
