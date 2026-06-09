# Usage

## Chat Completions

Standard OpenAI-compatible chat completions. Works with any OpenAI SDK, library, or tool that supports custom base URLs.

```bash
# cloud provider (free tier, auto-fallback on rate limit)
curl http://localhost:4000/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "mistral-large", "messages": [{"role": "user", "content": "explain mixture of experts"}]}'

# streaming (SSE)
curl http://localhost:4000/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "cerebras-qwen3-235b", "messages": [{"role": "user", "content": "write a haiku"}], "stream": true}'
```

### Python (openai SDK)

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:4000",
    api_key=LITELLM_MASTER_KEY,
)

# chat
resp = client.chat.completions.create(
    model="cerebras-qwen3-235b",
    messages=[{"role": "user", "content": "hello"}],
)
print(resp.choices[0].message.content)

# streaming
stream = client.chat.completions.create(
    model="cerebras-qwen3-235b",
    messages=[{"role": "user", "content": "count to 10"}],
    stream=True,
)
for chunk in stream:
    print(chunk.choices[0].delta.content or "", end="", flush=True)
```

---

## Browser Automation

The browser cluster can be used directly via the REST API, or indirectly by letting an LLM invoke browser tools through MCP.

### Direct REST API

```bash
# navigate to a page
curl -X POST http://localhost:4000/stealthy-auto-browse/ \
  -H "Authorization: Bearer $STEALTHY_AUTO_BROWSE_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"action": "goto", "url": "https://example.com"}'

# get all visible text
curl -X POST http://localhost:4000/stealthy-auto-browse/ \
  -H "Authorization: Bearer $STEALTHY_AUTO_BROWSE_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"action": "get_text"}'

# find all interactive elements with their coordinates
curl -X POST http://localhost:4000/stealthy-auto-browse/ \
  -H "Authorization: Bearer $STEALTHY_AUTO_BROWSE_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"action": "get_interactive_elements", "visible_only": true}'

# click at coordinates (OS-level, undetectable)
curl -X POST http://localhost:4000/stealthy-auto-browse/ \
  -H "Authorization: Bearer $STEALTHY_AUTO_BROWSE_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"action": "system_click", "x": 640, "y": 400}'

# type text (OS-level keyboard input)
curl -X POST http://localhost:4000/stealthy-auto-browse/ \
  -H "Authorization: Bearer $STEALTHY_AUTO_BROWSE_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"action": "system_type", "text": "hello world"}'

# screenshot — returns raw PNG (1920x1080 by default, always resize)
curl -H "Authorization: Bearer $STEALTHY_AUTO_BROWSE_AUTH_TOKEN" \
  "http://localhost:4000/stealthy-auto-browse/screenshot/browser?whLargest=512" -o screenshot.png
curl -H "Authorization: Bearer $STEALTHY_AUTO_BROWSE_AUTH_TOKEN" \
  "http://localhost:4000/stealthy-auto-browse/screenshot/browser?width=800" -o screenshot.png

# run a multi-step script atomically (all steps on the same replica, single request)
curl -X POST http://localhost:4000/stealthy-auto-browse/ \
  -H "Authorization: Bearer $STEALTHY_AUTO_BROWSE_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "action": "run_script",
    "steps": [
      {"action": "goto", "url": "https://duckduckgo.com"},
      {"action": "system_click", "x": 950, "y": 513},
      {"action": "system_type", "text": "what is groq?"},
      {"action": "send_key", "key": "enter"},
      {"action": "wait_for_element", "selector": "[data-testid='\''result'\'']", "timeout": 10},
      {"action": "get_text"}
    ]
  }'
```

Browser sessions are sticky via the `INSTANCEID` cookie. Use a persistent HTTP client to keep your session on the same replica across requests.

### Python — search, screenshot, upload, summarize

```python
import requests

session = requests.Session()  # sticky via INSTANCEID cookie
BASE = "http://localhost:4000"
SAB_AUTH = {"Authorization": f"Bearer {STEALTHY_AUTO_BROWSE_AUTH_TOKEN}"}

