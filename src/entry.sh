#!/usr/bin/env bash
set -Eeuo pipefail

APP="QEMU"
SUPPORT="https://github.com/qemus/qemu-docker"

cd /run

. reset.sh      # Initialize system
. install.sh    # Get bootdisk
. disk.sh       # Initialize disks
. display.sh    # Initialize graphics
. network.sh    # Initialize network
. boot.sh       # Configure boot
. proc.sh       # Initialize processor
. config.sh     # Configure arguments

trap - ERR

info "Booting image${BOOT_DESC}..."

exec qemu-system-x86_64 ${ARGS:+ $ARGS}
