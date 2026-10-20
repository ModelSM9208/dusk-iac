#!/usr/bin/env bash
# Checks that teardown left nothing behind. Run as root. Exits 1 if anything remains.
#   verify-absent.sh           after teardown-bazzite.sh
#   verify-absent.sh --purge   after teardown-bazzite.sh --purge
# No pipefail on purpose (see verify.sh). ok/bad always succeed, so the
# "test && ok || bad" pattern below is safe.
# shellcheck disable=SC2015
set -u
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

case "${1:-}" in
  "")      PURGE=0 ;;
  --purge) PURGE=1 ;;
  *)       echo "usage: $0 [--purge]" >&2; exit 2 ;;
esac

fail=0
ok()  { echo "PASS  $*"; }
bad() { echo "FAIL  $*"; fail=1; }

# Service
ss -Hltn 'sport = :8080' | grep -q . \
  && bad "something still listens on :8080" || ok "nothing listening on :8080"
compgen -G '/etc/containers/systemd/users/*/llama-dusk.container' >/dev/null \
  && bad "Quadlet unit still installed" || ok "Quadlet unit removed"

# Model store
mountpoint -q /var/mnt/duskmodels \
  && bad "model store still mounted" || ok "model store unmounted"
[[ -e /etc/systemd/system/var-mnt-duskmodels.mount ]] \
  && bad "mount unit still installed" || ok "mount unit removed"
find /etc/systemd/system -name var-mnt-duskmodels.mount -type l | grep -q . \
  && bad "enable links remain" || ok "no enable links"

# GPU contract
[[ -e /etc/udev/rules.d/70-dusk-gpu.rules ]] \
  && bad "udev rule still installed" || ok "udev rule removed"
[[ -e /dev/dri/dusk-render ]] \
  && bad "/dev/dri/dusk-render still present" || ok "dusk-render symlink gone"

# Identity
if (( PURGE )); then
  id dusk &>/dev/null && bad "user dusk still exists" || ok "user dusk removed"
  [[ -e /var/lib/systemd/linger/dusk ]] && bad "linger still enabled" || ok "linger disabled"
  grep -qs '^dusk:' /etc/subuid /etc/subgid \
    && bad "subuid/subgid ranges remain" || ok "subuid/subgid ranges released"
  [[ -e /var/home/dusk ]] && bad "home directory remains" || ok "home directory removed"
elif id dusk &>/dev/null; then
  ok "user dusk kept"
  n=$(systemd-run --machine=dusk@ --user --pipe --quiet --wait podman ps -aq 2>/dev/null | wc -l)
  (( n == 0 )) && ok "no containers left for dusk" || bad "$n container(s) left for dusk"
else
  bad "user dusk missing after a plain teardown"
fi

exit "$fail"
