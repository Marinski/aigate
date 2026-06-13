# predictalot (optional, `PREDICTALOT=1` / `PREDICTALOT_CUDA=1`)

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


## Usage

### Time-series forecasting (predictalot)

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