def browser(action, **kwargs):
    r = session.post(f"{BASE}/stealthy-auto-browse/", headers=SAB_AUTH, json={"action": action, **kwargs})
    r.raise_for_status()
    return r.json()["data"]

# navigate and search
browser("goto", url="https://duckduckgo.com")
browser("system_click", x=950, y=513)
browser("system_type", text="what is groq?")
browser("send_key", key="enter")
browser("wait_for_element", selector="[data-testid='result']", timeout=10000)
text = browser("get_text")["text"]

# screenshot and upload
screenshot = session.get(f"{BASE}/stealthy-auto-browse/screenshot/browser", headers=SAB_AUTH).content
requests.put(
    f"{BASE}/storage/uploads/search.png",
    headers={"Authorization": f"Bearer {HYBRIDS3_UPLOADS_KEY}", "Content-Type": "image/png"},
    data=screenshot,
)

# ask an LLM to summarize
r = requests.post(f"{BASE}/chat/completions",
    headers={"Authorization": f"Bearer {LITELLM_MASTER_KEY}", "Content-Type": "application/json"},
    json={"model": "cerebras-qwen3-235b", "messages": [
        {"role": "user", "content": f"Summarize these search results:\n\n{text[:8000]}"}
    ]})
print(r.json()["choices"][0]["message"]["content"])
```

---

## Object Storage

[hybrids3](https://github.com/psyb0t/docker-hybrids3) — S3-compatible, public-read uploads bucket, bearer token auth, TTL-based expiry.

### Basic CRUD

```bash
# upload (MIME type auto-detected from content)
curl -X PUT http://localhost:4000/storage/uploads/image.png \
  -H "Authorization: Bearer $HYBRIDS3_UPLOADS_KEY" \
  -H "Content-Type: image/png" \
  --data-binary @image.png

# download — public, no auth required
curl http://localhost:4000/storage/uploads/image.png -o image.png

# list files (supports ?prefix= and ?max-keys=)
curl "http://localhost:4000/storage/uploads?prefix=images/" \
  -H "Authorization: Bearer $HYBRIDS3_UPLOADS_KEY"

# delete
curl -X DELETE http://localhost:4000/storage/uploads/image.png \
  -H "Authorization: Bearer $HYBRIDS3_UPLOADS_KEY"
```

### Presigned URLs

Generate a time-limited URL that anyone can download without auth credentials:

```bash
# generate (default 1 hour, max 7 days)
curl -X POST "http://localhost:4000/storage/presign/uploads/report.pdf?expires=86400" \
  -H "Authorization: Bearer $HYBRIDS3_UPLOADS_KEY"

# response for public bucket — plain URL (no expiry needed since bucket is public-read anyway)
{"url": "http://localhost:4000/storage/uploads/report.pdf", "expires": null}

# download via presigned URL — no auth header
curl "http://localhost:4000/storage/uploads/report.pdf"
```

### Nested paths

Object keys support `/` for directory-like organization:

```bash
curl -X PUT "http://localhost:4000/storage/uploads/projects/myapp/build.tar.gz" \
  -H "Authorization: Bearer $HYBRIDS3_UPLOADS_KEY" \
  --data-binary @build.tar.gz

# list only that project's files
curl "http://localhost:4000/storage/uploads?prefix=projects/myapp/" \
  -H "Authorization: Bearer $HYBRIDS3_UPLOADS_KEY"
```

### boto3

```python
import boto3
from botocore.config import Config

s3 = boto3.client(
    "s3",
    endpoint_url="http://localhost:4000/storage",
    aws_access_key_id="uploads",              # bucket name (acts as public_key)
    aws_secret_access_key=HYBRIDS3_UPLOADS_KEY,
    region_name="us-east-1",
    config=Config(signature_version="s3v4"),
)

