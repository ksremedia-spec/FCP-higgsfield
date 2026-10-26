# Higgsfield account API contract

This is the API the Final Cut Pro edition calls, and how each detail was established.

## Which API, and why

Higgsfield exposes two different HTTP APIs:

| | **Account ("plan credits") API** — used here | Higgsfield Cloud API |
|---|---|---|
| Base URL | `https://fnf-api-gw.higgsfield.ai/fnf/developer/v2alpha` | `https://api.higgsfield.ai` |
| Auth | User sign-in: OAuth 2.0 + PKCE (Clerk), `Authorization: Bearer <token>` | API key pair, `Authorization: Key <id>:<secret>` |
| Billing | The user's Higgsfield plan credits | Cloud API credits |
| Used by | Official Higgsfield CLI (`@higgsfield/cli`), the Higgsfield MCP server, and — per Higgsfield's help centre — the Adobe plugins ("all of them use your existing Higgsfield plan credits, the same as MCP and CLI") | Official SDKs `higgsfield-client` (Python) and `@higgsfield/client` (Node) |
| Editing tools | `reframe`, `draw_to_video`, `video_background_remover`, `image_background_remover`, `topaz_video`, `bytedance_video_upscale`, `kling_video_edit`, … | Generation models; no documented reframe/background/upscale endpoints found |

The Premiere Pro plugin signs in with the user's Higgsfield account and spends plan credits. To match that, this product uses the **account API**.

## How the contract was captured

The account API has no public reference documentation. Every endpoint, header and body below was observed from the official client:

1. Downloaded the official CLI release `hf_1.2.2_linux_amd64.tar.gz` from `github.com/higgsfield-ai/cli/releases`. Its SHA-256 (`6a642f61…bb51`) matches the checksum published inside the npm package `@higgsfield/cli@1.2.2`.
2. Ran it with `HTTPS_PROXY` pointed at a local `mitmproxy`, which logged each request and answered with mock responses. Nothing reached Higgsfield's servers and no credits were spent.
3. Iterated the mock responses until the CLI parsed them. That fixed the response fields the CLI reads, as well as the request shapes.
4. Cross-checked live, read-only, through the official Higgsfield MCP server (same backend):
   - `balance` → `{"credits":854.14,"subscription_plan_type":"plus"}`
   - reframe cost preflight → `{"cost":{"credits":123,"credits_exact":123}}` (10 s, 1080p) and `140` (30 s, 720p)
   - the job-type catalog (`models_explore`)

The test suite (`Tests/HiggsfieldKitTests/ClientContractTests.swift`, `AuthTests.swift`) asserts that the Swift client produces the same requests the CLI produced.

## Sign-in (OAuth 2.0 authorization code + PKCE)

Captured from `hf auth login`:

```
GET https://clerk.higgsfield.ai/oauth/authorize
    ?client_id=<client id>
    &code_challenge=<base64url(sha256(verifier))>
    &code_challenge_method=S256
    &redirect_uri=http://localhost:8765/callback
    &response_type=code
    &scope=email profile offline_access user:org:read
    &state=<random>

POST https://clerk.higgsfield.ai/oauth/token
Content-Type: application/x-www-form-urlencoded
client_id=<client id>&code=<code>&code_verifier=<verifier>&grant_type=authorization_code&redirect_uri=http%3A%2F%2Flocalhost%3A8765%2Fcallback
→ {"access_token","token_type":"Bearer","expires_in","refresh_token","scope"}
```

Refresh, captured from `hf auth token` with an expired session:

```
POST https://clerk.higgsfield.ai/oauth/token
client_id=<client id>&grant_type=refresh_token&refresh_token=<refresh token>
```

The CLI's own `client_id` is **not** reused. That would impersonate the official CLI. The app signs in in one of three ways:

- **Its own OAuth client** (`HiggsfieldOAuthClientID` build setting). Higgsfield has to issue this client ID.
- **The official CLI's session.** The app runs `hf auth token`, a documented command that prints the current token and refreshes it when expired (verified above).
- **A pasted access token.**

## Workspace

`GET /account/workspaces` → `{"items":[{"id","name","credits",…}]}`

Every subsequent request carries `hf-workspace-id: <id>`. The CLI refuses most commands until a workspace is selected.

## Account

`GET /account/balance` → `{"credits":854.14,"subscription_plan_type":"plus","email":"…"}`

## Catalog

```
GET /job_types?type=video&label=model&label=app&limit=200   # models
GET /job_types?label=chain&limit=200                         # workflows (reframe, draw_to_video, …)
GET /job_types/{job_type}
→ {"items":[{"job_type":"reframe","type":"video","json_schema":{…JSON Schema of params…}}]}
```

The CLI accepted the catalog only when parameters were in `json_schema`, a JSON Schema object (`properties`, `enum`, `minimum`, …). The panel builds its settings UI from this schema at runtime and falls back to a bundled snapshot dated 2026-10-26 (`tools/catalog-snapshot-2026-10-26.json`).

## Media upload

