#!/usr/bin/env bash
set -Eeuo pipefail

# Check if running with interactive TTY or redirected to docker log
if [ -t 1 ]; then
  progress="--progress=bar:noscroll"
else
  progress="--progress=dot:giga"
fi

file="/boot.iso" && [ -f "$file" ] && [ -s "$file" ] && BOOT="$file" && return 0
file="/boot.img" && [ -f "$file" ] && [ -s "$file" ] && BOOT="$file" && return 0

file=$(find "$STORAGE" -maxdepth 1 -type f -iname boot.iso -printf "%f\n" | head -n 1)
[ -z "$file" ] && file=$(find "$STORAGE" -maxdepth 1 -type f -iname boot.img -printf "%f\n" | head -n 1)
[ -n "$file" ] && file="$STORAGE/$file" 
[ -f "$file" ] && [ -s "$file" ] && BOOT="$file" && return 0

if [ -z "$BOOT" ]; then
  error "No boot disk specified, set BOOT= to the URL of an ISO file." && exit 64
fi

base=$(basename "$BOOT")
[ -n "$base" ] && file="$STORAGE/$base" 
[ -f "$file" ] && [ -s "$file" ] && BOOT="$file" && return 0

base=$(basename "${BOOT%%\?*}")
: "${base//+/ }"; printf -v base '%b' "${_//%/\\x}"
base=$(echo "$base" | sed -e 's/[^A-Za-z0-9._-]/_/g')
[ -n "$base" ] && file="$STORAGE/$base" 
[ -f "$file" ] && [ -s "$file" ] && BOOT="$file" && return 0

TMP="$STORAGE/${base%.*}.tmp"
rm -f "$TMP"

msg="Downloading $base..."
info "$msg" && html "$msg"

/run/progress.sh "$TMP" "" "Downloading $base ([P])..." &
{ wget "$BOOT" -O "$TMP" -q --timeout=10 --show-progress "$progress"; rc=$?; } || :

fKill "progress.sh"

(( rc != 0 )) && error "Failed to download $BOOT , reason: $rc" && exit 60
[ ! -s "$TMP" ] && error "Failed to download $BOOT" && exit 61

html "Download finished successfully..."

size=$(stat -c%s "$TMP")

if ((size<100000)); then
  error "Invalid ISO file: Size is smaller than 100 KB" && exit 62
fi

mv -f "$TMP" "$file"

return 0
