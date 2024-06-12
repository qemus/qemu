#!/usr/bin/env bash
set -Eeuo pipefail

detectType() {

  local dir=""
  local file="$1"

  [ ! -f "$file" ] && return 1
  [ ! -s "$file" ] && return 1

  case "${file,,}" in
    *".iso" )

      [ -n "${BOOT_MODE:-}" ] && break

      # Automaticly detect UEFI-compatible ISO's
      dir=$(isoinfo -f -i "$file")

      [ -z "$dir" ] && error "Failed to read ISO file, invalid format!" && return 1

      dir=$(echo "${dir^^}" | grep "^/EFI")
      [ -n "$dir" ] && BOOT_MODE="uefi"

      ;;
    *".img" | *".raw" | *".qcow2" | *".ova")

      ;;
    * )
      error "Unknown file format, extension \".${file/*./}\" is not recognized!" && return 1 ;;
  esac

  BOOT="$file"
  return 0
}

downloadFile() {

  local url="$1"
  local base="$2"
  local msg rc total progress

  local dest="$STORAGE/$base.tmp"
  rm -f "$dest"

  # Check if running with interactive TTY or redirected to docker log
  if [ -t 1 ]; then
    progress="--progress=bar:noscroll"
  else
    progress="--progress=dot:giga"
  fi

  msg="Downloading image"
  info "Downloading $base..."
  html "$msg..."

  /run/progress.sh "$dest" "0" "$msg ([P])..." &

  { wget "$url" -O "$dest" -q --timeout=30 --show-progress "$progress"; rc=$?; } || :

  fKill "progress.sh"

  if (( rc == 0 )) && [ -f "$dest" ]; then
    total=$(stat -c%s "$dest")
    if [ "$total" -lt 100000 ]; then
      error "Invalid image file: is only $total bytes?" && return 1
    fi
    html "Download finished successfully..."
    mv -f "$dest" "$STORAGE/$base"
    return 0
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
detectType "$file" && return 0

if [ -z "$BOOT" ] || [[ "$BOOT" == *"example.com/image.iso" ]]; then
  hasDisk && return 0
  error "No boot disk specified, set BOOT= to the URL of an image file." && exit 64
fi

base=$(basename "${BOOT%%\?*}")
: "${base//+/ }"; printf -v base '%b' "${_//%/\\x}"
base=$(echo "$base" | sed -e 's/[^A-Za-z0-9._-]/_/g')

case "${base,,}" in
  *".iso" )
    detectType "$STORAGE/$base" && return 0 ;;
  *".img" | *".raw" | *".qcow2" | *".ova" | "*.vdi" | "*.vmdk" )
    detectType "$STORAGE/$base" && return 0 ;;
  *".gz" | *".gzip" | *".xz" | *".7z" | *".zip" | *".rar" | *".lzma" | *".bz" | *".bz2" )
    detectType "$STORAGE/${base%.*}" && return 0 ;;
  * )
    error "Unknown file format, extension \".${base/*./}\" is not recognized!" && exit 33 ;;
esac

if ! downloadFile "$BOOT" "$base"; then
  rm -f "$STORAGE/$base.tmp"
  exit 60
fi

if [[ "${base,,}" == *".iso" ]]; then
 ! detectType "$STORAGE/$base" && exit 63
 return 0
fi

case "${base,,}" in
  *".gz" | *".gzip" | *".xz" | *".7z" | *".zip" | *".rar" | *".lzma" | *".bz" | *".bz2" )
    info "Extracting $base..."
    html "Extracting image..." ;;
esac

case "${base,,}" in
  *".gz" | *".gzip" )
    gzip -dc "$STORAGE/$base" > "$STORAGE/${base%.*}"
    base="${base%.*}"
    ;;
  *".xz" )
    xz -dc "$STORAGE/$base" > "$STORAGE/${base%.*}"
    base="${base%.*}"
    ;;
  *".7z" | *".zip" | *".rar" | *".lzma" | *".bz" | *".bz2" )

    tmp="$STORAGE/extract"
    rm -rf "$tmp"
    mkdir -p "$tmp"
    7z x "$STORAGE/$base" -o"$tmp" > /dev/null

    rm -f "$STORAGE/$base"
    base="${base%.*}"

    if [ ! -s "$tmp/$base" ]; then
      rm -rf "$tmp"
      error "Cannot find file \"${base}\" in .${BOOT/*./} archive!" && exit 32
    fi

    mv "$tmp/$base" "$STORAGE/$base"
    rm -rf "$tmp"

    ;;
esac

if [[ "${base,,}" == *".iso" ]]; then
 ! detectType "$STORAGE/$base" && exit 63
 return 0
fi

# QCOW2, VDI, VHD, VHDX, VMDK

case "${base,,}" in
  *".img" | *".raw" | *".ova" | *".vdi" | "*.vmdk" )
    mv -f "$dest" "$STORAGE/data.img"
    BOOT=""
    return 0 ;;
  *".qcow2" )
    BOOT_MODE="uefi"
    mv -f "$STORAGE/$base" "$STORAGE/data.qcow2"
    BOOT=""
    return 0 ;;
  * )
    error "Unknown file format, extension \".${base/*./}\" is not recognized!" && exit 33 ;;
esac

! detectType "$STORAGE/$base" && exit 63

return 0
