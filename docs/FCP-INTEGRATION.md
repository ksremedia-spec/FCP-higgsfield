# Final Cut Pro integration

This document covers how the panel connects to Final Cut Pro, what Final Cut Pro allows, and where that differs from Premiere Pro.

Sources are Apple's *Professional Video Applications* documentation (developer.apple.com): Workflow Extensions, Interacting with the Final Cut Pro Timeline, Content and Metadata Exchanges, and the FCPXML Reference / DTD 1.10.

## Pieces

| Component | What it is | Where |
|---|---|---|
| **Workflow extension** | `.appex` that Final Cut Pro hosts in a floating window. Opened from the Extensions button in the FCP toolbar or **Window ▸ Extensions ▸ Higgsfield**. Runs the panel. | `App/HiggsfieldWorkflowExtension`, Info.plist keys in `App/project.yml` |
| **Container app** | *Higgsfield for Final Cut Pro.app*. Required by Apple to deliver the extension. It also runs the same panel as a floating window, brokers the Higgsfield CLI session for the sandboxed extension, and receives renders from FCP's Share menu. | `App/HiggsfieldFCP` |
| **HiggsfieldPanel** | The SwiftUI panel shared by both | `Sources/HiggsfieldPanel` |
| **HiggsfieldKit** | Higgsfield API client, operations, FCPXML, jobs (Foundation only) | `Sources/HiggsfieldKit` |

## What a workflow extension can and cannot do

Apple's timeline interface (`ProExtensionHost`) gives an extension:

- the **active sequence**: name, start, duration, frame duration, timecode format
- its containers: **project → event → library**, including `FCPXLibrary.url`
- the **playhead** time (`playheadTime()`), with `movePlayhead(to:)`
- the **selected time range** (`sequenceTimeRange`)
- change notifications (`FCPXTimelineObserver`)

It **does not** give the selected clips, their media files, or any way to edit the timeline. Media moves only through FCPXML:

- **drag and drop**, in both directions
- the **Open Document** Apple event, sending FCPXML to FCP
- a **custom share destination**, receiving renders in the container app. Apple: "a workflow extension cannot receive rendered media directly from Final Cut Pro".

Each Premiere workflow therefore maps to the closest supported mechanism.

## Getting source footage into the panel

| Path | How | What arrives |
|---|---|---|
| **Drag from the FCP browser** (primary) | Drag a clip, or a range selected in the browser, onto the source well. | FCPXML (`com.apple.finalcutpro.xml.v1-x`). The panel resolves `asset/media-rep@src` to the original media file and maps the clip's `start`/`duration` to file-relative In/Out points, removing timecode starts. Only the selected range is trimmed and uploaded. |
| **Link the timeline, then "Use Clip at Playhead" / "Use Range"** | Drag the project from the browser once. Afterwards the panel reads the live playhead or selected range from `ProExtensionHost` and finds the topmost video clip there in the project's spine, including connected clips and `<clip><video>` wrappers. | Source file plus the exact source range under the playhead or range. This is the closest equivalent to Premiere's "edit the clip on the timeline". |
| **File ▸ Share ▸ Higgsfield** | One-time setup: **File ▸ Share ▸ Add Destination ▸ Export File**, name it "Higgsfield", and under *Open with* choose *Higgsfield for Final Cut Pro*. Sharing a project or range renders it, and FCP opens the file with the container app, which places it in the shared inbox. | A rendered movie of the timeline range, with effects, titles and compounds flattened. Use it for compound clips, multicam, or anything with effects applied. |
| **Finder / Open panel** | Drop or choose a file. | Any movie or image. |
| **Earlier Higgsfield result** | Choose "Use In ▸ …" on a finished job. | The job output is referenced by id (`video_job`/`image_job`) without re-uploading. |

Unsupported in browser drags: compound clips (`ref-clip`), multicam (`mc-clip`), auditions and audio-only clips. The panel says so and points to the Share path.

### Sandbox note

The extension must be sandboxed, and an FCPXML drag carries paths, not sandbox extensions. As a personal tool it declares temporary exceptions for:

- read-only: `/Volumes/` and the home folder (source media), and `/opt/homebrew/` and `/usr/local/` (the Higgsfield CLI)
- read-write: `~/Library/Application Support/HiggsfieldFCP/` (shared with the container app) and the CLI's own login folder

