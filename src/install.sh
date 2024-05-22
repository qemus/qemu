#!/usr/bin/env bash
set -Eeuo pipefail

file=$(find / -maxdepth 1 -type f -iname boot.iso | head -n 1)
[ ! -s "$file" ] && file=$(find "$STORAGE" -maxdepth 1 -type f -iname boot.iso | head -n 1)

if [ -f "$file" ] && [ -s "$file" ]; then
  BOOT="$file"
  return 0
fi

if [ -z "$BOOT" ]; then
  hasDisk && return 0
  error "No boot disk specified, set BOOT= to the URL of an ISO file." && exit 64
fi

base=$(basename "$BOOT")
file="$STORAGE/$base" 

if [ -f "$file" ] && [ -s "$file" ]; then
  BOOT="$file"
  return 0
fi

base=$(basename "${BOOT%%\?*}")
: "${base//+/ }"; printf -v base '%b' "${_//%/\\x}"
base=$(echo "$base" | sed -e 's/[^A-Za-z0-9._-]/_/g')
file="$STORAGE/$base" 

if [ -f "$file" ] && [ -s "$file" ]; then
  BOOT="$file"
  return 0
fi

TMP="$STORAGE/${base%.*}.tmp"
rm -f "$TMP"

# Check if running with interactive TTY or redirected to docker log
if [ -t 1 ]; then
  progress="--progress=bar:noscroll"
else
  progress="--progress=dot:giga"
fi

msg="Downloading $base..."
info "$msg" && html "$msg"

/run/progress.sh "$TMP" "" "Downloading $base ([P])..." &
{ wget "$BOOT" -O "$TMP" -q --timeout=30 --show-progress "$progress"; rc=$?; } || :

fKill "progress.sh"

(( rc == 4 )) && error "Failed to download $BOOT , network failure!" && exit 60
(( rc != 0 )) && error "Failed to download $BOOT , reason: $rc" && exit 60
[ ! -s "$TMP" ] && error "Failed to download $BOOT" && exit 61

html "Download finished successfully..."

size=$(stat -c%s "$TMP")

if ((size<100000)); then
  error "Invalid ISO file: Size is smaller than 100 KB" && exit 62
fi

mv -f "$TMP" "$file"

return 0
