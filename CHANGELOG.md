# Changelog

All notable changes to this project are documented here.

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
