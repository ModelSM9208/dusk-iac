#!/usr/bin/env bash
# Prefill/decode benchmark against the running service. Run as root.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
cd "$(dirname "$0")/.."

KEY=$(systemd-run --machine=dusk@ --user --pipe --quiet --wait \
  podman secret inspect --showsecret --format '{{.SecretData}}' dusk-api-key)

# Fixed ~3.3k-token prompt from the repo itself; cache off so prefill is measured
REQ=$(python3 -c 'import json;print(json.dumps({"messages":[{"role":"user","content":"Summarize this document in five bullet points:\n\n"+open("docs/BUILD.md").read()[:12000]}],"max_tokens":400,"temperature":0.2,"cache_prompt":False}))')

OUT=$(curl -sf 127.0.0.1:8080/v1/chat/completions -H "Authorization: Bearer ${KEY}" \
  -H 'Content-Type: application/json' -d "$REQ") || { echo "FAIL: request failed (HTTP error or server down)" >&2; exit 1; }

python3 -c '
import json, sys
t = json.loads(sys.argv[1]).get("timings") or sys.exit("FAIL: no timings in response")
pps, pn = t["prompt_per_second"], t["prompt_n"]
dps, dn = t["predicted_per_second"], t["predicted_n"]
print(f"prefill {pps:7.1f} tok/s  ({pn} tokens)")
print(f"decode  {dps:7.1f} tok/s  ({dn} tokens)")
' "$OUT"
