#!/bin/bash

# ── llamacpp wrapper: gated on LLAMACPP=1 / LLAMACPP_CUDA=1 ─────────────────
#
# Two variants run side-by-side on distinct service hostnames inside the
# compose network:
#   llamacpp        → CPU (LLAMACPP=1)
#   llamacpp-cuda   → GPU (LLAMACPP_CUDA=1)
# Both registered with LiteLLM as `local-llamacpp-<slug>` and
# `local-llamacpp-cuda-<slug>` chat models. The tests below exercise the
# full path through LiteLLM (model routing → wrapper supervisor → spawn
# llama-server → vision chat completion → response) so any breakage in the
# pipeline gets caught.
#
# What we test, per variant:
#   1. `/v1/models` lists the configured surya-ocr-2 slug
#   2. The captcha fixture (tests/.fixtures/captcha.png) returns a JSON
#      response containing the expected literal text "AIGATE2026" — this
#      proves: (a) the wrapper spawned llama-server with the right gguf +
#      mmproj, (b) the model loaded a real image and decoded it, (c) the
#      OpenAI vision chat completions wire format works through the whole
#      LiteLLM → wrapper → llama-server proxy chain.
#   3. The doc.pdf fixture's first page is rasterized with `pdftoppm` and
#      sent the same way; we assert the response contains "quick brown fox"
#      so we catch regressions where Surya stops working on PDF-derived
#      raster input but still works on captcha-style PNGs.

_llamacpp_cpu_enabled()  { [ "${LLAMACPP:-0}" = "1" ]; }
_llamacpp_cuda_enabled() { [ "${LLAMACPP_CUDA:-0}" = "1" ]; }

# ── helpers ────────────────────────────────────────────────────────────────

# data:image/<fmt>;base64,<payload> URL — vision chat completions over
# OpenAI take this in the `image_url.url` field. We base64-encode the
# fixture inline so the request stays a single curl.
_llamacpp_data_url() {
    local fmt="$1" path="$2"
    printf 'data:image/%s;base64,' "$fmt"
    base64 -w 0 < "$path"
}

# Raster page 1 of a PDF to a PNG at 200 DPI. Uses pdftoppm (poppler-utils)
# inside the test runner image. Output goes to a stable tmp path so the
# test fn can pass it to _llamacpp_data_url.
_llamacpp_pdf_page1_png() {
    local pdf="$1" out_dir="$2"
    pdftoppm -png -r 200 -f 1 -l 1 "$pdf" "$out_dir/page" >/dev/null 2>&1
    # pdftoppm writes <prefix>-<page-number>.png. Single-page → page-1.png.
    echo "$out_dir/page-1.png"
}

# POST one /v1/chat/completions request with a single vision message
# containing the image + a Surya training-time task prompt, and echo the
# raw assistant text content. Anything non-200 returns the body so the
# caller can grep for what went wrong.
#
# Surya prompts are TRAINED INTO THE MODEL — paraphrasing them produces
# unpredictable output mode (layout-JSON vs OCR-HTML). The exact strings
# come from datalab-to/surya:surya/inference/prompts.py:
#   BLOCK_PROMPT — "OCR this block image to HTML."
#       For a tight crop of one text region (captcha, single text block).
#   HIGH_ACCURACY_BBOX_PROMPT — "OCR this image to HTML. Each block is a
#       div with data-label and data-bbox (x0 y0 x1 y1, normalized 0-1000)."
#       For a full page with multiple regions (PDF page, scanned doc).
#
#   $1 model_id   — e.g. local-llamacpp-surya-ocr-2
#   $2 image_url  — full data:image/...;base64,... string
#   $3 timeout_s  — curl --max-time
#   $4 task       — "block" or "page" (chooses the prompt)
_llamacpp_ocr_call() {
    local model="$1" image_url="$2" timeout="$3" task="$4"
    local prompt
    case "$task" in
        block) prompt="OCR this block image to HTML." ;;
        page)  prompt="OCR this image to HTML. Each block is a div with data-label and data-bbox (x0 y0 x1 y1, normalized 0-1000)." ;;
        *)     echo "  FAIL: unknown task '$task'"; return 1 ;;
    esac
    local body
    body=$(python3 -c "
import json, sys
print(json.dumps({
    'model': sys.argv[1],
    'max_tokens': 1024,
    'temperature': 0.0,
    'messages': [
        {
            'role': 'user',
            'content': [
                {'type': 'image_url', 'image_url': {'url': sys.argv[2]}},
                {'type': 'text', 'text': sys.argv[3]},
            ],
        },
    ],
}))
" "$model" "$image_url" "$prompt")
    curl -s -m "$timeout" -X POST "$BASE_URL/v1/chat/completions" \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -d "$body" \
        -w "\nHTTP_CODE:%{http_code}"
}

