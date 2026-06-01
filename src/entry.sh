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
. network.sh    # Initialize network
. boot.sh       # Configure boot
. proc.sh       # Initialize processor
. power.sh      # Configure shutdown
. memory.sh     # Check available memory
. balloon.sh    # Initialize ballooning
. config.sh     # Configure arguments
. finish.sh     # Finish initialization

trap - ERR

version=$(qemu-system-x86_64 --version | head -n 1 | cut -d '(' -f 1 | awk '{ print $NF }')
info "Booting image${BOOT_DESC} using QEMU v$version..."

[[ "$SHUTDOWN" != [Yy1]* ]] && exec qemu-system-x86_64 ${ARGS:+ $ARGS}

{ qemu-system-x86_64 ${ARGS:+ $ARGS} >"$QEMU_OUT" 2>"$QEMU_LOG"; rc=$?; } || :
(( rc != 0 )) && error "$(<"$QEMU_LOG")" && exit 15

terminal
tail -fn +0 "$QEMU_LOG" --pid=$$ 2>/dev/null &
socat STDIO,rawer,echo=0 FILE:"$QEMU_TERM",nonblock 2>/dev/null || :

sleep 1 & wait $!
[ ! -f "$QEMU_END" ] && finish 0