If a file still can't be read, the panel shows **Allow…**, which opens a folder chooser and remembers your grant as a security-scoped bookmark.

### Sharing between the app and the extension

Both processes use `~/Library/Application Support/HiggsfieldFCP/` for job history, settings, the Share inbox, and the sign-in token (a private 0600 file). That works with free personal signing.

With a paid developer team, `App/Config/Local.xcconfig` (copied from `Local.xcconfig.example`) switches both targets to the *Shared* entitlements:

- an App Group container, `<Team ID>.com.ksremedia.HiggsfieldFCP`, replaces the folder
- a Keychain access group, `<Team ID>.com.ksremedia.HiggsfieldFCP.shared`, holds the sign-in token

On first launch the panel copies job history, settings and drafts into the group container and moves the sign-in there, then into the Keychain. If the Keychain entitlement is missing at run time, it falls back to the private file. The entitlements are committed per variant (`*-Personal.entitlements`, `*-Shared.entitlements`), and `CODE_SIGN_ENTITLEMENTS` picks one through `HIGGSFIELD_ENTITLEMENTS_VARIANT` (`App/Config/Signing.xcconfig`).

## Returning results to Final Cut Pro

| Path | How | Where it lands |
|---|---|---|
| **Drag to the timeline** (primary) | Drag the result's thumbnail from Activity onto the FCP timeline or browser. | The extension writes an `NSPasteboardItem` whose data provider supplies FCPXML 1.10 for `com.apple.finalcutpro.xml.v1-10` and `com.apple.finalcutpro.xml` (Apple's documented promise pattern), plus a file URL. Apple: clips dropped on the timeline are added to the project's event and **inserted where they're dropped**. |
| **Add to Final Cut Pro** | One click per job, or automatic when *Add Results to Final Cut Pro Automatically* is on. | FCPXML with an `<event name="Higgsfield AI">` is opened in FCP through the Open Document event (`NSWorkspace.open(_:withApplicationAt:)`). The `library location` import option is set from `FCPXLibrary.url` of the open timeline, so it **goes straight into the current library without the library chooser**. |

Each imported clip carries:

- the job's prompt, model, settings and job ID in the clip **Notes**
- keywords "Higgsfield" and the tool name, so a Keyword Collection gathers all AI clips
- a stable `uid` (`<bundle id>.<job id>`), so re-importing relinks rather than duplicating

Formats use FCP's predefined names when they match, for example `FFVideoFormat1080p2398`. Vertical and other custom sizes use explicit `width`/`height`/`frameDuration`, and durations are conformed to whole frames.

Results are saved to `~/Movies/Higgsfield/<date>/` (Movies-folder entitlement). FCP can't read other apps' containers, so files must live somewhere it can reach.

**Not possible:** inserting at the playhead programmatically or replacing a clip in place. FCP exposes no editing API to extensions. Premiere's plugin can call Premiere's scripting API; in FCP the result has to be dropped or connected by the editor, for example with the import above followed by **Q**/**W**/**E**.

## Workflow Extension SDK

Apple distributes `ProExtensionHost.framework` with the Workflow Extension SDK, which is a developer download.

- The project builds without it, as CI does. `ProExtensionHostBridge` binds to `ProExtensionHostSingleton()` and the documented selectors at run time with `dlsym` and Objective-C messaging.
- With the SDK installed, run `scripts/configure-workflow-sdk.sh` before building. It generates `App/Config/ProExtensionHost.local.xcconfig`, which weak-links the framework, and the post-build phase embeds it into the extension. This matches Apple's template setup, where the framework is present at extension startup.
- Without the framework the panel still works, including drag in/out, but shows no live playhead or range and can't target the open library automatically. FCP then asks which library to import into.

## Install and enable (per Apple)

1. Build the scheme `HiggsfieldFCP`: run `xcodegen generate --spec App/project.yml`, then open `App/HiggsfieldFCP.xcodeproj`. Sign both targets with your Apple ID (Personal Team is fine), or put a paid Team ID in `App/Config/Local.xcconfig`.
2. Copy *Higgsfield for Final Cut Pro.app* to `/Applications` and launch it once. This registers the extension.
3. In Final Cut Pro: Extensions button in the toolbar, or **Window ▸ Extensions ▸ Higgsfield**.