# Parse the assistant content out of an OpenAI chat completion response.
# Returns empty string on parse failure (caller asserts).
_llamacpp_extract_content() {
    local raw="$1"
    echo "$raw" | sed '/^HTTP_CODE:/d' \
        | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d['choices'][0]['message']['content'])
except Exception:
    pass
"
}

# ── parameterised assertions ───────────────────────────────────────────────

_llamacpp_test_models_list() {
    local model="$1" tag="$2"
    local out
    out=$(curl -sf "$BASE_URL/v1/models" -H "$AUTH_HEADER" 2>/dev/null) || {
        echo "  FAIL: ${tag} GET /v1/models"; return 1
    }
    assert_contains "$out" "\"$model\"" "${tag} /v1/models lists ${model}" || return 1
    echo "OK: ${tag} models_list"
}

_llamacpp_test_captcha_ocr() {
    local model="$1" tag="$2"
    local fixture="$WORKDIR/tests/.fixtures/captcha.png"
    [ -f "$fixture" ] || { echo "  SKIP: missing $fixture"; return 0; }
    local url; url=$(_llamacpp_data_url "png" "$fixture")
    local raw code content
    raw=$(_llamacpp_ocr_call "$model" "$url" 600 "block")
    code=$(echo "$raw" | sed -n 's/^HTTP_CODE://p' | tail -1)
    if [ "$code" != "200" ]; then
        echo "  FAIL: ${tag} captcha OCR HTTP $code"
        echo "  body: $(echo "$raw" | sed '/^HTTP_CODE:/d' | head -c 400)"
        return 1
    fi
    content=$(_llamacpp_extract_content "$raw")
    assert_contains "$content" "AIGATE2026" "${tag} captcha contains 'AIGATE2026'" || {
        echo "  hint: model returned: $(echo "$content" | head -c 200)"
        return 1
    }
    echo "OK: ${tag} captcha_ocr"
}

_llamacpp_test_pdf_ocr() {
    local model="$1" tag="$2"
    local fixture="$WORKDIR/tests/.fixtures/doc.pdf"
    [ -f "$fixture" ] || { echo "  SKIP: missing $fixture"; return 0; }
    if ! command -v pdftoppm >/dev/null 2>&1; then
        echo "  SKIP: ${tag} pdftoppm not in PATH (need poppler-utils in the runner)"
        return 0
    fi
    local tmp; tmp=$(mktemp -d)
    local png; png=$(_llamacpp_pdf_page1_png "$fixture" "$tmp")
    [ -f "$png" ] || { echo "  FAIL: ${tag} pdftoppm produced no PNG"; rm -rf "$tmp"; return 1; }
    local url; url=$(_llamacpp_data_url "png" "$png")
    local raw code content
    raw=$(_llamacpp_ocr_call "$model" "$url" 600 "page")
    code=$(echo "$raw" | sed -n 's/^HTTP_CODE://p' | tail -1)
    rm -rf "$tmp"
    if [ "$code" != "200" ]; then
        echo "  FAIL: ${tag} pdf OCR HTTP $code"
        echo "  body: $(echo "$raw" | sed '/^HTTP_CODE:/d' | head -c 400)"
        return 1
    fi
    content=$(_llamacpp_extract_content "$raw")
    # The fixture line: "The quick brown fox jumps over the lazy dog."
    # Case-fold the comparison; Surya emits HTML with mixed-case prose.
    local lower_content
    lower_content=$(echo "$content" | tr '[:upper:]' '[:lower:]')
    assert_contains "$lower_content" "quick brown fox" "${tag} pdf contains 'quick brown fox'" || {
        echo "  hint: model returned: $(echo "$content" | head -c 200)"
        return 1
    }
    echo "OK: ${tag} pdf_ocr"
}

