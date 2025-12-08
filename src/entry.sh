#!/usr/bin/env bash
set -Eeuo pipefail

: "${APP:="QEMU"}"
: "${PLATFORM:="x64"}"
: "${SUPPORT:="https://github.com/qemus/qemu"}"

cd /run

. start.sh      # Startup hook
. utils.sh      # Load functions
. reset.sh      # Initialize system
. server.sh     # Start webserver
. install.sh    # Download image
. disk.sh       # Initialize disks
. display.sh    # Initialize graphics
. network.sh    # Initialize network
. boot.sh       # Configure boot
. proc.sh       # Initialize processor
. power.sh      # Configure shutdown
. memory.sh     # Check available memory
. config.sh     # Configure arguments
. finish.sh     # Finish initialization

trap - ERR

version=$(qemu-system-x86_64 --version | head -n 1 | cut -d '(' -f 1 | awk '{ print $NF }')
info "Booting ${APP}${BOOT_DESC} using QEMU v$version..."

{ qemu-system-x86_64 ${ARGS:+ $ARGS} >"$QEMU_OUT" 2>"$QEMU_LOG"; rc=$?; } || :
(( rc != 0 )) && error "$(<"$QEMU_LOG")" && exit 15

terminal
( sleep 30; boot ) &
tail -fn +0 "$QEMU_LOG" --pid=$$ 2>/dev/null &
cat "$QEMU_TERM" 2> /dev/null | tee "$QEMU_PTY" | \
sed -u -e 's/\x1B\[[=0-9;]*[a-z]//gi' \
-e 's/\x1B\x63//g' -e 's/\x1B\[[=?]7l//g' \
-e '/^$/d' -e 's/\x44\x53\x73//g' \
-e 's/failed to load Boot/skipped Boot/g' \
-e 's/0): Not Found/0)/g' & wait $! || :

sleep 1 & wait $!
[ ! -f "$QEMU_END" ] && finish 0
