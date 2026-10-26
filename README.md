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

The code is complete for all seven tools. It is built and tested in CI on macOS (app and Final Cut Pro extension) and Linux (core library). The Higgsfield requests match those of Higgsfield's official CLI, and the FCPXML validates against Apple's DTD.

It has **not yet been run against the live Higgsfield API through this app, or inside Final Cut Pro**. The build environment had neither network access to Higgsfield nor a Mac. [docs/VALIDATION.md](docs/VALIDATION.md) lists exactly what is verified and gives a checklist plus an opt-in CI job to close the remaining gaps.

## Build

Requirements: macOS 13+, Xcode 15+, [XcodeGen](https://github.com/yonaskolb/XcodeGen), Final Cut Pro 10.6+.

```sh
brew install xcodegen
scripts/configure-workflow-sdk.sh        # optional: links Apple's Workflow Extension SDK if installed
xcodegen generate --spec App/project.yml
open App/HiggsfieldFCP.xcodeproj         # set your Team, build "HiggsfieldFCP"
```

Copy *Higgsfield for Final Cut Pro.app* to `/Applications` and launch it once to register the extension.

### Signing in

- **Higgsfield CLI session.** Works today. Run `npm install -g @higgsfield/cli` once; the panel uses `hf auth token` (and `hf auth login` when needed).
- **Sign in with Higgsfield.** Built-in OAuth. It needs a client ID issued by Higgsfield: set `HIGGSFIELD_OAUTH_CLIENT_ID` in `App/project.yml`.
- **Access token.** Paste one.

### Share destination (rendered timelines)

In Final Cut Pro, go to **File ▸ Share ▸ Add Destination**, add **Export File**, name it "Higgsfield", and set *Open with* to *Higgsfield for Final Cut Pro*.

## Repository layout

| Path | Contents |
|---|---|
| `Sources/HiggsfieldKit` | Foundation-only core: Higgsfield account API client, auth (OAuth PKCE, CLI bridge), JSON-schema model settings, the seven operations, job runner, FCPXML parse/build, timeline resolver |
| `Sources/HiggsfieldPanel` | SwiftUI panel, AVFoundation media helpers, Keychain, FCP host bridge, drag and drop, FCP import |
| `App/` | XcodeGen spec, container app, Final Cut Pro workflow extension |
| `Sources/hfcp` | Command-line harness for validating against the live API |
| `Tests/` | Contract, operation, job, FCPXML and panel tests |
| `docs/` | [PARITY](docs/PARITY.md), [VALIDATION](docs/VALIDATION.md), [API-CONTRACT](docs/API-CONTRACT.md), [FCP-INTEGRATION](docs/FCP-INTEGRATION.md), [RESEARCH](docs/RESEARCH.md) |
| `tools/` | Catalog snapshot and generator, DTD fetcher |

## Notes

- Results are saved to `~/Movies/Higgsfield/<date>/`, where Final Cut Pro can import them.
- Higgsfield's account API has no cancel endpoint. *Stop Tracking* stops waiting locally; the job still completes and is billed.
- "Higgsfield" is a trademark of its owner. Distributing this app under that name or with Higgsfield branding requires Higgsfield's permission.