# ── CPU variant ────────────────────────────────────────────────────────────

test_llamacpp_cpu_models_list() {
    _llamacpp_cpu_enabled || { echo "  SKIP: LLAMACPP not enabled"; return 0; }
    _llamacpp_test_models_list "local-llamacpp-surya-ocr-2" "llamacpp-cpu"
}

test_llamacpp_cpu_captcha_ocr() {
    _llamacpp_cpu_enabled || { echo "  SKIP: LLAMACPP not enabled"; return 0; }
    _llamacpp_test_captcha_ocr "local-llamacpp-surya-ocr-2" "llamacpp-cpu"
}

test_llamacpp_cpu_pdf_ocr() {
    _llamacpp_cpu_enabled || { echo "  SKIP: LLAMACPP not enabled"; return 0; }
    _llamacpp_test_pdf_ocr "local-llamacpp-surya-ocr-2" "llamacpp-cpu"
}

# ── CUDA variant ───────────────────────────────────────────────────────────

test_llamacpp_cuda_models_list() {
    _llamacpp_cuda_enabled || { echo "  SKIP: LLAMACPP_CUDA not enabled"; return 0; }
    _llamacpp_test_models_list "local-llamacpp-cuda-surya-ocr-2" "llamacpp-cuda"
}

test_llamacpp_cuda_captcha_ocr() {
    _llamacpp_cuda_enabled || { echo "  SKIP: LLAMACPP_CUDA not enabled"; return 0; }
    _llamacpp_test_captcha_ocr "local-llamacpp-cuda-surya-ocr-2" "llamacpp-cuda"
}

test_llamacpp_cuda_pdf_ocr() {
    _llamacpp_cuda_enabled || { echo "  SKIP: LLAMACPP_CUDA not enabled"; return 0; }
    _llamacpp_test_pdf_ocr "local-llamacpp-cuda-surya-ocr-2" "llamacpp-cuda"
}

# ── image_url fetch via hybrids3 presigned URL ─────────────────────────────
#
# llama-server's mtmd vision pipeline only accepts data: URLs natively. The
# wrapper rewrites http(s):// URLs to data: URLs before forwarding, so the
# OpenAI wire spec stays honoured. These tests verify that path:
#
#   1. Upload captcha.png / doc.pdf-page-1 to hybrids3 (public uploads/
#      bucket via PUT + bearer auth).
#   2. POST to hybrids3's presign endpoint to get a URL string (the URL
#      shape is the same whether the bucket needs signing or not; for the
#      public uploads/ bucket the returned URL is unsigned but the test
#      still flows through the entire upload → presign → consume → cleanup
#      lifecycle so any regression in any step gets caught).
#   3. Rewrite the presigned URL's host from `localhost:4000` (the value
#      hybrids3 returns based on its external BASE_URL config) to
#      `nginx:4000` — the in-network alias that the llamacpp container can
#      actually reach via the aigate-internal network. This mirrors how
#      any other in-container caller would have to translate
#      operator-facing hostnames to in-network hostnames.
#   4. Send a chat completion with image_url=<rewritten URL>. The wrapper
#      fetches it, base64-encodes the body, rewrites the message in place,
#      and forwards to llama-server.
#   5. DELETE the uploaded blob so the bucket doesn't accumulate test debris.

_llamacpp_hybrids3_upload() {
    # $1 local file, $2 content-type, $3 desired key
    local file="$1" ct="$2" key="$3"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
        "$BASE_URL/storage/uploads/$key" \
        -H "Authorization: Bearer ${HYBRIDS3_UPLOADS_KEY}" \
        -H "Content-Type: $ct" \
        --data-binary "@$file")
    [ "$code" = "200" ] || {
        echo "  FAIL: hybrids3 upload $key HTTP $code"
        return 1
    }
}