s3.upload_file("image.png", "uploads", "images/photo.png")
obj = s3.get_object(Bucket="uploads", Key="images/photo.png")
data = obj["Body"].read()

s3.list_objects_v2(Bucket="uploads", Prefix="images/")
s3.delete_object(Bucket="uploads", Key="images/photo.png")

# generate presigned URL
url = s3.generate_presigned_url(
    "get_object",
    Params={"Bucket": "uploads", "Key": "images/photo.png"},
    ExpiresIn=3600,
)
```

Configure TTL and size limits in `.env`:

```env
HYBRIDS3_UPLOADS_TTL=168h        # auto-delete after N time (default 7 days)
HYBRIDS3_UPLOADS_MAX_SIZE=100MB  # per-file size limit
```

---

## Agentic coding — Claudebox + Pibox-zai

Two agentic services wrap a coding agent in a Docker container and expose it as an API. Each request runs the agent's full loop — read/write files, run shell commands, install packages, browse the web, use tools, all within an isolated workspace.

- **[Claudebox](https://github.com/psyb0t/docker-claudebox)** — Claude Code, OAuth token or Anthropic API key. Models: `claudebox-haiku`, `claudebox-sonnet`, `claudebox-opus`.
- **[Pibox-zai](https://github.com/psyb0t/docker-pibox)** — [pi-coding-agent](https://github.com/earendil-works/pi-mono) pointed at z.ai for GLM models. Models: `pibox-zai-glm-4.5-air`, `pibox-zai-glm-4.7`, `pibox-zai-glm-5.1`. Adds `/files/*` CRUD plus optional Telegram + cron modes.

Both speak the Anthropic wire protocol and expose the same shape of API (sync + async `/run`, OpenAI-compatible `/v1/chat/completions`, MCP server).

### Via LiteLLM chat completions

The simplest way — just use claudebox models in the standard chat API:

```bash
curl http://localhost:4000/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claudebox-sonnet",
    "messages": [{"role": "user", "content": "list all Python files in this workspace"}],
    "extra_headers": {"X-Claude-Workspace": "myproject"}
  }'
```

### Via direct API

More control: structured output formats, session resumption, fire-and-forget, tool call history.

```bash
# basic run
curl -X POST http://localhost:4000/claudebox/run \
  -H "Authorization: Bearer $CLAUDEBOX_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "write a Go HTTP server", "workspace": "go-project"}'

# with structured JSON output
curl -X POST http://localhost:4000/claudebox/run \
  -H "Authorization: Bearer $CLAUDEBOX_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "extract the name and version from package.json",
    "workspace": "myproject",
    "jsonSchema": "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"version\":{\"type\":\"string\"}},\"required\":[\"name\",\"version\"]}"
  }'

# with full tool call history
curl -X POST http://localhost:4000/claudebox/run \
  -H "Authorization: Bearer $CLAUDEBOX_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "build the project and run tests", "workspace": "myapp", "outputFormat": "json-verbose"}'

# check which workspaces are busy
curl http://localhost:4000/claudebox/status \
  -H "Authorization: Bearer $CLAUDEBOX_API_TOKEN"

# cancel a running task
curl -X POST "http://localhost:4000/claudebox/run/cancel?workspace=myapp" \
  -H "Authorization: Bearer $CLAUDEBOX_API_TOKEN"
```

### File operations

```bash
# upload a file to a workspace
curl -X PUT http://localhost:4000/claudebox/files/myproject/data.csv \
  -H "Authorization: Bearer $CLAUDEBOX_API_TOKEN" \
  --data-binary @data.csv

# list files in a workspace
curl http://localhost:4000/claudebox/files/myproject \
  -H "Authorization: Bearer $CLAUDEBOX_API_TOKEN"

# download a file from a workspace
curl http://localhost:4000/claudebox/files/myproject/results.json \
  -H "Authorization: Bearer $CLAUDEBOX_API_TOKEN" \
  -o results.json

# delete a file
curl -X DELETE http://localhost:4000/claudebox/files/myproject/old.log \
  -H "Authorization: Bearer $CLAUDEBOX_API_TOKEN"
```

### File + task workflow

```bash
# 1. upload input data
curl -X PUT http://localhost:4000/claudebox/files/analysis/sales.csv \
  -H "Authorization: Bearer $CLAUDEBOX_API_TOKEN" \
  --data-binary @sales.csv

# 2. run analysis (Claude reads the file, writes a report)
curl -X POST http://localhost:4000/claudebox/run \
  -H "Authorization: Bearer $CLAUDEBOX_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "analyze sales.csv, compute monthly totals and trends, write a report to report.md", "workspace": "analysis"}'

# 3. download the report
curl http://localhost:4000/claudebox/files/analysis/report.md \
  -H "Authorization: Bearer $CLAUDEBOX_API_TOKEN"
```

### Always-active skills

Drop a `SKILL.md` file into a named subdirectory under `.data/claudebox/config/.always-skills/` — it will be injected into the system prompt of every Claude invocation automatically. No restarts needed. Applies to API, MCP, chat, everything.

```
.data/claudebox/config/.always-skills/
└── coding-rules/
    └── SKILL.md   ← injected into every session
```

Example `SKILL.md`:

```markdown
When writing Go code, always use slog for structured logging, never fmt.Println.
When writing Python, always use pathlib for file paths, never os.path.
Always write tests alongside implementations.
```

Skills stack — every `SKILL.md` found is appended in alphabetical order by directory name. Per-request `appendSystemPrompt` or `X-Claude-Append-System-Prompt` is appended after always-skills, so per-request instructions take precedence.

---

## Image Generation

```bash
# image generation (cloud — HuggingFace FLUX)
curl http://localhost:4000/images/generations \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "hf-flux-schnell", "prompt": "cyberpunk city at night"}'

# image generation (local CUDA — sd-turbo, fast)
curl http://localhost:4000/images/generations \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "local-sdcpp-cuda-sd-turbo", "prompt": "cyberpunk city at night", "size": "512x512"}'

# image generation (local CPU — sd-turbo, slower)
curl http://localhost:4000/images/generations \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "local-sdcpp-cpu-sd-turbo", "prompt": "cyberpunk city at night", "size": "512x512"}'
```

---

## Vision

Upload an image to storage (public URL), then pass it to a vision model:

```bash
# upload the image
curl -X PUT http://localhost:4000/storage/uploads/photo.jpg \
  -H "Authorization: Bearer $HYBRIDS3_UPLOADS_KEY" \
  -H "Content-Type: image/jpeg" \
  --data-binary @photo.jpg

# public URL — no auth needed to read from uploads bucket
# http://localhost:4000/storage/uploads/photo.jpg

# ask a vision model
curl http://localhost:4000/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "groq-llama-4-scout",
    "messages": [{
      "role": "user",
      "content": [
        {"type": "text", "text": "what is in this image?"},
        {"type": "image_url", "image_url": {"url": "http://YOUR_HOST:4000/storage/uploads/photo.jpg"}}
      ]
    }]
  }'
```

Vision-capable models: `groq-llama-4-scout`, `hf-llama-4-scout`, `hf-qwen-vl-72b`, `hf-qwen3-vl-8b`, `hf-gemma-3-12b`, `mistral-small`, `anthropic-claude-opus-4`, `anthropic-claude-sonnet-4`, `anthropic-claude-haiku-4`, `openai-gpt-4o`, `openai-gpt-4o-mini`, `claudebox-opus`, `claudebox-sonnet`, `claudebox-haiku`, `local-ollama-cpu-gemma4-e2b`, `local-ollama-cpu-gemma3-4b`, `local-ollama-cuda-gemma4-e2b`, `local-ollama-cuda-gemma4-e4b`.

---

## Transcription

```bash
curl http://localhost:4000/audio/transcriptions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -F "model=groq-whisper-large-v3" \
  -F "file=@audio.mp3"
```

Transcription models — talkies (CPU+CUDA), plus the hosted Groq/OpenAI offerings:

- **Cloud**: `groq-whisper-large-v3-turbo`, `groq-whisper-large-v3`, `voxtral-small`, `openai-whisper`, `openai-gpt-4o-transcribe`, `openai-gpt-4o-mini-transcribe`
- **Local talkies CPU** (`TALKIES=1`): `local-talkies-whisper-large-v3`, `local-talkies-whisper-large-v3-turbo`, `local-talkies-canary-180m-flash`, `local-talkies-nemotron-3.5-asr-0.6b` (NVIDIA Nemotron-3.5-ASR via parakeet.cpp — 40+ locales, per-word timestamps + confidence)
- **Local talkies CUDA** (`TALKIES_CUDA=1`): same as CPU plus `local-talkies-cuda-parakeet-tdt-0.6b-v3`, `local-talkies-cuda-canary-1b-flash` (EN/DE/FR/ES + EN↔X translation), `local-talkies-cuda-canary-qwen-2.5b` (hybrid SALM)

talkies-specific knobs (any model): `response_format=text|json|verbose_json|srt|vtt`, `diarization=true` (stereo channel-split — left=L, right=R, segments tagged with `channel`).

---

## Text-to-Speech

```bash
# CPU — talkies Kokoro (multiple voices)
curl http://localhost:4000/audio/speech \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "local-talkies-kokoro-tts", "input": "Hello world", "voice": "af_heart"}' \
  -o speech.mp3

# CPU — Kokoro served via NVIDIA's ONNXRuntime export (no PyTorch on hot path)
curl http://localhost:4000/audio/speech \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "local-talkies-kokoro-82m-nvidia", "input": "Hello world", "voice": "af_heart"}' \
  -o speech.mp3

# CUDA — Qwen3-TTS Base 0.6B voice cloning (also inside talkies-cuda as of v0.4.0)
curl http://localhost:4000/audio/speech \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "local-talkies-cuda-qwen3-tts", "input": "Hello world", "voice": "alloy"}' \
  -o speech.mp3

# CUDA — Qwen3-TTS CustomVoice 1.7B + emotion (one of 9 preset speakers)
curl http://localhost:4000/audio/speech \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "local-talkies-cuda-qwen3-tts-1.7b-custom", "input": "Hello world", "voice": "Vivian", "instructions": "happy"}' \
  -o speech.mp3

# CUDA — Qwen3-TTS VoiceDesign (synthesise a voice from a natural-language description)
curl http://localhost:4000/audio/speech \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "local-talkies-cuda-qwen3-tts-1.7b-design", "input": "Hello world", "voice": "design", "instructions": "a young energetic female voice"}' \
  -o speech.mp3
```

TTS models:

- **Kokoro family (~41 voices across en/es/fr/hi/it/pt — discover via `GET /v1/audio/voices`)**:
  - `local-talkies-kokoro-tts` / `local-talkies-cuda-kokoro-tts` — PyTorch path, Kokoro still runs on CPU even inside the CUDA image.
  - `local-talkies-kokoro-82m-nvidia` / `local-talkies-cuda-kokoro-82m-nvidia` — same weights and voice catalog, but served via ONNXRuntime against NVIDIA's TensorRT-friendly ONNX export. No PyTorch on the inference hot path; G2P via espeak-ng. Pick this if you want a leaner runtime; pick the PyTorch one if you prefer misaki-driven G2P quality.
- **Qwen3-TTS family (CUDA-only — 4 modes, all wire-shape OpenAI-compatible; mode is implicit in the model slug)**:
  - `local-talkies-cuda-qwen3-tts` (0.6B Base) / `local-talkies-cuda-qwen3-tts-1.7b` (1.7B Base) — voice cloning. Drop a reference `.wav` (10-30 s clean speech) into `${DATA_DIR_TALKIES}/custom-voices/` and use `voice=<filename-without-ext>`. Nested paths supported (`voice=clients/acme/jane` → `${DATA_DIR_TALKIES}/custom-voices/clients/acme/jane.wav`). Samples `alloy` / `echo` / `fable` baked in. 17 languages.
  - `local-talkies-cuda-qwen3-tts-0.6b-custom` / `local-talkies-cuda-qwen3-tts-1.7b-custom` — CustomVoice mode. Pass `voice=<preset>` where preset is one of 9 baked-in speakers: `Vivian`, `Serena`, `Uncle_Fu`, `Dylan`, `Eric`, `Ryan`, `Aiden`, `Ono_Anna`, `Sohee`. The `1.7b-custom` variant also takes `instructions=<emotion>` (`"happy"` / `"sad"` / …).
  - `local-talkies-cuda-qwen3-tts-1.7b-design` — VoiceDesign mode. Pass `voice="design"` (sentinel) + `instructions=<natural-language description>`; the model synthesises a voice that matches the description.
- **Cloud**: `openai-tts-1`, `openai-tts-1-hd`.

Per-request sampling controls on Qwen3-TTS (v0.8.0+, OpenAI-extras via `extra_body` on official SDKs): `temperature`, `top_k`, `top_p`, `repetition_penalty`, `max_new_tokens`, `do_sample`, plus `language` for CustomVoice / VoiceDesign. Out-of-range returns 422.

Qwen3-TTS streaming: `response_format="pcm"` against any qwen3_tts model streams the raw PCM body via HTTP/1.1 chunked transfer-encoding (TTFA ~200-700 ms vs ~3-8 s buffered). Tune chunk size via `TALKIES_QWEN3_STREAM_CHUNK_SIZE` (default `8` codec-steps-per-chunk).

---

## Embeddings

```bash
# Local — Nomic Embed v2 (MoE) served by the vllm-cuda wrapper
curl http://localhost:4000/v1/embeddings \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "local-vllm-cuda-nomic-embed-v2", "input": "The quick brown fox jumps over the lazy dog"}'

# Batch — pass an array of strings
curl http://localhost:4000/v1/embeddings \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "local-vllm-cuda-nomic-embed-v2", "input": ["doc 1", "doc 2", "doc 3"]}'
```

The vllm-cuda wrapper lazy-loads on the first request and unloads after `VLLM_CUDA_MODEL_TTL` (default 10 minutes) of idleness, so the first request after a cold start incurs the model-load cost (~10-30s). Subsequent requests are immediate until idle-eviction or until a competing CUDA service (`ollama-cuda`, `sdcpp-cuda`, `talkies-cuda`) needs the GPU. To add models, edit `vllm/models.json` (one slug per model, with `repo`, `vllm_args`, and a non-empty `endpoints` array).

---

## LibreChat Web UI

Enable with `LIBRECHAT=1` in `.env`. Access at `http://localhost:4000/librechat/`.

### First-time setup

1. Navigate to `http://localhost:4000/librechat/`
2. Register an account — the first user automatically becomes admin
3. Set `LIBRECHAT_ALLOW_REGISTRATION=false` in `.env` and restart (`docker compose restart librechat`) to lock registration

### What's pre-configured

- All LiteLLM models are available in the model selector (auto-fetched)
- All MCP tools (browser, storage, claudebox, image generation, TTS) are connected and available in conversations
- Conversations are stored in MongoDB and persist across restarts
- WebSocket streaming for real-time responses

### Configuration

All settings are customizable via `.env` — see [services-reference.md](services-reference.md#librechat-optional-librechat1) for the full list of environment variables.

The LibreChat config file at `librechat/librechat.yaml` controls endpoints, MCP servers, and interface settings. Edit it directly for advanced customization (e.g. adding more MCP servers, changing interface options).

---

## Web search (SearXNG MCP)

With `SEARXNG=1`, the MCP `search_web` tool is auto-registered. Any function-calling model can search the web — the tool aggregates Google, Bing, DuckDuckGo, and Wikipedia results through the self-hosted SearXNG at `/searxng/`.

```bash
# direct MCP tools/call
curl -X POST http://localhost:4000/mcp/ \
  -H "Authorization: Bearer $MCP_TOOLS_AUTH_TOKEN" \
  -H "Accept: application/json, text/event-stream" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call",
       "params":{"name":"search_web","arguments":{"query":"site:arxiv.org diffusion models 2026","limit":5}}}'
```

You can also hit the SearXNG UI directly at `http://localhost:4000/searxng/` for ad-hoc queries (protected by nginx admin auth).

→ [SearXNG service reference](services-reference.md#searxng-optional-searxng1) · [MCP tool schema](mcp-tools.md#mcp_tools-auto-enabled-with-imagetts-search-providers)

---

## Time-series forecasting (predictalot)

With `PREDICTALOT=1` the `/predictalot/` route exposes five foundation forecasters via a type-routed REST API + 26-tool MCP surface. Direct nginx route, bearer auth via `PREDICTALOT_AUTH_TOKEN`. MCP is aggregated into `/mcp/`.

Quick smoke test:

```bash
curl http://localhost:4000/predictalot/v1/univariate/forecast \
  -H "Authorization: Bearer $PREDICTALOT_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"chronos-2","context":[[10,11,12,13,14,15,16,17,18,19,20]],"config":{"horizon":5}}'
```

Full API — every type, every model, every ensemble, MCP tool list, accuracy benchmarks: **[docker-predictalot README](https://github.com/psyb0t/docker-predictalot)**.

---

## Audio production (audiolla)

With `AUDIOLLA=1` (or `AUDIOLLA_CUDA=1` for GPU) the `/audiolla/` route exposes a self-hosted audio-production stack — stem separation, restoration, mastering, MIR analysis, DSP transforms, loudness, speech enhancement, diarization, MIDI transcription + composition, **plus text-to-audio generation** (stable-audio-open / musicgen / riffusion / audioldm2 on CUDA). Curated YAML workflow presets and ad-hoc op-chain pipelines run server-side. Direct nginx route, bearer auth via `AUDIOLLA_AUTH_TOKEN`. MCP is aggregated into `/mcp/`.

**v1.0.1 API:** every audio endpoint takes a **JSON body**. The only multipart route is `PUT /v1/files/{path}` for staging raw bytes. Audio-producing endpoints require `output_path` xor `output_url` (no more raw bytes in responses). To run a smoke test you stage the file first, then POST referencing it.

```bash
# 1) stage the source file (this is the ONLY route that takes bytes on the wire)
curl -X PUT http://localhost:4000/audiolla/v1/files/uploads/song.wav \
  -H "Authorization: Bearer $AUDIOLLA_AUTH_TOKEN" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @song.wav

# 2) detect chords + key — JSON in, JSON out (analyze endpoints don't produce audio,
#    so no output_path is needed)
curl -X POST http://localhost:4000/audiolla/v1/audio/chords \
  -H "Authorization: Bearer $AUDIOLLA_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"file_path":"uploads/song.wav"}'

# 3) stem-separate (4 stems) — audio-producing, so output_path is required
curl -X POST http://localhost:4000/audiolla/v1/audio/separate \
  -H "Authorization: Bearer $AUDIOLLA_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"file_path":"uploads/song.wav","engine":"htdemucs","output_paths":{
      "drums":"out/drums.wav","bass":"out/bass.wav",
      "other":"out/other.wav","vocals":"out/vocals.wav"}}'

# 4) download the resulting stem
curl -o vocals.wav http://localhost:4000/audiolla/v1/files/out/vocals.wav \
  -H "Authorization: Bearer $AUDIOLLA_AUTH_TOKEN"

# inspect configured engines + their load state
curl http://localhost:4000/audiolla/v1/engines \
  -H "Authorization: Bearer $AUDIOLLA_AUTH_TOKEN"
```

MusicGen weights are CC-BY-NC 4.0; the engine refuses to load unless `AUDIOLLA_ENABLE_NONCOMMERCIAL=1` is set on the container. AudioLDM 2 is CC-BY 4.0 — no opt-in needed.

Full API — every endpoint, every engine, generators, presets, ad-hoc pipelines, async jobs, fetch policy, MCP tool list, the v0.23 → v1.0 migration cheatsheet: **[docker-audiolla README](https://github.com/psyb0t/docker-audiolla)**.

---

## Email gateway (mailbox)

With `MAILBOX=1`, the `/mailbox/` route fronts N email accounts driven by a single YAML config (`MAILBOX_CONFIG`). Stateless — every read hits the upstream IMAP server live. Bearer auth via `MAILBOX_AUTH_TOKEN` (also mirrored into the config's `auth.tokens:` list).

```bash
# list configured accounts
curl http://localhost:4000/mailbox/mailboxes \
  -H "Authorization: Bearer $MAILBOX_AUTH_TOKEN"

# unified inbox across all accounts (paginated)
curl "http://localhost:4000/mailbox/inbox?limit=10" \
  -H "Authorization: Bearer $MAILBOX_AUTH_TOKEN"

# search a specific account
curl "http://localhost:4000/mailbox/inbox?mailbox=work&subject=invoice&limit=5" \
  -H "Authorization: Bearer $MAILBOX_AUTH_TOKEN"

# send through a configured account (SMTP)
curl -X POST http://localhost:4000/mailbox/mailboxes/work/send \
  -H "Authorization: Bearer $MAILBOX_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"to": ["someone@example.com"], "subject": "hello", "body_text": "from aigate"}'

# delete by uid
curl -X DELETE http://localhost:4000/mailbox/mailboxes/work/messages/<uid> \
  -H "Authorization: Bearer $MAILBOX_AUTH_TOKEN"
```

The MCP catalog is flat regardless of how many accounts you've configured — per-account tools take a `mailbox` parameter (name or address) instead of namespacing.

→ [mailbox service reference](services-reference.md#mailbox-optional-mailbox1) · [mailbox MCP tools](mcp-tools.md#mailbox--imapsmtp-gateway-mailbox1)

---

## Telegram client (telethon)

With `TELETHON=1`, the `/telethon/` route fronts a Telegram client using the official MTProto user-account API. Requires `TELETHON_API_ID` / `TELETHON_API_HASH` from [my.telegram.org/apps](https://my.telegram.org/apps) and a string session in `TELETHON_SESSION`. Bearer auth via `TELETHON_AUTH_KEY`.

```bash
# who am I — verifies the session is authorized
curl http://localhost:4000/telethon/api/me \
  -H "Authorization: Bearer $TELETHON_AUTH_KEY"

# list dialogs
curl "http://localhost:4000/telethon/api/dialogs?limit=10" \
  -H "Authorization: Bearer $TELETHON_AUTH_KEY"

# send a message (markdown supported via parse_mode)
curl -X POST http://localhost:4000/telethon/api/messages \
  -H "Authorization: Bearer $TELETHON_AUTH_KEY" \
  -H "Content-Type: application/json" \
  -d '{"chat": "@username", "text": "**hello** from aigate", "parse_mode": "md"}'

# read recent messages from a chat
curl "http://localhost:4000/telethon/api/messages?chat=me&limit=5" \
  -H "Authorization: Bearer $TELETHON_AUTH_KEY"
```

Chat references accept `@username`, phone numbers, `t.me/...` links, or numeric IDs as strings. The same surface is exposed as MCP tools (`telethon-send_message`, `telethon-get_dialogs`, etc.) so any function-calling model can operate Telegram on your behalf.

→ [Telethon service reference](services-reference.md#telethon-plus-optional-telethon1) · [Telethon MCP tools](mcp-tools.md#telethon-plus--telegram-client-telethon1)
