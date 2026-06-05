# Services Reference

## LiteLLM

| Endpoint               | URL                                           | Auth                    |
| ---------------------- | --------------------------------------------- | ----------------------- |
| Chat completions       | `POST /chat/completions`                      | `Bearer $LITELLM_MASTER_KEY` |
| Embeddings             | `POST /embeddings`                            | `Bearer $LITELLM_MASTER_KEY` |
| Image generation       | `POST /images/generations`                    | `Bearer $LITELLM_MASTER_KEY` |
| Audio transcription    | `POST /audio/transcriptions`                  | `Bearer $LITELLM_MASTER_KEY` |
| Text-to-speech         | `POST /audio/speech`                           | `Bearer $LITELLM_MASTER_KEY` |
| Models list            | `GET /models`                                 | `Bearer $LITELLM_MASTER_KEY` |
| Health check           | `GET /health/liveliness`                      | none                    |
| MCP server (all tools) | `POST /mcp/`                                  | `Bearer $LITELLM_MASTER_KEY` |
| Admin UI               | `GET /ui/`                                    | optional basic auth     |

The admin UI at `/ui/` is rate-limited to 30 requests/minute by default (configurable via `RATELIMIT_ADMIN` in `.env`). Set `LITELLM_UI_BASIC_AUTH=user:password` in `.env` to enable HTTP basic auth on top of that.

---

## Claudebox

### Chat (via LiteLLM)

Use claudebox models through the standard LiteLLM chat completions endpoint. Pass workspace via extra headers:

```bash
curl http://localhost:4000/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claudebox-sonnet",
    "messages": [{"role": "user", "content": "analyze data.csv and summarize it"}],
    "extra_headers": {"X-Claude-Workspace": "myproject"}
  }'
```

Available models: `claudebox-haiku`, `claudebox-sonnet`, `claudebox-opus`, `pibox-zai-glm-4.5-air`, `pibox-zai-glm-4.7`, `pibox-zai-glm-5.1`

### Direct API endpoints

Base URLs: `http://localhost:4000/claudebox/` (Claude Code via OAuth/API key) and `http://localhost:4000/pibox-zai/` (pi-coding-agent via z.ai/GLM).

`claudebox/*` requires `Authorization: Bearer $CLAUDEBOX_API_TOKEN`. `pibox-zai/*` requires `Authorization: Bearer $PIBOX_ZAI_API_TOKEN`. Health endpoints are open. Pibox uses `/healthz` (not `/health`); the rest of the path shape (`/run`, `/run/{id}`, `/v1/chat/completions`, `/mcp`, `/files/{path}`) is the same except `/files/` is workspace-rooted on pibox vs. workspace-prefixed on claudebox.

| Method | Path                                  | Description                                              |
| ------ | ------------------------------------- | -------------------------------------------------------- |
| `GET`  | `/claudebox/health`                   | Health check — no auth required                          |
| `GET`  | `/claudebox/status`                   | Returns which workspaces currently have running Claude processes |
| `POST` | `/claudebox/run`                      | Run a prompt through Claude Code                         |
| `POST` | `/claudebox/run/cancel?workspace=<x>` | Kill the running Claude process in a workspace           |
| `PUT`  | `/claudebox/files/<workspace>/<path>` | Upload a file to a workspace                             |
| `GET`  | `/claudebox/files/<workspace>/<path>` | Download a file from a workspace                         |
| `GET`  | `/claudebox/files/<workspace>`        | List files in a workspace                                |
| `GET`  | `/claudebox/files`                    | List files in the root workspace directory               |
| `DELETE`| `/claudebox/files/<workspace>/<path>`| Delete a file from a workspace                           |

### POST /claudebox/run — request body

| Field                | Type   | Description                                                              | Default         |
| -------------------- | ------ | ------------------------------------------------------------------------ | --------------- |
| `prompt`             | string | The prompt to send to Claude Code                                        | _(required)_    |
| `workspace`          | string | Subpath under `/workspaces` for isolation                                | default workspace |
| `model`              | string | `haiku`, `sonnet`, `opus`, or full model name                            | account default |
| `systemPrompt`       | string | Replace the default system prompt entirely                               | _(none)_        |
| `appendSystemPrompt` | string | Append to the default system prompt without replacing it                 | _(none)_        |
| `jsonSchema`         | string | JSON Schema string — Claude returns JSON matching this schema            | _(none)_        |
| `effort`             | string | Reasoning effort: `low`, `medium`, `high`, `max`                        | _(none)_        |
| `outputFormat`       | string | `json` or `json-verbose` (includes full tool call history)               | `json`          |
| `noContinue`         | bool   | Start a fresh session instead of continuing the previous one             | `false`         |
| `resume`             | string | Resume a specific session by session ID                                  | _(none)_        |
| `fireAndForget`      | bool   | Keep the Claude process running even if the HTTP client disconnects      | `false`         |

Returns **409 Conflict** if the workspace already has a running Claude process.

### Response format (json)

```json
{
  "type": "result",
  "subtype": "success",
  "isError": false,
  "result": "the response text",
  "numTurns": 3,
  "durationMs": 12400,
  "totalCostUsd": 0.049,
  "sessionId": "abc123-...",
  "usage": {
    "inputTokens": 312,
    "outputTokens": 87,
    "cacheReadInputTokens": 1024
  }
}
```

### Response format (json-verbose)

Same as `json` but includes a `turns` array with every tool call, tool result, and assistant message:

```json
{
  "type": "result",
  "subtype": "success",
  "result": "Done. I created data_summary.md with statistics.",
  "turns": [
    {
      "role": "assistant",
      "content": [
        {"type": "tool_use", "id": "toolu_abc", "name": "Bash", "input": {"command": "head data.csv"}}
      ]
    },
    {
      "role": "tool_result",
      "content": [
        {"type": "toolResult", "toolUseId": "toolu_abc", "isError": false, "content": "id,name,value\n1,foo,42\n..."}
      ]
    }
  ],
  "numTurns": 5,
  "totalCostUsd": 0.089,
  "sessionId": "abc123-..."
}
```

### OpenAI-compatible endpoint

Claudebox also speaks OpenAI's `chat/completions` protocol directly. This is what LiteLLM uses internally, but you can also hit it directly:

