#!/usr/bin/env bash
# Remove Dusk from a Bazzite host. Run as root. The reverse of install-bazzite.sh,
# and with --purge also of bootstrap-bazzite.sh.
#
#   teardown-bazzite.sh           Undeploy: service, units, every dusk container,
#                                 model mount, udev rule. Keeps the dusk user, its
#                                 API key and its image, so install-bazzite.sh
#                                 alone brings Dusk back.
#   teardown-bazzite.sh --purge   Also removes the dusk user and everything it owns
#                                 (home, image, API key), its linger flag and its
#                                 subuid/subgid ranges: back to before bootstrap.
#
# Idempotent: safe on a host where Dusk is partly or wholly absent. Run it twice;
# the second run must finish cleanly and change nothing.
#
# Deliberately left alone:
#   - the render line bootstrap copied into /etc/group (identical to the image's
#     entry in /usr/lib/group, so harmless; bootstrap skips the copy if present)
#   - bazzite's removal from the docker/libvirt groups (host hardening, not Dusk)
#   - the container-kfd SELinux module (belongs to the vLLM build)
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

case "${1:-}" in
  "")      PURGE=0 ;;
  --purge) PURGE=1 ;;
  *)       echo "usage: $0 [--purge]" >&2; exit 2 ;;
esac

# 1. Service and units. Stop the consumer before touching the mount it reads from.
#    Errors are ignored here only because the manager or unit may already be gone.
if id dusk &>/dev/null; then
  DUSK_UID=$(id -u dusk)
  systemctl --user -M dusk@ stop llama-dusk.service 2>/dev/null || true
  rm -rf -- "/etc/containers/systemd/users/${DUSK_UID:?}"
  systemctl --user -M dusk@ daemon-reload 2>/dev/null || true
  # dusk exists only to run this service, so none of its containers may outlive an
  # undeploy. A stopped container keeps its device, mount and port config, ready to
  # start (a leftover smoke test had no API key). The image and API key are kept.
  if systemctl is-active --quiet "user@${DUSK_UID}.service"; then
    systemd-run --machine=dusk@ --user --pipe --quiet --wait \
      podman rm --all --force >/dev/null
  fi
fi
rmdir /etc/containers/systemd/users 2>/dev/null || true    # only if now empty

# 2. Model store. disable --now unmounts and removes every enable link to the unit.
systemctl disable --now var-mnt-duskmodels.mount 2>/dev/null || true
if mountpoint -q /var/mnt/duskmodels; then
  echo "/var/mnt/duskmodels is still mounted (busy?): stop what is using it and re-run" >&2
  exit 1
fi
rm -f /etc/systemd/system/var-mnt-duskmodels.mount
systemctl daemon-reload
rmdir /var/mnt/duskmodels 2>/dev/null || true             # only if empty

# 3. GPU contract. A change event re-runs the rules, which drops the symlink.
rm -f /etc/udev/rules.d/70-dusk-gpu.rules
udevadm control --reload
udevadm trigger --action=change --subsystem-match=drm --sysname-match='renderD*'
udevadm settle
if [[ -e /dev/dri/dusk-render ]]; then
  echo "warning: /dev/dri/dusk-render still present; it will not survive a reboot" >&2
fi

# 4. Identity (--purge only)
if (( PURGE )) && id dusk &>/dev/null; then
  DUSK_UID=$(id -u dusk)
  if systemctl is-active --quiet "user@${DUSK_UID}.service"; then
    # Let podman unwind its own storage (containers, image, secret) cleanly first
    systemd-run --machine=dusk@ --user --pipe --quiet --wait \
      podman system reset --force >/dev/null 2>&1 || true
  fi
  loginctl disable-linger dusk
  loginctl terminate-user dusk 2>/dev/null || true
  systemctl stop "user@${DUSK_UID}.service" 2>/dev/null || true
  userdel --remove dusk
  # Newer shadow-utils releases the ranges itself; make sure either way
  sed -i '/^dusk:/d' /etc/subuid /etc/subgid
fi

if (( PURGE )); then
  echo "teardown complete (purge); check with: tests/verify-absent.sh --purge"
else
  echo "teardown complete; check with: tests/verify-absent.sh"
fi
