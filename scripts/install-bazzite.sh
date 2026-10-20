#!/usr/bin/env bash
# Deploy dusk-iac onto a Bazzite host. Run as root, after bootstrap-bazzite.sh.
# Declarative: dusk's Quadlet directory is replaced with exactly what the repo holds.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
cd "$(dirname "$0")/.."

HOST=xtx                                   # the only per-host line in this script
DUSK_UID=$(id -u dusk)
DEST="/etc/containers/systemd/users/${DUSK_UID}"
asdusk() { systemd-run --machine=dusk@ --user --pipe --quiet --wait "$@"; }

# 1. GPU: this host's rule must produce the /dev/dri/dusk-render name base/ expects
install -m 0644 -o root -g root "hosts/${HOST}/70-dusk-gpu.rules" /etc/udev/rules.d/
udevadm control --reload
udevadm trigger --action=change --subsystem-match=drm --sysname-match='renderD*'
udevadm settle
[[ -e /dev/dri/dusk-render ]] \
  || { echo "/dev/dri/dusk-render missing: check the PCI address in the udev rule" >&2; exit 1; }

# 2. Model store. A live mount keeps its old options until it is re-mounted,
#    so stop the consumer, reset the enable links, and remount every deploy.
install -m 0644 -o root -g root "hosts/${HOST}/var-mnt-duskmodels.mount" /etc/systemd/system/
systemctl daemon-reload
systemctl --user -M dusk@ stop llama-dusk.service 2>/dev/null || true
systemctl reenable var-mnt-duskmodels.mount
systemctl restart var-mnt-duskmodels.mount

# 3. Image: the only network step. Pulled by digest, so the registry can't substitute bytes.
IMG=$(sed -n 's/^Image=//p' base/llama-dusk.container)
asdusk podman image exists "$IMG" || asdusk podman pull "$IMG"

# 4. Units: replace, don't merge, so files deleted from the repo vanish from the host
rm -rf -- "${DEST:?}"
install -d -m 0755 "$DEST/llama-dusk.container.d"
install -m 0644 -o root -g root base/llama-dusk.container "$DEST/"
install -m 0644 -o root -g root "hosts/${HOST}/llama-dusk.container.d/"*.conf "$DEST/llama-dusk.container.d/"
systemctl --user -M dusk@ daemon-reload
systemctl --user -M dusk@ restart llama-dusk.service

echo "deployed host=${HOST}; run tests/verify.sh in about a minute"
