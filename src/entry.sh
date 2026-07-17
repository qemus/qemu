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
. define.sh     # Define images
. install.sh    # Download image
. disk.sh       # Initialize disks
. display.sh    # Initialize graphics
. audio.sh      # Initialize audio
. network.sh    # Initialize network
. boot.sh       # Configure boot
. proc.sh       # Initialize processor
. power.sh      # Configure shutdown
. memory.sh     # Check available memory
. balloon.sh    # Initialize ballooning
. config.sh     # Configure arguments
. finish.sh     # Finish initialization

trap - ERR

cmd=(qemu-system-x86_64)
version=$("${cmd[@]}" --version | awk 'NR==1 { print $4 }')
info "Booting image${BOOT_DESC} using QEMU v$version..." && echo

if ! enabled "$SHUTDOWN"; then
  exec "${cmd[@]}" ${ARGS:+ $ARGS}
fi

if ! interactive; then
  "${cmd[@]}" ${ARGS:+ $ARGS} &
else
  startConsole
  setsid -w "${cmd[@]}" ${ARGS:+ $ARGS} </dev/null &
fi

pid=$!
rc=0

wait "$pid" || rc=$?
[ -f "$QEMU_END" ] && exit "$rc"

sleep 1 & wait $!
finish "$rc"
