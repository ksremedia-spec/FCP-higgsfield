# Handoff: continuing on the Mac

This is for the Claude session running on the owner's Mac. It covers what exists, what is proven, what is left, and how to work on it. The earlier work happened in a cloud sandbox with **no Mac, no Final Cut Pro, and no network access to Higgsfield**. The Mac has all three, so the remaining work is mostly verification and fixing whatever it turns up.

## In one paragraph

This repo is a Final Cut Pro edition of the official [Higgsfield Premiere Pro plugin](https://higgsfield.ai/plugins/premiere-pro): a workflow extension plus a container app that run one SwiftUI panel. The panel has the plugin's seven tools (Generate Video, Generate Image, Edit Video, Reframe, Remove Background, Upscale, Draw to Edit) and runs on the owner's Higgsfield account and plan credits. The code is complete and CI is green. Every feature is at **L2/L3**: requests are proven identical to the official CLI's, FCPXML is valid against Apple's DTD, and the backend job types were confirmed live. **Nothing has run against the live API through this app's client (L4) or inside Final Cut Pro (L5).** Getting there is the job.

## Where things stand

| | |
|---|---|
| Repo | `github.com/ksremedia-spec/FCP-higgsfield` |
| Branch | **`claude/fcp-edition`**. The remote has no `main` yet and there is no PR. Clone with `-b claude/fcp-edition`. |
| Last commit | See `git log`. On 2026-10-26 the free live checks (step A) ran through `hfcp` from a cloud workspace and the fixes they called for were committed; step D (comparison) is written up in PARITY. |
| Other branch | `ci/panel-snapshots`, force-pushed by CI with offscreen panel renders. Don't build on it. |
| Owner's account (read-only check, 2026-10-26) | Plus plan, 854.14 credits. Reframe cost: 10 s at 1080p = 123 credits, 30 s at 720p = 138. All estimates are in VALIDATION.md. |

## Ground rules from the owner

1. **Strict product parity** with the Premiere plugin: same workflows, visual hierarchy and simplicity, macOS-native. Never reduce it to a prompt box plus an import button.
2. **Never mark a feature complete because its UI exists.** Raise a level in `docs/PARITY.md` only with evidence: L4 = ran end to end through this app's client against the live API; L5 = exercised inside Final Cut Pro. Record the evidence in `docs/VALIDATION.md`.
3. **Never spend Higgsfield credits without the owner's go-ahead.** Cost preflights, balance, catalog and schema calls are free. Before paid runs, list each run with its preflight cost and ask once for the batch.
4. **Never reuse the official CLI's OAuth `client_id`.** Sign-in is via the official CLI session (`hf auth token`) or a pasted token. Built-in OAuth stays hidden until Higgsfield issues a client ID (`HIGGSFIELD_OAUTH_CLIENT_ID`).
5. It's a **personal tool for one user**: no distribution, notarisation, App Store or trademark work.
6. Don't open a PR unless asked. Commit to `claude/fcp-edition`.
7. The owner prefers you work autonomously from start to finish, and report clearly what is verified and what isn't.

## 1. Set up the Mac

```sh
git clone -b claude/fcp-edition https://github.com/ksremedia-spec/FCP-higgsfield.git
cd FCP-higgsfield
xcodebuild -version                      # Xcode 15+; CI uses Xcode 16 on macOS 15
brew install xcodegen
npm install -g @higgsfield/cli           # official CLI; provides `hf`
hf auth login                            # browser sign-in, once
hf auth token >/dev/null && echo "CLI session OK"
```

Optional:

- **Workflow Extension SDK** (live playhead, range, and importing straight into the open library). Download it from <https://developer.apple.com/download/all/?q=WorkflowExtensions>, install it, then run `scripts/configure-workflow-sdk.sh`. That writes `App/Config/ProExtensionHost.local.xcconfig` (git-ignored), and a post-build script embeds the framework. Without it, everything else works: drag in and out, Share, and Add to Final Cut Pro (FCP then asks which library to use).
- **Paid developer team** (the owner has one). Copy `App/Config/Local.xcconfig.example` to `App/Config/Local.xcconfig` and set `HIGGSFIELD_TEAM_ID`. That signs both targets with the team (and survives `xcodegen generate`), adds an App Group and a Keychain group, and moves job history and sign-in over on first launch. See the README section *Paid developer team*.

### Build, test, install

```sh
swift test                                   # all HiggsfieldKit and panel tests (panel tests are macOS-only)
xcodegen generate --spec App/project.yml     # regenerate after editing project.yml or adding files
xcodebuild -project App/HiggsfieldFCP.xcodeproj -scheme HiggsfieldFCP -configuration Debug \
  -derivedDataPath build/DerivedData -allowProvisioningUpdates build
```

Signing: with `Local.xcconfig` it's automatic. Otherwise open the project in Xcode and pick a team for both targets (Personal Team works). `xcodegen generate` resets that choice.

```sh
APP="build/DerivedData/Build/Products/Debug/Higgsfield for Final Cut Pro.app"
rm -rf "/Applications/Higgsfield for Final Cut Pro.app" && cp -R "$APP" /Applications/
open "/Applications/Higgsfield for Final Cut Pro.app"          # launching once registers the extension
pluginkit -mAvvv -p com.apple.FinalCut.WorkflowExtension        # must list com.ksremedia.HiggsfieldFCP.WorkflowExtension
```

In Final Cut Pro (10.6+), open it from the Extensions button in the toolbar or **Window ▸ Extensions ▸ Higgsfield**.

If the extension is missing or stale:

- `pluginkit -mAvvv` shows the path of each registered copy. Remove old copies, such as builds left in DerivedData, so only `/Applications` remains.
- Register explicitly with `pluginkit -a ".../HiggsfieldWorkflowExtension.appex"` and enable it with `pluginkit -e use -i com.ksremedia.HiggsfieldFCP.WorkflowExtension`.
- Restart Final Cut Pro.

## 2. What to do, in order

### A. Free live API checks (no credits)

```sh
swift build -c release --product hfcp
H=.build/release/hfcp                    # --cli reuses the official CLI session
$H --cli balance
$H --cli workspaces
$H --cli catalog --type video | head -50
$H --cli catalog --chain
for jt in reframe draw_to_video video_background_remover image_background_remover topaz_video \
          bytedance_video_upscale bytedance_image_upscale kling_video_edit seedance_2_0 seedance_2_5 \
          flux_3_video_edit nano_banana_flash nano_banana_pro; do echo "== $jt"; $H --cli schema "$jt"; done
$H --cli cost reframe --duration 10 --set aspect_ratio=9:16 --set resolution=1080p     # expect about 123
$H --cli cost generateVideo --prompt "slow dolly in on a lighthouse"
$H --cli cost generateImage --prompt "product shot"
$H --cli cost editVideo --prompt "make it snow" --duration 6
$H --cli cost removeBackground --duration 5
$H --cli cost upscale --model bytedance_video_upscale --duration 5 --width 1280 --height 720   # Topaz has no estimate
$H --cli cost drawToEdit --prompt "make the jacket red" --duration 5 --set resolution=720p
```

**Done on 2026-10-26** (VALIDATION.md has the results). It settled both open questions: the Draw to Edit sketch goes in `image_references`, and all four Edit Video models take `video_references`. It also found that media are now top-level properties, and that `nano_banana_2` and `soul_2` are stale ids; all fixed. Re-run step A on the Mac only as a sanity check. `$H --cli preview <tool> …` prints the exact request the panel would submit, for free.

If live schemas differ from the bundled fallback (`Sources/HiggsfieldKit/Operations/CatalogSnapshot.swift`), the live one wins at run time. Fix the snapshot too: update `tools/catalog-snapshot-2026-10-26.json` and run `python3 tools/generate_catalog_snapshot.py`.

### B. Paid end-to-end runs (ask first)

Use short clips (3–5 s, 720p) to keep costs low. Show the owner the preflight costs, get one go-ahead, then run:

```sh
$H --cli run generateImage --prompt "product shot on wet stone" --yes
$H --cli run reframe --file clip.mov --set aspect_ratio=9:16 --yes
$H --cli run removeBackground --file clip.mov --yes      # then inspect the output: alpha? codec? container?
$H --cli run upscale --file clip.mov --set resolution=2160p --yes
$H --cli run editVideo --file clip.mov --prompt "make it snow" --yes
$H --cli run drawToEdit --file clip.mov --sketch strokes.png --prompt "make the jacket red" --yes
$H --cli run generateVideo --prompt "slow dolly in on a lighthouse" --yes
```

- `hfcp run` uses the same job runner as the panel and saves results to `~/Movies/Higgsfield/<date>/`.
- For Remove Background, check whether the result carries alpha (`ffprobe -show_streams`, or `mdls`), and whether FCP imports it with transparency. If not, document the closest alternative in PARITY #5.
- A successful run of a tool here is L4 for that tool's request path. Then repeat it in the panel.

### C. Inside Final Cut Pro (L5)

Work through the **Acceptance checklist** at the bottom of `docs/VALIDATION.md`:

- Setup and account: sign in through the CLI session, from both the app and the extension.
- Sources: browser drag with range, linked project with **Use Clip at Playhead / Use Range**, File ▸ Share ▸ Higgsfield.
- All seven tools.
- Returning results: drag to the timeline, and **Add to Final Cut Pro** into the open library with Notes and keywords.
- Persistence: close the extension mid-job and reopen.
- Errors.

Tick the items off in that file as they pass.

### D. Compare with the official plugin

**Compared on 2026-10-26** from the official page, its panel screenshots and its demo video; see PARITY, *Panel layout vs the official plugin*. The official panel is a home screen (recent generations plus an app grid, a floating prompt bar), not a tool strip. The panel has **not** been reworked: that redesign waits for the owner's decision.

### E. Keep the docs honest

After each step, update the following, plainly and concisely, in the style already there:

- `docs/PARITY.md`: levels and "main open item"
- `docs/VALIDATION.md`: move items from *Not yet verified* to verified, with the evidence
- the README *Status* paragraph

## 3. Likely first failures, and where to look

| Symptom | Likely cause | Where |
|---|---|---|
| Extension not in FCP's Extensions menu | Not registered, a stale copy, or a signing problem | `pluginkit` commands above. Info.plist keys in `App/project.yml`: `NSExtensionPointIdentifier com.apple.FinalCut.WorkflowExtension`, `ProExtensionPrincipalViewControllerClass HiggsfieldWorkflowExtensionViewController` (the `@objc` name in `WorkflowExtensionViewController.swift`). |
| Panel says "timeline API unavailable" | SDK not embedded, or the symbol or selector names differ from the real SDK | `ProExtensionHostBridge` in `Sources/HiggsfieldPanel/Platform/FinalCutHost.swift` binds at run time with `dlsym("ProExtensionHostSingleton")` and selectors. Check the names in its doc comment against the SDK headers (`ProExtensionHost.framework/Headers`): `timeline`, `activeSequence`, `sequenceTimeRange`, `playheadTime`, `movePlayheadTo:`, `add/removeTimelineObserver:`, `name`, `startTime`, `duration`, `frameDuration`, `container`, `url`, and the observer callbacks. |
| "Use Higgsfield CLI Session" fails in the extension | The sandbox blocks running `hf`. The designed fallback is for the extension to open `higgsfieldfcp://cli-token`; the container app then runs `hf auth token`, saves the token to the shared store, and writes `cli-status.json`. The extension waits up to about 5½ minutes. | `PanelModel.refreshCLISessionForExtension`, `requestCLITokenFromContainerApp`, and `HiggsfieldCLIBridge` (search paths; the npm shim resolves to `vendor/hf`). Set `HIGGSFIELD_CLI_PATH` to force a binary. |
| Dragging from the FCP browser is ignored, or the file is unreadable | Pasteboard type not offered as expected, or a sandbox read denial | `SourceDropView` in `FinalCutExchange.swift`, the parser in `FCPXMLDocument.swift`. The panel's **Allow…** button saves a security-scoped bookmark. |
| Dragging a result to the timeline does nothing | Pasteboard types or FCPXML rejected | `FCPXMLDragProvider` (offers `com.apple.finalcutpro.xml.v1-10`, the generic type and a file URL), `FCPXMLBuilder.swift`. Save the XML and import it via File ▸ Import ▸ XML to see FCP's error. |
| Add to Final Cut Pro shows the library chooser | No SDK, so no library URL. This is expected without the SDK. | `FinalCutImporter.importIntoEvent`, the `library location` import option. |
| Submit returns 4xx | Parameter names, enums or media roles differ from the live schema | Compare with `hfcp schema <job type>`. `RequestBuilder` in `OperationDraft.swift`, `forcedParameters` in `OperationKind.swift`. |
| Upload never finishes | Media confirm loop | `HiggsfieldClient.uploadMedia` (PUT to presigned URL with the slot's `content_type`, then confirm until `uploaded`; `hfcp upload <file>` tests it for free) |
| No credits or plan in the header | Workspace selection | `hfcp --cli workspaces`; the `hf-workspace-id` header |

**Debugging notes**

- The panel has **no logging yet**. Add `os.Logger(subsystem: "com.ksremedia.HiggsfieldFCP", category: "…")` where you need it, and watch with `log stream --predicate 'subsystem == "com.ksremedia.HiggsfieldFCP"'`.
- To debug the extension, start FCP. In Xcode, choose **Debug ▸ Attach to Process by PID or Name…** and enter `HiggsfieldWorkflowExtension`, waiting for launch. Then open the panel in FCP.
- The container app runs the same panel, which is quicker for UI and API work.

## 4. Architecture

| Piece | What | Key files |
|---|---|---|
| `HiggsfieldKit` (Foundation only; also built and tested on Linux in CI) | API client, auth, schema-driven settings, the seven operations, job runner, FCPXML | `API/HiggsfieldClient.swift` (actor; one refresh on 401; retries), `Auth/TokenProviders.swift`, `Auth/HiggsfieldCLIBridge.swift`, `Schema/ParameterSchema.swift`, `Schema/MediaSlot.swift`, `Operations/OperationKind.swift` (job types per tool, forced params, limits), `Operations/OperationDraft.swift` (`RequestBuilder`), `Operations/ModelCatalog.swift` + `CatalogSnapshot.swift`, `Jobs/JobRunner.swift`, `Jobs/JobRecord.swift`, `FCPXML/*` |
| `HiggsfieldPanel` (macOS) | SwiftUI panel and platform glue | `PanelModel.swift` (all state: auth, drafts, catalog, submit, jobs, sources, timeline), `Platform/FinalCutHost.swift` (timeline bridge), `Platform/FinalCutExchange.swift` (drag in/out, FCP import), `Platform/SharedStorage.swift` (shared folder or App Group; file or Keychain token), `Platform/AVMedia.swift` (probe, trim, frame grab), `Platform/LoopbackSignIn.swift`, `Views/*` |
| `App/HiggsfieldFCP` | Container app: same panel in a floating window, CLI token broker (`higgsfieldfcp://cli-token`), Share inbox | `HiggsfieldFCPApp.swift` |
| `App/HiggsfieldWorkflowExtension` | The `.appex` FCP hosts | `WorkflowExtensionViewController.swift` |
| `App/project.yml`, `App/Config/*.xcconfig` | XcodeGen spec, signing variants (`Signing.xcconfig`, optional `Local.xcconfig`), SDK config | `*-Personal.entitlements` / `*-Shared.entitlements` |
| `hfcp` | Command-line harness using the same client and runner | `Sources/hfcp/main.swift` |
| Tests | Contract tests against CLI captures, auth, schema, operations, jobs, FCPXML (DTD-validated when `FCPXML_DTD` is set), panel tests and snapshots | `Tests/` |

Tool → job types (first available wins; the user can pick others):

| Tool | Job types |
|---|---|
| Generate Video | `seedance_2_0`, `kling3_0`, `veo3_1`, … |
| Generate Image | `nano_banana_flash` ("Nano Banana 2"), `nano_banana_pro`, `gpt_image_2`, … |
| Edit Video | `seedance_2_0`, `kling_video_edit`, `seedance_2_5` (forced `mode: video_edit`), `flux_3_video_edit` |
| Reframe | `reframe` (60 s maximum) |
| Remove Background | `video_background_remover` / `image_background_remover` |
| Upscale | `topaz_video`, `bytedance_video_upscale` / `bytedance_image_upscale` |
| Draw to Edit | `draw_to_video` (source in `video`, sketch in `image_references`) / `nano_banana_flash` with a mask (`is_inpaint`) |

## 5. API essentials

Full details are in `docs/API-CONTRACT.md`. This is Higgsfield's **account API**, the one the CLI, the MCP server and the Adobe plugins use, billed to plan credits. It is not the Cloud API.

- Base `https://fnf-api-gw.higgsfield.ai/fnf/developer/v2alpha`. Headers: `Authorization: Bearer <token>`, `hf-workspace-id`.
- Account: `GET /account/balance`, `GET /account/workspaces` → `{"items":[…]}`.
- Catalog: `GET /job_types?type=video&label=model&label=app&limit=200`, `GET /job_types/{id}` (parameters in `json_schema`).
- Cost: `POST /jobs/{job_type}/cost {"params":…}` → `{credits, credits_exact}`.
- Submit: `POST /{images|videos|audios}/{job_type}/generations {"params":…}` → `{"id"}`.
- Poll: `GET /jobs/{id}` → `{status, result_url, min_result_url}`.
- Upload: `POST /media?type=&extension=` → PUT to the presigned URL with Content-Type = the slot's `content_type` (signed; anything else is a 403) → `POST /media/{id}/confirm?type=` until `status: "uploaded"`.
- Media in params (live schemas, 2026-10-26): top-level properties, e.g. `"video":{"id","type"}` or `"video_references":[{"id","type"}]`, with `type` one of `video_input|media_input|video_job|image_job`. Older schemas used `"medias":[{"data":{…},"role":…}]`; the app supports both and follows the schema.
- **There is no cancel endpoint.** *Stop Tracking* only stops polling; the job still runs and is billed.

## 6. Decisions to keep (and why)

- **No timeline editing API in FCP.** Results come back by FCPXML drag (inserted at the drop point) or by the Open Document import. Sources arrive by browser drag (range kept), a linked project plus the playhead, or the Share destination. Details: `docs/FCP-INTEGRATION.md`.
- **Runtime binding to ProExtensionHost** keeps the project buildable without the SDK (CI has none).
- **One persistent JobRunner per panel.** Reconnecting swaps the client in place, and in-flight uploads are never marked failed. This prevents double polling and double charges.
- **Submissions retry only on 408/429/503**, never on 500, since a 500 could mean the job was created and a retry would charge twice.
- **Separate files per process** (`jobs-app.json` / `jobs-extension.json`, settings, drafts), so the app and the extension never poll or overwrite each other's jobs.
- **Results go to `~/Movies/Higgsfield/<date>/`**, because FCP can't read the sandboxed extension's container.
- **Shared storage.** Personal: `~/Library/Application Support/HiggsfieldFCP/`, with a 0600 token file. Paid team: the App Group plus Keychain. The extension has temporary-exception entitlements for that folder, the CLI login folders, `/Volumes` and home (read-only), and `/opt/homebrew` and `/usr/local`.
- **Aspect defaults.** Reframe 9:16. Generate tools 16:9 or auto. Processing tools keep the source shape (`auto`). No invented defaults (21:9 was a bug).
- **Edit tools take their duration from the source**, so no default duration is seeded.
- **FCPXML 1.10.** Uses predefined format names where possible, frame-conformed durations, `uid = <bundle id>.<job id>` so re-imports relink, and the prompt, model, settings and job ID in Notes, with keywords "Higgsfield" and the tool name.
- **CLI shim.** The npm `hf` shim is resolved to the native `vendor/hf` binary, so an app launched from Finder doesn't need `node`. PATH is augmented for the child process, and its output pipes are drained while it runs.

## 7. CI

The workflow is `.github/workflows/ci.yml`:

- **core-linux**: Swift 5.10 `swift test` for HiggsfieldKit, with DTD validation.
- **macos** (macOS 15):
  - `swift test` and `swift build`
  - `xcodegen` and `xcodebuild` (unsigned), then a check of the bundle layout and Info.plist keys
  - a second build with `Local.xcconfig.example`, ad-hoc signed, checking the embedded App Group and Keychain entitlements
  - panel snapshots published to `ci/panel-snapshots`
- **live-api**: manual (workflow_dispatch). It runs read-only `hfcp` commands and needs the repo secret `HIGGSFIELD_ACCESS_TOKEN` (from `hf auth token`; it expires). On the Mac, the same checks run locally (step A), which is simpler.

Keep `HiggsfieldKit` free of Apple-only APIs so the Linux job keeps passing. macOS-only code lives in `HiggsfieldPanel` under `#if os(macOS)`. To refresh `docs/screenshots`, run `PANEL_SNAPSHOTS=/tmp/snaps swift test --filter testRenderPanelSnapshots` and copy the PNGs over.

## 8. Other open items

- **Built-in "Sign in with Higgsfield"** needs an OAuth client ID issued by Higgsfield. Until then, use the CLI session or a pasted token.
- **Premiere features out of reach:** inserting or replacing on the timeline programmatically (FCP has no API for it), "upscale on export", 8K upscale (no 8K job type found), and the After Effects variant. See the end of `docs/PARITY.md`.