```
POST /media?type=video&extension=mp4            (no body)
→ {"id":"<media id>","upload_url":"<presigned URL>"}

PUT <presigned URL>                             (raw bytes, empty Content-Type, no Authorization)

POST /media/{id}/confirm?type=video             (no body)
→ {"id":"<media id>","status":"uploaded"}       # only "uploaded" is accepted as usable
```

`type` is `image`, `video` or `audio`.

## Submitting a job

```
POST /{images|videos|audios}/{job_type}/generations
{"params": {...}}
→ {"id":"<job id>"}
```

**Media layout (live schemas, checked 2026-10-26).** Each media input is a top-level property of `params`, named by the job type's schema: a single object (`video`, `start_image`, `end_image`, `ref_image`, `mask`) or an array (`video_references`, `image_references`, `audio_references`). The official CLI 1.2.2 sends them that way:

```json
// hf generate create draw_to_video --prompt "make the jacket red" --video <id> --image-references <sketch id> --duration 5 --resolution 720p
{"params":{"duration":5,"image_references":[{"id":"2222…","type":"media_input"}],"prompt":"make the jacket red","resolution":"720p","video":{"id":"1111…","type":"video_input"}}}

// hf generate create reframe --video-references <id> --aspect_ratio 9:16
{"params":{"aspect_ratio":"9:16","video_references":[{"id":"1111…","type":"video_input"}]}}

// hf generate create nano_banana_flash --prompt "make it red" --image-references <id> --mask '{"id":…}' --is_inpaint true
{"params":{"image_references":[{"id":"2222…","type":"media_input"}],"is_inpaint":true,"mask":{"id":"3333…","type":"media_input"},"prompt":"make it red"}}
```

These were recorded through a local proxy that answered every request itself; nothing reached Higgsfield. The app reads which properties a job type has from its live schema and builds the same bodies (`LiveLayoutContractTests`).

**Earlier layout.** The first captures (below) used a `params.medias` array, `{"data": {"id": "<uuid>", "type": "video_input"}, "role": "video"}`. The app still uses it for a schema that declares `medias`.

| `data.type` | Meaning (observed) |
|---|---|
| `video_input` | uploaded video |
| `media_input` | uploaded image |
| `video_job` / `image_job` | output of an earlier job (no re-upload) |

Earlier captured bodies (`medias` layout):

```json
// hf generate workflow reframe --video <uploaded id> --aspect-ratio 9:16
{"params":{"aspect_ratio":"9:16","medias":[{"data":{"id":"5555…","type":"video_input"},"role":"video"}]}}

// hf generate create seedance_2_0 --prompt "neon city" --duration 5 --video <id> --aspect-ratio 16:9
{"params":{"aspect_ratio":"16:9","duration":5,"medias":[{"data":{"id":"5555…","type":"video_input"},"role":"video"}],"prompt":"neon city"}}

// hf generate create nano_banana_2 --prompt "add a hat" --image <id> --aspect-ratio 16:9   → POST /images/nano_banana_2/generations
{"params":{"aspect_ratio":"16:9","medias":[{"data":{"id":"8888…","type":"media_input"},"role":"image"}],"prompt":"add a hat"}}
```

**Media role names differ per job type.** The CLI turned flag names into roles when the schema didn't constrain them, so the captures alone don't fix each job type's roles. The panel reads the roles from the live `json_schema` (`MediaSlot` → first accepted candidate). Known role sets:

- `reframe`: `video`, `start_image`, `image` (MCP `reframe` tool schema)
- `video_background_remover`, `topaz_video`, `bytedance_video_upscale`: `video_references` (catalog)
- `draw_to_video`: `video`, `image_references`, `ref_image` (catalog); the CLI help example uses `--sketch`. Whichever the live schema lists is used.

## Cost preflight

```
POST /jobs/{job_type}/cost
{"params": {...}}
→ {"credits": 42.5, "credits_exact": 42.5}
```

Some job types need resolvable media for an estimate. The image upscale preflight answered "requires a resolvable image_id". In that case the panel shows the estimate as unavailable rather than inventing a number.

## Polling

`GET /jobs/{id}` →

```json
{"id","job_type","display_name","status","created_at","params","result_url","min_result_url"}
```

Status strings found in the CLI: `queued`, `pending`, `in_progress`, `processing`, `completed`, `failed`, `nsfw`, `canceled`/`cancelled`. The CLI polls every 3 s by default, with a 10-minute timeout. The panel polls at 3 s with gentle backoff to 10 s, and has no hard timeout, because jobs are persisted.

## Cancellation

The CLI contains no cancel endpoint for account-API jobs. The panel therefore offers "Stop tracking" and says plainly that the job continues and is billed.

## Errors

The message is taken from `detail` (including FastAPI-style validation arrays), `details`, `message` or `error`, the same order the official SDKs use:

- 401 → refresh the token once, then ask the user to sign in.
- 402, or a credit-related refusal → "Not enough credits".
- 403 → plan or workspace restriction, for example `job_minimum_pro_plan_required`, which the catalog documents for Seedance 2.0 on lower plans.
- 408/429/5xx → retried with exponential backoff for idempotent requests. Job submission is retried only on 408/429/503, so a job is never billed twice.
