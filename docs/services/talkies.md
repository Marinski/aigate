# talkies / talkies-cuda — unified speech (ASR + TTS)

> Profile flags: `TALKIES=1` (CPU) / `TALKIES_CUDA=1` (NVIDIA GPU).
> One container, both endpoints: `/v1/audio/transcriptions` and `/v1/audio/speech`.

External image: [`psyb0t/talkies`](https://github.com/psyb0t/docker-talkies) (pinned to `v0.9.0` / `v0.9.0-cuda`). CPU image ships **6 models** — four ASR (`whisper-large-v3`, `whisper-large-v3-turbo`, `canary-180m-flash`, `nemotron-3.5-asr-0.6b` via parakeet.cpp) plus two TTS (`kokoro-82m` PyTorch and `kokoro-82m-nvidia` ONNXRuntime). CUDA image ships **14 models** — adds Parakeet-TDT, Canary-1B-Flash, Canary-Qwen-2.5B SALM, and the full Qwen3-TTS line (Base 0.6B + Base 1.7B + CustomVoice 0.6B + CustomVoice 1.7B + VoiceDesign 1.7B). Kokoro stays CPU-bound in both images.

## Available models

### Transcription (ASR)

| Slug | Backend | Languages | Notes |
|---|---|---|---|
| `local-talkies-whisper-large-v3` | Systran/faster-whisper-large-v3 | multilingual | highest accuracy |
| `local-talkies-whisper-large-v3-turbo` | deepdml/faster-whisper-large-v3-turbo-ct2 | multilingual | ~8× faster than large-v3 |
| `local-talkies-canary-180m-flash` | nvidia/canary-180m-flash | English | FastConformer encoder |
| `local-talkies-nemotron-3.5-asr-0.6b` | nvidia/Nemotron-3.5-ASR-Streaming-0.6B (parakeet.cpp) | 40+ locales | OpenMDW-1.1, per-word timestamps + confidence, WER-0 vs NeMo. C++17/ggml backend; CPU-only in both images at this stage. Operators can register additional parakeet.cpp checkpoints (any Parakeet TDT/CTC/RNNT GGUF in [mudler/parakeet-cpp-gguf](https://huggingface.co/mudler/parakeet-cpp-gguf)) via a custom `models.json`. |
| `local-talkies-cuda-parakeet-tdt-0.6b-v3` | nvidia/parakeet-tdt-0.6b-v3 | 25 European | NeMo RNNT |
| `local-talkies-cuda-canary-1b-flash` | nvidia/canary-1b-flash | EN/DE/FR/ES + EN↔X translation | NeMo multitask |
| `local-talkies-cuda-canary-qwen-2.5b` | nvidia/canary-qwen-2.5b | English | NeMo SALM hybrid ASR+LLM (text-only; no per-word timestamps) |

### Text-to-Speech (TTS)

| Slug | Model | Notes |
|---|---|---|
| `local-talkies-kokoro-tts` / `local-talkies-cuda-kokoro-tts` | hexgrad/Kokoro-82M | PyTorch + misaki G2P. ~41 voices across en/es/fr/hi/it/pt — `af_heart`, `bm_george`, `ef_dora`, etc. Discover via `GET /v1/audio/voices`. Runs on CPU even inside the CUDA image. |
| `local-talkies-kokoro-82m-nvidia` / `local-talkies-cuda-kokoro-82m-nvidia` | nvidia/kokoro-82M-onnx-opt | Same Kokoro weights + same voices, served via ONNXRuntime against NVIDIA's TensorRT-friendly ONNX export + espeak-ng G2P. No PyTorch on the inference hot path. Pick for a leaner runtime; pick PyTorch for misaki-driven G2P quality. |
| `local-talkies-cuda-qwen3-tts` | Qwen/Qwen3-TTS-12Hz-0.6B-Base | Base 0.6B voice cloning. Drop reference `.wav` (10-30 s clean speech) into `${DATA_DIR_TALKIES}/custom-voices/` → use `voice=<filename-without-ext>`. Nested paths supported. Samples `alloy` / `echo` / `fable` baked in. 17 languages (en, zh, ja, ko, fr, de, es, it, pt, ru, vi, th, id, ar, tr, pl, nl). |
| `local-talkies-cuda-qwen3-tts-1.7b` | Qwen/Qwen3-TTS-12Hz-1.7B-Base | Same as above, larger / higher quality. |
| `local-talkies-cuda-qwen3-tts-0.6b-custom` | Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice | CustomVoice mode. 9 baked-in presets: `Vivian`, `Serena`, `Uncle_Fu`, `Dylan`, `Eric`, `Ryan`, `Aiden`, `Ono_Anna`, `Sohee` — pass as `voice=<preset>`. |
| `local-talkies-cuda-qwen3-tts-1.7b-custom` | Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice | Same 9 presets + `instructions=<emotion>` (`"happy"`, `"sad"`, …). |
| `local-talkies-cuda-qwen3-tts-1.7b-design` | Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign | VoiceDesign mode. Pass `voice="design"` (sentinel) + `instructions=<natural-language description>` (e.g. `"a young energetic female voice"`). |

## curl recipes

### Transcription

```bash
curl http://localhost:4000/audio/transcriptions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -F "model=local-talkies-whisper-large-v3-turbo" \
  -F "file=@audio.mp3"
```

talkies-specific knobs (any ASR model):
- `response_format=text|json|verbose_json|srt|vtt`
- `diarization=true` — stereo channel-split. Left=L, right=R; segments + words get a `"channel": "L"/"R"` field
- `timestamp_granularities[]=word` — word-level timing on backends that support it (Whisper, Canary, Nemotron)

### Text-to-Speech — Kokoro

```bash
# PyTorch Kokoro (CPU, multiple voices)
curl http://localhost:4000/audio/speech \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "local-talkies-kokoro-tts", "input": "Hello world", "voice": "af_heart"}' \
  -o speech.mp3

# Kokoro via NVIDIA's ONNXRuntime export (no PyTorch on hot path)
curl http://localhost:4000/audio/speech \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "local-talkies-kokoro-82m-nvidia", "input": "Hello world", "voice": "af_heart"}' \
  -o speech.mp3
```

### Text-to-Speech — Qwen3-TTS (CUDA)

```bash
# Base 0.6B — voice cloning via baked-in samples or your own reference .wav
curl http://localhost:4000/audio/speech \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "local-talkies-cuda-qwen3-tts", "input": "Hello world", "voice": "alloy"}' \
  -o speech.mp3

# CustomVoice 1.7B + emotion (one of 9 preset speakers)
curl http://localhost:4000/audio/speech \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "local-talkies-cuda-qwen3-tts-1.7b-custom",
       "input": "Hello world",
       "voice": "Vivian",
       "instructions": "happy"}' \
  -o speech.mp3

# VoiceDesign — synthesise a voice from a natural-language description
curl http://localhost:4000/audio/speech \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "local-talkies-cuda-qwen3-tts-1.7b-design",
       "input": "Hello world",
       "voice": "design",
       "instructions": "a young energetic female voice"}' \
  -o speech.mp3
```

### Qwen3-TTS per-request sampling controls

OpenAI-extras (v0.8.0+) via `extra_body` on official SDKs, all Qwen3-TTS modes: `temperature`, `top_k`, `top_p`, `repetition_penalty`, `max_new_tokens`, `do_sample`, plus `language` (for CustomVoice / VoiceDesign). Out-of-range returns HTTP 422.

### Qwen3-TTS PCM streaming

`response_format="pcm"` against any qwen3_tts model streams the raw PCM body via HTTP/1.1 chunked transfer-encoding — TTFA drops to ~200-700 ms vs ~3-8 s buffered. Tune chunk size via `TALKIES_QWEN3_STREAM_CHUNK_SIZE` (default `8` codec-steps-per-chunk).

## Behavior

- **Lazy load + idle TTL unload** — weights download on first request, sit on disk in `${DATA_DIR_TALKIES}` (HF cache layout). A background sweeper unloads any model idle longer than `TALKIES_MODEL_TTL` (default `10m`); next request warm-reloads from disk.
- **Sibling eviction** — only one model resident per talkies container at a time. When request N arrives for a different model, talkies evicts the prior one before loading.
- **Resource-manager aware** — `local-talkies-cuda-*` participates in the `cuda-stt-talkies` group, `local-talkies-*` in `cpu-stt-talkies`. A competing job (LLM, image gen, TTS, other STT) triggers `DELETE /api/ps/{model_id}` for every model before its own load.
- **VAD chunking** — long audio is sliced via Silero VAD into ≤28-second speech regions before each backend forward pass, then results are stitched into one Whisper-shape timeline. Backends that don't support timeline assembly (the SALM `canary-qwen-2.5b`) concatenate per-chunk text without timestamps.
- **Audio preprocessing** — any container/codec is ffmpeg-converted to 16 kHz mono WAV before the backend sees it. Stereo `diarization=true` splits L/R into two mono streams, transcribes each, and time-interleaves the segments with channel tags.
- **OpenAI parity** — every `response_format` returns the correct Content-Type body: `text/plain` for `text`, `application/x-subrip` for `srt`, `text/vtt` for `vtt`, `application/json` for `json` / `verbose_json`. `verbose_json` carries `text`, `language`, `duration`, `segments[{id,start,end,text,channel?,…}]`, `words[{word,start,end,channel?}]`.

## Endpoints (internal — accessed through LiteLLM, not directly via nginx)

| Endpoint | URL | Description |
|---|---|---|
| Transcribe | `POST /v1/audio/transcriptions` | OpenAI-compatible multipart upload (`file`, `model`, `language`, `response_format`, `timestamp_granularities[]`, `diarization`). |
| Speech | `POST /v1/audio/speech` | OpenAI-compatible TTS. JSON body with `model`, `input`, `voice`, `response_format` (`mp3`/`opus`/`aac`/`flac`/`wav`/`pcm`). |
| List models | `GET /v1/models` | Configured model_ids |
| List voices | `GET /v1/audio/voices` | Available voices per slug |
| Loaded models | `GET /api/ps` | Currently loaded backends + `idle_seconds` |
| Unload one | `DELETE /api/ps/{model_id}` | Evict one model (URL-encoded id) |
| Unload all | `POST /unload` | Evict every loaded backend |
| Health | `GET /healthz` | Liveness + device + configured model_ids |

## Configuration

| Variable | Default | Description |
|---|---|---|
| `TALKIES_MODEL_TTL` / `TALKIES_CUDA_MODEL_TTL` | `10m` | Idle duration before unload (`-1` disables). Accepts bare seconds or Go-style strings (`3h30m5s`, `45m`, `90s`). |
| `TALKIES_SWEEPER_INTERVAL` / `TALKIES_CUDA_SWEEPER_INTERVAL` | `1m` | Idle sweeper poll interval |
| `TALKIES_LOAD_TIMEOUT` / `TALKIES_CUDA_LOAD_TIMEOUT` | `5m` | Max wait for model load before the request errors |
| `TALKIES_MAX_UPLOAD_BYTES` / `TALKIES_CUDA_MAX_UPLOAD_BYTES` | `104857600` | Max audio upload size (bytes) |
| `TALKIES_LOG_LEVEL` / `TALKIES_CUDA_LOG_LEVEL` | `INFO` | Log level |
| `TALKIES_PRELOAD` / `TALKIES_CUDA_PRELOAD` | _empty_ | Comma-separated model_ids to load at boot |
| `TALKIES_VAD_CHUNK_THRESHOLD` / `TALKIES_CUDA_VAD_CHUNK_THRESHOLD` | `30` | Audio length (seconds) above which VAD chunking kicks in |
| `TALKIES_VAD_MAX_SPEECH` / `TALKIES_CUDA_VAD_MAX_SPEECH` | `28` | Max chunk length fed to a single forward pass |
| `TALKIES_QWEN3_STREAM_CHUNK_SIZE` | `8` | Qwen3-TTS PCM streaming chunk size (codec-steps-per-chunk) |
| `TALKIES_MEM_LIMIT` / `TALKIES_CUDA_MEM_LIMIT` | `8g` / `12g` | Container memory limit |
| `TALKIES_CPUS` / `TALKIES_CUDA_CPUS` | `4.0` | Container CPU limit |
| `DATA_DIR_TALKIES` | `${DATA_DIR}/talkies` | Bind-mount root for talkies' `/data` dir. Contains `hf/hub/models--*/` (HF cache, shared by CPU + CUDA) and — for CUDA — `custom-voices/<name>.wav` (Qwen3-TTS reference voices). |

Plus all the hosted cloud transcription / TTS slugs registered through LiteLLM live alongside talkies (`groq-whisper-large-v3-turbo`, `openai-tts-1`, etc.) — see [docs/providers.md](../providers.md) for the full alias table.