| Method | Path                               | Description                      |
| ------ | ---------------------------------- | -------------------------------- |
| `GET`  | `/claudebox/openai/v1/models`      | List available models            |
| `POST` | `/claudebox/openai/v1/chat/completions` | Chat completions (streaming + non-streaming) |

Custom headers for workspace control:

| Header                          | Description                                                      |
| ------------------------------- | ---------------------------------------------------------------- |
| `X-Claude-Workspace`            | Workspace subpath to run in                                      |
| `X-Claude-Continue`             | Set to `1`, `true`, or `yes` to continue the previous session    |
| `X-Claude-Append-System-Prompt` | Text to append to the system prompt for this request             |

Note: `temperature`, `max_tokens`, `tools`, and other standard OpenAI fields are accepted but silently ignored — Claude Code manages these internally.

### MCP server

Claudebox exposes an MCP server at `/claudebox/mcp/`. Tools: `claude_run`, `read_file`, `write_file`, `list_files`, `delete_file`. See [mcp-tools.md](mcp-tools.md) for full parameter reference.

### Workspace isolation

Each workspace subpath gets its own directory, file context, and conversation history. Only one Claude process can run per workspace at a time — concurrent requests return 409. Use different workspace names for parallel work:

```bash
# these run concurrently without conflicting
curl -X POST http://localhost:4000/claudebox/run \
  -H "Authorization: Bearer $CLAUDEBOX_API_TOKEN" \
  -d '{"prompt": "write a Go HTTP server", "workspace": "go-project"}'

curl -X POST http://localhost:4000/claudebox/run \
  -H "Authorization: Bearer $CLAUDEBOX_API_TOKEN" \
  -d '{"prompt": "write pytest tests", "workspace": "py-tests"}'
```

---

## Object Storage (hybrids3)

Base URL: `http://localhost:4000/storage/`

### HTTP API

| Method   | Path                              | Auth                        | Description                                        |
| -------- | --------------------------------- | --------------------------- | -------------------------------------------------- |
| `GET`    | `/storage/health`                 | none                        | Returns `{"status":"ok"}`                          |
| `GET`    | `/storage/`                       | master or bucket key        | List buckets (master sees all, bucket key sees own)|
| `GET`    | `/storage/<bucket>`               | public: none / private: key | List objects (supports `?prefix=` and `?max-keys=`)|
| `PUT`    | `/storage/<bucket>/<key>`         | bucket key or master key    | Upload object (MIME auto-detected)                 |
| `GET`    | `/storage/<bucket>/<key>`         | public: none / private: key | Download object                                    |
| `HEAD`   | `/storage/<bucket>/<key>`         | public: none / private: key | Object metadata — no body                          |
| `DELETE` | `/storage/<bucket>/<key>`         | bucket key or master key    | Delete object — 204 even if it doesn't exist       |
| `POST`   | `/storage/presign/<bucket>/<key>` | bucket key or master key    | Generate presigned URL                             |
| `POST`   | `/storage/mcp/`                   | per-tool `auth_key`         | MCP endpoint                                       |

Authentication: pass `Authorization: Bearer <key>` where `<key>` is the bucket's private key or `$HYBRIDS3_MASTER_KEY`.

The `uploads` bucket is configured as public-read — GET/LIST require no auth. PUT/DELETE always require the bucket key.

### Presigned URLs

```bash
# generate a GET presigned URL (default; expires in 1 hour, max 7 days)
curl -X POST "http://localhost:4000/storage/presign/uploads/photo.jpg?expires=3600" \
  -H "Authorization: Bearer $HYBRIDS3_UPLOADS_KEY"

# generate a PUT presigned URL — append ?method=PUT
curl -X POST "http://localhost:4000/storage/presign/uploads/photo.jpg?method=PUT&expires=3600" \
  -H "Authorization: Bearer $HYBRIDS3_UPLOADS_KEY"

# response for public bucket (GET) — plain URL, no expiry
{"url": "http://localhost:4000/storage/uploads/photo.jpg", "expires": null}

# response for private bucket / PUT — signed URL with expiry
{"url": "http://localhost:4000/storage/private/doc.pdf?X-Amz-Algorithm=...&X-Amz-Signature=...", "expires": 3600}

# use a GET presigned URL — no auth header needed
curl "http://localhost:4000/storage/uploads/photo.jpg"

# use a PUT presigned URL — upload directly, no auth header
curl -X PUT --data-binary @photo.jpg "<presigned-put-url>"
```

The signature binds the HTTP method into its canonical request — a GET-signed URL cannot be used to PUT, and vice versa. Public buckets still require a signed URL for PUT (anonymous writes are never allowed; anonymous reads still work).

### S3-compatible access (boto3)

```python
import boto3
from botocore.config import Config

s3 = boto3.client(
    "s3",
    endpoint_url="http://localhost:4000/storage",
    aws_access_key_id="uploads",           # bucket name (public_key)
    aws_secret_access_key=HYBRIDS3_UPLOADS_KEY,
    region_name="us-east-1",
    config=Config(signature_version="s3v4"),
)

s3.upload_file("image.png", "uploads", "image.png")
s3.download_file("uploads", "image.png", "local.png")
s3.list_objects_v2(Bucket="uploads", Prefix="images/")
s3.delete_object(Bucket="uploads", Key="image.png")

# generate presigned URLs via boto3 — GET or PUT
get_url = s3.generate_presigned_url(
    "get_object",
    Params={"Bucket": "uploads", "Key": "image.png"},
    ExpiresIn=3600,
)
put_url = s3.generate_presigned_url(
    "put_object",
    Params={"Bucket": "uploads", "Key": "image.png"},
    ExpiresIn=3600,
)
```

### Response headers

Every response includes `X-Request-Id` for log correlation and `X-Content-Type-Options: nosniff`. Upload responses include `ETag` (MD5 of content). GET/HEAD responses include `ETag`, `Last-Modified`, `Content-Length`, and `Content-Type` (auto-detected from content).

### Concurrency and locking

Each object key has its own async read-write lock. Multiple concurrent reads are allowed. Writes are exclusive — a write blocks all other readers and writers on that key. Requests that can't acquire the lock within 30 seconds, or that hold it for more than 300 seconds, get 503.

### TTL

The `uploads` bucket has TTL configured (default: `HYBRIDS3_UPLOADS_TTL`, typically 168h / 7 days). Uploading a file resets its expiry clock. A background sweep runs every minute and deletes expired objects.

---

