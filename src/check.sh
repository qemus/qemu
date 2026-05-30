#!/usr/bin/env bash
set -Eeuo pipefail

: "${NETWORK:="Y"}"

[ -f "/run/shm/qemu.end" ] && echo "QEMU is shutting down.." && exit 1
[ ! -s "/run/shm/qemu.pid" ] && echo "QEMU is not running yet.." && exit 0
[[ "$NETWORK" == [Nn]* ]] && echo "Networking is disabled.." && exit 0

file="/run/shm/qemu.url"
[ ! -s "$file" ] && echo "The container has not enabled networking yet..." && exit 1

url=$(<"$file")

if ! curl -m 20 -ILfSs "$url" > /dev/null; then
  echo "Failed to reach VM at $url" && exit 1
fi

echo "Healthcheck OK"
exit 0
