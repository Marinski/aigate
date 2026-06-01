# Providers and Models

Providers are configured via YAML fragments in `litellm/config/providers/`. `make run` assembles them into `litellm/config.yaml` (auto-generated, gitignored). Free-tier providers are tried first in fallback chains. Each provider is opt-in: set its flag to `1` in `.env` (e.g. `GROQ=1`) and fill in the API key. The flag activates the provider — the key alone does nothing.

## Free-tier reality check

"Free" never means unlimited. Every cloud provider on this gateway has a hard cap somewhere — RPM, RPD, TPM, TPD, monthly tokens, monthly request count, or a tiny dollar-denominated credit. Cross the cap and you get 429s, blocked accounts, or pay-as-you-go billing. The fallback chains in `litellm/config/fallbacks.json` hop to the next provider on 429, but if you've exhausted all of them you're either falling all the way to local models or getting an error.

Numbers below were correct at last check (provider docs change — click through for current values before relying on a tier).

| Provider     | CC required? | Per-minute            | Per-day                              | Monthly cap                          | Notes                                                                                | Official limits page                                                                                                  |
| ------------ | ------------ | --------------------- | ------------------------------------ | ------------------------------------ | ------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------- |
| Groq         | No           | 30 RPM, 6–12K TPM     | 1K–14.4K RPD, 100K–500K TPD          | —                                    | Per-model. `llama-3.3-70b`: 1K RPD / 100K TPD. `llama-3.1-8b`: 14.4K RPD / 500K TPD. | [console.groq.com/docs/rate-limits](https://console.groq.com/docs/rate-limits)                                        |
| Cerebras     | No           | 5 RPM, 30K TPM        | 1M TPH, 1M TPD                       | —                                    | "Free Trial" eligible models only: `qwen-3-235b`, `gpt-oss-120b`, `zai-glm-4.7`, `llama3.1-8b`. | [inference-docs.cerebras.ai/support/rate-limits](https://inference-docs.cerebras.ai/support/rate-limits)                |
| OpenRouter   | No (for $0)  | 20 RPM on `:free`     | 50 RPD with $0 / 1000 RPD with $10+  | —                                    | Daily cap is per-account, not per-model.                                             | [openrouter.ai/docs/api-reference/limits](https://openrouter.ai/docs/api-reference/limits)                            |
| HuggingFace  | No           | varies per provider   | varies per provider                  | **$0.10 credits/mo** (PRO: $2/mo)    | Once credits run out you must purchase more — there is no "stays free forever" tier. | [huggingface.co/docs/inference-providers/pricing](https://huggingface.co/docs/inference-providers/pricing)            |
| Mistral      | No           | not published         | not published                        | not published                        | "Experiment" plan exists but Mistral doesn't publish numeric limits — see Admin → Limits in console after sign-up. Only `mistral-large`, `mistral-small`, `ministral-8b`, `mistral-embed` are free-tier. | [docs.mistral.ai/admin/user-management-finops/tier](https://docs.mistral.ai/admin/user-management-finops/tier)         |
| Cohere       | No           | 20 RPM chat, 10 RPM rerank, 2K inputs/min embed | —                          | **1,000 API calls/month** (chat)     | Hard monthly request cap is very low — runs out fast on any real workload.            | [docs.cohere.com/v2/docs/rate-limits](https://docs.cohere.com/v2/docs/rate-limits)                                     |
| Claudebox    | Subscription | depends on plan       | depends on plan                      | —                                    | Uses your Claude Pro/Max OAuth — no extra cost beyond the sub.                       | [anthropic.com/pricing](https://www.anthropic.com/pricing)                                                            |
| Pibox-zai    | Subscription | depends on plan       | depends on plan                      | —                                    | pi-coding-agent pointed at z.ai — uses your z.ai subscription.                       | [z.ai](https://z.ai)                                                                                                  |
| Anthropic    | **Yes**      | tiered                | tiered                               | pay-per-token, no free tier          | Not free. Standard API.                                                              | [docs.anthropic.com/en/api/rate-limits](https://docs.anthropic.com/en/api/rate-limits)                                |
| OpenAI       | **Yes**      | tiered                | tiered                               | pay-per-token, no free tier          | Not free. Standard API.                                                              | [platform.openai.com/docs/guides/rate-limits](https://platform.openai.com/docs/guides/rate-limits)                    |
| Local (CPU / CUDA) | N/A    | unlimited             | unlimited                            | unlimited                            | Only constrained by your hardware. Last-resort fallback when all cloud tiers fail.   | —                                                                                                                     |

What this means for the gateway:

- **Hammer Groq → 429 → fallback** chain hops. A single requesting client doing >30 chat completions/minute is hitting Groq's RPM ceiling, not yours.
- **Cohere is a footgun**: 1,000 calls/month at trial is enough for testing, not enough for any real workload. Don't put Cohere first in a custom fallback chain unless you've enabled production billing.
- **HuggingFace free is ~$0.10/month** — designed for evaluation, not production. Use a custom provider key (your own HF Pro / direct Together / Fireworks / etc.) for sustained use.
- **OpenRouter $0 → 50 req/day total** across all `:free` models. Bumping to $10 loaded raises it to 1000 RPD.
- **Cerebras free tier is brutally rate-capped**: 5 RPM (not per-second, not per-day — per **minute**) is the bottleneck long before the 1M TPD budget. And it's only 4 models — anything else needs the paid Developer plan.
- **Mistral doesn't publish free-tier numbers anywhere** — the "Experiment" plan exists but exact RPS/TPM/TPMonth values live only in your account's Admin → Limits page. Plan accordingly, treat it as low-volume eval-only until you've seen your numbers.
- **Local models** are the only true "no limit" — at the cost of your own VRAM / CPU / latency.

## Groq (free tier — 30 RPM, 1K–14.4K RPD per model, no CC)

Sign up: [console.groq.com](https://console.groq.com) — no credit card required. Per-model limits at [console.groq.com/docs/rate-limits](https://console.groq.com/docs/rate-limits).

| Model                          | Alias                               | Notes           |
| ------------------------------ | ----------------------------------- | --------------- |
| llama-3.1-8b-instant           | `groq-llama-3.1-8b`                 | fast            |
| llama-3.3-70b-versatile        | `groq-llama-3.3-70b`                |                 |
| llama-4-scout-17b-16e-instruct | `groq-llama-4-scout`                | multimodal      |
| moonshotai/kimi-k2-instruct    | `groq-kimi-k2`                      |                 |
| openai/gpt-oss-20b             | `groq-gpt-oss-20b`                  |                 |
| openai/gpt-oss-120b            | `groq-gpt-oss-120b`                 |                 |
| qwen/qwen3-32b                 | `groq-qwen3-32b`                    |                 |
| compound-beta                  | `groq-compound`                     | tool use        |
| compound-beta-mini             | `groq-compound-mini`                | tool use, fast  |
| whisper-large-v3               | `groq-whisper-large-v3`             | transcription   |
| whisper-large-v3-turbo         | `groq-whisper-large-v3-turbo`       | transcription, fast |

## Cerebras (free tier — 5 RPM / 30K TPM / 1M TPD, no CC)

Sign up: [cloud.cerebras.ai](https://cloud.cerebras.ai) — no credit card required. The "Free Trial" plan covers **4 models only** (`qwen-3-235b`, `gpt-oss-120b`, `zai-glm-4.7`, `llama3.1-8b`) and is capped at **5 requests per minute / 30K tokens per minute / 1M tokens per hour / 1M tokens per day** per model. Token bucketing — quota replenishes continuously, not on a fixed reset. The 5 RPM ceiling burns out long before the 1M TPD budget on any real workload. Limits page: [inference-docs.cerebras.ai/support/rate-limits](https://inference-docs.cerebras.ai/support/rate-limits). Among the fastest inference available (Llama 3.1 8B ~1,800 t/s, Qwen3 235B ~1,400 t/s).

| Model                          | Alias                    | Notes                         |
| ------------------------------ | ------------------------ | ----------------------------- |
| qwen-3-235b-a22b-instruct-2507 | `cerebras-qwen3-235b`    | flagship, very fast — free-tier eligible |
| gpt-oss-120b                   | `cerebras-gpt-oss-120b`  | free-tier eligible            |
| zai-glm-4.7                    | `cerebras-glm-4.7`       | free-tier eligible            |
| llama3.1-8b                    | `cerebras-llama-3.1-8b`  | fastest, free-tier eligible   |

## OpenRouter (free tier — 50 RPD at $0, 1000 RPD at $10+)

Sign up: [openrouter.ai](https://openrouter.ai) — 50 req/day free across all `:free` models with $0 loaded; 1000 req/day once you've loaded ≥$10 in credits (lifetime, not monthly). Limits page: [openrouter.ai/docs/api-reference/limits](https://openrouter.ai/docs/api-reference/limits).

| Model                                | Alias              |
| ------------------------------------ | ------------------ |
| nousresearch/hermes-3-llama-3.1-405b | `or-hermes-3-405b` |
| qwen/qwen3-coder                     | `or-qwen3-coder`   |
| qwen/qwen3-next-80b-a3b-instruct     | `or-qwen3-80b`     |
| nvidia/nemotron-3-super-120b-a12b    | `or-nemotron-120b` |
| minimax/minimax-m2.5                 | `or-minimax-m2.5`  |
| meta-llama/llama-3.3-70b-instruct    | `or-llama-3.3-70b` |
| openai/gpt-oss-120b                  | `or-gpt-oss-120b`  |
| openai/gpt-oss-20b                   | `or-gpt-oss-20b`   |

## HuggingFace Inference Providers ($0.10/mo free credits — not really "free")

Sign up: [huggingface.co](https://huggingface.co/settings/tokens). Free users get **$0.10 in credits per month** (PRO: $2/mo, Team/Enterprise: $2/seat/mo). Past that you're pay-as-you-go at the provider's rate — HF doesn't mark up. Treat this as a "try before you buy" tier, not sustained free inference. Pricing: [huggingface.co/docs/inference-providers/pricing](https://huggingface.co/docs/inference-providers/pricing).

| Model                                        | Alias                  | Notes          |
| -------------------------------------------- | ---------------------- | -------------- |
| meta-llama/Llama-3.1-8B-Instruct             | `hf-llama-3.1-8b`      |                |
| meta-llama/Llama-3.3-70B-Instruct            | `hf-llama-3.3-70b`     |                |
| meta-llama/Llama-4-Scout-17B-16E-Instruct    | `hf-llama-4-scout`     | multimodal     |
| Qwen/Qwen3-8B                                | `hf-qwen3-8b`          |                |
| Qwen/QwQ-32B                                 | `hf-qwq-32b`           | reasoning      |
| deepseek-ai/DeepSeek-R1                      | `hf-deepseek-r1`       | reasoning      |
| Qwen/Qwen2.5-VL-72B-Instruct                 | `hf-qwen-vl-72b`       | multimodal     |
| Qwen/Qwen2.5-VL-7B-Instruct                  | `hf-qwen3-vl-8b`       | multimodal     |
| google/gemma-3-12b-it                        | `hf-gemma-3-12b`       | multimodal     |
| black-forest-labs/FLUX.1-schnell             | `hf-flux-schnell`      | image gen, fast |

## Mistral AI (free "Experiment" tier — exact limits not published, no CC)

Sign up: [console.mistral.ai](https://console.mistral.ai) — no credit card required to start. Mistral has a free **"Experiment" plan** ("intended for evaluation and prototyping only") and a paid **"Scale" plan** (pay-as-you-go, auto-promoted Tier 1 → Tier 4 by cumulative billing). The free plan covers `mistral-large`, `mistral-small`, `ministral-8b`, and `mistral-embed`. Anything else (magistral, devstral, codestral, voxtral) requires Scale plan.

**Mistral does not publish numeric free-tier RPS/TPM/TPMonth values anywhere on their public docs site.** The official tier page ([docs.mistral.ai/admin/user-management-finops/tier](https://docs.mistral.ai/admin/user-management-finops/tier)) explicitly directs you to "Admin → Limits" inside your own console to see exact numbers. Treat the free tier as low-volume eval until you've signed in and checked yours.

| Model                 | Alias              | Tier | Notes              |
| --------------------- | ------------------ | ---- | ------------------ |
| mistral-large-2512    | `mistral-large`    | free |                    |
| mistral-small-2603    | `mistral-small`    | free | multimodal         |
| ministral-3-8b-2512   | `ministral-8b`     | free | fast               |
| magistral-medium-2509 | `magistral-medium` | paid | reasoning          |
| magistral-small-2509  | `magistral-small`  | paid | reasoning          |
| devstral-2512         | `devstral`         | paid | coding agent       |
| codestral-2508        | `codestral`        | paid | code completion    |
| mistral-embed         | `mistral-embed`    | free | embeddings         |
| voxtral-small-25-07   | `voxtral-small`    | -    | audio transcription |

## Cohere (trial — 20 RPM chat, **1K calls/month total cap**, no CC)

Sign up: [dashboard.cohere.com](https://dashboard.cohere.com) — no credit card required. Trial key gives access to all models, but **the monthly chat cap is only 1,000 API calls** — runs out fast on any real workload. Rerank: 10 RPM. Embed: 2,000 inputs/min (text) or 5 inputs/min (images). Limits page: [docs.cohere.com/v2/docs/rate-limits](https://docs.cohere.com/v2/docs/rate-limits). For production, switch to a production key (500 RPM chat, contact sales).

| Model                  | Alias                   | Notes                        |
| ---------------------- | ----------------------- | ---------------------------- |
| command-a-03-2025      | `cohere-command-a`      | flagship, 256K ctx, tool use |
| command-r-plus-08-2024 | `cohere-command-r-plus` | strong, 128K ctx             |
| command-r-08-2024      | `cohere-command-r`      | balanced                     |
| command-r7b-12-2024    | `cohere-command-r7b`    | fast, small                  |
| c4ai-aya-expanse-32b   | `cohere-aya-32b`        | multilingual (23 languages)  |
| embed-v4.0             | `cohere-embed`          | embeddings                   |
| rerank-v3.5            | `cohere-rerank`         | reranking                    |

## Claudebox (requires Claude subscription or API key)

Full Claude Code CLI in API mode — not a standard LLM API. Each request runs Claude Code's full agentic loop with tool use, file I/O, shell access, and web browsing. Authentication: either an OAuth token from a Claude Pro/Max/Team subscription, or an Anthropic API key (pay-per-use).

Set up with `claude setup-token` or generate at [console.anthropic.com](https://console.anthropic.com/settings/keys).

| Alias              | Underlying model      | Best for                                        |
| ------------------ | --------------------- | ----------------------------------------------- |
| `claudebox-haiku`  | Claude Haiku 4.5      | Quick tasks, high-volume, minimal token use      |
| `claudebox-sonnet` | Claude Sonnet 4.6     | Daily coding, balanced speed/intelligence        |
| `claudebox-opus`   | Claude Opus 4.6       | Complex reasoning, architecture, hard debugging  |

## Pibox-zai — pi-coding-agent via z.ai (requires z.ai account)

[z.ai](https://z.ai) provides an Anthropic-compatible API backed by GLM models. Routed through [pibox](https://github.com/psyb0t/docker-pibox) — [pi-coding-agent](https://github.com/earendil-works/pi-mono) wrapped in an API server, pointed at z.ai. Same agentic capabilities (shell, files, tools, MCP) as claudebox. Why pibox over a second claudebox: pi speaks the Anthropic wire protocol natively, no Claude Code license/OAuth ceremony, and pibox adds a `/files/*` CRUD API plus optional Telegram + cron modes for free. The `-zai` suffix names the upstream — future `PIBOX_*` flags can run pi against OpenAI, OpenRouter, etc.

| Alias                       | Underlying model |
| --------------------------- | ---------------- |
| `pibox-zai-glm-4.5-air`     | GLM-4.5-Air      |
| `pibox-zai-glm-4.7`         | GLM-4.7          |
| `pibox-zai-glm-5.1`         | GLM-5.1          |

Override the exposed list with `PIBOX_ZAI_AVAILABLE_MODELS=glm-4.5-air,glm-4.7,glm-5.1` and the default model with `PIBOX_ZAI_DEFAULT_MODEL=glm-4.7` in `.env`.

## Anthropic (optional, API key required)

Standard Anthropic API — not agentic, just LLM inference. Sign up: [console.anthropic.com](https://console.anthropic.com).

| Alias                        | Model             | Notes      |
| ---------------------------- | ----------------- | ---------- |
| `anthropic-claude-opus-4`    | claude-opus-4-6   | multimodal |
| `anthropic-claude-sonnet-4`  | claude-sonnet-4-6 | multimodal |
| `anthropic-claude-haiku-4`   | claude-haiku-4-5  | multimodal |

## OpenAI (optional, API key required)

Sign up: [platform.openai.com](https://platform.openai.com).

| Alias                  | Model       | Notes          |
| ---------------------- | ----------- | -------------- |
| `openai-gpt-4o`        | gpt-4o      | multimodal     |
| `openai-gpt-4o-mini`   | gpt-4o-mini | multimodal     |
| `openai-o3`            | o3          | reasoning      |
| `openai-o3-mini`       | o3-mini     | reasoning      |
| `openai-dall-e-3`      | dall-e-3    | image gen      |
| `openai-gpt-image-1`   | gpt-image-1 | image gen      |
| `openai-whisper`               | whisper-1              | transcription  |
| `openai-gpt-4o-transcribe`     | gpt-4o-transcribe      | transcription, lower WER than whisper, streaming |
| `openai-gpt-4o-mini-transcribe`| gpt-4o-mini-transcribe | transcription, cheaper variant of the gpt-4o transcriber |
| `openai-tts-1`         | tts-1       | text-to-speech |
| `openai-tts-1-hd`      | tts-1-hd    | text-to-speech |

---

## Ollama (local CPU — `OLLAMA=1`)

Models are downloaded on first start and cached in `.data/ollama/`. No GPU required.

| Alias | Model | Notes |
| ----- | ----- | ----- |
| `local-ollama-cpu-llama3.2-3b` | llama3.2:3b | general chat, ~2GB RAM |
| `local-ollama-cpu-qwen3-4b` | qwen3:4b | general chat, thinking mode, ~2.6GB RAM |
| `local-ollama-cpu-smollm2-1.7b` | smollm2:1.7b | general chat, smallest, ~1GB RAM |
| `local-ollama-cpu-qwen2.5-coder-1.5b` | qwen2.5-coder:1.5b | code, ~1GB RAM |
| `local-ollama-cpu-qwen2.5-coder-3b` | qwen2.5-coder:3b | code, ~2GB RAM |
| `local-ollama-cpu-phi4-mini` | phi4-mini | general chat, 128K ctx, ~2.5GB RAM |
| `local-ollama-cpu-gemma4-e2b` | gemma4:e2b | general chat + vision (Gemma 4), ~7.2GB RAM |
| `local-ollama-cpu-gemma3-4b` | gemma3:4b | general chat + vision — lightweight, ~2.6GB RAM |
| `local-ollama-cpu-dolphin-phi` | dolphin-phi:latest | uncensored, ~1.6GB RAM |
| `local-ollama-cpu-nuextract-v1.5` | nuextract | structured extraction — unstructured text → JSON, ~2.3GB RAM |
| `local-ollama-cpu-bge-m3` | bge-m3 | embeddings, multilingual, 8192 ctx, ~570MB RAM |
| `local-ollama-cpu-qwen3-embed-0.6b` | qwen3-embedding:0.6b | embeddings, ~500MB RAM |

## Ollama CUDA (local NVIDIA — `OLLAMA_CUDA=1`)

Requires `nvidia-container-toolkit`. Flash attention + quantized KV cache enabled. Resource manager unloads the CUDA LLM before any CUDA TTS/STT request.

| Alias | Model | Notes |
| ----- | ----- | ----- |
| `local-ollama-cuda-qwen3-8b` | qwen3:8b | general chat, thinking mode, ~5GB VRAM |
| `local-ollama-cuda-llama3.1-8b` | llama3.1:8b | general chat, ~5GB VRAM |
| `local-ollama-cuda-gemma4-e2b` | gemma4:e2b | general chat + vision, ~7.2GB VRAM |
| `local-ollama-cuda-gemma4-e4b` | gemma4:e4b | general chat + vision, ~9.6GB VRAM |
| `local-ollama-cuda-qwen2.5-coder-7b` | qwen2.5-coder:7b | code, ~5GB VRAM |
| `local-ollama-cuda-deepseek-coder-v2-16b` | deepseek-coder-v2:16b | code, MoE 2.4B active, 160K ctx, ~8.9GB VRAM |
| `local-ollama-cuda-deepseek-r1-8b` | deepseek-r1:8b | reasoning, thinking mode, ~5.2GB VRAM |
| `local-ollama-cuda-qwen3-abliterated-16b` | huihui_ai/qwen3-abliterated:16b | uncensored, ~9.8GB VRAM |
| `local-ollama-cuda-gemma4-abliterated-e4b` | huihui_ai/gemma-4-abliterated:e4b | uncensored + vision, ~9.6GB VRAM |
| `local-ollama-cuda-dolphin-phi` | dolphin-phi:latest | uncensored, tiny, ~1.6GB VRAM |
| `local-ollama-cuda-llama3.2-3b` | llama3.2:3b | general chat, ~2.0GB VRAM |
| `local-ollama-cuda-qwen3-4b` | qwen3:4b | general chat, thinking mode, ~2.6GB VRAM |
| `local-ollama-cuda-smollm2-1.7b` | smollm2:1.7b | tiny general chat, ~1.0GB VRAM |
| `local-ollama-cuda-qwen2.5-coder-1.5b` | qwen2.5-coder:1.5b | code completion, tiny, ~1.0GB VRAM |
| `local-ollama-cuda-qwen2.5-coder-3b` | qwen2.5-coder:3b | code completion, small, ~2.0GB VRAM |
| `local-ollama-cuda-phi4-mini` | phi4-mini | general chat + reasoning, ~2.5GB VRAM |
| `local-ollama-cuda-gemma3-4b` | gemma3:4b | general chat + vision, lightweight, ~2.6GB VRAM |
| `local-ollama-cuda-nuextract-v1.5` | iodose/nuextract-v1.5 | structured extraction — unstructured text → JSON, ~2.3GB VRAM |
| `local-ollama-cuda-bge-m3` | bge-m3 | embeddings, multilingual, 8192 ctx, ~570MB VRAM |
| `local-ollama-cuda-qwen3-embed-0.6b` | qwen3-embedding:0.6b | embeddings, ~500MB VRAM |

## talkies CPU (local — `TALKIES=1`)

Unified OpenAI-compatible speech service via [`psyb0t/talkies:v0.3.0`](https://github.com/psyb0t/docker-talkies). One container exposes both `/v1/audio/transcriptions` (whisper + canary-180m) and `/v1/audio/speech` (Kokoro-82M TTS). Stereo channel-split diarization (`diarization=true` → segments tagged with `"channel": "L"/"R"`), VAD-chunked long audio, idle-unload TTL. Weights auto-downloaded into `.data/talkies/` on first request. Loaded models auto-unload after `TALKIES_MODEL_TTL` (default `10m`).

| Alias | Model | Mode |
| ----- | ----- | ---- |
| `local-talkies-whisper-large-v3` | Systran/faster-whisper-large-v3 | transcription (multilingual, highest accuracy) |
| `local-talkies-whisper-large-v3-turbo` | deepdml/faster-whisper-large-v3-turbo-ct2 | transcription (multilingual, ~8x faster than large-v3) |
| `local-talkies-canary-180m-flash` | nvidia/canary-180m-flash | transcription (English, FastConformer encoder) |
| `local-talkies-kokoro-tts` | hexgrad/Kokoro-82M | TTS — ~41 voices across en/es/fr/hi/it/pt (`af_heart`, `bm_george`, `ef_dora`, …; discover via `GET /v1/audio/voices`) |

## talkies CUDA (local NVIDIA — `TALKIES_CUDA=1`)

CUDA-accelerated talkies (`psyb0t/talkies:v0.3.0-cuda`). Adds Parakeet TDT, Canary-1B-Flash, and Canary-Qwen-2.5B SALM on top of the CPU set. Kokoro TTS still runs on CPU inside the CUDA image (fast enough that it doesn't need a GPU). Shares `.data/talkies/` with the CPU variant. The LiteLLM resource manager evicts these from VRAM whenever a competing CUDA job (LLM / image / TTS / other STT) arrives.

| Alias | Model | Mode |
| ----- | ----- | ---- |
| `local-talkies-cuda-whisper-large-v3` | Systran/faster-whisper-large-v3 | transcription (CUDA, multilingual) |
| `local-talkies-cuda-whisper-large-v3-turbo` | deepdml/faster-whisper-large-v3-turbo-ct2 | transcription (CUDA, fastest Whisper at near-large WER) |
| `local-talkies-cuda-parakeet-tdt-0.6b-v3` | nvidia/parakeet-tdt-0.6b-v3 | transcription (CUDA, 25 European languages) |
| `local-talkies-cuda-canary-180m-flash` | nvidia/canary-180m-flash | transcription (CUDA, English) |
| `local-talkies-cuda-canary-1b-flash` | nvidia/canary-1b-flash | transcription (CUDA, EN/DE/FR/ES + EN↔X translation) |
| `local-talkies-cuda-canary-qwen-2.5b` | nvidia/canary-qwen-2.5b | transcription (CUDA, English, NeMo SALM hybrid ASR+LLM) |
| `local-talkies-cuda-kokoro-tts` | hexgrad/Kokoro-82M | TTS (runs on CPU inside the CUDA image) |
| `local-talkies-cuda-qwen3-tts` | Qwen/Qwen3-TTS-12Hz-0.6B-Base | TTS — voice cloning via reference `.wav` files in `${DATA_DIR_TALKIES}/custom-voices/`; samples `alloy`/`echo`/`fable` baked in; supports 17 languages (en, zh, ja, ko, fr, de, es, it, pt, ru, vi, th, id, ar, tr, pl, nl) |

## sd.cpp CPU (local — `SDCPP=1`)

Local CPU image generation via [stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp). Go wrapper with model hot-swap, idle auto-unload, OpenAI-compatible `/v1/images/generations`. Models cached in `.data/sdcpp/models/`.

| Alias | Model | Notes |
| ----- | ----- | ----- |
| `local-sdcpp-cpu-sd-turbo` | stabilityai/sd-turbo | fastest, smallest (~1.7GB) |
| `local-sdcpp-cpu-sdxl-turbo` | stabilityai/sdxl-turbo | better quality (~2.5GB) |

## sd.cpp CUDA (local NVIDIA — `SDCPP_CUDA=1`)

CUDA-accelerated image generation. Same Go wrapper with CUDA backend. Non-blocking — rejects concurrent requests with 503 (resource manager handles scheduling via semaphore).

| Alias | Model | Notes |
| ----- | ----- | ----- |
| `local-sdcpp-cuda-sd-turbo` | stabilityai/sd-turbo | fastest on GPU (~1.7GB VRAM) |
| `local-sdcpp-cuda-sdxl-turbo` | stabilityai/sdxl-turbo | fast, good quality (~2.5GB VRAM) |
| `local-sdcpp-cuda-sdxl-lightning` | ByteDance/SDXL-Lightning | fast, high quality (~2.5GB VRAM) |
| `local-sdcpp-cuda-flux-schnell` | black-forest-labs/FLUX.1-schnell | best quality, largest (~7GB VRAM) |
| `local-sdcpp-cuda-juggernaut-xi` | RunDiffusion/Juggernaut-XI-v11 | photorealistic SDXL fine-tune (~2.5GB VRAM) |

---

## NVIDIA NIM API (paid — `NVIDIA=1`)

NVIDIA NIM (NVIDIA Inference Microservices) hosts a wide range of open models on `api.nvidia.com`. Requires an API key from [build.nvidia.com](https://build.nvidia.com). Set `NVIDIA_API_BASE` to override the default endpoint.

| Alias | Underlying model | Notes |
| ----- | ---------------- | ----- |
| `nvidia-kimi-k2` | moonshotai/kimi-k2-thinking | reasoning, thinking mode |
| `nvidia-palmyra-fin-70b` | writer/palmyra-fin-70b-32k | finance-specialized (Writer) |
| `nvidia-llama-3.2-90b` | meta/llama-3.2-90b-vision-instruct | multimodal, vision |
| `nvidia-qwen3-80b` | qwen/qwen3-next-80b-a3b-instruct | MoE, fast, general |
| `nvidia-qwen3-coder` | qwen/qwen3-coder-480b-a35b-instruct | code-specialized MoE |
| `nvidia-deepseek-v3.2` | deepseek-ai/deepseek-v3.2 | reasoning |
| `nvidia-nv-embedqa-e5-v5` | nvidia/nv-embedqa-e5-v5 | embeddings |

## Google Gemini (paid — `GEMINI=1`)

Google's Gemini models via the Gemini API. Requires an API key from [aistudio.google.com](https://aistudio.google.com).

| Alias | Underlying model | Notes |
| ----- | ---------------- | ----- |
| `gemini-2.5-pro` | gemini/gemini-2.5-pro | flagship reasoning |
| `gemini-2.5-flash` | gemini/gemini-2.5-flash | balanced speed/quality |
| `gemini-2.5-flash-lite` | gemini/gemini-2.5-flash-lite | fast, cheap |
| `gemini-3-flash-preview` | gemini/gemini-3-flash-preview | preview, latest gen |
| `gemini-3.1-flash-lite-preview` | gemini/gemini-3.1-flash-lite-preview | preview lite |
| `gemini-embedding-001` | gemini/gemini-embedding-001 | embeddings |

## Local vLLM (external — `VLLM_LOCAL=1`)

Existing Docker-based vLLM instances running on the host. Uses `custom_llm_provider: openai` pointing at the local vLLM API servers. Requires `LOCAL_VLLM_API_KEY`, `GEMMA_LOCAL_API_BASE`, and `QWEN_LOCAL_API_BASE` in `.env`.

| Alias | Model | Port |
| ----- | ----- | ---- |
| `local-vllm-gemma4` | gemma-4-31B-it-4bit-awq | 8000 |
| `local-vllm-qwen3.6` | qwen-3.6-35b-a3b-awq-4bit | 8001 |

## Local Embedding (external — `EMBED_LOCAL=1`)

External embedding server (Nomic Embed v2) running on the host at port 8010. Uses `custom_llm_provider: openai` with `mode: embedding`.

| Alias | Model | Notes |
| ----- | ----- | ----- |
| `local-embed-nomic` | nomic-embed-text-v2 | text embeddings |

---

## Fallbacks

Every model has its own fallback chain. When a provider fails, is rate-limited, or returns an error, LiteLLM automatically tries the next model in the chain. Free providers are always tried first.

For example, `groq-llama-3.3-70b` falls back through `cerebras-qwen3-235b` → `mistral-small` → `cohere-command-r` → `or-llama-3.3-70b` → `hf-llama-3.3-70b` → `claudebox-sonnet` → `pibox-zai-glm-4.7` → `openai-gpt-4o`. See `litellm/config/fallbacks.json` for all chains.
