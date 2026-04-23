#!/usr/bin/env bash
#
# verify.sh — reproduce & verify the "VM loses network when container has
# multiple Docker networks" behaviour of qemus/qemu.
#
# Usage: ./verify.sh <case-dir>
#   where <case-dir> is one of: 01-single-network, 02-external-network,
#                               03-two-networks
#
# The script brings up the compose file under <case-dir>, waits for the
# container's network setup to finish and for the VM to DHCP, then collects
# host-side signals via `docker exec` / `docker logs` and prints a PASS/FAIL
# summary.
#
# Requires: docker, docker compose, a host with KVM + /dev/net/tun.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
CONTAINER="qemu-multinet-repro"

die() { echo "ERROR: $*" >&2; exit 2; }
note() { echo "--- $* ---"; }
pass() { echo "PASS: $*"; PASSES=$((PASSES + 1)); }
fail() { echo "FAIL: $*"; FAILURES=$((FAILURES + 1)); }

PASSES=0
FAILURES=0

[ $# -eq 1 ] || die "expected exactly one arg (case directory)"
CASE_DIR="$SCRIPT_DIR/$1"
[ -f "$CASE_DIR/compose.yml" ] || die "$CASE_DIR/compose.yml not found"

# shellcheck disable=SC2329  # invoked via trap
CREATED_EXTERNAL_NETA=0

# shellcheck disable=SC2329  # invoked via trap
cleanup() {
    local rc=$?
    note "cleanup"
    docker compose -f "$CASE_DIR/compose.yml" down --remove-orphans --timeout 5 \
        > /dev/null 2>&1 || true
    if [ "$CREATED_EXTERNAL_NETA" = 1 ]; then
        docker network rm netA > /dev/null 2>&1 || true
    fi
    exit "$rc"
}
trap cleanup EXIT

if [ "$1" = "02-external-network" ]; then
    if ! docker network inspect netA > /dev/null 2>&1; then
        note "creating external network netA (172.28.0.0/24)"
        docker network create --subnet 172.28.0.0/24 netA > /dev/null
        CREATED_EXTERNAL_NETA=1
    fi
fi

note "docker compose up -d ($1)"
docker compose -f "$CASE_DIR/compose.yml" down --remove-orphans --timeout 5 \
    > /dev/null 2>&1 || true
docker compose -f "$CASE_DIR/compose.yml" up -d > /dev/null

note "waiting for container networking to initialise"
for _ in $(seq 1 60); do
    if docker exec "$CONTAINER" pgrep -x dnsmasq > /dev/null 2>&1; then
        break
    fi
    sleep 1
done
docker exec "$CONTAINER" pgrep -x dnsmasq > /dev/null 2>&1 \
    || { docker logs --tail 80 "$CONTAINER" || true; die "dnsmasq never started inside the container"; }

note "container interfaces"
docker exec "$CONTAINER" ip -br addr || true

note "container routes"
docker exec "$CONTAINER" ip route || true

note "container NAT rules"
docker exec "$CONTAINER" iptables -t nat -S POSTROUTING || true
echo
docker exec "$CONTAINER" iptables -t nat -S PREROUTING || true

note "getInfo() debug line from container logs"
# strip ANSI escapes; accept any (or zero) chars before "Host:"
DEBUG_LINE=$(docker logs "$CONTAINER" 2>&1 \
    | sed -r 's/\x1b\[[0-9;]*[A-Za-z]//g' \
    | grep -E 'Host:.*Interface:' | tail -n 1 || true)
echo "$DEBUG_LINE"

DETECTED_IF=$(echo "$DEBUG_LINE" | sed -n 's/.*Interface: \([^ ]*\).*/\1/p')

DEFAULT_IF=$(docker exec "$CONTAINER" ip -o -4 route show default \
    | awk '{print $5; exit}')

BRIDGE_IFS=$(docker exec "$CONTAINER" ip -o -4 addr show scope global \
    | awk '{print $2}' | sort -u | grep -Ev '^(lo|docker|qemu)$' || true)

note "checks"

if [ -n "$DETECTED_IF" ]; then
    pass "getInfo() picked an interface ($DETECTED_IF)"
else
    fail "getInfo() did not emit a recognisable Interface: line"
fi

if [ -n "$DETECTED_IF" ] && [ -n "$DEFAULT_IF" ] && [ "$DETECTED_IF" = "$DEFAULT_IF" ]; then
    pass "detected interface ($DETECTED_IF) holds the default route"
else
    fail "detected interface is '$DETECTED_IF' but default route is on '$DEFAULT_IF'"
fi

if docker exec "$CONTAINER" iptables -t nat -S POSTROUTING \
    | grep -qE -- "-A POSTROUTING -o $DETECTED_IF -j MASQUERADE"; then
    pass "MASQUERADE rule present on detected interface ($DETECTED_IF)"
else
    fail "MASQUERADE rule missing on detected interface ($DETECTED_IF)"
fi

MISSING_MASQ=()
while read -r iface; do
    [ -n "$iface" ] || continue
    if ! docker exec "$CONTAINER" iptables -t nat -S POSTROUTING \
        | grep -qE -- "-A POSTROUTING -o $iface -j MASQUERADE"; then
        MISSING_MASQ+=("$iface")
    fi
done <<< "$BRIDGE_IFS"

if [ ${#MISSING_MASQ[@]} -eq 0 ]; then
    pass "every external container interface has a MASQUERADE rule"
else
    fail "no MASQUERADE rule on: ${MISSING_MASQ[*]} (VM traffic routed via these will leak un-NATed)"
fi

note "summary for case $1"
echo "passes:   $PASSES"
echo "failures: $FAILURES"

if [ "$FAILURES" -gt 0 ]; then
    exit 1
fi
exit 0
