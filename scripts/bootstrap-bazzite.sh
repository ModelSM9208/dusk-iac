#!/usr/bin/env bash
# One-time host prep for Dusk on Bazzite. Idempotent: re-running changes nothing.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

# Preconditions the design depends on
[[ $(getenforce) == Enforcing ]] || { echo "SELinux is not enforcing" >&2; exit 1; }
[[ $(podman info --format '{{.Host.OCIRuntime.Name}}') == crun ]] \
  || { echo "OCI runtime is not crun; keep-groups would silently do nothing" >&2; exit 1; }

# Service identity: no login shell; useradd allocates the subuid/subgid range
id dusk &>/dev/null || useradd --create-home --shell /usr/sbin/nologin dusk
if ! grep -q '^dusk:' /etc/subuid || ! grep -q '^dusk:' /etc/subgid; then
  echo "dusk has no subuid/subgid range" >&2; exit 1
fi
DUSK_UID=$(id -u dusk)

# ostree keeps render in /usr/lib/group, which usermod can't edit: copy it into /etc first
grep -q '^render:' /etc/group || grep '^render:' /usr/lib/group >> /etc/group
regroup=0
if ! id -nG dusk | grep -qw render; then usermod -aG render dusk; regroup=1; fi

# Start dusk's user manager at boot, with no login
loginctl enable-linger dusk
# A running manager keeps the groups it started with
if (( regroup )); then systemctl restart "user@${DUSK_UID}.service"; fi
for _ in $(seq 30); do systemctl is-active --quiet "user@${DUSK_UID}.service" && break; sleep 1; done

# API key: generated once, lives only in dusk's secret store, never in the repo
asdusk() { systemd-run --machine=dusk@ --user --pipe --quiet --wait "$@"; }
if ! asdusk podman secret exists dusk-api-key; then
  openssl rand -hex 32 | tr -d '\n' | asdusk podman secret create dusk-api-key - >/dev/null
fi

echo "bootstrap ok: dusk uid=${DUSK_UID}, groups=$(id -nG dusk)"
