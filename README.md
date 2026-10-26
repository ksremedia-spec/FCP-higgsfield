# Higgsfield for Final Cut Pro

A Final Cut Pro edition of the [Higgsfield Premiere Pro plugin](https://higgsfield.ai/plugins/premiere-pro). It is a compact panel inside Final Cut Pro with the same seven AI tools, running on your Higgsfield account and plan credits:

**Generate Video · Generate Image · Edit Video · Reframe · Remove Background · Upscale · Draw to Edit**

<p><img src="docs/screenshots/02-generate-video.png" width="260" alt="Generate Video"> <img src="docs/screenshots/05-reframe.png" width="260" alt="Reframe"> <img src="docs/screenshots/08-draw-to-edit.png" width="260" alt="Draw to Edit"></p>

<sub>Rendered offscreen on macOS CI (`PanelTests.testRenderPanelSnapshots`); all screens are in [docs/screenshots](docs/screenshots).</sub>

## Workflow

1. **Open** Higgsfield from the Extensions button in Final Cut Pro's toolbar, or **Window ▸ Extensions ▸ Higgsfield**.
2. **Bring in footage.** Drag a clip from the FCP browser (a selected range is kept), or drag your project once and click **Use Clip at Playhead / Use Range**. Use **File ▸ Share ▸ Higgsfield** for rendered timelines.
3. **Configure.** Write a prompt, pick a model, and adjust the settings, which come from Higgsfield's live model catalog. The credit estimate shows on the button.
4. **Generate** (⌘↩). Activity shows each job's progress and a preview. Several jobs can run at once, and they survive closing the panel.
5. **Bring it back.** Drag the result onto the timeline, where it lands at the drop point, or click **Add to Final Cut Pro** (or turn on auto-add) to import it straight into the open library. Prompt, model and job ID go in the clip's Notes.

Details on each feature and how it maps to Premiere are in **[docs/PARITY.md](docs/PARITY.md)**.

## Status

The code is complete for all seven tools. It is built and tested in CI on macOS (app and Final Cut Pro extension) and Linux (core library). The FCPXML validates against Apple's DTD.

On 2026-10-26 the free parts ran against the live Higgsfield API through this app's own client: sign-in through the official CLI session, balance, catalog, every tool's schema and every tool's cost estimate. That run found that Higgsfield now takes media as top-level properties, a wrong Draw to Edit sketch slot, stale model ids and incomplete estimates; all are fixed, and every tool's request now matches what the official CLI 1.2.2 sends today.

**Not yet done:** a paid generation per tool (needs your go-ahead), and anything inside Final Cut Pro (needs the Mac). The official panel also uses a different layout (a home screen with recent generations and an app grid); that redesign is waiting on a decision. [docs/VALIDATION.md](docs/VALIDATION.md) lists exactly what is verified and how to close the remaining gaps.

## Build and install (personal setup)

Requirements: macOS 13+, Xcode 15+, [XcodeGen](https://github.com/yonaskolb/XcodeGen), Final Cut Pro 10.6+, and a free Apple ID in Xcode. No paid developer account is needed; if you have one, see [Paid developer team](#paid-developer-team-optional) for a few extras.

```sh
brew install xcodegen
scripts/configure-workflow-sdk.sh        # optional: enables live playhead/range if Apple's Workflow Extension SDK is installed
xcodegen generate --spec App/project.yml
open App/HiggsfieldFCP.xcodeproj
```

1. In Xcode, select each of the two targets (**HiggsfieldFCP** and **HiggsfieldWorkflowExtension**). Under **Signing & Capabilities**, pick your Apple ID; *Personal Team* is fine. No extra capabilities are needed. (`xcodegen generate` resets this choice; `Local.xcconfig`, below, keeps it.)
2. Build the **HiggsfieldFCP** scheme (⌘B), choose **Product ▸ Show Build Folder in Finder**, and copy *Higgsfield for Final Cut Pro.app* to `/Applications`.
3. Launch it once. That registers the extension with Final Cut Pro.

### Paid developer team (optional)

The setup above is complete on its own. A paid team adds:

- **Signing that survives `xcodegen generate`.** Your Team ID lives in a git-ignored config file rather than the generated project.
- **The sign-in token in the Keychain**, instead of a private file, and an **App Group** container shared by the app and the extension, instead of a folder in Application Support.

```sh
cp App/Config/Local.xcconfig.example App/Config/Local.xcconfig
open -e App/Config/Local.xcconfig     # set HIGGSFIELD_TEAM_ID
```

Your Team ID is under **Membership details** at [developer.apple.com/account](https://developer.apple.com/account). Build as usual; skip step 1 above. Xcode registers the App Group and the Keychain group when it signs.

On first launch the panel moves your job history, settings and sign-in from the personal folder into the App Group, so you don't sign in again. To go back, delete `Local.xcconfig` and sign in again.

If Xcode says the bundle identifier isn't available to your team, for example because your free Personal Team registered it earlier, set `HIGGSFIELD_BUNDLE_ID_PREFIX` in the same file (e.g. `com.yourname`).

Developer ID signing and notarisation aren't needed. They only matter for running the app on other people's Macs.

### Signing in

Install the official Higgsfield CLI once:

```sh
npm install -g @higgsfield/cli
```

Then click **Use Higgsfield CLI Session** in the panel. If the CLI isn't signed in yet, it opens Higgsfield's sign-in page in your browser. After that the panel reuses the CLI's login, and the CLI renews it as needed.

You can also paste an access token from `hf auth token`. A built-in "Sign in with Higgsfield" button exists in the code, but it needs an OAuth client ID that only Higgsfield can issue, so it stays hidden.

### Where things live

| What | Where |
|---|---|
| Generated and processed media | `~/Movies/Higgsfield/<date>/` (Final Cut Pro imports from here) |
| Job history, settings, the sign-in token | `~/Library/Application Support/HiggsfieldFCP/` (the token is a private file, readable only by you, the same way the CLI keeps its own login). With a paid team: the App Group container `~/Library/Group Containers/<Team ID>.com.ksremedia.HiggsfieldFCP/`, and the token in the Keychain. |
| Renders from **File ▸ Share ▸ Higgsfield** | the `Inbox` folder inside the above |

### Share destination (rendered timelines)

In Final Cut Pro, go to **File ▸ Share ▸ Add Destination**, add **Export File**, name it "Higgsfield", and set *Open with* to *Higgsfield for Final Cut Pro*.

## Repository layout

| Path | Contents |
|---|---|
| `Sources/HiggsfieldKit` | Foundation-only core: Higgsfield account API client, auth (OAuth PKCE, CLI bridge), JSON-schema model settings, the seven operations, job runner, FCPXML parse/build, timeline resolver |
| `Sources/HiggsfieldPanel` | SwiftUI panel, AVFoundation media helpers, credential storage, FCP host bridge, drag and drop, FCP import |
| `App/` | XcodeGen spec, container app, Final Cut Pro workflow extension |
| `Sources/hfcp` | Command-line harness for validating against the live API |
| `Tests/` | Contract, operation, job, FCPXML and panel tests |
| `docs/` | [HANDOFF](docs/HANDOFF.md) (start here when continuing on a Mac), [PARITY](docs/PARITY.md), [VALIDATION](docs/VALIDATION.md), [API-CONTRACT](docs/API-CONTRACT.md), [FCP-INTEGRATION](docs/FCP-INTEGRATION.md), [RESEARCH](docs/RESEARCH.md) |
| `tools/` | Catalog snapshot and generator, DTD fetcher |

## Notes

- Results are saved to `~/Movies/Higgsfield/<date>/`, where Final Cut Pro can import them.
- Higgsfield's account API has no cancel endpoint. *Stop Tracking* stops waiting locally; the job still completes and is billed.
