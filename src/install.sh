#!/usr/bin/env bash
set -Eeuo pipefail

detectMode () {

  local dir=""
  local file="$1"

  [ ! -f "$file" ] && return 1
  [ ! -s "$file" ] && return 1

  if [ -z "${BOOT_MODE:-}" ]; then
    # Automaticly detect UEFI-compatible ISO's
    dir=$(isoinfo -f -i "$file")
    dir=$(echo "${dir^^}" | grep "^/EFI")
    [ -n "$dir" ] && BOOT_MODE="uefi"
  fi

  BOOT="$file"
  return 0
}

downloadFile() {

  local url="$1"
  local base="$2"
  local dest="$3"  
  local rc total progress

  rm -f "$dest"

  # Check if running with interactive TTY or redirected to docker log
  if [ -t 1 ]; then
    progress="--progress=bar:noscroll"
  else
    progress="--progress=dot:giga"
  fi

  local msg="Downloading $base"
  info "$msg..." && html "$msg..."

  /run/progress.sh "$dest" "0" "$msg ([P])..." &

  { wget "$url" -O "$dest" -q --timeout=30 --show-progress "$progress"; rc=$?; } || :

  fKill "progress.sh"

  if (( rc == 0 )) && [ -f "$dest" ]; then
    total=$(stat -c%s "$dest")
    if [ "$total" -lt 100000 ]; then
      error "Invalid image file: is only $total bytes?" && return 1
    fi
    html "Download finished successfully..." && return 0
  fi

  msg="Failed to download $url"
  (( rc == 3 )) && error "$msg , cannot write file (disk full?)" && return 1
  (( rc == 4 )) && error "$msg , network failure!" && return 1
  (( rc == 8 )) && error "$msg , server issued an error response!" && return 1

  error "$msg , reason: $rc"
  return 1
}

file=$(find / -maxdepth 1 -type f -iname boot.iso | head -n 1)
[ ! -s "$file" ] && file=$(find "$STORAGE" -maxdepth 1 -type f -iname boot.iso | head -n 1)
detectMode "$file" && return 0

if [ -z "$BOOT" ] || [[ "$BOOT" == *"example.com/image.iso" ]]; then
  hasDisk && return 0
  error "No boot disk specified, set BOOT= to the URL of an ISO file." && exit 64
fi

base=$(basename "$BOOT")
detectMode "$STORAGE/$base" && return 0

base=$(basename "${BOOT%%\?*}")
: "${base//+/ }"; printf -v base '%b' "${_//%/\\x}"
base=$(echo "$base" | sed -e 's/[^A-Za-z0-9._-]/_/g')
detectMode "$STORAGE/$base" && return 0

TMP="$STORAGE/${base%.*}.tmp"

if ! downloadFile "$BOOT" "$base" "$TMP"; then
  rm -f "$TMP"
  exit 60
fi

mv -f "$TMP" "$STORAGE/$base"
! detectMode "$STORAGE/$base" && exit 63

return 0
