#!/usr/bin/env bash
set -Eeuo pipefail

detect () {
  local dir=""
  local file="$1"
  [ ! -f "$file" ] && return 1
  [ ! -s "$file" ] && return 1

  dir=$(isoinfo -f -i "$file")

  # Automaticly detect UEFI-compatible ISO's
  if echo "${dir^^}" | grep -q "^/EFI"; then
    [ -z "${BOOT_MODE:-}" ] && BOOT_MODE="uefi"
  fi

  BOOT="$file"
  return 0
}

file=$(find / -maxdepth 1 -type f -iname boot.iso | head -n 1)
[ ! -s "$file" ] && file=$(find "$STORAGE" -maxdepth 1 -type f -iname boot.iso | head -n 1)
detect "$file" && return 0

if [ -z "$BOOT" ] || [[ "$BOOT" == *"example.com/image.iso" ]]; then
  hasDisk && return 0
  error "No boot disk specified, set BOOT= to the URL of an ISO file." && exit 64
fi

base=$(basename "$BOOT")
detect "$STORAGE/$base" && return 0

base=$(basename "${BOOT%%\?*}")
: "${base//+/ }"; printf -v base '%b' "${_//%/\\x}"
base=$(echo "$base" | sed -e 's/[^A-Za-z0-9._-]/_/g')
detect "$STORAGE/$base" && return 0

TMP="$STORAGE/${base%.*}.tmp"
rm -f "$TMP"

# Check if running with interactive TTY or redirected to docker log
if [ -t 1 ]; then
  progress="--progress=bar:noscroll"
else
  progress="--progress=dot:giga"
fi

msg="Downloading $base"
info "$msg..." && html "$msg..."

/run/progress.sh "$TMP" "" "$msg ([P])..." &
{ wget "$BOOT" -O "$TMP" -q --timeout=30 --show-progress "$progress"; rc=$?; } || :

fKill "progress.sh"

msg="Failed to download $BOOT"
(( rc == 3 )) && error "$msg , cannot write file (disk full?)" && exit 60
(( rc == 4 )) && error "$msg , network failure!" && exit 60
(( rc == 8 )) && error "$msg , server issued an error response!" && exit 60
(( rc != 0 )) && error "$msg , reason: $rc" && exit 60
[ ! -s "$TMP" ] && error "$msg" && exit 61

html "Download finished successfully..."

size=$(stat -c%s "$TMP")

if ((size<100000)); then
  error "Invalid ISO file: Size is smaller than 100 KB" && exit 62
fi

mv -f "$TMP" "$STORAGE/$base"
! detect "$STORAGE/$base" && exit 63

return 0