_llamacpp_hybrids3_presign() {
    # $1 key. Echoes the URL after rewriting host so it's reachable from
    # inside the aigate-internal network.
    local key="$1"
    local raw url
    raw=$(curl -sf -X POST \
        "$BASE_URL/storage/presign/uploads/$key" \
        -H "Authorization: Bearer ${HYBRIDS3_UPLOADS_KEY}")
    url=$(echo "$raw" | python3 -c "import sys,json; print(json.load(sys.stdin).get('url',''))" 2>/dev/null)
    # hybrids3 echoes operator-facing URLs (localhost:4000). The llamacpp
    # container fetches over the docker network where `nginx` is the only
    # name that resolves. Substitute the host portion in place; query
    # string (if any) survives intact.
    echo "${url/http:\/\/localhost:4000/http:\/\/nginx:4000}"
}

_llamacpp_hybrids3_delete() {
    curl -s -o /dev/null -X DELETE \
        "$BASE_URL/storage/uploads/$1" \
        -H "Authorization: Bearer ${HYBRIDS3_UPLOADS_KEY}" \
        >/dev/null 2>&1
}

_llamacpp_test_url_captcha() {
    local model="$1" tag="$2"
    local fixture="$WORKDIR/tests/.fixtures/captcha.png"
    [ -f "$fixture" ] || { echo "  SKIP: missing $fixture"; return 0; }
    if [ -z "${HYBRIDS3_UPLOADS_KEY:-}" ]; then
        echo "  SKIP: HYBRIDS3_UPLOADS_KEY not set in .env"; return 0
    fi
    local key="llamacpp-test-captcha-$$-$(date +%s).png"
    _llamacpp_hybrids3_upload "$fixture" "image/png" "$key" || return 1
    local url; url=$(_llamacpp_hybrids3_presign "$key")
    [ -n "$url" ] || { _llamacpp_hybrids3_delete "$key"; echo "  FAIL: empty presigned URL"; return 1; }

    local raw code content
    raw=$(_llamacpp_ocr_call "$model" "$url" 600 "block")
    _llamacpp_hybrids3_delete "$key"
    code=$(echo "$raw" | sed -n 's/^HTTP_CODE://p' | tail -1)
    if [ "$code" != "200" ]; then
        echo "  FAIL: ${tag} url captcha OCR HTTP $code"
        echo "  body: $(echo "$raw" | sed '/^HTTP_CODE:/d' | head -c 400)"
        return 1
    fi
    content=$(_llamacpp_extract_content "$raw")
    assert_contains "$content" "AIGATE2026" "${tag} url-fetched captcha contains 'AIGATE2026'" || {
        echo "  hint: model returned: $(echo "$content" | head -c 200)"
        return 1
    }
    echo "OK: ${tag} url_captcha_ocr"
}

test_llamacpp_cpu_url_captcha() {
    _llamacpp_cpu_enabled || { echo "  SKIP: LLAMACPP not enabled"; return 0; }
    _llamacpp_test_url_captcha "local-llamacpp-surya-ocr-2" "llamacpp-cpu"
}

test_llamacpp_cuda_url_captcha() {
    _llamacpp_cuda_enabled || { echo "  SKIP: LLAMACPP_CUDA not enabled"; return 0; }
    _llamacpp_test_url_captcha "local-llamacpp-cuda-surya-ocr-2" "llamacpp-cuda"
}

ALL_TESTS+=(
    test_llamacpp_cpu_models_list
    test_llamacpp_cpu_captcha_ocr
    test_llamacpp_cpu_pdf_ocr
    test_llamacpp_cpu_url_captcha
    test_llamacpp_cuda_models_list
    test_llamacpp_cuda_captcha_ocr
    test_llamacpp_cuda_pdf_ocr
    test_llamacpp_cuda_url_captcha
)
