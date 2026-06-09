# Changelog

All notable changes to this project are documented here.

## [v3.8.1] — 2026-06-09

Docs-only sync for v3.8.0. No behaviour change, no image-pin change, no LiteLLM config change. The v3.8.0 commit shipped the actual code change (audiolla v1.0.5, talkies v0.9.0, nine new LiteLLM model entries) but left the prose docs pinned to the older talkies versions / older model lists. This release pulls the docs forward.

### Files

- `README.md`: services overview table — talkies CPU row updated from `psyb0t/talkies:v0.3.0` (3 Whisper variants + canary-180m + kokoro) to `psyb0t/talkies:v0.9.0` (6 models — adds `nemotron-3.5-asr-0.6b` and `kokoro-82m-nvidia`, drops the long-removed `distil-whisper-large-v3`). Talkies CUDA row updated from `v0.3.0-cuda` to `v0.9.0-cuda` (14 models — adds the full Qwen3-TTS line: Base 0.6B + Base 1.7B + CustomVoice 0.6B + CustomVoice 1.7B + VoiceDesign 1.7B).
- `docs/providers.md`: talkies CPU + CUDA tables grow rows for every new model. CPU gains `local-talkies-nemotron-3.5-asr-0.6b` + `local-talkies-kokoro-82m-nvidia`. CUDA gains `local-talkies-cuda-nemotron-3.5-asr-0.6b`, `local-talkies-cuda-kokoro-82m-nvidia`, and the four Qwen3-TTS mode slugs (Base 1.7B, CustomVoice 0.6B, CustomVoice 1.7B + emotion, VoiceDesign 1.7B). Header lines updated from `v0.3.0` to `v0.9.0`.
- `docs/services-reference.md`: talkies section header updated from `v0.4.0 / v0.4.0-cuda` to `v0.9.0 / v0.9.0-cuda`. "6 models / 14 models" counts now stated explicitly. Model bullet list reorganised — CPU bullets gain nemotron-3.5-asr + kokoro-82m-nvidia; CUDA bullets reorganised into a "Qwen3-TTS family" sub-section that documents how `voice` and `instructions` semantics shift per mode, plus PCM streaming + per-request sampling controls.
- `docs/usage.md`: Transcription model list gains `local-talkies-nemotron-3.5-asr-0.6b` (CPU + CUDA). Text-to-speech section grows three new curl examples (Kokoro ONNX, Qwen3-TTS CustomVoice + emotion, Qwen3-TTS VoiceDesign) and the TTS model bullet list is reorganised into Kokoro / Qwen3-TTS families with per-mode `voice` + `instructions` semantics. Sampling-controls and PCM-streaming knobs are now mentioned in this doc too.
- `docs/testing.md`: model-count assertion line updated — "CPU: 4 ASR + Kokoro; CUDA: 7 ASR + Kokoro" → "CPU: 4 ASR + 2 Kokoro = 6 models; CUDA: 7 ASR + 2 Kokoro + 5 Qwen3-TTS = 14 models".
- `.env.example`: `TALKIES=` / `TALKIES_CUDA=` doc comments rewritten to describe the new model set (nemotron, kokoro-82m-nvidia, full Qwen3-TTS line with per-mode notes). New optional knob `TALKIES_QWEN3_STREAM_CHUNK_SIZE` (default `8`) documented for PCM streaming chunk size.

## [v3.8.0] — 2026-06-09

Bump audiolla **v1.0.3 → v1.0.5** (both CPU and CUDA) and talkies **v0.5.0 → v0.9.0** (both CPU and CUDA). Both jumps add user-visible engines on the upstream side, so the LiteLLM provider configs grow nine new model entries (no MCP-side changes — talkies is non-MCP).

### audiolla v1.0.3 → v1.0.5

Patch-level — no API changes. Both upstream releases are pure additive / bugfix:

- **v1.0.4** — `/v1/audio/enhance/deepfilter` no longer 400s on the first call after boot. The `is_deepfilter_engine` predicate AND'd `hasattr(engine, '_df_state')`, but `_df_state` is set lazily inside `_load_sync` on first inference, so the handler rejected the request before the engine could load. Predicate now checks only the public `enhance` method. Plus a structured-logging rewrite — single `audiolla.logging.configure()` init path, line-delimited JSON, `LOG_LEVEL` env var, `X-Request-Id` correlation both directions, per-request summary level-scaled to status code (DEBUG `/healthz`, INFO 2xx/3xx, WARN 4xx, ERROR 5xx).
- **v1.0.5** — UVR `_STEM_RE` regex updated for the newer `audio-separator` filename format, plus a phantom-output filter (model reports files it never wrote — pre-fix the wrapper returned "model produced no output files" even when separation succeeded). DeepFilterNet runtime needs `git` on PATH. `Dockerfile.cuda` was missing `COPY presets`. Pyannote test now accepts `num_speakers == 0` on synthetic input. 25/25 engines now log inference start / done with size + duration_ms + warn / exception on every raise. Replaces 71 bash `e2e_*.sh` with 83 pytest files (479 functions); CUDA suite 470 passed, 9 skipped.

### talkies v0.5.0 → v0.9.0

Four minor versions, all wire-compatible with v0.5.0 — no breaking changes. New engines:

