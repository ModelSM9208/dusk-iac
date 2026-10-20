#!/usr/bin/env bash
# Print a content snapshot of every /etc entry that differs from the ostree image.
# config-diff alone reports only *which* files changed, not *what* is in them;
# hashing the contents lets diff catch a leftover line inside a modified file.
#
#   tests/etc-snapshot.sh > /tmp/before
#   ...lifecycle step...
#   diff /tmp/before <(sudo tests/etc-snapshot.sh)
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
cd /etc

ostree admin config-diff | sort -k2 | while read -r status path; do
  if [[ -L $path ]]; then
    printf '%s link %s -> %s\n' "$status" "$path" "$(readlink -- "$path")"
  elif [[ -f $path ]]; then
    printf '%s %s %s\n' "$status" "$(sha256sum -- "$path" | cut -d' ' -f1)" "$path"
  elif [[ -d $path ]]; then
    printf '%s dir  %s\n' "$status" "$path"
  else
    printf '%s gone %s\n' "$status" "$path"
  fi
done
