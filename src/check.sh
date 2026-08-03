#!/usr/bin/env bash
set -Eeuo pipefail

: "${DHCP:="N"}"
: "${NETWORK:="Y"}"

cd /run
. utils.sh      # Load functions

[ -f "/run/shm/qemu.end" ] && echo "QEMU is shutting down..." && exit 1
# Treat the startup window as healthy so container health checks do not restart
# the service before QEMU has had time to publish its PID.
[ ! -s "/run/shm/qemu.pid" ] && echo "QEMU is not running yet..." && exit 0

if disabled "$NETWORK"; then
  echo "Networking is disabled."
  exit 0
fi

if enabled "$DHCP"; then
  echo "Guest networking uses DHCP; connectivity check skipped."
  exit 0
fi

file="/run/shm/qemu.url"

if [ ! -s "$file" ]; then

  echo "The container has not enabled networking yet..."
  exit 0

fi

url=$(<"$file")

if ! curl -m 20 -LfSs -o /dev/null "$url"; then
  echo "Failed to reach VM at $url" && exit 1
fi

echo "Healthcheck OK"
exit 0
