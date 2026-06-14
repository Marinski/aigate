#!/bin/bash
# Install the language set in PISTON_LANGUAGES_BAKED by talking to a
# locally-spawned piston API server. Used only during the docker build
# of the prebake image — at runtime piston is invoked via the upstream
# entrypoint and these languages are already on disk.
set -eu

echo "[pre-bake] starting piston API server in background"
node /piston_api/src &
PISTON_PID=$!

echo "[pre-bake] waiting for piston API"
for i in $(seq 1 30); do
    if python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:2000/api/v2/runtimes', timeout=3)" 2>/dev/null; then
        echo "[pre-bake] piston API up after $i probes"
        break
    fi
    sleep 2
done

for spec in $(echo "${PISTON_LANGUAGES_BAKED}" | tr ',' ' '); do
    lang=${spec%=*}
    ver=${spec#*=}
    if [ -z "$lang" ] || [ -z "$ver" ]; then
        echo "[pre-bake] bad spec '$spec' (expected language=version)" >&2
        continue
    fi
    echo "[pre-bake] installing ${lang} ${ver}"
    python3 <<PY
import json, urllib.request, sys
req = urllib.request.Request(
    'http://localhost:2000/api/v2/packages',
    data=json.dumps({'language': '${lang}', 'version': '${ver}'}).encode(),
    headers={'Content-Type': 'application/json'},
    method='POST',
)
try:
    print(urllib.request.urlopen(req, timeout=900).read().decode('utf-8', 'replace'))
except urllib.error.HTTPError as e:
    print('HTTP', e.code, e.read().decode('utf-8', 'replace'), file=sys.stderr)
    sys.exit(1)
PY
done

echo "[pre-bake] stopping piston API"
kill ${PISTON_PID} 2>/dev/null || true
wait ${PISTON_PID} 2>/dev/null || true

echo "[pre-bake] final /piston/packages contents:"
ls -la /piston/packages/ 2>&1 | head -50
