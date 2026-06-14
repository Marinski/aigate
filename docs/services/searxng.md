# SearXNG (optional, `SEARXNG=1`)

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


## Usage

### Web search (SearXNG MCP)

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

→ [SearXNG configuration](#configuration) · [MCP tool schema](../mcp-tools.md#mcp_tools-auto-enabled-with-imagetts-search-providers)

---

