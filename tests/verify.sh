#!/usr/bin/env bash
# Post-deploy checks for llama-dusk. Run as root. Exits 1 if any check fails.
# No pipefail on purpose: grep -q closes the pipe early, and pipefail would
# count the writer's SIGPIPE as a failed check. ok/bad always succeed, so the
# "test && ok || bad" pattern below is safe.
# shellcheck disable=SC2015
set -u
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
# Without set -e a failed cd would run every relative-path check from the wrong place
cd "$(dirname "$0")/.." || exit 1

HOST=xtx
URL=http://127.0.0.1:8080
fail=0
ok()  { echo "PASS  $*"; }
bad() { echo "FAIL  $*"; fail=1; }
asdusk() { systemd-run --machine=dusk@ --user --pipe --quiet --wait "$@"; }

# Model store
findmnt -no OPTIONS /var/mnt/duskmodels | tr ',' '\n' | grep -qx ro \
  && ok "model store is read-only" || bad "model store not mounted ro"
[[ $(stat -c %C /var/mnt/duskmodels) == *:container_file_t:* ]] \
  && ok "model store labelled container_file_t" || bad "model store has the wrong label"
if touch /var/mnt/duskmodels/.write-test 2>/dev/null; then
  rm -f /var/mnt/duskmodels/.write-test; bad "model store accepted a write"
else
  ok "write to model store rejected"
fi

# Service and its inputs
systemctl --user -M dusk@ is-active --quiet llama-dusk.service \
  && ok "service active" || bad "service not active"
asdusk podman inspect llama-dusk --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' \
  | grep -q '^/var/mnt/duskmodels/' && ok "model mounted from /var/mnt/duskmodels" \
  || bad "model not mounted from /var/mnt/duskmodels"

# Wait up to 3 minutes for the model to load
for _ in $(seq 36); do curl -sf "$URL/health" >/dev/null && break; sleep 5; done
curl -sf "$URL/health" >/dev/null && ok "health ok" || bad "not healthy after 3 min"

# Did the drop-in's sizing actually reach the server?
CTX=$(sed -n 's/^Environment=LLAMA_ARG_CTX_SIZE=//p' "hosts/${HOST}/llama-dusk.container.d/"*.conf)
asdusk podman logs llama-dusk 2>&1 | grep -q "n_ctx_slot = ${CTX}," \
  && ok "context size ${CTX} applied" || bad "context size ${CTX} not applied"

# Auth, tested on an inference endpoint (/health and /v1/models are open by design)
KEY=$(asdusk podman secret inspect --showsecret --format '{{.SecretData}}' dusk-api-key)
code() { curl -s -o /dev/null -w '%{http_code}' -H "$1" -H 'Content-Type: application/json' \
  "$URL/v1/chat/completions" -d '{"messages":[{"role":"user","content":"hi"}],"max_tokens":1}'; }
[[ $(code "X-Probe: no-key") == 401 ]]             && ok "no key -> 401"   || bad "no key was not rejected"
[[ $(code "Authorization: Bearer wrong") == 401 ]] && ok "bad key -> 401"  || bad "bad key was not rejected"
[[ $(code "Authorization: Bearer ${KEY}") == 200 ]] && ok "good key -> 200" || bad "good key was refused"

# Host precondition: no passwordless root via container/VM admin groups
for g in docker libvirt incus-admin; do
  m=$(getent group "$g" | cut -d: -f4)
  [[ -z $m ]] && ok "no members in $g" || bad "$g has members ($m): root without a password"
done

exit "$fail"
