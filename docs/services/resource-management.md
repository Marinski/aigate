# Resource Management (cross-cutting)


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
