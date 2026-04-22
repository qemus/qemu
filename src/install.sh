#!/usr/bin/env bash
set -Eeuo pipefail

# Fast-path: if ubuntu.boot exists the disk is already installed — skip all ISO logic.
if [ -f "$STORAGE/ubuntu.boot" ]; then
  BOOT=""
  return 0
fi

# 0. Golden disk fast-path: if a pre-installed qcow2 is baked into the image,
#    create a per-container qcow2 overlay on top of it and skip the full install.
GOLDEN_DISK="/golden/ubuntu.qcow2"
GOLDEN_MIN_BYTES=1048576  # 1 MB minimum — placeholder files are ignored
if [ -f "$GOLDEN_DISK" ] && [ "$(stat -c%s "$GOLDEN_DISK" 2>/dev/null || echo 0)" -gt "$GOLDEN_MIN_BYTES" ] && [ ! -f "$STORAGE/ubuntu.base" ]; then
  info "Golden disk found — creating qcow2 overlay for this container..."
  OVERLAY="$STORAGE/data.qcow2"
  qemu-img create -f qcow2 -b "$GOLDEN_DISK" -F qcow2 "$OVERLAY"
  setOwner "$OVERLAY" || true
  # Write a sentinel so the disk.sh knows to use qcow2 format
  echo "data.qcow2" > "$STORAGE/ubuntu.base"
  setOwner "$STORAGE/ubuntu.base" || true
  touch "$STORAGE/ubuntu.boot"
  setOwner "$STORAGE/ubuntu.boot" || true
  BOOT=""
  return 0
fi

# 1. Find ISO in root directory
BOOT=$(find / -maxdepth 1 -type f -iname "*.iso" -print -quit 2>/dev/null || true)

# 2. If no ISO found, check ubuntu.base for saved remastered ISO
if [ -z "$BOOT" ]; then
  BASE_FILE="$STORAGE/ubuntu.base"
  if [ -f "$BASE_FILE" ]; then
    ISO_NAME=$(cat "$BASE_FILE")
    STORAGE_ISO="$STORAGE/$ISO_NAME"
    if [ -f "$STORAGE_ISO" ]; then
      BOOT="$STORAGE_ISO"
      return 0
    fi
    error "ISO file '$ISO_NAME' from ubuntu.base not found in storage"
    exit 44
  fi
  # 3. Fall back to any ISO already in storage (e.g. ubuntu-source.iso)
  STORAGE_ISO=$(find "$STORAGE" -maxdepth 1 -type f -iname "*.iso" -print -quit 2>/dev/null || true)
  if [ -n "$STORAGE_ISO" ]; then
    info "Found ISO in storage: $STORAGE_ISO"
    BOOT="$STORAGE_ISO"
  else
    error "No ISO file found. Mount Ubuntu ISO to container root or place in storage."
    exit 64
  fi
fi

# 3. Remaster ISO — write directly to storage to avoid /tmp space issues
ISO_SIZE="$(stat -c%s "$BOOT")"
ISO_NAME="ubuntu.${ISO_SIZE}.iso"
STORAGE_ISO="$STORAGE/$ISO_NAME"

OEM_ARGS=()
[ -d "/oem" ] && OEM_ARGS=("--oem-dir" "/oem")

info "Remastering Ubuntu ISO for automated installation..."
/opt/isoenv/bin/python /run/remaster_iso.py \
  --src "$BOOT" \
  --dst "$STORAGE_ISO" \
  --config-dir /run/assets \
  "${OEM_ARGS[@]}"

if [ ! -f "$STORAGE_ISO" ]; then
  error "Remastered ISO not created"
  exit 42
fi

setOwner "$STORAGE_ISO" || true

echo "$ISO_NAME" > "$STORAGE/ubuntu.base"
setOwner "$STORAGE/ubuntu.base" || true

touch "$STORAGE/ubuntu.boot"
setOwner "$STORAGE/ubuntu.boot" || true

BOOT="$STORAGE_ISO"
return 0
