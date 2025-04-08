#!/usr/bin/env bash
set -Eeuo pipefail

: "${APP:="QEMU"}"
: "${PLATFORM:="x64"}"
: "${SUPPORT:="https://github.com/qemus/qemu"}"

cd /run

. utils.sh      # Load functions
. reset.sh      # Initialize system
. define.sh     # Define images
. install.sh    # Download image
. disk.sh       # Initialize disks
. display.sh    # Initialize graphics
. network.sh    # Initialize network
. boot.sh       # Configure boot
. proc.sh       # Initialize processor
. config.sh     # Configure arguments

trap - ERR

version=$(qemu-system-x86_64 --version | head -n 1 | cut -d '(' -f 1 | awk '{ print $NF }')
info "Booting image${BOOT_DESC} using QEMU v$version..."

exec qemu-system-x86_64 ${ARGS:+ $ARGS}
