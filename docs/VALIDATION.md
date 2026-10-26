# Validation

This page lists what has been verified and how, what has not been verified yet, and how to close each remaining gap.

## Verified automatically (every push, GitHub Actions)

| Check | Where | What it proves |
|---|---|---|
| **HiggsfieldKit tests on Linux** (Swift 5.10) and **macOS** (Xcode 16) | `swift test` | 73 tests (see below) |
| **Panel tests on macOS** | `Tests/HiggsfieldPanelTests` | Draw-to-Edit sketch and mask pixels, FCPXML drag pasteboard types and data, FCP browser/project drops → sources, timeline playhead resolution, validation messages, tool defaults, graceful behaviour with no FCP host, personal storage, and the one-time move into an App Group |
| **FCPXML ⟷ Apple DTD 1.10** | `FCPXMLBuilderTests` with `FCPXML_DTD` (fetched from developer.apple.com by `tools/fetch_fcpxml_dtd.py`) | Every generated import/drag document validates with `xmllint --dtdvalid`. A deliberately broken document is rejected, so the check is real. |
| **Container app + workflow extension build** | `xcodegen` + `xcodebuild` | Both targets compile and link against the package. The `.appex` is embedded under `PlugIns/` with `NSExtensionPointIdentifier = com.apple.FinalCut.WorkflowExtension` and the principal view controller key. |
| **Paid-team signing config** | second `xcodebuild` with `App/Config/Local.xcconfig.example`, ad-hoc signed | Both targets embed the App Group and Keychain group entitlements and Info.plist keys from the Team ID, and the extension stays sandboxed. The default build carries neither. |
| **UI snapshots** | `PanelTests.testRenderPanelSnapshots` → branch `ci/panel-snapshots` (latest copy in [docs/screenshots](screenshots)) | Every tool screen renders. Reviewed visually; issues found and fixed: aspect-ratio default, frame-rate label, free-text parameters moved under *Advanced*. |

### What the HiggsfieldKit tests cover

- **API contract** (`ClientContractTests`): reframe, image and video submissions, cost preflight, upload handshake, job polling and catalog queries. Each is byte-identical, or JSON-equal, to requests captured from the official Higgsfield CLI. Also covered: headers (`Authorization: Bearer`, `hf-workspace-id`), single 401 refresh, retry policy (a submission is never retried on a 500), and error-message extraction.
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

## Verified live (read-only, official Higgsfield MCP server, this account)

| Call | Result |
|---|---|
| `balance` | `{"credits":854.14,"subscription_plan_type":"plus"}` |
| reframe cost preflight, 10 s at 1080p | 123 credits |
| reframe cost preflight, 30 s at 720p | 140 credits |
| image upscale cost preflight with a placeholder id | Rejected: the server needs an uploaded image for this estimate. The panel shows "estimate unavailable" in that case. |
| `models_explore` list/get | The job types and parameters used by every tool exist (snapshot in `tools/`) |

The official CLI's behaviour was also verified through a capture proxy, with no credits spent:

- `hf auth token` refreshes an expired session through the standard refresh-token grant.
- Uploads become usable only at `status: "uploaded"`.
- The CLI reads `result_url` / `min_result_url` from `GET /jobs/{id}`.

## Not yet verified, and why

| Item | Blocker in the build environment | How to verify |
|---|---|---|
| Live requests from **this app's client** | Higgsfield hosts are blocked by the sandbox's network policy | Run the **Live Higgsfield API check** workflow (below), or use `hfcp` on any machine |
| A **paid generation per tool** through the app (L4) | Spends credits; not done without your go-ahead | `hfcp run …` (below) or the panel |
| **Remove Background output format** (alpha? container?) | Needs a live run | `hfcp run removeBackground --file clip.mov --yes`, then check the file in FCP |
| **Draw to Edit sketch role** (`sketch` vs `ref_image`) | Needs the live schema | `hfcp schema draw_to_video` |
| **Anything inside Final Cut Pro** (L5) | No Mac/FCP in the build environment | The acceptance checklist below |
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

## Paid end-to-end checks with `hfcp` (spend credits)

```sh
swift build -c release --product hfcp
H=.build/release/hfcp            # uses $HIGGSFIELD_ACCESS_TOKEN or --cli (official CLI session)
$H --cli cost reframe --duration 6 --set aspect_ratio=9:16          # free
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