## Browser Cluster (stealthy-auto-browse)

| Endpoint             | URL                                                                 | Auth                         |
| -------------------- | ------------------------------------------------------------------- | ---------------------------- |
| Browser API          | `POST /stealthy-auto-browse/`                                       | optional bearer token        |
| Screenshot (browser) | `GET /stealthy-auto-browse/screenshot/browser`                      | optional bearer token        |
| Screenshot (desktop) | `GET /stealthy-auto-browse/screenshot/desktop`                      | optional bearer token        |
| MCP server           | `POST /stealthy-auto-browse/mcp/`                                   | optional bearer token        |
| Queue health         | `GET /stealthy-auto-browse/__queue/health`                          | none                         |
| Cluster status       | `GET /stealthy-auto-browse/__queue/status`                          | none                         |

Set `STEALTHY_AUTO_BROWSE_AUTH_TOKEN` in `.env` to set the bearer auth token. Defaults to `lulz-4-security` if unset — always change this in production.

### Cluster configuration

- 5 browser replicas by default — set `STEALTHY_AUTO_BROWSE_NUM_REPLICAS` to change
- Each replica: 256 MB RAM, up to 1 GB swap
- HAProxy routes requests to replicas and enforces session stickiness:
  - MCP requests: pinned by `Mcp-Session-Id` header
  - All other requests: pinned by `INSTANCEID` cookie, max 1 concurrent request per replica

### Browser API request body

```json
{
  "action": "goto",
  "url": "https://example.com"
}
```

Atomic actions: `goto`, `get_text`, `get_html`, `get_interactive_elements`, `screenshot`, `system_click`, `system_type`, `send_key`, `click`, `fill`, `scroll`, `mouse_move`, `wait_for_element`, `wait_for_text`, `eval_js`, `browser_action`.

`run_script` composes multiple actions into a single request — executes them sequentially on the same replica in a single HTTP round-trip:

```json
{
  "action": "run_script",
  "steps": [
    {"action": "goto", "url": "https://example.com"},
    {"action": "wait_for_element", "selector": "h1", "timeout": 5},
    {"action": "get_text"}
  ]
}
```

---

## sd.cpp — Local Image Generation (optional, `SDCPP=1`)

Local image generation via [stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp) with a Go wrapper. CPU variant runs with `SDCPP=1`, CUDA variant with `SDCPP_CUDA=1`. Both expose an OpenAI-compatible `/v1/images/generations` endpoint proxied through LiteLLM.

### Endpoints (internal — accessed through LiteLLM, not directly via nginx)

| Endpoint | URL | Description |
| -------- | --- | ----------- |
| Image generation | `POST /v1/images/generations` | OpenAI-compatible, proxied through LiteLLM |
| Load model | `POST /sdcpp/v1/load?model=<key>` | Pre-load a model without generating |
| Unload model | `POST /sdcpp/v1/unload` | Free VRAM/RAM |
| Cancel generation | `POST /sdcpp/v1/cancel` | Kill in-progress generation |
| Status | `GET /sdcpp/v1/status` | Current state: loaded model, generating, process info |
| Models list | `GET /v1/models` | Available models |
| Health | `GET /sdcpp/v1/health` | Wrapper health check |

### Models

**CPU** (`SDCPP=1`): sd-turbo, sdxl-turbo

**CUDA** (`SDCPP_CUDA=1`): sd-turbo, sdxl-turbo, sdxl-lightning, flux-schnell, juggernaut-xi

### Behavior

- **Auto-load**: sending a generation request loads the model automatically if not loaded
- **Model hot-swap**: requesting a different model stops the current sd-server, starts a new one
- **Idle timeout**: unloads model after 5 minutes of inactivity (configurable)
- **Non-blocking**: concurrent requests get 503 immediately instead of queuing. The LiteLLM resource manager semaphore handles scheduling.
- **CUDA resource manager**: only one CUDA job (LLM, image gen, TTS, STT) runs at a time. Competing services are unloaded before the request proceeds.

### Environment variables

| Variable | Default | Description |
| -------- | ------- | ----------- |
| `SDCPP_IDLE_TIMEOUT` | `5m` | CPU idle timeout before auto-unload |
| `SDCPP_CUDA_IDLE_TIMEOUT` | `5m` | CUDA idle timeout before auto-unload |
| `SDCPP_MEM_LIMIT` | `12g` | CPU container memory limit |
| `SDCPP_MEMSWAP_LIMIT` | `24g` | CPU container memory + swap limit |
| `SDCPP_CPUS` | `4.0` | CPU container CPU limit |
| `SDCPP_CUDA_MEM_LIMIT` | `12g` | CUDA container memory limit |
| `SDCPP_CUDA_MEMSWAP_LIMIT` | `24g` | CUDA container memory + swap limit |
| `SDCPP_CUDA_CPUS` | `4.0` | CUDA container CPU limit |
| `SDCPP_LOAD_TIMEOUT` / `SDCPP_CUDA_LOAD_TIMEOUT` | `10m` | Max time to wait for model load |
| `SDCPP_VERBOSE` / `SDCPP_CUDA_VERBOSE` | `false` | Debug logging |
| `SDCPP_LOG_LEVEL` / `SDCPP_CUDA_LOG_LEVEL` | `info` | Log level |

---

## talkies — Unified OpenAI-compatible speech (optional, `TALKIES=1` or `TALKIES_CUDA=1`)

