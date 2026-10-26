# Higgsfield for Final Cut Pro

A personal Final Cut Pro edition of the Higgsfield Premiere Pro plugin: a workflow extension plus a container app that share one SwiftUI panel.

**Start with [docs/HANDOFF.md](docs/HANDOFF.md).** It has the current state, the remaining verification plan, likely failure points and the architecture.

## Rules

- Strict parity with the official Premiere plugin. Never mark a feature complete because its UI exists: raise levels in `docs/PARITY.md` only with live (L4) or in-FCP (L5) evidence, and record that evidence in `docs/VALIDATION.md`.
- Never spend Higgsfield credits without the owner's go-ahead. `hfcp` balance, workspaces, catalog, schema and cost are free; `hfcp run` and Generate in the panel are paid.
- Never reuse the official Higgsfield CLI's OAuth client ID.
- Personal tool: no distribution or notarisation work. No PR unless asked; work on `claude/fcp-edition`.
- Keep `Sources/HiggsfieldKit` Foundation-only (it is tested on Linux in CI).

## Commands

```sh
swift test                                    # all tests
swift build -c release --product hfcp         # live API harness; use --cli to reuse the `hf` session
xcodegen generate --spec App/project.yml
xcodebuild -project App/HiggsfieldFCP.xcodeproj -scheme HiggsfieldFCP -configuration Debug \
  -derivedDataPath build/DerivedData -allowProvisioningUpdates build
pluginkit -mAvvv -p com.apple.FinalCut.WorkflowExtension
```
