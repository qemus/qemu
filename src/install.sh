#!/usr/bin/env bash
set -Eeuo pipefail

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
  error "No ISO file found. Mount Ubuntu ISO to container root."
  exit 64
fi

# 3. Remaster ISO
REMASTERED_ISO="/tmp/ubuntu-autoinstall.iso"
OEM_ARGS=()
[ -d "/oem" ] && OEM_ARGS=("--oem-dir" "/oem")

info "Remastering Ubuntu ISO for automated installation..."
/opt/isoenv/bin/python /run/remaster_iso.py \
  --src "$BOOT" \
  --dst "$REMASTERED_ISO" \
  --config-dir /run/assets \
  "${OEM_ARGS[@]}"

if [ ! -f "$REMASTERED_ISO" ]; then
  error "Remastered ISO not created"
  exit 42
fi


# 4. Save to storage
ISO_SIZE="$(stat -c%s "$BOOT")"
ISO_NAME="ubuntu.${ISO_SIZE}.iso"
STORAGE_ISO="$STORAGE/$ISO_NAME"

mv -f "$REMASTERED_ISO" "$STORAGE_ISO" || { error "Failed to save ISO"; exit 43; }
setOwner "$STORAGE_ISO" || true

echo "$ISO_NAME" > "$STORAGE/ubuntu.base"
setOwner "$STORAGE/ubuntu.base" || true

touch "$STORAGE/ubuntu.boot"
setOwner "$STORAGE/ubuntu.boot" || true

BOOT="$STORAGE_ISO"
return 0
