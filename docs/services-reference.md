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

External image: [`psyb0t/talkies`](https://github.com/psyb0t/docker-talkies) (pinned to `v0.9.0` / `v0.9.0-cuda`). One container, both endpoints: `POST /v1/audio/transcriptions` (whisper + canary + parakeet + nemotron) and `POST /v1/audio/speech` (Kokoro-82M TTS in both PyTorch and ONNXRuntime variants, plus the full Qwen3-TTS line on CUDA). CPU image ships **6 models** — four ASR (`whisper-large-v3`, `whisper-large-v3-turbo`, `canary-180m-flash`, `nemotron-3.5-asr-0.6b` via parakeet.cpp) plus two TTS (`kokoro-82m` PyTorch and `kokoro-82m-nvidia` ONNXRuntime). CUDA image ships **14 models** — adds Parakeet-TDT, Canary-1B-Flash, Canary-Qwen-2.5B SALM, and the full Qwen3-TTS line (Base 0.6B + Base 1.7B + CustomVoice 0.6B + CustomVoice 1.7B + VoiceDesign 1.7B). Kokoro stays CPU-bound in both images.

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
- `nemotron-3.5-asr-0.6b` — NVIDIA Nemotron-3.5-ASR-Streaming-0.6B via [parakeet.cpp](https://github.com/mudler/parakeet.cpp) (OpenMDW-1.1, 40+ locales, per-word timestamps + confidence, WER-0 vs NeMo). C++17/ggml backend; CPU-only in both images at this stage. Operators can register additional parakeet.cpp checkpoints (any Parakeet TDT/CTC/RNNT GGUF in [mudler/parakeet-cpp-gguf](https://huggingface.co/mudler/parakeet-cpp-gguf)) via a custom `models.json`.
- `kokoro-82m` — TTS via PyTorch / misaki G2P, ~41 voices across en/es/fr/hi/it/pt
- `kokoro-82m-nvidia` — TTS via NVIDIA's TensorRT-friendly [ONNX export](https://huggingface.co/nvidia/kokoro-82M-onnx-opt) + espeak-ng G2P. Same 40-voice catalog and wire shape; no PyTorch on the inference hot path.

**CUDA** (`TALKIES_CUDA=1`): all of the above plus
- `parakeet-tdt-0.6b-v3` — 25 European languages (NeMo RNNT)
- `canary-1b-flash` — EN/DE/FR/ES + EN↔X translation (NeMo multitask)
- `canary-qwen-2.5b` — English, NeMo SALM hybrid ASR+LLM (text-only; no per-word timestamps)
- **Qwen3-TTS family — mode is implicit in the model slug; `voice` and `instructions` semantics shift per mode**:
  - `qwen3-tts-0.6b` / `qwen3-tts-1.7b` — Base mode. Voice cloning via reference `.wav` files. Drop a `<name>.wav` (10-30 s clean speech) into `${DATA_DIR_TALKIES}/custom-voices/` on the host (mounted as `/data/custom-voices` inside the container) and use `voice=<name>` on `/v1/audio/speech`. Samples `alloy` / `echo` / `fable` baked in. Nested paths supported (`voice=clients/acme/jane` → `${DATA_DIR_TALKIES}/custom-voices/clients/acme/jane.wav`). 17 languages (en, zh, ja, ko, fr, de, es, it, pt, ru, vi, th, id, ar, tr, pl, nl).
  - `qwen3-tts-0.6b-custom` / `qwen3-tts-1.7b-custom` — CustomVoice mode. Pass `voice=<preset>` where preset is one of 9 baked-in speakers: `Vivian`, `Serena`, `Uncle_Fu`, `Dylan`, `Eric`, `Ryan`, `Aiden`, `Ono_Anna`, `Sohee`. The 1.7B variant also accepts `instructions=<emotion>` (`"happy"` / `"sad"` / …).
  - `qwen3-tts-1.7b-design` — VoiceDesign mode. Pass `voice="design"` (sentinel) + `instructions=<natural-language description>` (e.g. `"a young energetic female voice"`); the model synthesises a voice that matches the description.
  - **Per-request sampling controls** (v0.8.0+, OpenAI-extras via `extra_body` on official SDKs, all modes): `temperature`, `top_k`, `top_p`, `repetition_penalty`, `max_new_tokens`, `do_sample`, plus `language` (for CustomVoice / VoiceDesign). Out-of-range returns 422.
  - **PCM streaming** (v0.7.0+): `response_format="pcm"` streams the raw PCM body via HTTP/1.1 chunked transfer-encoding (TTFA ~200-700 ms vs ~3-8 s buffered). Tune chunk size via `TALKIES_QWEN3_STREAM_CHUNK_SIZE` (default `8` codec-steps-per-chunk).

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

## vllm / vllm-cuda — local LLM + embeddings (optional, `VLLM=1` / `VLLM_CUDA=1`)

Supervised wrapper around `vllm serve` that holds at most one model in memory at a time. Lazy-loads on first request for a given model_id, idle-unloads after `VLLM_*_MODEL_TTL`, and exposes the same `/api/ps` + `DELETE /api/ps/{model_id}` lifecycle surface as talkies so the LiteLLM resource_manager can swap models in/out of memory under contention.

Both variants share the supervisor (`vllm/src/vllm_wrap/`), built from `vllm/` with `Dockerfile.cpu` (`vllm/vllm-openai-cpu` base) or `Dockerfile.cuda` (`vllm/vllm-openai:v0.21.0` base). Each ships its own model list:

- `vllm/models.cpu.json` — CPU-tuned `vllm_args` (no `--gpu-memory-utilization`, smaller context for Qwen3 to bound KV cache RAM)
- `vllm/models.cuda.json` — CUDA-tuned `vllm_args` (gpu memory split, larger context)

Each entry maps a slug to `{repo, vllm_args, endpoints}`. Endpoints must be a subset of `{"chat", "completions", "embeddings"}`. Both variants share `${DATA_DIR_VLLM}/models/<org>/<repo>/` (populated once by `vllm-pull`) so enabling both does not duplicate downloads.

| Endpoint                                  | URL (via litellm)                  | Auth                              |
| ----------------------------------------- | ---------------------------------- | --------------------------------- |
| Chat (OpenAI-compat)                      | `POST /v1/chat/completions`        | `Bearer $LITELLM_MASTER_KEY`      |
| Completions (legacy OpenAI)               | `POST /v1/completions`             | `Bearer $LITELLM_MASTER_KEY`      |
| Embeddings                                | `POST /v1/embeddings`              | `Bearer $LITELLM_MASTER_KEY`      |
| Health (internal)                         | `GET vllm-cuda:8000/healthz`       | none                              |
| Loaded models (internal)                  | `GET vllm-cuda:8000/api/ps`        | none                              |
| Unload one (internal — resource_manager)  | `DELETE vllm-cuda:8000/api/ps/{id}`| none                              |
| Unload all (internal)                     | `POST vllm-cuda:8000/unload`       | none                              |

Default models:

- `nomic-embed-v2` — `nomic-ai/nomic-embed-text-v2-moe` (MoE, 305M active, 8192 ctx, embeddings only)
- `qwen3-0.6b` — `Qwen/Qwen3-0.6B` (chat + completions, 16384 ctx)

LiteLLM aliases register per enabled variant:

- `VLLM=1` → `local-vllm-nomic-embed-v2`, `local-vllm-qwen3-0.6b`
- `VLLM_CUDA=1` → `local-vllm-cuda-nomic-embed-v2`, `local-vllm-cuda-qwen3-0.6b`

Every tunable below has a CPU (`VLLM_*`) and CUDA (`VLLM_CUDA_*`) counterpart with the same meaning and default:

| Tunable | Default | Notes |
| ------- | ------- | ----- |
| `VLLM_MODEL_TTL` / `VLLM_CUDA_MODEL_TTL` | `600` | Seconds idle before the subprocess is killed (`-1` disables) |
| `VLLM_SWEEPER_INTERVAL` / `VLLM_CUDA_SWEEPER_INTERVAL` | `60` | How often the idle sweeper checks (seconds) |
| `VLLM_LOAD_TIMEOUT` / `VLLM_CUDA_LOAD_TIMEOUT` | `600` | Max time to wait for `/health` after spawning `vllm serve` |
| `VLLM_REQUEST_TIMEOUT` / `VLLM_CUDA_REQUEST_TIMEOUT` | `300` | Per-request proxy timeout |
| `VLLM_LOG_LEVEL` / `VLLM_CUDA_LOG_LEVEL` | `INFO` | Wrapper log level |
| `VLLM_PRELOAD` / `VLLM_CUDA_PRELOAD` | _empty_ | Pre-spawn this model_id at boot |
| `VLLM_PREFETCH` / `VLLM_CUDA_PREFETCH` | _empty_ | Comma-separated model_ids the entrypoint should fetch on first start |
| `VLLM_MEM_LIMIT` / `VLLM_CUDA_MEM_LIMIT` | `12g` | Container memory limit |
| `VLLM_CPUS` / `VLLM_CUDA_CPUS` | `4.0` | Container CPU limit |
| `VLLM_CPU_KVCACHE_SPACE` | `4` | CPU-only: GB of RAM reserved for the vllm KV cache |
| `DATA_DIR_VLLM` | `${DATA_DIR}/vllm` | Bind-mount root for the wrapper's `/data` dir. Holds the flat HF-repo layout under `models/<org>/<repo>/<files>` (no blobs/snapshots dedup) — `vllm-pull` populates this via `huggingface-cli download <repo> --local-dir <path>`. Both CPU and CUDA wrappers, and any other service mounting the same dir, share the same files. |

---

## llamacpp / llamacpp-cuda — local GGUF + vision VLMs (optional, `LLAMACPP=1` / `LLAMACPP_CUDA=1`)

Sister service to `vllm` / `vllm-cuda` — same lifecycle surface (`/api/ps`, `DELETE /api/ps/{model_id}`, `POST /unload`, idle-TTL unload, single-resident-model-at-a-time enforced by the supervisor), but the underlying engine is `llama-server` from llama.cpp, the weights are GGUF, and **vision models (mmproj)** are supported. Picks the slack from vllm-wrap's weak vision support on CPU and serves any Qwen3-VL-class document model cleanly on either hardware.

Base images pinned by digest: `ghcr.io/ggml-org/llama.cpp:server@sha256:7d02b045...` (CPU) and `:server-cuda@sha256:841b199a...` (CUDA), both upstream build `b9603` (rev `ba1df050f3dc78...`). Wrapper code lives in `llamacpp/src/llamacpp_wrap/` and mirrors `vllm/src/vllm_wrap/` 1-for-1.

### Default model — Surya OCR 2

`datalab-to/surya-ocr-2-gguf` (revision `6a3a4c30e5e74...`, ~650M params, Apache-2.0 code / modified AI Pubs Open Rail-M weights, free for research/personal/startups <$5M ARR). One VLM that handles **OCR**, **layout detection**, and **table recognition** — behaviour switches on the **prompt string**, not on the model.

> **Surya prompts are training-time contracts.** Paraphrasing them produces unpredictable output mode (the model emits a layout-JSON instead of OCR-HTML when given a generic "transcribe this" prompt). Pass the literal strings below.

| Task | Prompt (verbatim) | Output shape |
| ---- | ----------------- | ------------ |
| **Block OCR** | `OCR this block image to HTML.` | HTML for one tight crop. Use after layout-segmenting a page; equivalent to `RecognitionPredictor`'s block mode. |
| **Full-page OCR** | `OCR this image to HTML. Each block is a div with data-label and data-bbox (x0 y0 x1 y1, normalized 0-1000).` | Whole page OCR'd in one call, blocks tagged with `data-label` + `data-bbox`. Equivalent to `RecognitionPredictor`'s default full-page mode. |
| **Layout detection** | `Output the layout of this image as JSON. Each entry is a dict with "label", "bbox", and "count" fields. Bbox is x0 y0 x1 y1, normalized 0-1000.` | JSON array of `{label, bbox, count}` describing the reading-order-sorted blocks. Labels are the canonical Surya set: `Text`, `SectionHeader`, `Caption`, `Footnote`, `Equation`, `ListGroup`, `Picture`, `Table`, `Form`, `PageHeader`, `PageFooter`, `TableOfContents`, `Figure`, `Code`, `Bibliography`, `BlankPage`, `ChemicalBlock`, `Diagram`. |
| **Table recognition** | `Output the table rows then columns as JSON. Each entry is a dict with "label" ("Row" or "Col") and "bbox" (x0 y0 x1 y1, normalized 0-1000).` | JSON array of `{label, bbox}` where label is `Row` or `Col`. Geometric intersections give the cells (simple mode). For full HTML (spanning cells / headers) use `TableRecPredictor.predict_full()` from the upstream Surya Python lib, pointed at our endpoint. |

### Endpoints

| Endpoint                                  | URL (via LiteLLM)                       | Auth                              |
| ----------------------------------------- | --------------------------------------- | --------------------------------- |
| Chat (OpenAI-compat, vision-capable)      | `POST /v1/chat/completions`             | `Bearer $LITELLM_MASTER_KEY`      |
| Completions (legacy OpenAI)               | `POST /v1/completions`                  | `Bearer $LITELLM_MASTER_KEY`      |
| Embeddings                                | `POST /v1/embeddings`                   | `Bearer $LITELLM_MASTER_KEY`      |
| Health (internal)                         | `GET llamacpp{,-cuda}:8000/healthz`     | none                              |
| Loaded model (internal)                   | `GET llamacpp{,-cuda}:8000/api/ps`      | none                              |
| Unload one (internal — resource_manager)  | `DELETE llamacpp{,-cuda}:8000/api/ps/{id}` | none                            |
| Unload all (internal)                     | `POST llamacpp{,-cuda}:8000/unload`     | none                              |

LiteLLM model slugs (registered once each variant is enabled):

- `LLAMACPP=1` → `local-llamacpp-surya-ocr-2`
- `LLAMACPP_CUDA=1` → `local-llamacpp-cuda-surya-ocr-2`

### Image input — data URLs OR http(s)

The wrapper accepts both, and rewrites the request before forwarding to `llama-server` (which only natively accepts `data:` URLs):

```jsonc
"content": [
  // EITHER inline base64:
  { "type": "image_url", "image_url": { "url": "data:image/png;base64,iVBORw0K..." } },
  // OR any http(s) URL the wrapper can reach from inside the docker network:
  { "type": "image_url", "image_url": { "url": "https://example.com/page.png" } },
  { "type": "image_url", "image_url": { "url": "http://hybrids3:8080/uploads/scan-1.png" } },
  { "type": "image_url", "image_url": { "url": "http://nginx:4000/storage/uploads/scan-1.png" } },
  { "type": "text", "text": "<one of the prompts from the table above>" }
]
```

URL fetching is hard-capped at **32 MB / 30 s** per image, follows redirects, and trusts an explicit `image/*` Content-Type when present (falls back to the URL extension). Anything else (non-`http(s)`, non-`data:`, missing) is passed through untouched so the underlying backend's own error handling kicks in.

PDFs are NOT a native input — rasterize page 1 (and beyond) to PNG client-side at **96 DPI** (Surya's training-time default; higher DPI inflates the prompt-token count quadratically without quality gain). Examples: `pdftoppm -png -r 96 -f 1 -l 1 doc.pdf out`, or `pdf2image` from Python.

### Throughput — what to expect, per hardware

The vision encoder runs once per image and is the dominant cost. Token count after encoding scales **roughly quadratically with image area**, so DPI choice for PDFs matters a lot on CPU. Wall-clock numbers below are measured end-to-end through the LiteLLM router → llamacpp wrapper → llama-server pipeline (real test runs, not isolated benchmarks).

#### CUDA (RTX-class single-GPU)

| Task | Image | Wall clock per call |
|---|---|---|
| Captcha OCR (block) | 400×120 PNG | ~3 s |
| Full-page OCR | A4 page @ 96 DPI (~794×1123) | ~6-12 s |
| Layout detection | A4 page @ 96 DPI | ~5-10 s |
| Table recognition | Table-only crop | ~3-6 s |

Suitable for interactive workloads. Idle TTL unload returns VRAM to other CUDA services (ollama / sdcpp / talkies / vllm) — first request after eviction pays the model-load cost (~5-10 s).

#### CPU (4-core container, `--n-gpu-layers 0`)

Measured against the actual test fixtures:

| Task | Image | Wall clock per call |
|---|---|---|
| Captcha OCR (block) | 400×120 PNG | **~24 s** |
| URL-fetch captcha (block) | same, fetched from hybrids3 first | **~24 s** |
| Full-page OCR | A4 page @ 96 DPI (~794×1123, ~1100 prompt tokens) | **~2-3 min** |
| Layout detection | A4 page @ 96 DPI | **~2 min** |
| Table recognition | Table PDF @ 96 DPI | **~2 min** |
| Full-page OCR | A4 page @ **200 DPI** (~1654×2339, ~3940 prompt tokens) | **~7+ min** (avoid — see below) |

Suitable for **batch / overnight document processing**, sub-second small-image OCR (captchas, single-line crops). Not suitable for interactive A4-page work.

#### DPI sweet spot

- **96 DPI is Surya's training-time default** — going higher rarely helps text accuracy and inflates the token count quadratically.
- **Lower than 96 DPI** starts breaking small text recognition (footnotes, dense tables, low-contrast scans).
- For batch CPU work, stay at 96 DPI. For CUDA, 96 DPI is still preferred (faster encode, same accuracy).

Both `pdftoppm` (poppler) and Python's `pdf2image.convert_from_path(..., dpi=96)` default to higher DPI — pass `-r 96` / `dpi=96` explicitly.

### Configuration

Every tunable below has a CPU (`LLAMACPP_*`) and CUDA (`LLAMACPP_CUDA_*`) counterpart with the same meaning and default:

| Tunable | Default | Notes |
| ------- | ------- | ----- |
| `LLAMACPP_MODEL_TTL` / `LLAMACPP_CUDA_MODEL_TTL` | `600` | Seconds idle before `llama-server` is killed (`-1` disables) |
| `LLAMACPP_SWEEPER_INTERVAL` / `LLAMACPP_CUDA_SWEEPER_INTERVAL` | `60` | How often the idle sweeper checks (seconds) |
| `LLAMACPP_LOAD_TIMEOUT` / `LLAMACPP_CUDA_LOAD_TIMEOUT` | `600` | Max time to wait for `/health` after spawning `llama-server` |
| `LLAMACPP_REQUEST_TIMEOUT` / `LLAMACPP_CUDA_REQUEST_TIMEOUT` | `300` | Per-request proxy timeout |
| `LLAMACPP_LOG_LEVEL` / `LLAMACPP_CUDA_LOG_LEVEL` | `INFO` | Wrapper log level |
| `LLAMACPP_PRELOAD` / `LLAMACPP_CUDA_PRELOAD` | _empty_ | Pre-spawn this model_id at boot |
| `LLAMACPP_MEM_LIMIT` / `LLAMACPP_CUDA_MEM_LIMIT` | `12g` | Container memory limit |
| `LLAMACPP_CPUS` / `LLAMACPP_CUDA_CPUS` | `4.0` | Container CPU limit |
| `DATA_DIR_LLAMACPP` | `${DATA_DIR}/llamacpp` | Bind-mount root for the wrapper's `/data` dir. Holds the flat HF-repo layout under `models/<org>/<repo>/<files>` (no blobs/snapshots dedup) — the `llamacpp-pull` sidecar populates this via `huggingface-cli download <repo> --local-dir <path>` reading from BOTH `llamacpp/models.cpu.json` and `models.cuda.json` (union of `repo` fields). Both CPU and CUDA wrappers share the same files. |

Per-model GGUF + mmproj filenames + `llama-server` extra args are declared in `llamacpp/models.{cpu,cuda}.json`. Adding a new model:

1. Append a new entry to both JSONs (or one if it's only relevant for one hardware). Required fields: `repo`, `gguf_file`, `endpoints`. Optional: `revision`, `mmproj_file` (vision models), `llama_server_args` (e.g. `--ctx-size`, `--n-gpu-layers`, `--parallel`).
2. Bring the stack down and back up — the `llamacpp-pull` sidecar will fetch the new repo on next boot.
3. Add a corresponding LiteLLM provider entry to `litellm/config/providers/llamacpp{,-cuda}.yaml` and regenerate `config.yaml` via `make build-config`.
4. If the new model is heavy enough to need its own resource_manager group, add a `_LLAMACPP_MODELS` entry in `litellm/callbacks/resource_manager.py` so the `DELETE /api/ps/{model_id}` eviction fires on it.

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

## predictalot (optional, `PREDICTALOT=1` / `PREDICTALOT_CUDA=1`)

Foundation time-series forecasting (`chronos-2`, `timesfm-2.5`, `moirai-2`, `toto-1`, `sundial-base-128m`). Type-routed REST + MCP. Direct nginx route, not via LiteLLM. MCP is aggregated into `/mcp/`.

CPU and CUDA variants run **side-by-side** on distinct routes and aliases — `/predictalot/` → CPU container, `/predictalot-cuda/` → GPU container. Enable independently via `PREDICTALOT=1` and/or `PREDICTALOT_CUDA=1`. CUDA needs `nvidia-container-toolkit`. Both share `${DATA_DIR_PREDICTALOT}/models` so the second variant to boot reuses the first's HF snapshots with zero re-fetch.

| Endpoint        | CPU (`PREDICTALOT=1`)                   | CUDA (`PREDICTALOT_CUDA=1`)                   |
| --------------- | --------------------------------------- | --------------------------------------------- |
| REST            | `http://localhost:4000/predictalot/*`   | `http://localhost:4000/predictalot-cuda/*`    |
| MCP (direct)    | `http://localhost:4000/predictalot/mcp` | `http://localhost:4000/predictalot-cuda/mcp` |
| MCP (aggregated)| `http://localhost:4000/mcp/` (`predictalot-*` prefix) | `http://localhost:4000/mcp/` (`predictalot_cuda-*` prefix) |
| Health          | `http://localhost:4000/predictalot/healthz` | `http://localhost:4000/predictalot-cuda/healthz` |

Auth: `Authorization: Bearer $PREDICTALOT_AUTH_TOKEN` (defaults to `AIGATE_TOKEN`).

Full API — endpoints, request/response shapes, per-model quirks, accuracy benchmarks: **[docker-predictalot README](https://github.com/psyb0t/docker-predictalot)**.

Env vars: `PREDICTALOT_AUTH_TOKEN`, `PREDICTALOT_DEVICE` (CPU), `PREDICTALOT_CUDA_DEVICE` (CUDA), `PREDICTALOT_PREFETCH`, `PREDICTALOT_PRELOAD`, `PREDICTALOT_MODEL_IDLE_TIMEOUT`, `PREDICTALOT_MAX_BODY_SIZE`, `PREDICTALOT_LOG_LEVEL`, `DATA_DIR_PREDICTALOT`, per-route `RATELIMIT_PREDICTALOT[_BURST]` and `RATELIMIT_PREDICTALOT_CUDA[_BURST]`, shared `TIMEOUT_PREDICTALOT`. Full reference in [`.env.example`](../.env.example).

---

## audiolla (optional, `AUDIOLLA=1` / `AUDIOLLA_CUDA=1`)

Self-hosted **audio-production** REST + MCP API (v1.0.1+). Stem separation (Demucs / UVR), restoration (UVR de-reverb / de-echo / de-noise), mastering (matchering + pedalboard chains), MIR analysis (librosa: BPM, key, LUFS, beats, onsets, melody, chords, segments), DSP transforms (sox + ffmpeg), loudness normalization, speech enhancement (DeepFilterNet), VAD (silero), diarization (pyannote), CLAP embeddings + zero-shot classification, AudioSet tagging (AST), audio→MIDI (basic-pitch), MIDI compose / inspect / transform / render via fluidsynth. **CUDA-only text-to-audio generation** under `POST /v1/audio/generate/{engine}`: `stable-audio-open` (Stability Community Licence), `musicgen-small` / `musicgen-medium` (CC-BY-NC — gated on `AUDIOLLA_ENABLE_NONCOMMERCIAL=1`), `riffusion` (CreativeML OpenRAIL-M), `audioldm2` (CC-BY 4.0 — commercial-safe, no opt-in).

Curated YAML workflow presets ship in-image (`master-for-spotify`, `podcast-cleanup`, `vocal-cleanup`). Ad-hoc op-chain pipelines run server-side — intermediates stay in memory between steps, no re-upload. Async jobs + webhooks for long-running work. Direct nginx route, not via LiteLLM. MCP is aggregated into `/mcp/`.

**API contract (breaking from v0.23.x):** every audio endpoint takes a **JSON body**. The only multipart/raw-bytes route is `PUT /v1/files/{path}` for staging. Input is `file_path` (FILES_DIR-relative, after staging) XOR `file_url` (server fetches, subject to `AUDIOLLA_FETCH_MODE`). Audio-producing tools require **`output_path` XOR `output_url`** (`output_path` stages under `${DATA_DIR_AUDIOLLA}/files` — caller downloads via `GET /v1/files/<path>`; `output_url` PUTs to a presigned URL). The pre-1.0 `*_base64` response fields are gone — pull results from the staging area.

CPU and CUDA variants run **side-by-side** on distinct routes and aliases — `/audiolla/` → CPU container, `/audiolla-cuda/` → GPU container. Enable independently via `AUDIOLLA=1` and/or `AUDIOLLA_CUDA=1`. CUDA needs `nvidia-container-toolkit` and is significantly faster on Demucs, UVR, pyannote, basic-pitch, DeepFilterNet, CLAP. Both share `${DATA_DIR_AUDIOLLA}` for the weight cache, so the second variant to boot reuses the first's downloads with zero re-fetch.

| Endpoint        | CPU (`AUDIOLLA=1`)                   | CUDA (`AUDIOLLA_CUDA=1`)                   |
| --------------- | ------------------------------------ | ------------------------------------------ |
| REST            | `http://localhost:4000/audiolla/*`   | `http://localhost:4000/audiolla-cuda/*`    |
| MCP (direct)    | `http://localhost:4000/audiolla/v1/mcp` | `http://localhost:4000/audiolla-cuda/v1/mcp` |
| MCP (aggregated)| `http://localhost:4000/mcp/` (`audiolla-*` prefix) | `http://localhost:4000/mcp/` (`audiolla_cuda-*` prefix) |
| Health          | `http://localhost:4000/audiolla/healthz` | `http://localhost:4000/audiolla-cuda/healthz` |
| Catalog         | `GET /audiolla/v1/catalog`           |
| Engine lifecycle| `GET /audiolla/v1/ps`, `DELETE /audiolla/v1/ps/{engine}`, `POST /audiolla/v1/unload` |

Auth: `Authorization: Bearer $AUDIOLLA_AUTH_TOKEN` (defaults to `AIGATE_TOKEN`). Pyannote diarization additionally needs `HF_TOKEN` + the user accepting model terms at huggingface.co/pyannote/speaker-diarization-3.1.

Full API — every endpoint, every request/response shape, all 90+ routes, generation engines, presets, pipelines, MCP tool list, server-side URL fetch policy, the v0.23→v1.0 migration cheatsheet, and the canonical `openapi.yaml`: **[docker-audiolla README](https://github.com/psyb0t/docker-audiolla)**.

Env vars: `AUDIOLLA_AUTH_TOKEN`, `AUDIOLLA_DEVICE`, `AUDIOLLA_ENABLED_ENGINES`, `AUDIOLLA_PRELOAD`, `AUDIOLLA_ENGINE_TTL`, `AUDIOLLA_SWEEPER_INTERVAL`, `AUDIOLLA_MAX_UPLOAD_BYTES`, `AUDIOLLA_FETCH_*` (server-side URL fetch policy), `AUDIOLLA_JOB_TTL`, `AUDIOLLA_JOB_MAX_CONCURRENT`, `AUDIOLLA_ENABLE_NONCOMMERCIAL` (CC-BY-NC opt-in for MusicGen), `DATA_DIR_AUDIOLLA`, `RATELIMIT_AUDIOLLA[_BURST]`, `TIMEOUT_AUDIOLLA`. Full reference in [`.env.example`](../.env.example).

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
| vllm-cuda | 10 minutes | `VLLM_CUDA_MODEL_TTL` (wrapper idle sweeper); resource manager also triggers `DELETE /api/ps/{model}` |
| vllm (CPU) | 10 minutes | `VLLM_MODEL_TTL` (wrapper idle sweeper); resource manager also triggers `DELETE /api/ps/{model}` |

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
| talkies / vllm-cuda | `DELETE /api/ps/{model_id}` (per model) or `POST /unload` (kill any loaded) |

### Non-blocking rejection

The sd.cpp wrapper uses `TryLock` — if a generation or model swap is in progress, new requests get 503 immediately instead of queuing. Scheduling happens at the LiteLLM layer via the semaphore, not inside individual services.