- **v0.6.0** — New TTS slug `kokoro-82m-nvidia` (NVIDIA's TensorRT-friendly ONNX export of Kokoro-82M, Apache-2.0). Same 40-voice catalog, same wire shape, served via ONNXRuntime against the ONNX export + espeak-ng G2P. No PyTorch on the inference hot path. Plus `instructions` field for Qwen3-TTS — passed through to `faster-qwen3-tts` as `instruct`. Voices without a sibling `.txt` transcript now fall back to x-vector-only mode (with a warning) instead of returning 400. Integration test harness self-spawns its own `--rm --gpus all` container per test file.
- **v0.7.0** — PCM streaming for Qwen3-TTS. `response_format="pcm"` against a `qwen3_tts` model now streams the raw PCM body via HTTP/1.1 chunked transfer-encoding instead of buffering the full utterance. First-audio latency drops from ~3-8 s to ~200-700 ms. New env var `TALKIES_QWEN3_STREAM_CHUNK_SIZE` (default 8) controls codec-steps-per-chunk. Plus a supply-chain bump-on-mutation Makefile workflow (`pkg-*` targets call `scripts/bump_exclude_newer.sh` before any uv operation).
- **v0.8.0** — Full Qwen3-TTS mode coverage. Four new model slugs covering all three upstream operational modes:

  | Slug | Mode | `voice` semantics | `instructions` semantics |
  |---|---|---|---|
  | `qwen3-tts-1.7b` | Base 1.7B voice cloning | reference-WAV path | (unused) |
  | `qwen3-tts-0.6b-custom` | CustomVoice 0.6B | 9 preset speakers (Vivian / Serena / Uncle_Fu / Dylan / Eric / Ryan / Aiden / Ono_Anna / Sohee) | (unused) |
  | `qwen3-tts-1.7b-custom` | CustomVoice 1.7B + emotion | same 9 preset speakers | emotion string ("happy" / "sad" / …) |
  | `qwen3-tts-1.7b-design` | VoiceDesign 1.7B | sentinel `"design"` | natural-language description ("a young energetic female voice") |

  Mode is implicit in the model slug; the OpenAI wire format stays pure. Per-request sampling controls as OpenAI extras (`temperature`, `top_k`, `top_p`, `repetition_penalty`, `max_new_tokens`, `do_sample`, `language`) via `extra_body` on official OpenAI SDKs; out-of-range returns 422.
- **v0.9.0** — New multilingual ASR via `mudler/parakeet.cpp` (C++17 / ggml). First slug shipped: `nemotron-3.5-asr-0.6b` (NVIDIA Nemotron-3.5-ASR-Streaming-0.6B, OpenMDW-1.1, 40+ locales, WER-0 against NeMo). Runs CPU-only in both images at this stage; returns per-word timestamps + confidence and synthesises Whisper-style segments via silence-gap grouping so `verbose_json` matches OpenAI's shape. Plus a latent v0.8.0 GPU drain barrier bugfix — sibling eviction returned before async CUDA dealloc finished, so the next backend's load could race the still-freeing pool and OOM on a tight GPU.

### Files

- `docker-compose.yml`: image pins bumped — `psyb0t/audiolla:v1.0.3` → `v1.0.5`, `v1.0.3-cuda` → `v1.0.5-cuda`, `psyb0t/talkies:v0.5.0` → `v0.9.0`, `v0.5.0-cuda` → `v0.9.0-cuda`. Comment line above each talkies block updated to match.
- `litellm/config/providers/talkies.yaml`: two new entries.
  - `local-talkies-nemotron-3.5-asr-0.6b` (audio_transcription)
  - `local-talkies-kokoro-82m-nvidia` (audio_speech)
- `litellm/config/providers/talkies-cuda.yaml`: seven new entries.
  - `local-talkies-cuda-nemotron-3.5-asr-0.6b` (audio_transcription)
  - `local-talkies-cuda-kokoro-82m-nvidia` (audio_speech — ONNXRuntime variant of kokoro-82m)
  - `local-talkies-cuda-qwen3-tts-1.7b` (audio_speech — Base mode)
  - `local-talkies-cuda-qwen3-tts-0.6b-custom` (audio_speech — CustomVoice 9-preset)
  - `local-talkies-cuda-qwen3-tts-1.7b-custom` (audio_speech — CustomVoice + emotion)
  - `local-talkies-cuda-qwen3-tts-1.7b-design` (audio_speech — VoiceDesign)
  - The pre-existing `local-talkies-cuda-qwen3-tts` (= `qwen3-tts-0.6b`) is preserved unchanged for backward compatibility.

### End-to-end smoke-test against the live aigate stack

All four containers came up healthy on the new pins. The new model entries were verified through the LiteLLM-routed HTTP endpoints (not direct container ports) so the full request path — LiteLLM router → talkies backend → engine — is exercised:

| Model | Endpoint | Result |
|---|---|---|
| `local-talkies-whisper-large-v3-turbo` (existing, regression check) | `/v1/audio/transcriptions` | 200 — "You are just a line of code." |
| `local-talkies-nemotron-3.5-asr-0.6b` (NEW) | `/v1/audio/transcriptions` | 200 — same text + word-level timestamps + `verbose_json` shape |
| `local-talkies-cuda-nemotron-3.5-asr-0.6b` (NEW) | `/v1/audio/transcriptions` | 200 — same |
| `local-talkies-kokoro-tts` (existing, regression check) | `/v1/audio/speech` | 200, 120 KB WAV |
| `local-talkies-kokoro-82m-nvidia` (NEW) | `/v1/audio/speech` | 200, 101 KB WAV |
| `local-talkies-cuda-kokoro-82m-nvidia` (NEW) | `/v1/audio/speech` | 200, 114 KB WAV |
| `local-talkies-cuda-qwen3-tts-1.7b` (NEW Base) | `/v1/audio/speech` voice=`alloy` | 200, 100 KB WAV |
| `local-talkies-cuda-qwen3-tts-0.6b-custom` (NEW) | `/v1/audio/speech` voice=`Vivian` | 200, 54 KB WAV |
| `local-talkies-cuda-qwen3-tts-1.7b-custom` (NEW) | `/v1/audio/speech` voice=`Vivian` instructions=`happy` | 200, 96 KB WAV |
| `local-talkies-cuda-qwen3-tts-1.7b-design` (NEW) | `/v1/audio/speech` voice=`design` instructions=`a young energetic female voice` | 200, 65 KB WAV |

### One first-boot snag worth knowing about

When the CPU `talkies` container does its first prefetch of `kokoro-82m-nvidia`, the HF CDN connection can hang in `CLOSE_WAIT` partway through the 21-file snapshot — leaving the on-disk dir half-populated (large `.onnx` file present, smaller files like `voices.txt` / `phone-zh.fst` / `.gitattributes` missing). On the next container start, the entrypoint sees the non-empty dir, prints `cached: kokoro-82m-nvidia`, and moves on — but the model load then fails at runtime with `503 no voices found in /data/models/kokoro-82m-nvidia/voices.txt — snapshot may not have been prefetched`. Fix: `docker exec --user root aigate-talkies-1 rm -rf /data/models/kokoro-82m-nvidia` and restart the service; the retry pulled all 21 files in 11 s.

## [v3.7.1] — 2026-06-08

Bump audiolla v1.0.1 → **v1.0.3**. Upstream shipped two patch releases that fix the exact issues that surfaced while smoke-testing v3.7.0's text-to-audio generators against the live aigate stack:

- **v1.0.2** — `HF_HUB_OFFLINE` default flipped to `0`. The previous image baked it to `1`, which refused even the lazy-download path used by every audio engine that pulls weights from the Hub on first request (`audioldm2`, `stable-audio-open`, `musicgen-*`, `riffusion`, `ast-tag`, `clap-embed`, `pyannote`). Every generation request 500'd with `OSError: model is not cached locally and an error occurred while trying to fetch metadata from the Hub`. Strict-offline deployments now opt back in via `-e HF_HUB_OFFLINE=1`.
- **v1.0.3** — Entrypoint mirrors `HUGGINGFACE_TOKEN ↔ HF_TOKEN`. `huggingface_hub` (the library underneath `diffusers` / `transformers`) reads `HF_TOKEN` as canonical — older audiolla docs (and aigate's compose env block) only set `HUGGINGFACE_TOKEN`, so gated repos got an anonymous request and 401'd even when the operator's token was authorised. Either env name is now sufficient.

Both bugs had been worked around manually in a draft v3.7.1 (compose-side env overrides `HF_HUB_OFFLINE=0` and `HF_TOKEN: ${HF_TOKEN:-}`). That draft is now superseded — upstream merged the same fixes, so the aigate-side overrides are deleted and the compose env block reverts to just `HUGGINGFACE_TOKEN: ${HF_TOKEN:-}`.

Verified end-to-end against the live aigate stack post-bump — all three generation engines from v3.7.0 work with no aigate-side workarounds:

| Engine | First-call time | Output |
|---|---|---|
| `audioldm2` (CC-BY 4.0, ungated) | 182 s (incl. ~3 GB download) | 4 s WAV, 128 KB |
| `musicgen-small` (CC-BY-NC, ungated on HF, gated on `AUDIOLLA_ENABLE_NONCOMMERCIAL=1`) | 86 s (incl. download) | 4 s WAV, 256 KB |
| `stable-audio-open` (Stability Community Licence, HF-gated) | 270 s (incl. ~6 GB download, after operator accepted the licence at huggingface.co) | 4 s WAV, 706 KB |

Files:

- `docker-compose.yml`: pinned images bumped on both audiolla services — `psyb0t/audiolla:v1.0.1` → `psyb0t/audiolla:v1.0.3` and `v1.0.1-cuda` → `v1.0.3-cuda`. Deleted the two draft-v3.7.1 env overrides on both services (`HF_HUB_OFFLINE: ${AUDIOLLA_HF_HUB_OFFLINE:-0}` and `HF_TOKEN: ${HF_TOKEN:-}`) — now redundant with upstream's defaults.

## [v3.7.0] — 2026-06-08

Bump audiolla v0.23.1 → **v1.0.1** (both CPU and CUDA). Upstream jumped straight to a 1.0 stability commitment with a fully breaking REST contract; every v0.23.x client breaks. Aigate-side this means rewriting the smoke tests and the docs/usage snippets, updating the MCP descriptions LiteLLM hands to LLM agents, and adding one new env var to gate the CC-BY-NC MusicGen weights.

### What v1.0.1 changed upstream

- **JSON body on every audio endpoint.** Multipart `Form()`/`File()` dropped. The single remaining bytes-on-the-wire entry point is `PUT /v1/files/{path}`.
- Input is `file_path` (FILES_DIR-relative, after staging) XOR `file_url` (server-side fetch, governed by `AUDIOLLA_FETCH_MODE`).
- Audio-producing tools require `output_path` (server stages under `FILES_DIR` — caller fetches via `GET /v1/files/<path>`) XOR `output_url` (server PUTs to a presigned URL). The pre-1.0 `*_base64` response fields are gone everywhere.
- **5 new CUDA-only text-to-audio generation engines** under `POST /v1/audio/generate/{engine}`: `stable-audio-open` (Stability Community Licence), `musicgen-small` / `musicgen-medium` (CC-BY-NC, gated), `riffusion` (CreativeML OpenRAIL-M), `audioldm2` (CC-BY 4.0 — commercial-safe, no gate).
- `openapi.yaml` is now the canonical contract; Pydantic models regenerate via `make generate`.
- 73 → 90 documented routes. Tool count grew from 81 to ~85+.

### Files

- `docker-compose.yml`: pinned image bumped on both audiolla services — `psyb0t/audiolla:v0.23.1` → `psyb0t/audiolla:v1.0.1` and the CUDA variant `v0.23.1-cuda` → `v1.0.1-cuda`. Added `AUDIOLLA_ENABLE_NONCOMMERCIAL: ${AUDIOLLA_ENABLE_NONCOMMERCIAL:-}` to both env blocks — off by default; flipping it to `1` lets the CUDA container load the MusicGen weights (matches the matchering / GPL v3 opt-in pattern).
- `tests/test_audiolla.sh`: `_audiolla_test_info_live` and `_audiolla_test_analyze_live` rewritten for the new contract. New `_audiolla_stage_fixture` helper PUTs `tests/.fixtures/audio.mp3` to a per-test path under `aigate-test/` (so the CPU and CUDA passes don't collide), then POSTs a JSON body with `{"file_path":"…"}`. The `-F "file=@…"` multipart calls are gone.
- `docs/usage.md`: audiolla section rewritten to show the v1.0 PUT-then-POST flow + `output_path` requirement, with a worked example that stages a file, runs `chords` (analysis), runs `separate` (audio-producing — needs `output_paths` per stem), and then downloads a stem from `GET /v1/files/<path>`.
- `litellm/config/mcp/audiolla.yaml`: description rewritten to call out the v1.0.1 JSON-everywhere contract, the input rules (`file_path` xor `file_url`), the output rules (`output_path` xor `output_url`), the dropped `*_base64` fields, and the five new `generate_<engine>` tools (with the licence notes). Same allowed-host workaround for FastMCP DNS rebinding stays in place.
- `litellm/config/mcp/audiolla-cuda.yaml`: description now points the agent at the CUDA fragment when it specifically wants the generation engines (only available on the GPU variant); references the CPU fragment for the full per-tool list.
- `.env.example`: documented `AUDIOLLA_ENABLE_NONCOMMERCIAL` knob, with licence-source pointer and which engines are gated vs free.
- `README.md`, `docs/services-reference.md`: bullet points updated to mention the text-to-audio generation engines and the v1.0+ JSON contract; the "Audio output modes" line replaced with the `output_path xor output_url` requirement.

### Things to know before flipping AUDIOLLA_ENABLE_NONCOMMERCIAL=1

MusicGen weights are CC-BY-NC 4.0 — non-commercial only. The engine code ships in the image but refuses to load the model unless the operator opts in. AudioLDM 2 is CC-BY 4.0 (commercial-safe, no opt-in). Stable Audio Open is Stability's Community Licence. Riffusion is CreativeML OpenRAIL-M. Read each one before shipping audio generated by it into a product.

## [v3.6.0] — 2026-06-08

Pass-through for pibox-zai's per-request agent knobs over the OpenAI-compatible endpoint, plus a Makefile fix for the v3.4.0 profile autodetect.

### Bump: pibox-zai → v0.8.0 (full `x-aicodebox-*` header surface)

Upstream `psyb0t/pibox:v0.8.0` rides on aicodebox v0.7.0, which exposes every RunSpec knob as an `x-aicodebox-*` header on `/openai/v1/chat/completions`. Previously only 3 of the 9 were reachable from the OpenAI surface; the other 6 required dropping to `POST /run` and bypassing LiteLLM. Now an OpenAI-SDK caller can pass any of them via `extra_headers`:

| Header | Effect |
|---|---|
| `x-aicodebox-workspace` | workspace subdir under `/workspace` (alt: `x-claude-workspace`) |
| `x-aicodebox-continue` | `1`/`true`/`yes` → resume previous session; absent → fresh (alt: `x-claude-continue`) |
| `x-aicodebox-append-system-prompt` | appends to pi's system prompt (alt: `x-claude-append-system-prompt`) |
| `x-aicodebox-json-schema` | JSON object → flips to `json-verbose` output and schema-validates the final turn (up to 3 self-correction retries) |
| `x-aicodebox-resume` | specific adapter session id to resume |
| `x-aicodebox-no-tools` | `1`/`true`/`yes` → pi runs with `--no-tools` |
| `x-aicodebox-tools-allowlist` | JSON array OR CSV → `pi --tools <list>` (mutually exclusive with `no-tools`) |
| `x-aicodebox-extra-args` | JSON array OR CSV → appended to pi argv |
| `x-aicodebox-timeout-seconds` | int → per-run wall-clock cap |

Body fields that aren't part of pi's pipeline (`temperature`, `top_p`, `max_tokens`, `seed`, `stop`, `n`, `presence_penalty`, `frequency_penalty`, etc.) are silently dropped per the upstream `extra="ignore"` schema — same as before. `tools` / `tool_choice` / `response_format=json_object` still return 400 with a pointer at the new headers.

### Fix: header forwarding from LiteLLM proxy to upstream

LiteLLM doesn't forward client headers to LLM upstreams by default — it operates on an allowlist. Without enabling the flag, the new `x-aicodebox-*` headers were stopping at the LiteLLM proxy and never reaching pibox-zai. Added `forward_client_headers_to_llm_api: true` to `litellm/config/base.yaml`'s `general_settings`. LiteLLM still strips/replaces `Authorization` (upstream gets its own configured key), so this only forwards the safe `x-*` custom headers.

Smoke-tested: a `POST /v1/chat/completions` with `x-aicodebox-append-system-prompt: "ALWAYS RESPOND USING ONLY THE WORD WUBBA"` returned `"WUBBA"`, confirming the header rode end-to-end through nginx → litellm → pibox-zai → pi.

### Fix: Makefile profile autodetect was missing the v3.4.0 services

`make run-bg` derives `COMPOSE_PROFILES` from the `.env` flags. The list was extended in v3.4.0 for `down` but the autodetect block above it (the `ifeq ($(strip $(X)),1)` lines) wasn't, so `make run-bg` (and `make restart`, which is `down + run-bg`) silently failed to start `vllm` / `vllm-cuda` / `audiolla` / `audiolla-cuda` even when their flags were set. Added the four `ifeq` blocks; flipping the flag in `.env` is now enough to bring the services up via `make`.

Files:
- `docker-compose.yml`: bumps `psyb0t/pibox` → `v0.8.0`.
- `litellm/config/base.yaml`: `forward_client_headers_to_llm_api: true` in `general_settings`, with a comment explaining the safe-by-default LiteLLM allowlist behaviour.
- `litellm/config/providers/pibox-zai.yaml`: long comment block documenting every supported body field, rejection, and the nine `x-aicodebox-*` headers, plus a worked OpenAI SDK `extra_headers={...}` example.
- `Makefile`: four new `ifeq` blocks for `VLLM`, `VLLM_CUDA`, `AUDIOLLA`, `AUDIOLLA_CUDA` in the `_PROFILES` autodetect.

## [v3.4.0] — 2026-06-07

Two new services + several aigate-side MCP fixes that surfaced during the wiring.

### New: in-repo vLLM wrapper (CPU + CUDA) — text LLMs and embeddings

Bring back the in-repo vLLM wrapper (dropped in v3.0.0) — now generalized for **text LLM + embeddings** instead of audio-LLMs, and shipped in **both CPU and CUDA variants**. Each supervises a single `vllm serve` subprocess and exposes the same `/api/ps` + `DELETE /api/ps/{model_id}` surface as talkies, so the LiteLLM resource_manager evicts each (and is evicted by each) under VRAM/RAM contention.

Variants:

- `VLLM=1` → `vllm` service from `Dockerfile.cpu` (base: `vllm/vllm-openai-cpu`), CPU-tuned `models.cpu.json`, LiteLLM prefix `local-vllm-*`, resource_manager group `cpu-vllm`.
- `VLLM_CUDA=1` → `vllm-cuda` service from `Dockerfile.cuda` (base: `vllm/vllm-openai:v0.21.0`), CUDA-tuned `models.cuda.json`, LiteLLM prefix `local-vllm-cuda-*`, resource_manager group `cuda-vllm`.
- Both can be enabled simultaneously. They share `${DATA_DIR_VLLM}/models/<org>/<repo>/` (populated once by `vllm-pull`) so no duplicate downloads.

Default models:

- `nomic-embed-v2` — `nomic-ai/nomic-embed-text-v2-moe` (MoE, 305M active, embeddings, 8192 ctx)
- `qwen3-0.6b` — `Qwen/Qwen3-0.6B` (chat + completions, 16384 ctx)

Weights live under `${DATA_DIR_VLLM}/models/<org>/<repo>/<files>` in the flat HF-repo layout (no `blobs/`/`snapshots/` dedup). The pull container populates this via `huggingface-cli download <repo> --local-dir <path>` so other services that bind-mount the same dir can load the same files directly. The supervisor passes the local path to `vllm serve` (not the HF repo string) and the wrapper runs `HF_HUB_OFFLINE=1`.

Endpoints proxied to the supervised subprocess: `/v1/chat/completions`, `/v1/completions`, `/v1/embeddings`. Audio-only endpoints (`/v1/audio/transcriptions`) are gone — talkies covers ASR.

Add more models by editing `vllm/models.json`. Each entry maps a slug to `{repo, vllm_args, endpoints}`; endpoints must be a subset of `{"chat", "completions", "embeddings"}`.

Files:

- `vllm/` — restored from `909e29a` and generalized:
  - `vllm/src/vllm_wrap/server.py` — dropped `/v1/audio/transcriptions`, dropped the multipart body rewriter (audio-only `verbose_json→json` normalization), added `/v1/embeddings` + `/v1/completions`. Single JSON-only proxy path.
  - `vllm/src/vllm_wrap/config.py` — endpoint validator now allows `{"chat", "completions", "embeddings"}`; added `VLLM_WRAP_DEVICE` (`cpu`/`cuda`) and `VLLM_WRAP_MODELS_DIR` (default `${DATA_DIR}/models`).
  - `vllm/src/vllm_wrap/supervisor.py` — resolves `repo` to a local path (`MODELS_DIR/<repo>`) and passes that to `vllm serve`; appends `--device <DEVICE>` when set.
  - `vllm/models.cuda.json` — CUDA-tuned `vllm_args` (Nomic embed v2 + Qwen3-0.6B).
  - `vllm/models.cpu.json` — CPU-tuned `vllm_args` (no `--gpu-memory-utilization`, smaller Qwen3 context).
  - `vllm/Dockerfile.cuda` — base `vllm/vllm-openai:v0.21.0`, copies `models.cuda.json`.
  - `vllm/Dockerfile.cpu` — base `vllm/vllm-openai-cpu:latest-x86_64`, copies `models.cpu.json`, sets `VLLM_WRAP_DEVICE=cpu`, `VLLM_CPU_KVCACHE_SPACE=4`.
  - `vllm/pyproject.toml` — bumped to 0.2.0, dropped `python-multipart`, updated description/keywords.
- `docker-compose.yml` — added `vllm` (CPU), `vllm-cuda`, and shared `vllm-pull` (profiles `[vllm, vllm-cuda]`). Pull container does `huggingface-cli download <repo> --local-dir /data/models/<repo>` for each model in the flat HF-repo layout (no blobs/snapshots dedup) so other services bind-mounting the same dir can reuse the weights.
- `litellm/build-config.py` — registers `vllm` (when `VLLM=1`) and `vllm-cuda` (when `VLLM_CUDA=1`) in `active_providers`.
- `litellm/config/providers/vllm.yaml` — CPU aliases `local-vllm-nomic-embed-v2` + `local-vllm-qwen3-0.6b`.
- `litellm/config/providers/vllm-cuda.yaml` — CUDA aliases `local-vllm-cuda-nomic-embed-v2` + `local-vllm-cuda-qwen3-0.6b`.
- `tests/test_vllm.sh` — wrapper introspection (`/healthz`, `/v1/models`, `/api/ps`, `POST /unload`, `DELETE /api/ps/{id}`) plus live LiteLLM-routed tests for chat + embeddings, parameterised on upstream host and alias so both CPU and CUDA variants are covered. Auto-picked up by `test.sh`; each test skips when its variant is disabled.
- `litellm/callbacks/resource_manager.py` — added `cpu-vllm` (CPU prefix `local-vllm-`) and `cuda-vllm` (CUDA prefix `local-vllm-cuda-`) groups. Both use the existing `DELETE /api/ps/{model_id}` unload pattern.
- `recommend-limits.sh` — tracks `VLLM=1` and `VLLM_CUDA=1`, shows both in the enabled-services line.
- `.env.example` — `VLLM=`/`VLLM_CUDA=` flags in Core; `VLLM_*` and `VLLM_CUDA_*` tuning vars (MODEL_TTL, SWEEPER_INTERVAL, LOAD_TIMEOUT, REQUEST_TIMEOUT, LOG_LEVEL, PRELOAD, PREFETCH) plus `VLLM_CPU_KVCACHE_SPACE` and `DATA_DIR_VLLM`.
- `tests/test_litellm.sh` — `EXPECTED_MODELS` extends with the CPU aliases when `VLLM=1` and the CUDA aliases when `VLLM_CUDA=1`.
- `docs/providers.md`, `docs/services-reference.md`, `docs/usage.md`, `README.md` — document both services side-by-side, the shared model store, model list, endpoint surface, tuning vars, embeddings curl example, and resource_manager groups.

### New: audiolla (CPU + CUDA) — self-hosted audio-production REST + MCP

Adds **audiolla** at `/audiolla/` (upstream: [psyb0t/docker-audiolla](https://github.com/psyb0t/docker-audiolla) v0.23.1). Self-hosted **audio-production** stack: stem separation (Demucs / UVR), restoration (UVR de-reverb / de-echo / de-noise), mastering (matchering + pedalboard chains), MIR analysis (librosa), DSP transforms (sox + ffmpeg), loudness normalization, speech enhancement (DeepFilterNet), VAD (silero), diarization (pyannote), CLAP embeddings + zero-shot classification, AudioSet tagging (AST), audio→MIDI (basic-pitch), MIDI compose / inspect / transform / render via fluidsynth. Curated YAML workflow presets (`master-for-spotify`, `podcast-cleanup`, `vocal-cleanup`) and ad-hoc op-chain pipelines run server-side — intermediates stay in memory between steps. Async jobs + webhooks for long-running work.

Audio output modes (per audio-producing tool): default base64, `output_path` (stages under `${DATA_DIR_AUDIOLLA}/files`), `output_url` (PUT to a presigned URL).

Wired the same way as predictalot (direct nginx route, not via LiteLLM, MCP aggregated into `/mcp/`). CPU and CUDA variants run **side-by-side** on distinct routes and aliases — `/audiolla/` → CPU, `/audiolla-cuda/` → GPU. Enable independently via `AUDIOLLA=1` and/or `AUDIOLLA_CUDA=1`. CUDA needs `nvidia-container-toolkit` and is significantly faster on Demucs, UVR, pyannote, basic-pitch, DeepFilterNet, CLAP. Both share `${DATA_DIR_AUDIOLLA}` for the weight cache, so the second variant to boot reuses the first's downloads with zero re-fetch.

Also trimmed the long predictalot endpoint matrix in the in-repo docs — the upstream README is now the canonical source of truth for both services.

- `docker-compose.yml`: new `audiolla` service (profile `["audiolla"]`, image `psyb0t/audiolla:v0.23.1`) and `audiolla-cuda` (profile `["audiolla-cuda"]`, image `psyb0t/audiolla:v0.23.1-cuda`, NVIDIA GPU reservation). Each binds its own compose-service-name alias (`audiolla` vs `audiolla-cuda`). Both bind-mount `${DATA_DIR_AUDIOLLA}` to `/data`. `AUDIOLLA_AUTH_TOKEN` defaults to `AIGATE_TOKEN` (master-auth chain). Nginx exposes both via parallel `location /audiolla/` and `location /audiolla-cuda/` blocks, each with its own rate-limit zone (`audiolla` / `audiolla_cuda`), `client_max_body_size = AUDIOLLA_MAX_UPLOAD_BYTES`, and `TIMEOUT_AUDIOLLA`-controlled proxy timeouts.
- `litellm/config/mcp/audiolla.yaml` + `litellm/config/mcp/audiolla-cuda.yaml`: two MCP fragments pointing at `http://audiolla:8000/v1/mcp/` and `http://audiolla-cuda:8000/v1/mcp/` respectively, each with bearer auth and a `static_headers: Host: "127.0.0.1:8000"` to satisfy FastMCP's DNS-rebinding-protection allowlist (Host header would otherwise be the compose service name and FastMCP returns 421). Description on the CPU fragment covers the full 80+ tool surface including workflow primitives (`list_presets`, `describe_preset`, `list_ops`, `run_preset`, `run_pipeline_tool`) and the three output modes; the CUDA fragment points back at the CPU description and clarifies it's the forced-GPU path.
- `litellm/build-config.py`: registers `audiolla` in `active_mcp_servers` when `AUDIOLLA=1` and `audiolla-cuda` when `AUDIOLLA_CUDA=1` (independent flags so both surfaces can be aggregated simultaneously).
- `recommend-limits.sh`: tracks both `AUDIOLLA=1` and `AUDIOLLA_CUDA=1`.
- `.env.example`: `AUDIOLLA=` + `AUDIOLLA_CUDA=` flags in Core; `AUDIOLLA_*` tuning vars (auth, device, enabled engines, preload, engine TTL, sweeper, upload cap, server-side URL fetch policy, job TTL + concurrency); `DATA_DIR_AUDIOLLA`; per-route `RATELIMIT_AUDIOLLA[_BURST]` and `RATELIMIT_AUDIOLLA_CUDA[_BURST]`; shared `TIMEOUT_AUDIOLLA`.
- `README.md`, `docs/services-reference.md`, `docs/usage.md`: minimal sections — what it is, where the endpoint lives, auth, a small smoke-test, and a link to the upstream README for the full API. Trimmed predictalot to the same minimal shape.
- `tests/test_audiolla.sh`: parameterised helpers (route prefix + tag) run the full suite — open-healthz, unauthenticated-rejection on `/v1/engines`, engines listing (asserts `htdemucs` + `librosa-analyze`), `/v1/catalog` discovery, two live ops against `tests/.fixtures/audio.mp3` (`/v1/audio/info` ffprobe, `/v1/audio/analyze` librosa), and a direct `/v1/mcp/` `tools/list` assertion (≥ 20 tools, spot-checks `separate`/`analyze`/`chords`) — separately against `/audiolla/` (gated on `AUDIOLLA=1`) and `/audiolla-cuda/` (gated on `AUDIOLLA_CUDA=1`).
- `.research_files/docker-audiolla/`: upstream repo clone (for reference; gitignored).

### Fix: aigate-side MCP wiring made `/mcp/` actually aggregate downstream services

Two bugs surfaced while wiring audiolla and would have been silently breaking predictalot for as long as `os.environ/` token references existed in the MCP fragments — `/mcp/` was missing every downstream-token-protected MCP server (predictalot, audiolla):

- `os.environ/AUDIOLLA_AUTH_TOKEN` and `os.environ/PREDICTALOT_AUTH_TOKEN` in LiteLLM MCP fragments resolve against the **LiteLLM** container's environment, not the downstream service's. `.env` only carries `AIGATE_TOKEN` (the master), so LiteLLM was sending an empty bearer to each MCP server → 401 → LiteLLM `Task cancelled while listing tools from {server}`. Fixed by re-exporting the same `${X_AUTH_TOKEN:-${AIGATE_TOKEN:-fallback}}` chain in the `litellm:` env block for both `PREDICTALOT_AUTH_TOKEN` and `AUDIOLLA_AUTH_TOKEN`.
- FastMCP's DNS-rebinding protection rejects requests whose `Host` header isn't in its allowlist (default `localhost` / `127.0.0.1`). LiteLLM was sending `Host: audiolla:8000` → 421 Misdirected Request → cancelled. Fixed in `litellm/config/mcp/audiolla.yaml` via `static_headers: Host: "127.0.0.1:8000"`. The request is already inside `aigate-internal` so there's no actual rebinding risk.
- Bumped `LITELLM_MCP_TOOL_LISTING_TIMEOUT` (default 30s) → 120s, `LITELLM_MCP_CLIENT_TIMEOUT` → 120s in the `litellm:` env block. Audiolla's 81-tool listing is on the edge of the default; tighter caps were silently dropping it.

After these fixes, `/mcp/` aggregates the full set — including 81 audiolla tools and the 26 predictalot tools — under the expected `<server>-<tool>` namespaced names.

### Restored: predictalot CUDA (side-by-side with CPU)

Brings back the predictalot CUDA variant (dropped in v3.2.0 due to a shared-alias conflict) using the same side-by-side pattern as audiolla. CPU on `/predictalot/` (alias `predictalot`), CUDA on `/predictalot-cuda/` (alias `predictalot-cuda`). Both share `${DATA_DIR_PREDICTALOT}/models` so the second variant to boot reuses the first's HF snapshots. CUDA needs `nvidia-container-toolkit`.

- `docker-compose.yml`: new `predictalot-cuda` service (profile `["predictalot-cuda"]`, image `psyb0t/predictalot:v0.2.1-cuda`, NVIDIA GPU reservation). Mounts `${DATA_DIR_PREDICTALOT}/models` so weights are shared with the CPU container. Nginx exposes both via parallel `location /predictalot/` and `location /predictalot-cuda/` blocks, each with its own `limit_req` zone (`predictalot` / `predictalot_cuda`) and `TIMEOUT_PREDICTALOT`-controlled proxy timeouts.
- `litellm/config/mcp/predictalot-cuda.yaml`: new MCP fragment pointing at `http://predictalot-cuda:8080/mcp` with bearer auth. Description points back at the CPU fragment for the full per-tool list.
- `litellm/build-config.py`: `predictalot` and `predictalot-cuda` are now two independent MCP registrations (gated on `PREDICTALOT=1` and `PREDICTALOT_CUDA=1` respectively) so the aggregator surfaces both as `predictalot-*` and `predictalot_cuda-*` tools when both variants are on.

### Fix: MCP server YAML keys must follow SEP-986

`litellm/config/mcp/audiolla-cuda.yaml` was shipped in v3.4.0 with the YAML key `audiolla-cuda:`. LiteLLM v1.80.18+ enforces SEP-986 on MCP server names — names cannot contain `-`. With both audiolla variants on, the proxy refused to start: `Exception: Server name cannot contain '-'. Use an alternative character instead Found: audiolla-cuda`. Renamed the inside-YAML keys to use underscores (`audiolla_cuda`, `predictalot_cuda`) while keeping the on-disk filenames with dashes so `build-config.py`'s `<server-name>.yaml` lookup still works. Tool prefixes in the aggregated `/mcp/` are now consistently `<server_with_underscores>-<tool>` as LiteLLM expected from the start.

### Fix: predictalot MCP fragment was missing the same wiring audiolla got

The audiolla v3.4.0 work fixed three things in its MCP fragment that the long-standing `litellm/config/mcp/predictalot.yaml` was silently missing too — so predictalot's MCP tools never actually surfaced in the aggregated `/mcp/`. This release backports the same fixes to `predictalot.yaml` (and applies them to the new `predictalot-cuda.yaml` from the start):

- **Trailing slash on the URL.** FastMCP mounts the streamable-HTTP transport at `/mcp/` (with the slash) and returns 307 to `/mcp/` for the unsigned form. LiteLLM's MCP client doesn't follow that redirect — it just hangs and cancels. Both `predictalot.yaml` and `predictalot-cuda.yaml` now use `http://<host>:8080/mcp/`.
- **`static_headers: Host: "127.0.0.1:8080"`.** Same DNS-rebinding-protection fix as audiolla — without the override LiteLLM sends `Host: predictalot[-cuda]:8080` and FastMCP returns 421.

After both fixes, `/mcp/` cleanly surfaces 26 `predictalot-*` tools (and another 26 `predictalot_cuda-*` when both variants are on).

### Fix: container healthchecks for predictalot / vllm / vllm-cuda

- **predictalot** healthcheck used `wget`, which isn't in `psyb0t/predictalot:v0.2.1`. Switched to a `python3 -c` urllib probe (same pattern as audiolla in v3.4.0). Without this, the container always showed `unhealthy` even when `/healthz` returned 200.
- **vllm** + **vllm-cuda** healthchecks used bare `python`, which isn't on the `vllm/vllm-openai*` base images (they have `python3` only). Switched both to `python3`. Same symptom — container running fine, healthcheck reporting `unhealthy`, which prevented `depends_on: condition: service_healthy` parents (nginx + litellm) from accepting them as dependencies.
- `.env.example`: `PREDICTALOT_CUDA=` flag in Core; per-route `RATELIMIT_PREDICTALOT_CUDA[_BURST]` knobs.
- `README.md`, `docs/services-reference.md`: side-by-side endpoint table and updated route diagram.
- `tests/test_predictalot.sh`: parameterised helpers (route prefix + mcp namespace) — 8 CPU tests + 8 CUDA tests, each gated on its own flag.

### Other

- `.gitignore`: added `.data/vllm/` + `.data/audiolla/` to the allowlist (with `.gitkeep`) so the empty bind-mount target dirs are tracked.
- Empty `.gitkeep` files committed under both new data dirs.
- `Makefile`: `down` target's `COMPOSE_PROFILES` list extended with `vllm`, `vllm-cuda`, `audiolla`, `audiolla-cuda` so `make down` (and `make restart`, which is `down + run-bg`) actually tears down the new services. `predictalot-cuda` was already in the list from before v3.2.0 (no change needed).

## [v3.3.0] — 2026-06-03

Bump hybrids3: v0.1.0 → v0.2.0. Adds presigned **PUT** URLs (existing presign endpoint now accepts `?method=PUT`). Backwards compatible — default is still GET.

- `docker-compose.yml`: bump `psyb0t/hybrids3` → `v0.2.0`.
- `docs/services-reference.md`: presign section documents the new `?method=PUT` query param and the boto3 `put_object` form. Notes that the method is bound into the SigV4 canonical request (GET-signed URLs can't PUT, vice versa), and that PUT on public buckets still requires a signed URL.

## [v3.2.0] — 2026-05-31

Drop `predictalot-cuda` service. CPU is fast enough and the two variants shared the same network alias (`predictalot`), making simultaneous use broken by design. CPU-only keeps it simple.

- `docker-compose.yml`: removed `predictalot-cuda` service block entirely.
- `.env.example`: removed `PREDICTALOT_CUDA=` line.
- `docs/services-reference.md`: updated section heading to drop CUDA mention.

## [v3.1.0] — 2026-05-31

Unified auth token + talkies network fix. Backwards compatible — existing `.env` files keep working unchanged.

### New: `AIGATE_TOKEN` master auth

Single bearer token now authenticates against every aigate-owned service. Set `AIGATE_TOKEN` in `.env` and it becomes the default for:

- `LITELLM_MASTER_KEY` (LiteLLM `/v1/*`)
- `CLAUDEBOX_API_TOKEN` (`/claudebox/*`)
- `PIBOX_ZAI_API_TOKEN` (`/pibox-zai/*` + its MCP)
- `PREDICTALOT_AUTH_TOKEN` (`/predictalot/*` + MCP, CPU + CUDA both)
- `MCP_TOOLS_AUTH_TOKEN` (`/mcp/*`)
- `STEALTHY_AUTO_BROWSE_AUTH_TOKEN` (`/stealthy-auto-browse/*`)
- `TELETHON_AUTH_KEY` (`/telethon/*`)
- `HYBRIDS3_MASTER_KEY` (S3 master)

Per-service tokens still override when set explicitly (chain pattern: `${SERVICE_TOKEN:-${AIGATE_TOKEN:-<literal-fallback>}}`). Upstream provider credentials (Anthropic OAuth, z.ai, Groq, OpenAI, etc.) are untouched — they're not aigate auth.

`mailbox` is not wired into this — its auth lives in the `MAILBOX_CONFIG` yaml file on the host, outside compose's interpolation scope.

### Fix: talkies couldn't reach HuggingFace

`talkies` / `talkies-cuda` were attached only to `aigate-internal` (which has `internal: true` → no upstream traffic). The talkies entrypoint prefetches enabled models from HuggingFace on boot — the DNS resolution failed and both containers crash-looped. Added `aigate-public` to both (matches the pattern already used by `ollama` / `ollama-cuda` / `sdcpp` / `sdcpp-cuda` / `predictalot` for the same reason).

### Cleanup: dead `TALKIES_PREFETCH` env var

`TALKIES_PREFETCH` / `TALKIES_CUDA_PREFETCH` were carried over from the old in-repo talkies design and never read by the upstream `psyb0t/talkies` image — the v0.5.0 entrypoint unconditionally prefetches all enabled models on boot (controlled by `TALKIES_ENABLED_MODELS`, not `_PREFETCH`). Stripped from `docker-compose.yml`, `.env.example`, and `docs/services-reference.md`. `TALKIES_PRELOAD` (lazy-load list read by the server at startup) is still honored and stays.

### Files changed

- `.env.example` — added `AIGATE_TOKEN` block in Core section; commented per-service tokens to mark them as overrides; dropped dead `TALKIES_PREFETCH` / `TALKIES_CUDA_PREFETCH` lines.
- `docker-compose.yml` — chained per-service token defaults through `AIGATE_TOKEN`; added `aigate-public` to `talkies` + `talkies-cuda`; stripped dead `TALKIES_PREFETCH` env passthrough on both talkies services.
- `docs/services-reference.md` — dropped the `TALKIES_PREFETCH` row from the tuning table.

## [v3.0.0] — 2026-05-29

**Breaking: removed in-repo `talkies/`, `asr-canary/`, `vllm/`, and `qwen3-cuda-tts/` source trees. All transcription + TTS now goes through the external [`psyb0t/talkies`](https://github.com/psyb0t/docker-talkies) image (pinned to `v0.5.0` / `v0.5.0-cuda`). One container exposes both `POST /v1/audio/transcriptions` (whisper + canary + parakeet) and `POST /v1/audio/speech` (Kokoro-82M; Qwen3-TTS-0.6B voice cloning on CUDA).**

### Env-var migration

| Old | New |
|---|---|
| `SPEACHES` / `SPEACHES_CUDA` | `TALKIES` / `TALKIES_CUDA` |
| `ASR_CANARY` / `ASR_CANARY_CUDA` | `TALKIES` / `TALKIES_CUDA` |
| `VLLM_CUDA` | removed (no replacement — run vllm-the-library separately if you need audio-input chat) |
| `QWEN_TTS_CUDA` | folded into `TALKIES_CUDA` (Qwen3-TTS bundles into the talkies-cuda image) |

### LiteLLM alias migration

| Old | New |
|---|---|
| `local-speaches-*` / `local-speaches-cuda-*` | `local-talkies-*` / `local-talkies-cuda-*` |
| `local-asr-canary-*` / `local-asr-canary-cuda-*` | `local-talkies-*` / `local-talkies-cuda-*` |
| `local-vllm-cuda-*` | removed |
| `local-qwen3-cuda-tts` | `local-talkies-cuda-qwen3-tts` |
| `local-speaches-kokoro-tts` | `local-talkies-kokoro-tts` (+ `-cuda-` variant) |

`distil-whisper-large-v3` is dropped from the talkies model set as English-only redundancy — use `whisper-large-v3-turbo` instead (multilingual, similar speed).

### Data-dir migration

`.data/speaches/`, `.data/asr-canary/`, `.data/vllm/`, `.data/qwen3-tts/` → `.data/talkies/` (single bind mount → `/data` inside the container; `hf/hub/models--*/` for the HF cache, `custom-voices/<name>.wav` for Qwen3-TTS reference voices).

### Voice cloning (CUDA only)

Drop a `<name>.wav` (10-30s clean speech) into `${DATA_DIR_TALKIES}/custom-voices/` on the host and use `voice=<name>` on `/v1/audio/speech`. Three sample voices (`alloy`, `echo`, `fable`) baked into the image. Nested paths supported (`voice=clients/acme/jane` → `${DATA_DIR_TALKIES}/custom-voices/clients/acme/jane.wav`). 17 languages: en, zh, ja, ko, fr, de, es, it, pt, ru, vi, th, id, ar, tr, pl, nl.

### Other in-repo cleanup

- `litellm/callbacks/resource_manager.py` — group set trimmed to `cuda-llm`, `cuda-img`, `cuda-stt-talkies`, `cpu-llm`, `cpu-img`, `cpu-stt-talkies`. Unload functions for speaches / asr-canary / vllm / qwen3-cuda-tts removed; per-group unloads parallelized via `asyncio.gather`. Talkies upstream model list covers all 12 v0.5.0 slugs (whisper × 2, parakeet, canary × 3, Kokoro, Qwen3-TTS).
- `recommend-limits.sh` — flag + allocation set rewritten to match the new service inventory.
- nginx inference-path timeouts (`TIMEOUT_API` / `TIMEOUT_CLAUDEBOX` / `TIMEOUT_LIBRECHAT` / `TIMEOUT_PREDICTALOT`) bumped to `24h` default — long CPU transcriptions and long-context completions no longer killed by a 600s read timeout. Non-inference paths (admin, telethon, searxng, mailbox, proxq, browser) kept their original short timeouts.
- `litellm.request_timeout` bumped to `86400` in `base.yaml`, with per-request injection via `resource_manager.async_pre_call_hook` so LiteLLM's hardcoded 600s default no longer fires.
- `.gitignore` rewritten to cover Python bytecode (`__pycache__/`, `*.pyc`), virtualenvs, IDE config, OS junk, and root-level scratch artifacts (probe scripts, downloaded test fixtures). `.data/talkies/` + `.data/talkies/custom-voices/` added to the data-dir allowlist; `.data/speaches/` removed.

## [v2.9.0] — 2026-05-26

**`asr-canary` now returns OpenAI Whisper-shape `verbose_json` with segment + word timestamps for the multitask Canary models, plus `srt` / `vtt` subtitle formats.**

Previously the wrapper accepted `response_format=verbose_json` for OpenAI compatibility but returned plain `{"text": …}` regardless — clients that depended on Whisper's `segments[]` / `words[]` arrays couldn't read timing data. This fixes that for the two backends that NeMo can timestamp: `canary-180m-flash` and `canary-1b-flash` (both `EncDecMultiTaskModel`). The SALM-based `canary-qwen-2.5b` is a chat LM under the hood and has no timestamp head — `verbose_json` requests still succeed but the `segments` / `words` arrays come back empty.

Response shape matches OpenAI exactly so existing whisper-family clients work with no changes:

```json
{
  "task": "transcribe",
  "language": "en",
  "duration": 2.43,
  "text": "You are just a line of code",
  "segments": [
    {"id": 0, "seek": 0, "start": 0.0, "end": 1.68,
     "text": "You are just a line of code",
     "tokens": [], "temperature": 0.0,
     "avg_logprob": null, "compression_ratio": null, "no_speech_prob": null}
  ],
  "words": [
    {"word": "You",  "start": 0.0,  "end": 0.08},
    {"word": "are",  "start": 0.4,  "end": 0.48},
    {"word": "just", "start": 0.56, "end": 0.64},
    {"word": "a",    "start": 0.8,  "end": 0.88},
    {"word": "line", "start": 0.96, "end": 1.04},
    {"word": "of",   "start": 1.2,  "end": 1.28},
    {"word": "code", "start": 1.36, "end": 1.68}
  ]
}
```

Whisper-only fields (`avg_logprob`, `no_speech_prob`, `compression_ratio`, `tokens`) are null-filled rather than omitted so clients reading them don't crash. `temperature` is hardcoded to `0.0` (Canary is greedy-decoded).

`srt` and `vtt` formats are built from the segments and returned as `text/plain` / `text/vtt` respectively. If the backend produces no segments (SALM, or an empty audio file), the wrapper falls back to a single segment spanning the full audio duration so the subtitle output is still valid.

Implementation notes:

- The wrapper takes an extra round through NeMo's `transcribe(timestamps=True)` only when the response format actually needs timing data (`verbose_json` / `srt` / `vtt`). Plain `json` / `text` paths skip the timestamp pass and stay fast.
- LiteLLM proxies repeated form fields to single values — a client sending `timestamp_granularities[]=segment&timestamp_granularities[]=word` through the LiteLLM proxy arrives at the wrapper as just `['word']`. To dodge this footgun the wrapper always emits both segments and words regardless of `timestamp_granularities[]` selection. Clients that read only one are unaffected; the other field is essentially free for us since NeMo computes both in the same pass.
- Audio duration is computed from the 16 kHz mono WAV the wrapper preprocesses the upload into (Python stdlib `wave`), so the `duration` field is always populated.

Two new live e2e tests (`test_asr_canary_transcribe_verbose_json`, `test_asr_canary_transcribe_srt`) exercise the new formats end-to-end through the LiteLLM proxy. asr-canary suite: 8/8 green.

## [v2.8.0] — 2026-05-25

**Add `vllm` — in-repo vLLM audio-LLM supervisor exposing transcribe + chat aliases for Qwen3-ASR + Voxtral.**

vllm-the-library serves two audio-LLMs that don't fit speaches' faster-whisper / parakeet stack: `Qwen/Qwen3-ASR-1.7B` and `mistralai/Voxtral-Mini-3B-2507`. Both are multilingual ASR AND accept chat-completions with audio input parts. vllm's own `serve` CLI gives us the OpenAI-compatible endpoints; what's missing is lifecycle: only one model fits in VRAM at a time, vLLM doesn't have a built-in eviction protocol, and the LiteLLM CUDA resource manager needs a speaches-shaped `/api/ps` surface to drive evictions. So we wrap it.

The service is named `vllm` (not `asr-vllm`) — Voxtral is a general audio-LLM (not pure ASR), and the same supervisor pattern can host additional vllm models in the future without renaming.

New microservice at `aigate/vllm/` (Python 3.12, FastAPI, base image `vllm/vllm-openai:v0.21.0` — minimum supporting both models):

- Single supervised `vllm serve` subprocess on `127.0.0.1:${VLLM_WRAP_SUBPROCESS_PORT}` (default 18000). Switching models = `SIGTERM` + drain (≤30s) + `SIGKILL` fallback, then spawn the new subprocess. `asyncio.Lock` serializes spawn/kill; `asyncio.Event` gates the kill path on in-flight request drain.
- Proxies `/v1/audio/transcriptions` (multipart) and `/v1/chat/completions` (JSON, streaming SSE supported) through httpx. Multipart `model` field is extracted via byte-regex to avoid double-reading `Request.body`.
- Each model gets two LiteLLM aliases — `local-vllm-cuda-<id>-transcribe` (mode `audio_transcription`) and `local-vllm-cuda-<id>-chat` (mode `chat`). Both proxy to the same upstream model_id, so switching endpoints is free; only switching models restarts vllm.
- Speaches-compatible `/api/ps` + `DELETE /api/ps/{model_id}` + `POST /unload`. The LiteLLM resource manager treats the entire service as one CUDA group (`cuda-vllm`) — a single eviction kills the resident subprocess, freeing VRAM for any competing CUDA job (LLM / image-gen / TTS / other STT).
- Background sweeper kills idle subprocess after `VLLM_WRAP_MODEL_TTL` seconds (default 600). Weights stay on disk; next request cold-starts vllm (~30–90s including weight load).
- Python module is named `vllm_wrap` (not `vllm`) to avoid colliding with vllm-the-library in the same Python environment. Wrapper env vars use `VLLM_WRAP_*` prefix for the same reason (vllm reserves `VLLM_PORT`, `VLLM_HOST_IP`, `VLLM_LOGGING_LEVEL`, etc.). User-facing `.env` flags stay aigate-flavored: `VLLM_CUDA=1`, `VLLM_CUDA_MODEL_TTL`, etc.

Wiring:

- `docker-compose.yml`: new `vllm-cuda` service (profile `vllm-cuda`, builds `aigate/vllm/Dockerfile.cuda`, NVIDIA GPU, `mem_limit: 12g`, `aigate-internal` only). New `vllm-cuda-pull` sidecar on `aigate-public` runs `huggingface-cli download` for both repos at startup; main container depends on pull completion via `service_completed_successfully`. Shared HF cache at `${DATA_DIR_VLLM:-${DATA_DIR}/vllm}:/data`.
- `litellm/config/providers/vllm-cuda.yaml`: four aliases — `*-transcribe` (mode `audio_transcription`) + `*-chat` (mode `chat`) for each of the two models.
- `litellm/build-config.py`: `vllm-cuda` registered as activatable provider; `VLLM_CUDA` counts as an MCP-trigger flag (auto-enables the `mcp_tools` server).
- `litellm/callbacks/resource_manager.py`: new `cuda-vllm` group + `_unload_vllm_cuda()` that issues `DELETE /api/ps/{model_id}` for every registered model_id. The vllm service does its own intra-service eviction (only one subprocess can exist), so the group treats the whole service as one eviction unit.
- `Makefile`: `VLLM_CUDA=1` → `vllm-cuda` profile, counts as MCP trigger, included in `make down` profile list, listed in `make help`.
- `.env.example`: new `VLLM_CUDA` flag, `DATA_DIR_VLLM`, and the full tuning surface — `VLLM_CUDA_MODEL_TTL` (default 600), `_SWEEPER_INTERVAL` (60), `_LOAD_TIMEOUT` (600), `_REQUEST_TIMEOUT` (300), `_LOG_LEVEL` (INFO), `_PRELOAD`, `_PREFETCH`.
- `README.md`: stack diagram lists vllm CUDA; services-overview table has a new row; data directories table mentions `.data/vllm/`; new transcription+audio-chat models section with the four aliases.
- `docs/providers.md`: new `vllm CUDA` provider section with alias → HF repo → mode table for all four aliases.
- `docs/services-reference.md`: new `vllm` service block with endpoints table, models-served table (~8 GB / ~10 GB VRAM each), behavior notes (single-subprocess invariant, lazy spawn, idle TTL, in-flight drain, resource-manager integration, two-aliases-per-model), and environment-variable table.
- `docs/usage.md`: transcription list extended with the two `-transcribe` aliases; new "Audio-input chat" subsection with curl example for `*-chat` aliases.
- `docs/testing.md`: new `vllm` row noting `/healthz`, `/v1/models`, `/api/ps`, `DELETE /api/ps/{model}`, `POST /unload` coverage, plus live transcribe + chat-audio e2e tests.
- `tests/test_vllm.sh`: five wrapper-level checks via `docker compose exec` into the internal-only `vllm-cuda` service (`/healthz`, `/v1/models`, `/api/ps`, `POST /unload`, `DELETE /api/ps/{unknown}` returns 200 or 404) plus four live e2e tests through the LiteLLM proxy — transcribe + chat-audio for both Qwen3-ASR and Voxtral with a real audio fixture.
- `tests/test_litellm.sh`: `EXPECTED_MODELS` gets all four `local-vllm-cuda-*` aliases under `VLLM_CUDA=1`.
- `.gitignore`: `vllm-repo/` added (research clone of vllm upstream, never committed).

## [v2.7.0] — 2026-05-25

**Add `asr-canary` — in-repo NeMo Canary STT microservice with CPU + CUDA variants.**

speaches' whisper / parakeet stack already covers most STT needs, but NVIDIA's Canary family is a different shape: Canary 180m-flash is the fastest English ASR ever published (~870× real-time on CPU), Canary 1b-flash adds EN↔DE/FR/ES translation, and Canary Qwen-2.5b is a hybrid SALM (speech-LLM) that emits punctuation/casing natively and can answer prompts about the audio. nemo_toolkit's `.transcribe()` / SALM `.generate()` APIs don't map onto faster-whisper, so we wrap them ourselves instead of trying to retrofit speaches.

New microservice at `aigate/asr-canary/` (Python 3.12, FastAPI, `nemo-toolkit[asr]==2.0.0`):

- OpenAI-compatible `/v1/audio/transcriptions` multipart upload (file + model + language + response_format). ffmpeg converts any container/codec to 16 kHz mono WAV before NeMo sees it.
- Speaches-compatible `/api/ps` resource-management surface — `GET /api/ps`, `DELETE /api/ps/{model_id}` (URL-encoded), `POST /unload` — so the LiteLLM CUDA/CPU resource manager evicts canary models from VRAM/RAM on competing-job arrival using the same `model_id.replace("/", "%2F")` path it already uses for speaches.
- Per-model `asyncio.Lock` serializes loads + transcribes. Background sweeper unloads any backend idle longer than `ASR_CANARY_MODEL_TTL` (default 600s). Weights stay on disk; next request warm-loads.
- Optional `ASR_CANARY_PRELOAD` (load into RAM/VRAM at boot) and `ASR_CANARY_PREFETCH` (HF snapshot at boot inside the main container) as comma-separated model_ids.

Wiring:

- `docker-compose.yml`: `asr-canary` (CPU, builds `aigate/asr-canary/Dockerfile`, profile `asr-canary`) + `asr-canary-cuda` (CUDA, builds `Dockerfile.cuda`, profile `asr-canary-cuda`). Both on `aigate-internal` only — main containers have no internet egress at runtime. Two pull sidecars (`asr-canary-pull`, `asr-canary-cuda-pull`) on `aigate-public` run `huggingface-cli download` at startup, mount the same `${DATA_DIR_ASR_CANARY:-${DATA_DIR}/asr-canary}:/data` (HF cache shared between CPU + CUDA — overlapping 180m-flash isn't re-downloaded). Speaches-pattern `depends_on: service_completed_successfully` makes the main containers boot after weights are on disk.
- `litellm/config/providers/asr-canary.yaml` + `asr-canary-cuda.yaml`: `local-asr-canary-180m-flash` (CPU); `local-asr-canary-cuda-180m-flash`, `local-asr-canary-cuda-1b-flash`, `local-asr-canary-cuda-qwen-2.5b` (CUDA). All `mode: audio_transcription`.
- `litellm/build-config.py`: `asr-canary` / `asr-canary-cuda` registered as activatable providers; `ASR_CANARY` / `ASR_CANARY_CUDA` count as MCP-trigger flags.
- `litellm/callbacks/resource_manager.py`: canary aliases registered as STT models. The single `cuda-stt` / `cpu-stt` group was **split** into `cuda-stt-speaches` + `cuda-stt-canary` (and CPU twins). speaches and asr-canary now compete as separate groups → each evicts the other on incoming jobs. Within each service the wrapper handles its own intra-service eviction. Speaches model lists also extended for the v2.6.0 additions (`whisper-large-v3-turbo`, `parakeet-tdt-0.6b-v3`) that were missed at the time.
- `litellm/callbacks/resource_manager.py`: monkey-patches `OpenAIWhisperAudioTranscriptionConfig.transform_audio_transcription_request` at module import to skip LiteLLM's unconditional `response_format` → `verbose_json` rewrite for parakeet-class models. Speaches' parakeet executor refuses `verbose_json`; the patch lets the client's chosen `response_format` (`json` / `text`) reach speaches untouched. Whisper/CT2 backends still get the original rewrite (they need `verbose_json` for duration extraction).
- **Dropped `local-speaches-crisper-whisper` / `local-speaches-cuda-crisper-whisper`.** The `nyrahealth/faster_CrisperWhisper` repo is the CT2 conversion but its HF model card declares no `library_name: ctranslate2` and no matching tag, so speaches' `passes_filter` rejects it with `404 Model … is not supported`. No alternate ctranslate2-tagged CrisperWhisper repo exists on HF. Removed from `litellm/config/providers/speaches{,-cuda}.yaml`, `litellm/callbacks/resource_manager.py` (groups + speaches model lists), `docker-compose.yml` pull job, `tests/test_litellm.sh`, `README.md`, `docs/usage.md`, `docs/providers.md`.
- `Makefile`: `ASR_CANARY=1` → `asr-canary` profile, `ASR_CANARY_CUDA=1` → `asr-canary-cuda` profile. Both count as MCP triggers (so `mcp` profile activates). `make down` includes both profiles in the kill list. `make help` lists both.
- `.env.example`: new `ASR_CANARY` / `ASR_CANARY_CUDA` flags, `DATA_DIR_ASR_CANARY` (shared CPU+CUDA dir, ~700MB CPU / ~14GB CUDA), and the full tuning surface (`ASR_CANARY_MODEL_TTL`, `ASR_CANARY_SWEEPER_INTERVAL`, `ASR_CANARY_MAX_UPLOAD_BYTES`, `ASR_CANARY_LOG_LEVEL`, `ASR_CANARY_PRELOAD`, `ASR_CANARY_PREFETCH` — each with a `_CUDA_` twin).
- `README.md`: ASCII stack diagram lists asr-canary CPU + CUDA; services-overview table has new rows; data directories table mentions the shared `.data/asr-canary/`; transcription-models tables (CPU + CUDA) have a section per variant.
- `docs/providers.md`: new `asr-canary CPU` + `asr-canary CUDA` provider sections with alias → HF repo → mode tables.
- `docs/services-reference.md`: new `asr-canary` service block with endpoint table, model list per variant, behavior notes (pre-pulled weights, lazy memory load, idle TTL, resource-manager integration, ffmpeg preprocessing), and environment-variable table.
- `docs/usage.md`: transcription-models list extended with the four new aliases.
- `docs/testing.md`: new asr-canary row noting `/healthz`, `/v1/models`, `/api/ps`, `DELETE /api/ps/{model}`, `POST /unload` coverage.
- `tests/test_asr_canary.sh`: exec-through-litellm into the internal-only `asr-canary` / `asr-canary-cuda` service (`docker compose exec litellm curl ...`) for the five endpoint checks above; CUDA variant additionally asserts 1b-flash + qwen-2.5b in `/v1/models`.
- `tests/test_litellm.sh`: `EXPECTED_MODELS` gets `local-asr-canary-180m-flash` under `ASR_CANARY=1` and three `local-asr-canary-cuda-*` aliases under `ASR_CANARY_CUDA=1`.

## [v2.6.0] — 2026-05-25

**Add three new local transcription model aliases on Speaches + make idle auto-unload explicit.**

Speaches already supports loading any HuggingFace model whose tags pass its registry filter (ctranslate2 + `automatic-speech-recognition` for whisper; `istupakov/parakeet-tdt-*` prefix for parakeet). Wiring three new ones as first-class LiteLLM aliases so callers can opt in by name without one-off `model=` overrides:

- `local-speaches-whisper-large-v3-turbo` → `deepdml/faster-whisper-large-v3-turbo-ct2`. The "turbo" Whisper from late 2024 — same architecture as large-v3 but with a 4-layer decoder instead of 32, ~8x faster decode at near-identical WER. CT2 weights, drop-in into the existing faster-whisper executor.
- `local-speaches-crisper-whisper` → `nyrahealth/faster_CrisperWhisper`. Whisper-medium fine-tuned for verbatim transcription that preserves disfluencies, fillers, repetitions, and pause timing instead of cleaning them up. Useful when downstream tooling needs the literal speech (transcript analysis, clinical notes, conversation mining).
- `local-speaches-parakeet-tdt-0.6b-v3` → `istupakov/parakeet-tdt-0.6b-v3-onnx`. Multilingual upgrade of v2 — covers 25 European languages (vs v2 being English-only). Same 0.6B params + NeMo TDT decoder, same ONNX path through speaches' parakeet executor.

All three exposed on both Speaches CPU (`local-speaches-*`) and Speaches CUDA (`local-speaches-cuda-*`). Existing `local-speaches-whisper-distil-large-v3` and `local-speaches-parakeet-tdt-0.6b` stay — these are additions, nothing removed.

Idle auto-unload made explicit instead of relying on speaches' default-300s:

- `docker-compose.yml`: `speaches` and `speaches-cuda` services now set `STT_MODEL_TTL` / `TTS_MODEL_TTL` via new env vars (`SPEACHES_STT_MODEL_TTL`, `SPEACHES_TTS_MODEL_TTL`, `SPEACHES_CUDA_STT_MODEL_TTL`, `SPEACHES_CUDA_TTS_MODEL_TTL`), default `600` (10 min). The LiteLLM resource manager still proactively unloads on competing-job arrival via `DELETE /api/ps/{model}`; the TTL is a secondary safety net for when no competing job ever arrives.
- `.env.example`: the four new TTL vars documented under "Speaches tuning".

Other files:
- `litellm/config/providers/speaches.yaml`, `speaches-cuda.yaml`: three new aliases each.
- `docker-compose.yml`: `speaches-pull` entrypoint extended to prefetch the three new HuggingFace repos (`deepdml/faster-whisper-large-v3-turbo-ct2`, `nyrahealth/faster_CrisperWhisper`, `istupakov/parakeet-tdt-0.6b-v3-onnx`). CUDA profile shares the same `.data/speaches/` cache — no separate CUDA pull job.
- `docs/providers.md`: Speaches CPU + CUDA tables extended with the three new rows each, plus a one-line note about the configurable TTL.
- `docs/usage.md`: transcription-models list extended with the new aliases.
- `README.md`: local transcription tables (CPU + CUDA) extended with the three new rows each.
- `tests/test_litellm.sh`: `EXPECTED_MODELS` lists for `SPEACHES=1` and `SPEACHES_CUDA=1` extended with the new aliases so the model-registration test asserts on them.

## [v2.5.0] — 2026-05-24

**Add OpenAI's new transcription models (`gpt-4o-transcribe` and `gpt-4o-mini-transcribe`) as LiteLLM aliases.**

OpenAI shipped two GPT-4o-based transcription models in March 2025 that share the `/v1/audio/transcriptions` endpoint with `whisper-1` but deliver lower WER (especially on accented/noisy/technical English) and support streaming partial chunks. Adding them as first-class aliases so they're usable from any LiteLLM caller without one-off `model=` overrides.

- `litellm/config/providers/openai.yaml`: add `openai-gpt-4o-transcribe` → `openai/gpt-4o-transcribe` and `openai-gpt-4o-mini-transcribe` → `openai/gpt-4o-mini-transcribe`. Both `mode: audio_transcription`. `openai-whisper` (whisper-1) untouched.
- `docs/providers.md`: append two rows to the OpenAI provider table.
- `docs/usage.md`: extend the transcription-models list with the new aliases.

Not yet wired into `fallbacks.json` — these are cloud/paid models, callers opt in by name. Output format note: gpt-4o-*-transcribe only support `json` / `text`. If you need `srt` / `vtt` / `verbose_json` (word-level timestamps), stick with `openai-whisper` or a Whisper local/Groq alias.

## [v2.4.0] — 2026-05-23

**Bump predictalot to v0.2.1 — type-routed API (breaking for callers) + auth on `/v1/<type>/models`.**

Breaking changes for any direct-HTTP or MCP caller of predictalot:

- HTTP: `/predictalot/v1/forecast` and `/predictalot/v1/models` no longer exist. Each forecast modality has its own URL family: `/v1/{univariate,multivariate,covariates/past,covariates/future,covariates,samples}/{forecast,forecast/ensemble,models}`. A model only appears under a type if it implements that modality. **All three sub-paths (`forecast`, `forecast/ensemble`, `models`) require the bearer token** — only `/healthz` is open.
- MCP: the 7-tool surface (`predictalot-forecast_<model>`, `predictalot-forecast_ensemble`, `predictalot-list_models`) is replaced by a 26-tool surface — `predictalot-forecast_<type>_<model>` (18 cells), `predictalot-forecast_<type>_ensemble` (6 per-type ensembles), `predictalot-list_<type>_models` (6 per-type listings). Tool argument shapes are unchanged for shared fields, but covariate variants add `past_covariates` / `future_covariates` kwargs and samples-type tools take `num_samples` instead of `quantile_levels`.

Migration: replace any `/v1/forecast` call with `/v1/univariate/forecast` (most common case — all five models support univariate). Replace `/v1/models` with `/v1/univariate/models` (or any per-type listing). For MCP, swap `forecast_<model>` for `forecast_univariate_<model>` and `list_models` for `list_univariate_models`.

What's new in v0.2.x:
- True multivariate forecasting (chronos-2 / moirai-2 / toto-1) — joint per-(series, channel) quantile predictions instead of per-channel univariate calls.
- Covariate-conditioned forecasting — past covariates (chronos-2, moirai-2), future covariates (chronos-2), and combined past + future (chronos-2).
- Raw-sample-path forecasting (toto-1, sundial-base-128m) for downstream Monte-Carlo workflows.
- Per-type ensembles — every type has its own `forecast/ensemble`, parallelizing only the members that actually implement that type.
- Unauthenticated `/healthz` liveness probe at root.
- v0.2.1 closes a v0.2.0 information-leak where unauthenticated callers could enumerate installed model slugs + load state + `lastUsedSecsAgo` via the per-type `/models` endpoints; all six `/v1/<type>/models` routes now require the bearer (when auth is configured).

Aigate-side updates:
- `docker-compose.yml`: bump `predictalot` → `psyb0t/predictalot:v0.2.1` and `predictalot-cuda` → `psyb0t/predictalot:v0.2.1-cuda`. Healthcheck switched from the removed `/v1/models` to the new `/healthz`.
- `tests/test_predictalot.sh`: rewritten to exercise the new surface — `/v1/univariate/models`, `/v1/multivariate/models` (verifies non-members excluded), `/v1/univariate/forecast` (chronos-2), `/v1/univariate/forecast/ensemble`, non-member-of-type rejection (timesfm-2.5 on `/v1/multivariate/forecast`), and the 26-tool MCP surface.
- Docs: `README.md`, `docs/usage.md`, `docs/services-reference.md`, `docs/mcp-tools.md`, `docs/testing.md`, and `litellm/config/mcp/predictalot.yaml` description rewritten for the type matrix.

## [v2.3.1] — 2026-05-22

**Revert ollama-cuda `OLLAMA_NUM_PARALLEL` default from 50 back to 1.**

v2.3.0 shipped `OLLAMA_NUM_PARALLEL=50` by default on `ollama-cuda`, with README + `.env.example` framing this as a knob tuned for parallel embedding throughput (qwen3-embed-0.6b). Reading ollama's scheduler after shipping showed `server/sched.go:414-417` hard-pins embedding models to `numParallel=1`:

```go
// Embedding models should always be loaded with parallel=1
if req.model.CheckCapabilities(model.CapabilityCompletion) != nil {
    numParallel = 1
}
```

The same file also force-pins `numParallel=1` for `mllama` / `qwen3vl(moe)` / `qwen35(moe)` / `qwen3next` / `lfm2(moe)` / `nemotron_h` architectures. So the 50 default only ever applied to plain chat models — and the documentation explicitly framing it as an embed-throughput knob was wrong.

For callers that actually want parallel embedding throughput in ollama: pass an array to `/api/embed` (or `input: [...]` on `/v1/embeddings`). The runner batches the array in a single forward pass — that's where the speedup lives, not in `NUM_PARALLEL`.

The `pibox` v0.3.1 → v0.7.0 bump that also shipped in v2.3.0 is unaffected and stays.

## [v2.3.0] — 2026-05-22

**Bump psyb0t/pibox v0.3.1 → v0.7.0 (fixes init-marker bug) + bump ollama-cuda NUM_PARALLEL default (reverted in v2.3.1).**

- `pibox-zai` (and `pibox` services in general) — bump `psyb0t/pibox:v0.3.1` → `v0.7.0`. v0.3.1's `init.d` bind-mounted a `.init-done` marker into the config volume, which froze `ANTHROPIC_BASE_URL` at the value seeded on first boot. After bumping `ANTHROPIC_BASE_URL` in `.env`, restarting the container did nothing — pi kept talking to whatever URL was burned in at first boot (in our case `api.anthropic.com` instead of z.ai). v0.3.2+ re-runs the baseurl setup on every boot. We jumped past 0.3.2 to 0.7.0 to pick up unrelated upstream fixes.
- ollama-cuda — `OLLAMA_NUM_PARALLEL` default bumped 1 → 50. Reverted in v2.3.1 — see that entry for the actual scheduler-pinning constraint that made this misleading.

## [v2.2.1] — 2026-05-21

**Docs sweep for v2.1 / v2.2 services. No code, no config schema, no behaviour changes.**

- `README.md` — intro capability list, resource-management section, usage curl examples, Logs-and-Debugging table, troubleshooting section, and the "Full usage guide" link blurb all now thread predictalot / mailbox / telethon / web-search mentions where the surrounding section was listing capabilities.
- `docs/usage.md` — four new sections backing the expanded README links: Web search (SearXNG MCP), Time-series forecasting (predictalot), Email gateway (mailbox), Telegram client (telethon). Each shows the direct REST surface plus pointers to the matching MCP tools and the deeper service reference.
- `docs/testing.md` — "What's Tested" extended with the new predictalot, mailbox, and telethon test suites (and the opt-in mailbox e2e gate).
- `litellm/config/mcp/mcp.yaml` — aggregator description for `mcp_tools` updated to list `search_web` alongside `generate_image` and `generate_tts` (it had been omitted since the SearXNG integration shipped).
- `.env.example` — `TELETHON_LOG_LEVEL` documented (was wired in `docker-compose.yml` but missing from the canonical env reference).

## [v2.2.0] — 2026-05-21

**Add mailbox — IMAP+SMTP gateway.**

- New service `mailbox` at `/mailbox/` via [psyb0t/docker-mailbox](https://github.com/psyb0t/docker-mailbox) `v0.3.0`. Stateless gateway across N email accounts driven by a single YAML config — unified inbox, per-account list/search/CRUD, SMTP send. No database; every read hits the upstream IMAP server live.
- Direct route only — not registered with LiteLLM (no chat/completion surface). `GET /mailbox/health` open; everything else gated on bearer token (`MAILBOX_AUTH_TOKEN`, which must also appear in the mailbox YAML's `auth.tokens:` list).
- MCP enabled by default and registered with LiteLLM's `/mcp/` aggregator. Flat tool set (`mailbox-mailboxes`, `mailbox-inbox`, `mailbox-list_messages`, `mailbox-get_message`, `mailbox-search`, `mailbox-send`, `mailbox-mark_seen`, `mailbox-move`, `mailbox-delete`, …) — every per-account tool takes `mailbox` as a parameter, so the catalog stays flat regardless of how many inboxes are configured.
- Config file holds plaintext IMAP/SMTP passwords + bearer tokens. `MAILBOX_CONFIG` is added to `Makefile`'s `check_file_vars` so the stack refuses to come up if the file isn't present. Template at `mailbox/config.example.yaml`; recommended host path `.data/mailbox/config.yaml` (auto-ignored under `.data/**`).
- New tests in `tests/test_mailbox.sh`: open `/health`, auth enforcement on `/mailboxes`, `/mailboxes` returns ≥1 account, and presence of mailbox MCP tools through the aggregator. All gated on `MAILBOX=1`.
- Nginx route `/mailbox/*` with `RATELIMIT_MAILBOX=60r/m` / `TIMEOUT_MAILBOX=120s` (IMAP fetches on large folders can be slow). New env vars documented in `.env.example`, `docs/services-reference.md`, `docs/mcp-tools.md`, and `README.md`.

## [v2.1.0] — 2026-05-21

**Add predictalot — foundation time-series forecasting.**

- New service `predictalot` (and `predictalot-cuda` GPU variant) at `/predictalot/` via [psyb0t/docker-predictalot](https://github.com/psyb0t/docker-predictalot) `v0.1.1`.
- Five univariate quantile forecasters behind one wire shape: `chronos-2` (Amazon), `timesfm-2.5` (Google), `moirai-2` (Salesforce), `toto-1` (Datadog), `sundial-base-128m` (Tsinghua) — plus `POST /v1/forecast/ensemble` for weighted-mean combinations.
- Direct route only — not registered with LiteLLM (no chat/completion surface). Bearer token auth via `PREDICTALOT_AUTH_TOKEN`.
- MCP enabled by default and registered with LiteLLM's `/mcp/` aggregator. Seven tools surfaced: `predictalot-forecast_{chronos_2,timesfm_2_5,moirai_2,toto_1,sundial_base_128m}`, `predictalot-forecast_ensemble`, `predictalot-list_models`.
- Models lazy-load on first request (HF snapshots to `.data/predictalot/models/`, ~1.4GB total) and auto-unload when idle (`PREDICTALOT_MODEL_IDLE_TIMEOUT=30m` default). CPU and CUDA variants share the same data dir, are mutually exclusive (both bind the `predictalot` network alias), and are gated on `PREDICTALOT=1` / `PREDICTALOT_CUDA=1` respectively.
- New tests in `tests/test_predictalot.sh`: `/v1/models` listing, auth enforcement, chronos-2 single forecast, unknown-model 404, and presence of all MCP tools through the aggregator. All gated on `PREDICTALOT=1` or `PREDICTALOT_CUDA=1`.
- Nginx route `/predictalot/*` with `RATELIMIT_PREDICTALOT=60r/m` / `TIMEOUT_PREDICTALOT=600s` (cold model loads can be slow). New env vars documented in `.env.example`, `docs/services-reference.md`, `docs/mcp-tools.md`, and `README.md`.

## [v2.0.0] — 2026-05-21

**BREAKING: replace `claudebox-zai` with `pibox-zai` (psyb0t/docker-pibox).**

Breaking changes for any caller hitting the removed surfaces:

- LiteLLM models `claudebox-zai-*` → `pibox-zai-glm-{4.5-air,4.7,5.1}`
- Nginx route `/claudebox-zai/*` → `/pibox-zai/*`
- Env vars `CLAUDEBOX_ZAI_*` → `PIBOX_ZAI_*`
- Data dir `.data/claudebox-zai/` → `.data/pibox-zai/`

Migration: rename env vars, move data dir (then `rm .data/pibox-zai/config/.init-done` so init.d re-seeds models.json), update model names in callers, update direct-route consumers.

Why:

- Swap the z.ai/GLM backend from a second `psyb0t/claudebox` instance to `psyb0t/pibox:v0.3.1` ([pi-coding-agent](https://github.com/earendil-works/pi-mono) wrapped in `aicodebox`). Pi speaks the Anthropic wire protocol natively — no Claude Code OAuth/license ceremony required.
- The `-zai` suffix names the upstream backend — future sibling services (e.g. `pibox-or`, `pibox-openai`) can run alongside, each pinned to its own provider.
- New endpoint surface vs. claudebox-zai: pibox uses `/healthz` (not `/health`), adds `/files/*` CRUD (PUT/GET/list/DELETE), exposes MCP at `/mcp/` (opt-in via `PIBOX_MCP_MODE=1`, on by default), and `/run` for native (non-OpenAI-compat) agent execution.
- LiteLLM model names updated: `pibox-zai-glm-4.5-air`, `pibox-zai-glm-4.7`, `pibox-zai-glm-5.1`. Fallback chains updated accordingly.
- Add `tests/test_pibox.sh` — 7 end-to-end tests covering reachability, direct API auth, file ops CRUD, model surfaces (pibox-native + via LiteLLM), chat completion through LiteLLM, and native `/run`. Tests gate on `PIBOX_ZAI=1` and auto-skip otherwise.
- `tests/test_claudebox.sh` stripped of pibox tests and gated on `CLAUDEBOX=1`.
- Provider docs, services reference, MCP tools doc, README, `.env.example`, `recommend-limits.sh`, security tests all updated to the new naming.

## [v1.6.3] — 2026-05-19

**Docs: correct free-tier rate-limit claims.**

- Cerebras: 5 RPM / 1M TPD on 4 models (verified against official docs).
- Mistral: free-tier limits not published — claim removed.
- Cross-verified Groq, OpenRouter, Hugging Face, Cohere claims against current provider documentation.

## [v1.6.2] — 2026-05-18

**Fix nginx prefix-stripping on variable-based `proxy_pass` routes.**

- nginx does not strip the location prefix when `proxy_pass` uses a variable (resolver-deferred upstreams). Added explicit `rewrite` rules to 5 routes: `/claudebox/`, `/claudebox-zai/`, `/stealthy-auto-browse/`, `/librechat/`, `/searxng/`.
- Drop dead `langfuse/.gitkeep` (langfuse service was never landed).

## [v1.6.1] — 2026-05-15

**Bump claudebox v1.13.1-minimal → v1.14.0-minimal: OpenAI-compat wrapper hardening.**

- Multi-turn workspace fix (workspace was lost on follow-up turns).
- SSRF guard on `/openai/v1/files`.
- `finish_reason` mapping (stop / length / tool_calls).
- 400 on unsupported request fields instead of silent ignore.
- `reasoning_effort` snake_case binding now propagates to the agent.

## [v1.6.0] — 2026-05-10

**Security patches + claudebox v1.13.1 + reasoning/vision models + Piper TTS.**

- **Security:** LiteLLM v1.83.5-nightly → v1.83.14-stable.patch.2 fixes CVE-2026-42208 (pre-auth SQL injection in API key verification, CVSS 9.3). Stable cosign-signed channel after the supply-chain incident on the v1.83.x line.
- **Security:** Redis 7.4.8-alpine → 7.4.9-alpine for RCE/UAF CVEs disclosed 2026-05-05. Applied to both `redis` and `stealthy-auto-browse-redis`.
- **Claudebox:** v1.9.0-minimal → v1.13.1-minimal (11 versions, mostly cron+telegram fixes irrelevant to aigate's API-only usage). v1.11.0 surfaces `opusplan` in `/openai/v1/models` — added `claudebox-opusplan` provider entry.
- **New local CUDA reasoning/vision models (4):** `local-ollama-cuda-phi4-reasoning-plus` (Phi-4 Reasoning Plus 14B+RL, ~11GB), `local-ollama-cuda-deepseek-r1-14b` (~9GB), `local-ollama-cuda-qwen3-30b-a3b` (Qwen3 30B MoE / 3B active, ~17GB), `local-ollama-cuda-qwen2.5vl-7b` (Qwen2.5-VL 7B vision, ~5GB). All added to `ollama-pull` for auto-download.
- **New local CPU Piper TTS models (17 across 16 languages):** fills the multilingual TTS gap. Multi-speaker: `en_US-libritts-high` (904 voices), `en_GB-vctk-medium` (109), `fr_FR-mls-medium`, `nl_NL-mls-medium`, `sv_SE-nst-medium`. Single-speaker: de/es/it/pl/pt-BR/ro/ru/tr/uk/vi/zh/ar. Served via the existing `speaches` container.
- **New fallback chains:** 5 chains added to `litellm/config/fallbacks.json` for the new reasoning + vision models.
- No env var or breaking changes.

## [v1.5.0] — 2026-05-08

**Tailscale support (L4 TCPForward) + rename internal docker networks `aigate-*`.**

- Add optional Tailscale container that publishes the aigate stack onto a tailnet via L4 TCPForward — no per-service TLS ceremony required, mesh VPN handles auth + encryption at the network layer.
- Rename docker networks `aicodebox-*` → `aigate-*` for clarity (the stack outgrew the original aicodebox-only naming).

## [v1.4.2] — 2026-04-29

**Bump claudebox to v1.9.0-minimal.**

- `psyb0t/claudebox:v1.8.0-minimal` → `v1.9.0-minimal` for both claudebox and claudebox-zai

## [v1.4.1] — 2026-04-29

**Upgrade Telethon to telethon-plus v0.2.0.**

- Switch image from `psyb0t/telethon:v0.1.1` to `psyb0t/telethon-plus:v0.2.0`
- Update repo links and login command in README and docs to point at docker-telethon-plus

## [v1.4.0] — 2026-04-29

**Add Telethon Telegram client service + MCP integration.**

- Add optional `TELETHON=1` service backed by `psyb0t/telethon-plus` — REST API at `/telethon/` and MCP server with 15 Telegram tools (send/read/edit/delete messages, dialogs, forward, files, group management)
- Add nginx `/telethon/` location block with rewrite rule to strip location prefix before proxying (fix: nginx does not strip prefix when `proxy_pass` uses a variable)
- Add `litellm/config/mcp/telethon.yaml` MCP config pointing at `http://telethon:8080/mcp`
- Add telethon to `litellm/build-config.py` active MCP servers
- Add `--force-recreate` to `make run`, `make run-bg`, `make restart` — baked-in Docker config blocks require full container recreate to pick up env changes
- Add `tests/test_telethon.sh` — health check via MCP `get_me`, tool count assertion, LLM-driven send/verify/delete test (model autonomously calls get_me, send_message, get_messages, delete_messages; post-run check confirms message actually gone)
- Update README, docs, `.env.example` with Telethon service details
- Bump claudebox and claudebox-zai to `v1.8.0-minimal`

## [v1.3.4] — 2026-04-28

**Docs cleanup: remove hardcoded counts.**

- Strip hardcoded service/model counts from README and docs — these go stale on every addition. Counts now sourced from `litellm/config/*` at build time.

## [v1.3.3] — 2026-04-28

**Fix nginx startup crash on disabled optional services.**

- nginx crashed with `host not found in upstream` when `CLAUDEBOX`, `HYBRIDS3`, `LIBRECHAT`, `SEARXNG`, or `BROWSER` were disabled. Fixed by adding Docker DNS resolver (`resolver 127.0.0.11`) and switching all optional upstreams to variable-based `proxy_pass` (defers hostname resolution to request time).

## [v1.3.2] — 2026-04-29

**Fix nginx crash when optional services are disabled; always force-recreate.**

- nginx was crash-looping with `host not found in upstream` when optional services (claudebox, hybrids3, searxng, etc.) were not running — fixed by adding Docker DNS resolver (`resolver 127.0.0.11`) and switching all optional upstreams to variable-based `proxy_pass` (defers hostname resolution to request time)
- `make run` / `make run-bg` / `make restart` now pass `--force-recreate` so env var changes always take effect (Docker config blocks are baked in at deploy time)
- Remove remaining hardcoded counts from README and docs

## [v1.3.1] — 2026-04-25

**Remove Langfuse v3 observability stack.**

- Langfuse v3's event pipeline requires S3 ListObjectsV2, and the JS AWS SDK v3 signs the canonical URI differently than HybridS3 expects when the endpoint URL contains a path prefix (`/storage`). PUTs succeed but LIST operations fail auth verification, making the entire trace pipeline non-functional.
- Remove langfuse-db-init, langfuse-clickhouse, langfuse, langfuse-worker services from docker-compose.yml
- Remove nginx `/langfuse` location block and rate limit zone
- Remove `LANGFUSE=1` profile detection from Makefile
- Remove langfuse from `litellm/build-config.py` active_callbacks
- Delete `litellm/config/callbacks/langfuse.yaml`
- Remove all LANGFUSE env vars from `.env.example`
- Remove langfuse-clickhouse data dir entries from `.gitignore`
- Update README and docs to remove all Langfuse references

## [v1.3.0] — 2026-04-24

**SearXNG self-hosted search + Langfuse LLM observability.**

- Add SearXNG (`SEARXNG=1`) — self-hosted meta-search (Google, Bing, DuckDuckGo, Wikipedia) at `/searxng/`
- Add `search_web` MCP tool — auto-enabled when `SEARXNG=1`; any function-calling model can search the web
- Add Langfuse (`LANGFUSE=1`) — LLM observability at `/langfuse/`; traces all LiteLLM requests (latency, tokens, cost, prompt, response)
- Langfuse uses the shared PostgreSQL instance (separate `langfuse` database, auto-created on first start)
- LiteLLM Langfuse integration via `success_callback`/`failure_callback` — injected by build-config when `LANGFUSE=1`
- mcp_tools auto-enable condition expanded to include SearXNG
- `.env.example` documented with SEARXNG/LANGFUSE flags and Langfuse credential generation instructions

## [v1.2.0] — 2026-04-25

**nuextract-v1.5 for structured extraction; all CPU models available on CUDA.**

- Add `iodose/nuextract-v1.5` to CPU ollama — fine-tuned Phi-3.5-mini for unstructured text → JSON extraction
- All CPU models now also registered on CUDA ollama — every small model available GPU-accelerated when `OLLAMA_CUDA=1`
- LibreChat registration enabled by default (`ALLOW_REGISTRATION=true`) — first user auto-promoted to admin
- proxq bumped to v0.9.0 — fixes upstream timeout not applied to HTTP client
- nginx proxq rate limit raised 120r/m → 600r/m
- `PROXQ_UPSTREAM_TIMEOUT` raised 10m → 30m

### Patches

- **v1.1.1** — proxq v0.9.0, rate limit 600r/m, upstream timeout 30m

## [v1.1.1] — 2026-04-25

**proxq v0.9.0, raise rate limit, 30m upstream timeout.**

- Bump proxq to v0.9.0 — fixes timeout config not being applied to the HTTP client.
- Raise nginx proxq rate limit 120r/m → 600r/m for higher-throughput workloads.
- `PROXQ_UPSTREAM_TIMEOUT` default 10m → 30m to accommodate long-running model calls.

## [v1.1.0] — 2026-04-24

**Local model lineup overhaul: gemma4, abliterated, reasoning, better code models.**

CPU (ollama):
- Add: phi4-mini (3.8B reasoning), gemma4:e2b (multimodal), gemma3:4b (lightweight vision fallback), qwen3-embedding:0.6b
- Drop: phi3.5 (superseded by phi4-mini), nomic-embed-text (bge-m3 is better)

CUDA (ollama-cuda):
- Add: gemma4:e4b + e2b (multimodal), deepseek-coder-v2:16b (MoE code), deepseek-r1:8b (reasoning), qwen3-abliterated:16b (uncensored chat), gemma4-abliterated:e4b (uncensored vision)
- Drop: dolphin-mistral:7b (outdated), dolphin3:latest (redundant)

- Fallback chains rewritten for all new/changed models
- Tests and docs updated throughout

### Patches

- **v1.0.1** — recommend-limits.sh: OS memory reserve (2 GB or 5% RAM), CPU local services use max-of-active + idle overhead like CUDA group. Add CHANGELOG.md.

## [v1.0.1] — 2026-04-24

**OS memory reserve + CPU resource-manager-aware scaling.**

- Reserve 2 GB or 5% of RAM (whichever larger) for the OS before service allocation in `recommend-limits.sh`.
- CPU local services (ollama, speaches, sdcpp) now use `max-of-active + idle overhead` in concurrent RAM calculation — same accounting as the CUDA group.

## [v1.0.0] — 2026-04-24

**Breaking:** Global `CUDA=1` replaced with per-service flags.

- `OLLAMA_CUDA=1` — GPU inference
- `SDCPP_CUDA=1` — GPU image generation
- `SPEACHES_CUDA=1` — GPU STT
- `QWEN_TTS_CUDA=1` — GPU TTS
- Each CUDA service independently toggleable — no more implicit activation
- Docker Compose profiles, Makefile, build-config, resource calculator, tests, and all docs updated
- Fixed flaky tests: removed stale HF image models, fixed CUDA STT input, simplified dolphin-phi test

## [v0.13.3] — 2026-04-23

**Merge ollama pullers into a single service.**

- One `ollama-pull` service with `PULL_CPU` / `PULL_CUDA` flags replaces the separate `ollama-pull` + `ollama-cuda-pull` services.
- CUDA puller now pulls all models (CPU + CUDA) when both flags are on.

## [v0.13.2] — 2026-04-23

**Fallback chains for all 99 models + resource management docs.**

- Complete fallback coverage: every model has a chain. Local preferred over paid for image / TTS / STT. Bogus `cpu-flux-schnell` references removed.
- README expanded with fallback chains, resource management, troubleshooting, and logs sections.

## [v0.12.1] — 2026-04-23

**Fix model prefix to include provider name.**

- Correct v0.12.0 rename: `local-cpu-*` → `local-ollama-cpu-*`, etc. Provider name is now part of the local-model prefix so future local backends (sdcpp, speaches) don't collide.

## [v0.13.1] — 2026-04-23

**Hardcode sdcpp listen address + documentation updates.**

- Hardcode wrapper listen address (`0.0.0.0:7234`) in the Go binary; remove from `docker-compose.yml` env config.
- Comprehensive documentation updates for the sd.cpp integration.

## [v0.13.0] — 2026-04-23

**Stable-diffusion.cpp image generation with CUDA resource semaphore.**

- Go wrapper for sd.cpp with CPU/CUDA backends, model hot-swap, idle timeout
- 5 image models: sd-turbo, sdxl-turbo, sdxl-lightning, flux-schnell, juggernaut-xi (CUDA); sd-turbo, sdxl-turbo (CPU)
- CUDA/CPU semaphore prevents GPU OOM — 503 on contention
- MCP auto-discovers sdcpp models, generate_image works end-to-end
- E2E test: LLM calls tool, MCP generates image, LLM responds with link

### Patches

- **v0.13.3** — Merge ollama pullers into single service with PULL_CPU/PULL_CUDA flags (28 → 27 services)
- **v0.13.2** — Fallback chains for all 99 models, resource management docs, fixed stale defaults
- **v0.13.1** — Hardcode sdcpp listen address, documentation updates

## [v0.12.0] — 2026-04-23

**Rename ollama model prefixes.**

- `ollama-cpu-*` → `local-ollama-cpu-*`, `ollama-cuda-*` → `local-ollama-cuda-*`
- Follows `local-<provider>-<hardware>-<model>` convention
- README intro rewritten

### Patches

- **v0.12.1** — Fix prefix to include provider name (local-cpu → local-ollama-cpu)

## [v0.11.1] — 2026-04-22

**Docs: add LibreChat + MCP tools sections, fix stale counts.**

- Docs-only patch. No code changes.

## [v0.11.0] — 2026-04-22

**MCP media tools, LibreChat web UI, image pinning.**

- MCP server: `generate_image` + `generate_tts` with dynamic model discovery, structured JSON, HybridS3 uploads
- LibreChat web UI at `/librechat/` with LiteLLM backend and MCP tools
- All container images pinned to exact versions
- All provider YAMLs annotated with `model_info.mode` for media models

### Patches

- **v0.11.1** — Docs: add LibreChat + MCP tools docs, fix stale counts (94→92 models, 18→20 tools)

## [v0.10.1] — 2026-04-21

**Docs: correct counts, optional labels, fix broken browser examples.**

- Docs-only patch. No code changes.

## [v0.10.0] — 2026-04-21

**CUDA audio services, resource manager, new ollama models.**

- `speaches-cuda` — CUDA-accelerated Whisper STT
- `qwen3-cuda-tts` — CUDA TTS with voice cloning
- Resource manager callback: unloads competing CUDA/CPU groups before each request (prevents OOM)
- CUDA groups: cuda-llm, cuda-tts, cuda-stt; CPU groups: cpu-tts, cpu-stt
- `GPU_NVIDIA` renamed to `CUDA` (more precise)
- stealthy-auto-browse v1.0.0: all browser tools → single `run_script` tool
- 9 new tests for audio and resource management

### Patches

- **v0.10.1** — Docs: correct model/tool counts, fix browser examples, label optional services

## [v0.9.0] — 2026-04-20

**GPU support with nvidia runtime, configurable data dirs.**

- `GPU_NVIDIA=1`: separate ollama-gpu instance with nvidia runtime
- 5 GPU models sized for 3060 12GB with per-model `num_gpu` control
- `DATA_DIR` / `DATA_DIR_<SERVICE>` env vars for relocating data directories
- All model names: `local-ollama-*` → `ollama-cpu-*` / `ollama-gpu-*`

## [v0.8.0] — 2026-04-20

**Replace moondream with gemma3:4b, add ollama tests.**

- Ollama test suite (4 tests: model registration, chat, embedding, vision)
- gemma3:4b as vision+chat model (moondream was broken)

## [v0.7.0] — 2026-04-18

**proxq async job queue proxy.**

- proxq (psyb0t/proxq) as always-on service in front of LiteLLM
- Async HTTP: submit request → get job ID → poll for result
- Whitelist mode: only OpenAI API paths are queued
- nginx routes `/q/` to proxq with rate limiting

### Patches

- **v0.7.3** — Bump proxq
- **v0.7.2** — Full proxq config via env vars (concurrency, retention, retries, caching)
- **v0.7.1** — Configurable nginx rate limits + timeouts via env vars, proxq v0.5.1

## [v0.7.3] — 2026-04-18

**Bump proxq.**

- Routine proxq image bump.

## [v0.7.2] — 2026-04-18

**proxq v0.5.1, full proxq config via env.**

- All proxq tunables now configurable via env vars (per-upstream retries, timeouts, OpenAI client package).

## [v0.7.1] — 2026-04-18

**Configurable rate limits + timeouts, proxq v0.5.1.**

- Bump proxq v0.4.1 → v0.5.1 (Go OpenAI client package, job header tracking).
- Nginx rate-limit and timeout values exposed via env vars.

## [v0.6.6] — 2026-04-17

**Fix db.**

- DB-related patch.

## [v0.6.5] — 2026-04-17

**Dynamic config build, all providers/services opt-in via flags.**

- `build-config.py` assembles LiteLLM config from per-provider YAML fragments based on `.env` flags
- All providers/services opt-in: `GROQ=1`, `CEREBRAS=1`, `CLAUDEBOX=1`, etc.
- Docker profiles for hybrids3, browser, ollama, speaches
- Fix postgres data loss: mount `.data/postgres` directly to PGDATA

### Patches

- **v0.6.6** — Fix DB

## [v0.6.4] — 2026-04-17

**Bump service image versions.**

- claudebox: v1.3.0-minimal → v1.4.0-minimal.
- stealthy-auto-browse: v0.21.0 → v0.22.5.

## [v0.6.3] — 2026-04-17

**Enable client-side JSON schema validation in LiteLLM.**

- `enable_json_schema_validation: true` in `litellm_settings` — catches providers that treat `json_schema` as a hint (Gemini 1.5, older Anthropic models) and rejects non-conforming responses on the gateway side.
- README documents the JSON schema validation in the LiteLLM service description.

## [v0.6.2] — 2026-04-16

**Bump claudebox image.**

- Routine claudebox image bump.

## [v0.6.1] — 2026-04-16

**Minor fixes.**

- Misc. patch-level fixes (commit message: `f`). See `git log v0.6.0..v0.6.1` for the diff.

## [v0.6.0] — 2026-04-15

**Remove model group aliases, fix vision group.**

- Removed `model_group_alias` (silently broken — maps to one model, not a list)
- Removed group-level fallbacks
- Added local-ollama-moondream to vision group

### Patches

- **v0.6.4** — Bump claudebox v1.4.0, stealthy-auto-browse v0.22.5
- **v0.6.3** — Enable client-side JSON schema validation
- **v0.6.2** — Update claudebox
- **v0.6.1** — Patch

## [v0.5.0] — 2026-04-15

**Remove infinity reranker.**

- Removed infinity service (too RAM-hungry for CPU-only stacks)
- README cleanup

## [v0.4.0] — 2026-04-15

**Local reranking, 83 models.**

- Infinity reranking service with mxbai-rerank-xsmall-v1
- Resource limits in recommend-limits.sh

## [v0.3.0] — 2026-04-15

**82 models, local TTS, nginx rate limiting, security hardening.**

- Speaches: whisper STT, parakeet transcription, Kokoro TTS
- nginx rate limiting on all endpoints
- Cloudflare real IP restoration
- HAProxy admin restricted to private networks

## [v0.2.0] — 2026-04-15

Initial feature expansion.

## [v0.1.1] — 2026-04-15

**Pin cloudflared image.**

- Pin cloudflared to a specific image tag for reproducibility.

## [v0.1.0] — 2026-04-15

Initial release.
