# Research notes

## Access limits during this build

The build ran in a sandbox whose network policy **blocks `higgsfield.ai` and all its subdomains**, as well as YouTube, X/Twitter and most blogs. That ruled out:

- loading <https://higgsfield.ai/plugins/premiere-pro> directly or viewing its screenshots and demo video
- calling the Higgsfield API from the build machine

What was reachable:

| Source | Used for |
|---|---|
| Web search (extracts of pages, including the official plugin page, Higgsfield blog and help centre) | Premiere plugin behaviour |
| npm and PyPI | Official Higgsfield packages: `@higgsfield/cli`, `@higgsfield/client`, `higgsfield-client` |
| GitHub releases | Official CLI binary `hf` 1.2.2 (checksum-verified against the npm package) |
| Official Higgsfield MCP server (connected to this session's account) | Live read-only backend checks: balance, catalog, cost preflights |
| developer.apple.com | Workflow Extensions, timeline API, FCPXML reference and DTD |

**Recommended follow-up:** compare this edition side by side with the official page and demo video and update [PARITY.md](PARITY.md) where the panel layout differs. Exact panel layout, labels and progress UI were not visible.

## Premiere Pro plugin: established behaviour

| Fact | Confidence | Source |
|---|---|---|
| Tools: Generate AI Video, Generate AI Image, Reframe, Remove Background, Upscale, Draw to Edit, Edit Video | High | Official plugin page (search extract); Higgsfield blog "Higgsfield Inside Adobe After Effects" |
| One installer for Premiere Pro and After Effects; opens from **Window ▸ Extensions ▸ Higgsfield** | High | Official page; phantomeditor.video; creatorstoolbox.com |
| Reframe: "Crop any clip to 9:16, 16:9, 4:3, 3:4, 21:9, or 1:1 with one click. Smart subject tracking keeps the focal point perfectly centered." | High (quoted) | Official page |
| Remove Background: "AI detects subjects with pixel-level precision"; no green screen, alpha for compositing | High | Official page |
| Draw to Edit: "Remove unwanted objects, add new elements, or replace entire areas with a single brush stroke"; users "circle the area you want to change" | High / Medium | Official page; user posts on X |
| Upscale "to 4K/8K"; Higgsfield's own post: "Upscale to 4K on export" | Medium (sources differ) | Third-party listings; Higgsfield X post |
| Edit Video "takes a clip already sitting on your timeline and runs a prompt-based AI pass on it in place" | Medium | headsupai.io, grainzilla.com |
| Edit Video limits: clip under 30 s to sync, only the first 15 s from its start are edited, many edits need ≥ 4 s | Medium (one tutorial each) | creativepadmedia.com, phantomeditor.video |
| Models featured: Seedance 2.0; Kling 3.0 in one walkthrough | Medium | Tutorials |
| Sign in to your Higgsfield account from the panel; processing runs on Higgsfield's servers (internet required) | High | Higgsfield documentation via search; tutorials |
| Uses the user's existing **plan credits**, "the same as MCP and CLI"; unlimited/free generations apply only on higgsfield.ai | High | Higgsfield help centre "External integrations" |
| Generated media can be dragged onto the timeline; "results drop straight into your Adobe timeline" | Medium | User posts; marketing |
| Failed runs may still cost credits | Low (one write-up) | phantomeditor.video |
| Host versions: Premiere Pro / After Effects 2025 (25.0)+ vs 2024+ | Conflicting | Official page vs third-party |

Not found: the model dropdown's contents, progress and history UI, whether results also land in a project bin, and how errors are shown.

## Higgsfield backend: established behaviour

- The plugins, CLI and MCP share the **account API** (`fnf-api-gw.higgsfield.ai/fnf/developer/v2alpha`). The full contract and capture method are in [API-CONTRACT.md](API-CONTRACT.md).
- Job types behind the plugin's tools, from the live catalog and MCP tool definitions:

| Plugin tool | Job type(s) |
|---|---|
| Reframe | `reframe` (6 ratios; 480p/720p/1080p; ≤ 60 s; duration and resolution required > 15 s) |
| Remove Background | `video_background_remover`, `image_background_remover` (the MCP tool picks by media type); `sam_3_video` is also listed as "Remove Background" |
| Upscale | `topaz_video` (1080p/2160p), `bytedance_video_upscale` (1080p/2k/4k, presets, fps 24–60), `bytedance_image_upscale` (2k/4k), `topaz_image` |
| Draw to Edit | `draw_to_video` workflow (CLI help: `--video … --sketch frame.png --prompt …`) |
| Edit Video | Seedance 2.0 with video references; `kling_video_edit` (Kling 3.0 Omni Edit); Seedance 2.5 `mode: video_edit`; `flux_3_video_edit` |
| Generate Video / Image | Catalog models: 58 video and 40+ image job types on 2026-10-26 |

- Live checks (official MCP, this account):
  - `balance` → 854.14 credits, plan "plus"
  - reframe preflight → 123 credits (10 s, 1080p) and 140 credits (30 s, 720p)
  - image upscale preflight requires an uploaded image

## Final Cut Pro platform

Summarised in [FCP-INTEGRATION.md](FCP-INTEGRATION.md), from Apple's documentation:

- Designing and building workflow extensions; Info.plist keys; `ProExtensionAttributes`
- `ProExtensionHost`: `FCPXHost`, `FCPXTimeline`, `FCPXSequence`, `FCPXLibrary.url`, observer. The Objective-C selectors were read from the docs' Objective-C variants.
- Drag and drop to and from FCP: versioned pasteboard types and the promise pattern
- Open Document Apple event and the `library location` import option
- Custom share destinations
- FCPXML 1.10 reference and DTD (used for validation)