External image: [`psyb0t/talkies`](https://github.com/psyb0t/docker-talkies) (pinned to `v0.4.0` / `v0.4.0-cuda`). One container, both endpoints: `POST /v1/audio/transcriptions` (whisper + canary + parakeet) and `POST /v1/audio/speech` (Kokoro-82M TTS, plus Qwen3-TTS voice cloning on CUDA). CPU image ships the four ASR models that run reasonably without a GPU (three Whisper variants + `canary-180m-flash`) plus Kokoro. CUDA image adds Parakeet-TDT, Canary-1B-Flash, Canary-Qwen-2.5B SALM, and Qwen3-TTS-0.6B (voice cloning, 17 languages) on top. Kokoro stays CPU-bound in both images.

### Endpoints (internal — accessed through LiteLLM, not directly via nginx)

| Endpoint | URL | Description |
| -------- | --- | ----------- |
| Transcribe | `POST /v1/audio/transcriptions` | OpenAI-compatible multipart upload (`file`, `model`, `language`, `response_format`, `timestamp_granularities[]`, `diarization`). Supports `json`, `text`, `verbose_json`, `srt`, `vtt`. Stereo channel-split diarization via `diarization=true` — segments + words get a `"channel": "L"/"R"` field. |
| Speech | `POST /v1/audio/speech` | OpenAI-compatible TTS — Kokoro-82M behind `kokoro-82m` slug. JSON body with `model`, `input`, `voice`, `response_format` (`mp3`/`opus`/`aac`/`flac`/`wav`/`pcm`). |
| List models | `GET /v1/models` | Configured model_ids |
| Loaded models | `GET /api/ps` | Currently loaded backends + `idle_seconds` |
| Unload one | `DELETE /api/ps/{model_id}` | Evict one model from RAM/VRAM (URL-encoded) |
| Unload all | `POST /unload` | Evict every loaded backend |
| List voices | `GET /v1/audio/voices` | Available Kokoro voices |
| Health | `GET /healthz` | Liveness + device + configured model_ids |

### Models

**CPU** (`TALKIES=1`):
- `whisper-large-v3`, `whisper-large-v3-turbo` — multilingual ASR
- `canary-180m-flash` — English ASR (FastConformer)
- `kokoro-82m` — TTS, ~41 voices across en/es/fr/hi/it/pt

**CUDA** (`TALKIES_CUDA=1`): all of the above plus
- `parakeet-tdt-0.6b-v3` — 25 European languages (NeMo RNNT)
- `canary-1b-flash` — EN/DE/FR/ES + EN↔X translation (NeMo multitask)
- `canary-qwen-2.5b` — English, NeMo SALM hybrid ASR+LLM (text-only; no per-word timestamps)
- `qwen3-tts-0.6b` — voice cloning, 17 languages (en, zh, ja, ko, fr, de, es, it, pt, ru, vi, th, id, ar, tr, pl, nl). Drop a `<name>.wav` (10-30s clean speech) into `${DATA_DIR_TALKIES}/custom-voices/` on the host (mounted as `/data/custom-voices` inside the container) and use `voice=<name>` on `/v1/audio/speech`. Samples `alloy`/`echo`/`fable` baked in. Nested paths supported (`voice=clients/acme/jane` → `${DATA_DIR_TALKIES}/custom-voices/clients/acme/jane.wav`).

### Behavior

- **Lazy load + idle TTL unload**: weights download on first request, sit on disk in `${DATA_DIR_TALKIES}` (HF cache layout). A background sweeper unloads any model idle longer than `TALKIES_MODEL_TTL` (default `10m`); next request warm-reloads from disk.
- **Sibling eviction**: only one model resident per talkies container at a time. When request N arrives for a different model, talkies evicts the prior one before loading.
- **Resource-manager aware**: `local-talkies-cuda-*` participates in the `cuda-stt-talkies` group, `local-talkies-*` in `cpu-stt-talkies`. A competing job (LLM, image gen, TTS, other STT) triggers `DELETE /api/ps/{model_id}` for every model before its own load.
- **VAD chunking**: long audio is sliced via Silero VAD into ≤28-second speech regions before each backend forward pass, then results are stitched into one Whisper-shape timeline. Backends that don't support timeline assembly (the SALM `canary-qwen-2.5b`) concatenate per-chunk text without timestamps.
- **Audio preprocessing**: any container/codec is ffmpeg-converted to 16 kHz mono WAV before the backend sees it. Stereo `diarization=true` splits L/R into two mono streams, transcribes each, and time-interleaves the segments with channel tags.
- **OpenAI parity**: every response_format returns the correct Content-Type body — `text/plain` for `text`, `application/x-subrip` for `srt`, `text/vtt` for `vtt`, `application/json` for `json` / `verbose_json`. `verbose_json` carries `text`, `language`, `duration`, `segments[{id,start,end,text,channel?,…}]`, `words[{word,start,end,channel?}]`.

### Environment variables

| Variable | Default | Description |
| -------- | ------- | ----------- |
| `TALKIES_MODEL_TTL` / `TALKIES_CUDA_MODEL_TTL` | `10m` | Idle duration before unload (`-1` disables). Accepts bare seconds or Go-style strings (`3h30m5s`, `45m`, `90s`). |
| `TALKIES_SWEEPER_INTERVAL` / `TALKIES_CUDA_SWEEPER_INTERVAL` | `1m` | Idle sweeper poll interval |
| `TALKIES_LOAD_TIMEOUT` / `TALKIES_CUDA_LOAD_TIMEOUT` | `5m` | Max wait for model load before the request errors |
| `TALKIES_MAX_UPLOAD_BYTES` / `TALKIES_CUDA_MAX_UPLOAD_BYTES` | `104857600` | Max audio upload size (bytes) |
| `TALKIES_LOG_LEVEL` / `TALKIES_CUDA_LOG_LEVEL` | `INFO` | Log level |
| `TALKIES_PRELOAD` / `TALKIES_CUDA_PRELOAD` | _empty_ | Comma-separated model_ids to load at boot |
| `TALKIES_VAD_CHUNK_THRESHOLD` / `TALKIES_CUDA_VAD_CHUNK_THRESHOLD` | `30` | Audio length (seconds) above which VAD chunking kicks in |
| `TALKIES_VAD_MAX_SPEECH` / `TALKIES_CUDA_VAD_MAX_SPEECH` | `28` | Max chunk length fed to a single forward pass |
| `TALKIES_MEM_LIMIT` / `TALKIES_CUDA_MEM_LIMIT` | `8g` / `12g` | Container memory limit |
| `TALKIES_CPUS` / `TALKIES_CUDA_CPUS` | `4.0` | Container CPU limit |
| `DATA_DIR_TALKIES` | `${DATA_DIR}/talkies` | Bind-mount root for talkies' `/data` dir. Contains `hf/hub/models--*/` (HF cache, shared by CPU + CUDA) and — for CUDA — `custom-voices/<name>.wav` (Qwen3-TTS reference voices). |

---

## MCP Tools — Media Generation (auto-enabled)

Auto-enabled when any image or TTS provider is active (HuggingFace, OpenAI, Speaches, SDCPP, CUDA). Runs as an internal service — no direct nginx route, accessed only through LiteLLM's aggregated MCP endpoint at `/mcp/`.

| Endpoint               | URL                | Auth                              |
| ---------------------- | ------------------ | --------------------------------- |
| MCP server (via proxy) | `POST /mcp/`       | `Bearer $LITELLM_MASTER_KEY`      |
| Health (internal only) | `GET :8000/health`  | none (not exposed via nginx)      |

### Tools

- `generate_image` — create images from text prompts (FLUX, DALL-E, Stable Diffusion depending on enabled providers)
- `generate_tts` — generate speech audio from text (Kokoro, Qwen3-TTS, OpenAI TTS depending on enabled providers)

Both tools return structured JSON with persistent HybridS3 URLs — no base64 blobs sent to the LLM.

See [mcp-tools.md](mcp-tools.md#mcp_tools--2-tools-auto-enabled-with-imagetts-providers) for full parameter reference.

### Environment variables

| Variable               | Default  | Description                          |
| ---------------------- | -------- | ------------------------------------ |
| `MCP_TOOLS_AUTH_TOKEN`  | —       | Bearer token for MCP auth (required) |
| `MCP_MEM_LIMIT`        | `256m`   | Container memory limit               |
| `MCP_MEMSWAP_LIMIT`    | `512m`   | Container memory + swap limit        |
| `MCP_CPUS`             | `0.5`    | CPU limit                            |

---

## LibreChat (optional, `LIBRECHAT=1`)

Web UI for LLM interaction at `/librechat/`. Pre-configured with all LiteLLM models and MCP tools. Uses MongoDB for conversation storage.

| Endpoint      | URL                          | Auth                     |
| ------------- | ---------------------------- | ------------------------ |
| Web UI        | `GET /librechat/`            | email/password (own auth)|
| API           | `/librechat/api/*`           | JWT (managed by LibreChat)|

### Authentication

LibreChat has its own email/password authentication — no basic auth (SPAs and basic auth are incompatible due to Authorization header collision). The first registered user automatically becomes admin. After creating your account, set `LIBRECHAT_ALLOW_REGISTRATION=false` in `.env` and restart to lock registration.

### MCP tools integration

All MCP tools from the LiteLLM aggregated endpoint are available in LibreChat conversations. Connected via streamable-http with `apiKey.source: admin` (bypasses LibreChat's OAuth detection probe). Configuration in `librechat/librechat.yaml`.

### Environment variables

| Variable                              | Default                                  | Description                                  |
| ------------------------------------- | ---------------------------------------- | -------------------------------------------- |
| `LIBRECHAT_DOMAIN_CLIENT`             | `http://librechat:3080/librechat`        | Public URL for client (sets `<base href>`)   |
| `LIBRECHAT_DOMAIN_SERVER`             | `http://librechat:3080/librechat`        | Public URL for server API                    |
| `LIBRECHAT_CREDS_KEY`                 | —                                        | Encryption key for stored credentials (64 hex chars) |
| `LIBRECHAT_CREDS_IV`                  | —                                        | Encryption IV (32 hex chars)                 |
| `LIBRECHAT_JWT_SECRET`                | —                                        | JWT signing secret                           |
| `LIBRECHAT_TITLE_MODEL`               | `groq-llama-3.3-70b`                     | Model for auto-titling conversations         |
| `LIBRECHAT_ALLOW_REGISTRATION`        | `true`                                   | Set to `false` after creating admin account  |
| `LIBRECHAT_ALLOW_EMAIL_LOGIN`         | `true`                                   | Enable email/password login                  |
| `LIBRECHAT_ALLOW_SOCIAL_LOGIN`        | `false`                                  | Enable social login providers                |
| `LIBRECHAT_ALLOW_UNVERIFIED_EMAIL_LOGIN` | `true`                                | Allow login without email verification       |
| `LIBRECHAT_DEBUG_LOGGING`             | `true`                                   | Enable debug-level logging                   |
| `LIBRECHAT_DEBUG_CONSOLE`             | `false`                                  | Log to console (in addition to file)         |
| `LIBRECHAT_MEM_LIMIT`                 | `512m`                                   | LibreChat container memory limit             |
| `LIBRECHAT_MEMSWAP_LIMIT`             | `1g`                                     | LibreChat container memory + swap limit      |
| `LIBRECHAT_CPUS`                      | `1.0`                                    | LibreChat CPU limit                          |
| `LIBRECHAT_MONGO_MEM_LIMIT`           | `512m`                                   | MongoDB container memory limit               |
| `LIBRECHAT_MONGO_MEMSWAP_LIMIT`       | `1g`                                     | MongoDB container memory + swap limit        |
| `LIBRECHAT_MONGO_CPUS`                | `0.5`                                    | MongoDB CPU limit                            |
| `RATELIMIT_LIBRECHAT`                 | `500r/m`                                 | Nginx rate limit                             |
| `RATELIMIT_LIBRECHAT_BURST`           | `100`                                    | Burst allowance                              |
| `TIMEOUT_LIBRECHAT`                   | `600s`                                   | Nginx proxy timeout                          |
| `LIBRECHAT_MAX_BODY_SIZE`             | `25m`                                    | Max upload size                              |
| `DATA_DIR_LIBRECHAT`                  | `${DATA_DIR}/librechat`                  | Data directory (MongoDB + uploads)           |

---

## SearXNG (optional, `SEARXNG=1`)

Self-hosted meta-search engine at `/searxng/`. Aggregates results from Google, Bing, DuckDuckGo, and Wikipedia. Protected by nginx admin auth (`LITELLM_UI_BASIC_AUTH`). Rate-limited to 60 req/min by default.

Also exposed to the MCP `search_web` tool — when `SEARXNG=1`, the MCP tools server gains a `search_web` tool that any function-calling model can invoke.

| Endpoint  | URL               | Auth               |
| --------- | ----------------- | ------------------ |
| Search UI | `GET /searxng/`   | nginx basic auth   |
| JSON API  | `GET /searxng/search?q=...&format=json` | nginx basic auth |

### Environment variables

| Variable                  | Default     | Description                          |
| ------------------------- | ----------- | ------------------------------------ |
| `RATELIMIT_SEARXNG`       | `60r/m`     | Nginx rate limit                     |
| `RATELIMIT_SEARXNG_BURST` | `20`        | Burst allowance                      |
| `TIMEOUT_SEARXNG`         | `60s`       | Nginx proxy timeout                  |
| `SEARXNG_MEM_LIMIT`       | `256m`      | Container memory limit               |
| `SEARXNG_MEMSWAP_LIMIT`   | `512m`      | Container memory + swap limit        |
| `SEARXNG_CPUS`            | `0.5`       | CPU limit                            |

Settings are in `searxng/settings.yml` (mounted read-only into the container). The default config enables HTML and JSON output formats and activates Google, Bing, DuckDuckGo, and Wikipedia engines with no rate limiter.

---

## Telethon Plus (optional, `TELETHON=1`)

Telegram client at `/telethon/`. Backed by [docker-telethon-plus](https://github.com/psyb0t/docker-telethon-plus) — exposes a REST API and MCP server for sending/reading messages, managing dialogs, forwarding content, and group operations.

| Endpoint        | URL                        | Auth         |
| --------------- | -------------------------- | ------------ |
| Health          | `GET /telethon/healthz`    | none         |
| REST API        | `/telethon/api/*`          | Bearer token |
| MCP server      | `/telethon/mcp`            | Bearer token |

### Setup

1. Get API credentials at [my.telegram.org/apps](https://my.telegram.org/apps)
2. Generate a string session:
   ```bash
   docker run -it --rm \
     -e TELETHON_API_ID=your_id \
     -e TELETHON_API_HASH=your_hash \
     psyb0t/telethon-plus:v0.2.0 login
   ```
3. Add to `.env`: `TELETHON=1`, `TELETHON_API_ID`, `TELETHON_API_HASH`, `TELETHON_SESSION`, `TELETHON_AUTH_KEY`

### Environment variables

| Variable                        | Default        | Description                              |
| ------------------------------- | -------------- | ---------------------------------------- |
| `TELETHON_API_ID`               | —              | Telegram app ID (required)               |
| `TELETHON_API_HASH`             | —              | Telegram app hash (required)             |
| `TELETHON_SESSION`              | —              | String session from login.py (required)  |
| `TELETHON_AUTH_KEY`             | `lulz-4-security` | Bearer token for REST + MCP auth      |
| `TELETHON_PROXY`                | —              | SOCKS5 proxy (`socks5://user:pass@host:port`) |
| `TELETHON_REQUEST_TIMEOUT`      | `60`           | Telegram API request timeout (seconds)   |
| `TELETHON_FLOOD_SLEEP_THRESHOLD`| `60`           | Auto-sleep on flood wait up to this many seconds |
| `RATELIMIT_TELETHON`            | `30r/m`        | Nginx rate limit                         |
| `RATELIMIT_TELETHON_BURST`      | `10`           | Burst allowance                          |
| `TIMEOUT_TELETHON`              | `60s`          | Nginx proxy timeout                      |
| `TELETHON_MEM_LIMIT`            | `256m`         | Container memory limit                   |
| `TELETHON_MEMSWAP_LIMIT`        | `512m`         | Container memory + swap limit            |
| `TELETHON_CPUS`                 | `0.2`          | CPU limit                                |

---

## predictalot (optional, `PREDICTALOT=1`)

Foundation time-series forecasting at `/predictalot/`. Backed by [docker-predictalot](https://github.com/psyb0t/docker-predictalot) — five foundation models (`chronos-2`, `timesfm-2.5`, `moirai-2`, `toto-1`, `sundial-base-128m`) exposed via a **type-routed API**. Each forecast modality has its own URL prefix; a model only appears under a type if it implements that modality. Per-type weighted-mean ensembles parallelize across all type members.

Not registered with LiteLLM (no chat/completion surface) — accessed directly via nginx. MCP is exposed by default through LiteLLM's `/mcp/` aggregator with **26 tools** (one per (type, model) cell + per-type ensemble + per-type listing).

### Forecast types

| Type | Base URL | Members | Request shape | Response shape |
|---|---|---|---|---|
| univariate | `/v1/univariate` | chronos-2, timesfm-2.5, moirai-2, toto-1, sundial-base-128m | `context: float[series][time]` | quantiles per series |
| multivariate | `/v1/multivariate` | chronos-2, moirai-2, toto-1 | `context: float[series][channel][time]` | quantiles per (series, channel) |
| covariates — past only | `/v1/covariates/past` | chronos-2, moirai-2 | univariate target + `pastCovariates` | quantiles per series |
| covariates — future only | `/v1/covariates/future` | chronos-2 | univariate target + `futureCovariates` | quantiles per series |
| covariates — past + future | `/v1/covariates` | chronos-2 | univariate target + both | quantiles per series |
| samples | `/v1/samples` | toto-1, sundial-base-128m | univariate target + `numSamples` | raw sample paths |

Every base URL exposes the same three sub-paths: `<base>/forecast`, `<base>/forecast/ensemble`, `<base>/models`.

### Endpoints

| Endpoint                       | URL                                            | Auth         |
| ------------------------------ | ---------------------------------------------- | ------------ |
| Liveness probe                 | `GET  /predictalot/healthz`                    | none (open)  |
| Per-type model listing         | `GET  /predictalot/v1/<type>/models`           | Bearer token |
| Per-type single-model forecast | `POST /predictalot/v1/<type>/forecast`         | Bearer token |
| Per-type weighted ensemble     | `POST /predictalot/v1/<type>/forecast/ensemble`| Bearer token |
| MCP (direct)                   | `/predictalot/mcp`                             | Bearer token |
| MCP (aggregated)               | `/mcp/` (via LiteLLM master key)               | Master key   |

### Quick example

```bash
curl -s http://localhost:4000/predictalot/v1/univariate/forecast \
  -H "Authorization: Bearer $PREDICTALOT_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "chronos-2",
    "context": [[10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]],
    "config": {"horizon": 5}
  }' | jq

# weighted ensemble — weight 0 disables a model, omitted entries default to 1
curl -s http://localhost:4000/predictalot/v1/univariate/forecast/ensemble \
  -H "Authorization: Bearer $PREDICTALOT_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "context": [[10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]],
    "config": {"horizon": 5},
    "weights": {"chronos-2": 2.0, "moirai-2": 1.0, "timesfm-2.5": 0}
  }' | jq
```

The ensemble response carries the weighted-mean forecast plus an `individual` map containing each contributing model's own forecast and applied weight, so dissent / post-processing is possible.

Models lazy-load on first request (each downloads ~50-800MB into the mounted models dir, subsequent calls are fast). Idle models are unloaded after `PREDICTALOT_MODEL_IDLE_TIMEOUT` (default 30m). The Sundial model runs in its own sidecar venv (it pins `transformers==4.40.1` for upstream compatibility) — transparent over the wire.

CPU and CUDA variants are mutually exclusive (both bind the `predictalot` network alias) — pick one. CUDA variant requires nvidia-container-toolkit + `--gpus` configuration on the host.

### Environment variables

| Variable                          | Default                            | Description                                                 |
| --------------------------------- | ---------------------------------- | ----------------------------------------------------------- |
| `PREDICTALOT_AUTH_TOKEN`          | `lulz-4-security-predictalot`      | Bearer token for `/predictalot/*` + MCP                     |
| `PREDICTALOT_DEVICE`              | `auto`                             | `auto` / `cpu` / `cuda` / `cuda:N`                          |
| `PREDICTALOT_PREFETCH`            | —                                  | Comma-separated slugs (or `all`) to fetch weights at boot   |
| `PREDICTALOT_PRELOAD`             | —                                  | Comma-separated slugs to load into memory at boot           |
| `PREDICTALOT_MODEL_IDLE_TIMEOUT`  | `30m`                              | Idle time before a loaded model is unloaded (Go-style)      |
| `PREDICTALOT_MAX_BODY_SIZE`       | `32mb`                             | Max request body                                            |
| `PREDICTALOT_LOG_LEVEL`           | `INFO`                             | Python log level                                            |
| `DATA_DIR_PREDICTALOT`            | `${DATA_DIR}/predictalot`          | Where HF snapshots are stored (~1.4GB for all five models)  |
| `RATELIMIT_PREDICTALOT`           | `60r/m`                            | Nginx rate limit                                            |
| `RATELIMIT_PREDICTALOT_BURST`     | `20`                               | Burst allowance                                             |
| `TIMEOUT_PREDICTALOT`             | `600s`                             | Nginx proxy timeout (cold model loads can be slow)          |
| `PREDICTALOT_MEM_LIMIT`           | `6g` (CPU) / `12g` (CUDA)          | Container memory limit                                      |
| `PREDICTALOT_CPUS`                | `4.0`                              | CPU limit                                                   |

See [docker-predictalot README](https://github.com/psyb0t/docker-predictalot) for full per-model quirks, request/response shapes, and accuracy benchmarks.

---

## mailbox (optional, `MAILBOX=1`)

Stateless IMAP+SMTP gateway at `/mailbox/`. Backed by [docker-mailbox](https://github.com/psyb0t/docker-mailbox) — point it at N email accounts via a single YAML config and out the other end you get one HTTP API + one MCP server (streamable-HTTP at `/mailbox/mcp`), both on the same bearer token. Unified inbox across all accounts, per-account CRUD, and SMTP send. No database; every read hits the upstream IMAP server live.

Not registered with LiteLLM (no chat/completion surface). MCP is enabled by default via LiteLLM's `/mcp/` aggregator with a flat tool set (`mailbox-mailboxes`, `mailbox-inbox`, `mailbox-list_messages`, `mailbox-get_message`, `mailbox-search`, `mailbox-send`, `mailbox-mark_seen`, `mailbox-move`, `mailbox-delete`, …) — every per-account op takes `mailbox` as a parameter, so 100 inboxes ship the same handful of tools.

| Endpoint        | URL                                  | Auth         |
| --------------- | ------------------------------------ | ------------ |
| Health          | `GET /mailbox/health`                | open         |
| List mailboxes  | `GET /mailbox/mailboxes`             | Bearer token |
| Unified inbox   | `GET /mailbox/inbox`                 | Bearer token |
| Per-mailbox ops | `GET/POST/DELETE /mailbox/<name>/…`  | Bearer token |
| Send            | `POST /mailbox/<name>/send`          | Bearer token |
| MCP (direct)    | `/mailbox/mcp`                       | Bearer token |
| MCP (aggregated)| `/mcp/` (via LiteLLM master key)     | Master key   |

### Setup

1. Copy `mailbox/config.example.yaml` to a host path **outside git history** (recommended: `.data/mailbox/config.yaml` — `.data/**` is gitignored).
2. Fill in the IMAP/SMTP creds for each account.
3. Put at least one bearer token in `auth.tokens:` and mirror it as `MAILBOX_AUTH_TOKEN` in `.env` (the MCP aggregator uses this to reach `/mailbox/mcp`).
4. Set `MAILBOX_CONFIG` in `.env` to the absolute or repo-relative path of the YAML.
5. `MAILBOX=1` in `.env`, then `make run-bg`.

```bash
curl -s http://localhost:4000/mailbox/mailboxes -H "Authorization: Bearer $MAILBOX_AUTH_TOKEN" | jq
curl -s "http://localhost:4000/mailbox/inbox?limit=5" -H "Authorization: Bearer $MAILBOX_AUTH_TOKEN" | jq
```

The config file holds **plaintext IMAP/SMTP passwords + bearer tokens** — treat it like a private key. Never commit. `Makefile`'s `check_file_vars` validates `MAILBOX_CONFIG` resolves to an existing file before bringing the stack up.

### Environment variables

| Variable               | Default                  | Description                                                          |
| ---------------------- | ------------------------ | -------------------------------------------------------------------- |
| `MAILBOX_CONFIG`       | — (required)             | Host path to the mailbox YAML config                                 |
| `MAILBOX_AUTH_TOKEN`   | `change-me-mailbox-auth` | Bearer token; MUST also appear in the YAML's `auth.tokens:`          |
| `RATELIMIT_MAILBOX`    | `60r/m`                  | Nginx rate limit                                                     |
| `RATELIMIT_MAILBOX_BURST` | `20`                  | Burst allowance                                                      |
| `TIMEOUT_MAILBOX`      | `120s`                   | Nginx proxy timeout (IMAP fetches can be slow on large folders)      |
| `MAILBOX_MEM_LIMIT`    | `256m`                   | Container memory limit                                               |
| `MAILBOX_CPUS`         | `0.5`                    | CPU limit                                                            |

See [docker-mailbox README](https://github.com/psyb0t/docker-mailbox) for the full config schema, query params (`mailbox=`, `unseen=`, `from=`, reader-mode HTML stripping, etc.), and the complete MCP tool list.

---

## Cloudflared (optional, `CLOUDFLARED=1`)

Disabled by default. Enable by setting `CLOUDFLARED=1` in `.env`.

### Quick tunnel (no account needed)

```env
CLOUDFLARED=1
```

Cloudflare assigns a random `*.trycloudflare.com` URL and logs it on startup:

```bash
docker compose up -d
docker compose logs cloudflared | grep trycloudflare
```

### Named tunnel (fixed domain, requires Cloudflare account)

```env
CLOUDFLARED=1
CLOUDFLARED_CONFIG=/absolute/path/to/config.yml
CLOUDFLARED_CREDS=/absolute/path/to/credentials.json
```

Example `config.yml`:

```yaml
tunnel: <your-tunnel-id>
credentials-file: /etc/cloudflared/credentials.json
ingress:
  - hostname: aigate.yourdomain.com
    service: http://nginx:4000
  - service: http_status:404
```

Get your tunnel ID and credentials: [Cloudflare Tunnel guide](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/get-started/)

---

## Tailscale (optional, `TAILSCALE=1`)

Disabled by default. Runs the official `tailscale/tailscale` image with [`tailscale serve`](https://tailscale.com/kb/1242/tailscale-serve) configured for **L4 TCP forwarding** to nginx on port 4000. Access is **tailnet-only** — no public exposure, no port forwarding, no Cloudflare in the middle.

L4 mode means tailscale forwards the raw TCP stream straight to nginx without inspecting the Host header. nginx sees the original request — including Host, paths, everything — exactly as the client sent it. No FQDN config needed on the tailscale side.

State is bind-mounted at `${DATA_DIR_TAILSCALE:-${DATA_DIR:-.data}/tailscale}` so the node identity survives container recreates. After the first auth, the node stays logged in even if `TS_AUTHKEY` is rotated.

### Setup (hosted Tailscale)

1. Generate an auth key at [login.tailscale.com/admin/settings/keys](https://login.tailscale.com/admin/settings/keys) (reusable + ephemeral both work).
2. Set:

   ```env
   TAILSCALE=1
   TS_AUTHKEY=tskey-auth-...
   TS_HOSTNAME=aigate
   ```

3. `make run-bg`. The node joins your tailnet under `TS_HOSTNAME`.
4. From any tailnet-joined device: `http://aigate.tailXXXX.ts.net` → aigate's nginx.

Find your tailnet name with `docker compose exec tailscale tailscale status` after first connect.

### Setup (Headscale or other custom control server)

Add `--login-server` to `TS_EXTRA_ARGS`:

```env
TAILSCALE=1
TS_AUTHKEY=hskey-auth-...
TS_HOSTNAME=aigate
TS_EXTRA_ARGS=--login-server=https://your-headscale.example.com
```

The FQDN your tailnet exposes (`aigate.<base_domain>`) is determined by your Headscale's `base_domain` setting — nothing to configure on the aigate side.

### Custom port

Default forward port is 80 (`http://<host>.<tailnet>/`). Change with `TS_SERVE_PORT=8080` etc.

### Notes

- L4 forwarding means HTTPS auto-cert (Tailscale's hosted ACME proxy) is **not** in play here — TLS termination, if you want it, lives in nginx. Easier to keep it as plain HTTP over the tailnet, which is already encrypted by WireGuard.
- The container needs `NET_ADMIN`, `NET_RAW`, and `/dev/net/tun` for kernel networking.
- Forwarding sysctls (`net.ipv4.ip_forward=1`, `net.ipv6.conf.all.forwarding=1`) are set so subnet-routing and exit-node modes work if you add `--advertise-routes=...` or `--advertise-exit-node` via `TS_EXTRA_ARGS`.
- Stays on the `aigate-public` network so the `nginx:4000` upstream resolves via Docker DNS.

---

## Resource Management

Local services (Ollama, sd.cpp, Speaches, Qwen3-TTS) share limited hardware. The platform coordinates them automatically — no manual model management needed.

### Idle auto-unload

Every local service unloads models after a period of inactivity:

| Service | Default idle timeout | Configurable via |
| ------- | -------------------- | ---------------- |
| Ollama (CPU/CUDA) | 5 minutes | Ollama's built-in `keep_alive` |
| sd.cpp CPU | 5 minutes | `SDCPP_IDLE_TIMEOUT` |
| sd.cpp CUDA | 5 minutes | `SDCPP_CUDA_IDLE_TIMEOUT` |
| Speaches | On-demand unload | Resource manager triggers `DELETE /api/ps/{model}` |
| Qwen3 CUDA TTS | On-demand unload | Resource manager triggers `POST /unload` |

### Auto-load on demand

Models load automatically when a request arrives. Send a chat completion to `local-ollama-cuda-qwen3-8b` and Ollama pulls/loads it. Send an image generation to `local-sdcpp-cuda-flux-schnell` and the sd.cpp wrapper spawns sd-server with that model. No pre-loading required.

### Hardware semaphores

A LiteLLM callback (`resource_manager.py`) enforces mutual exclusion per hardware class:

- **CUDA semaphore** — one CUDA job at a time across all groups: LLM (`cuda-llm`), image gen (`cuda-img`), TTS (`cuda-tts`), STT (`cuda-stt`)
- **CPU semaphore** — one CPU job at a time across: LLM (`cpu-llm`), image gen (`cpu-img`), TTS (`cpu-tts`), STT (`cpu-stt`)

When a request arrives for a local model:

1. The resource manager identifies which group it belongs to (e.g. `local-sdcpp-cuda-flux-schnell` → `cuda-img`)
2. It acquires the hardware semaphore (waits if another job is running)
3. It unloads all competing groups on the same hardware (e.g. unloads `cuda-llm`, `cuda-tts`, `cuda-stt`)
4. The request proceeds
5. On completion (success or failure), the semaphore is released

### Unload mechanisms

Each service has its own unload API:

| Service | Unload method |
| ------- | ------------- |
| Ollama | `POST /api/generate {"model": "...", "keep_alive": 0}` |
| sd.cpp | `POST /sdcpp/v1/unload` |
| Speaches | `DELETE /api/ps/{model_id}` |
| Qwen3 CUDA TTS | `POST /unload` |

### Non-blocking rejection

The sd.cpp wrapper uses `TryLock` — if a generation or model swap is in progress, new requests get 503 immediately instead of queuing. Scheduling happens at the LiteLLM layer via the semaphore, not inside individual services.
