#!/usr/bin/env bash
set -Eeuo pipefail

echo "DEBUG: install.sh is running, BOOT=$BOOT"

# Check if golden image already exists (ubuntu.boot marker)
if [ -f "$STORAGE/ubuntu.boot" ] && hasDisk; then
  echo "DEBUG: Golden image ready, skipping installation"
  BOOT="none"
  return 0
fi

# Check if we have a custom ISO to remaster
if [ -f "$BOOT" ]; then
  echo "DEBUG: Found $BOOT, checking for existing remastered ISO..."

  # Get ISO size for naming
  ISO_SIZE="$(stat -c%s "$BOOT")"
  STORAGE_ISO="$STORAGE/ubuntu.${ISO_SIZE}.iso"

  # Check if already remastered and saved
  if [ -f "$STORAGE_ISO" ]; then
    echo "DEBUG: Using existing remastered ISO at $STORAGE_ISO"
    BOOT="$STORAGE_ISO"
    return 0
  fi

  REMASTERED_ISO="/tmp/ubuntu-autoinstall.iso"

  info "Remastering Ubuntu ISO for automated installation..."
  /opt/isoenv/bin/python /run/remaster_iso.py \
    --src "$BOOT" \
    --dst "$REMASTERED_ISO" \
    --config-dir /run/assets

  if [ ! -f "$REMASTERED_ISO" ]; then
    error "Remastered ISO not created at $REMASTERED_ISO"
    exit 42
  fi

  # Move remastered ISO to storage
  info "Saving remastered ISO to storage..."
  if ! mv -f "$REMASTERED_ISO" "$STORAGE_ISO"; then
    error "Failed to move ISO to storage"
    exit 43
  fi
  ! setOwner "$STORAGE_ISO" && error "Failed to set owner for $STORAGE_ISO"

  # Create ubuntu.base file with ISO filename
  BASE_FILE="$STORAGE/ubuntu.base"
  echo "ubuntu.${ISO_SIZE}.iso" > "$BASE_FILE"
  ! setOwner "$BASE_FILE" && error "Failed to set owner for $BASE_FILE"

  touch "$STORAGE/ubuntu.boot"
  ! setOwner "$STORAGE/ubuntu.boot" && error "Failed to set owner for ubuntu.boot"

  info "Remastered ISO saved to $STORAGE_ISO"
  BOOT="$STORAGE_ISO"
  return 0
fi


getBase() {

  local base="${1%%\?*}"
  base=$(basename "$base")
  printf -v base '%b' "${base//%/\\x}"
  base="${base//[!A-Za-z0-9._-]/_}"

  echo "$base"
  return 0
}

getFolder() {

  local base=""
  local result="$1"

  if [[ "$result" != *"."* ]]; then

    result="${result,,}"

  else

    base=$(getBase "$result")
    result="${base%.*}"

    case "${base,,}" in

      *".gz" | *".gzip" | *".xz" | *".7z" | *".zip" | *".rar" | *".lzma" | *".bz" | *".bz2" )

        [[ "$result" == *"."* ]] && result="${result%.*}" ;;

    esac

  fi

  [ -z "$result" ] && result="unknown"
  echo "$result"

  return 0
}

moveFile() {

  local file="$1"
  local ext="${file##*.}"
  local dest="$STORAGE/boot.$ext"

  if [[ "$file" == "$dest" ]]; then
    BOOT="$file"
    return 0
  fi

  if [[ "${file,,}" == "/boot.${ext,,}" || "${file,,}" == "/custom.${ext,,}" ]]; then
    BOOT="$file"
    return 0
  fi

  if ! mv -f "$file" "$dest"; then
    error "Failed to move $file to $dest !"
    return 1
  fi

  BOOT="$dest"
  return 0
}

detectType() {

  local file="$1"
  local result=""
  local hybrid=""

  [ ! -f "$file" ] && return 1
  [ ! -s "$file" ] && return 1

  case "${file,,}" in
    *".iso" | *".img" | *".raw" | *".qcow2" ) ;;
    * ) return 1 ;;
  esac

  if [ -n "$BOOT_MODE" ] || [[ "${file,,}" == *".qcow2" ]]; then
    moveFile "$file" && return 0
    return 1
  fi

  if [[ "${file,,}" == *".iso" ]]; then

    hybrid=$(head -c 512 "$file" | tail -c 2 | xxd -p)

    if [[ "$hybrid" != "0000" ]]; then

      result=$(isoinfo -f -i "$file" 2>/dev/null)

      if [ -z "$result" ]; then
        error "Failed to read ISO file, invalid format!"
        return 1
      fi

      result=$(echo "${result^^}" | grep "^/EFI")
      [ -z "$result" ] && BOOT_MODE="legacy"

      moveFile "$file" && return 0
      return 1

    fi
  fi

  result=$(fdisk -l "$file" 2>/dev/null)
  [[ "${result^^}" != *"EFI "* ]] && BOOT_MODE="legacy"

  moveFile "$file" && return 0
  return 1
}

convertImage() {

  local source_file=$1
  local source_fmt=$2
  local dst_file=$3
  local dst_fmt=$4
  local dir base fs fa space space_gb
  local cur_size cur_gb src_size disk_param

  [ -f "$dst_file" ] && error "Conversion failed, destination file $dst_file already exists?" && return 1
  [ ! -f "$source_file" ] && error "Conversion failed, source file $source_file does not exists?" && return 1

  if [[ "${source_fmt,,}" == "${dst_fmt,,}" ]]; then
    mv -f "$source_file" "$dst_file"
    return 0
  fi

  local tmp_file="$dst_file.tmp"
  dir=$(dirname "$tmp_file")

  rm -f "$tmp_file"

  if [ -n "$ALLOCATE" ] && [[ "$ALLOCATE" != [Nn]* ]]; then

    # Check free diskspace
    src_size=$(qemu-img info "$source_file" -f "$source_fmt" | grep '^virtual size: ' | sed 's/.*(\(.*\) bytes)/\1/')
    space=$(df --output=avail -B 1 "$dir" | tail -n 1)

    if (( src_size > space )); then
      space_gb=$(formatBytes "$space")
      error "Not enough free space to convert image in $dir, it has only $space_gb available..." && return 1
    fi
  fi

  base=$(basename "$source_file")
  info "Converting $base..."
  html "Converting image..."

  local conv_flags="-p"

  if [ -z "$ALLOCATE" ] || [[ "$ALLOCATE" == [Nn]* ]]; then
    disk_param="preallocation=off"
  else
    disk_param="preallocation=falloc"
  fi

  fs=$(stat -f -c %T "$dir")
  [[ "${fs,,}" == "btrfs" ]] && disk_param+=",nocow=on"

  if [[ "$dst_fmt" != "raw" ]]; then
    if [ -z "$ALLOCATE" ] || [[ "$ALLOCATE" == [Nn]* ]]; then
      conv_flags+=" -c"
    fi
    [ -n "${DISK_FLAGS:-}" ] && disk_param+=",$DISK_FLAGS"
  fi

  # shellcheck disable=SC2086
  if ! qemu-img convert -f "$source_fmt" $conv_flags -o "$disk_param" -O "$dst_fmt" -- "$source_file" "$tmp_file"; then
    rm -f "$tmp_file"
    error "Failed to convert image in $dir, is there enough space available?" && return 1
  fi

  if [[ "$dst_fmt" == "raw" ]]; then
    if [ -n "$ALLOCATE" ] && [[ "$ALLOCATE" != [Nn]* ]]; then
      # Work around qemu-img bug
      cur_size=$(stat -c%s "$tmp_file")
      cur_gb=$(formatBytes "$cur_size")
      if ! fallocate -l "$cur_size" "$tmp_file" &>/dev/null; then
        if ! fallocate -l -x "$cur_size" "$tmp_file"; then
          error "Failed to allocate $cur_gb for image!"
        fi
      fi
    fi
  fi

  rm -f "$source_file"
  mv "$tmp_file" "$dst_file"

  if [[ "${fs,,}" == "btrfs" ]]; then
    fa=$(lsattr "$dst_file")
    if [[ "$fa" != *"C"* ]]; then
      error "Failed to disable COW for image on ${fs^^} filesystem!"
    fi
  fi

  html "Conversion completed..."
  return 0
}

findFile() {

  local dir file
  local base="$1"
  local ext="$2"
  local fname="${base}.${ext}"

  dir=$(find / -maxdepth 1 -type d -iname "$fname" -print -quit)
  [ ! -d "$dir" ] && dir=$(find "$STORAGE" -maxdepth 1 -type d -iname "$fname" -print -quit)

  if [ -d "$dir" ]; then
    if hasDisk; then
      BOOT="none"
      return 0
    fi
    error "The bind $dir maps to a file that does not exist!" && exit 37
  fi

  file=$(find / -maxdepth 1 -type f -iname "$fname" -print -quit)
  [ ! -s "$file" ] && file=$(find "$STORAGE" -maxdepth 1 -type f -iname "$fname" -print -quit)

  detectType "$file" && return 0

  return 1
}

findFile "boot" "img" && return 0
findFile "boot" "raw" && return 0
findFile "boot" "iso" && return 0
findFile "boot" "qcow2" && return 0

# Skip custom.iso check if we already remastered it
if [ -z "${REMASTERED:-}" ]; then
  findFile "custom" "iso" && return 0
fi

if hasDisk; then
  BOOT="none"
  return 0
fi

BOOT=$(expr "$BOOT" : "^\ *\(.*[^ ]\)\ *$")

if [ -z "$BOOT" ]; then
  error "No BOOT value specified! Provide Ubuntu ISO via volume mount."
  exit 64
fi

folder=$(getFolder "$BOOT")
STORAGE="$STORAGE/$folder"

if [ -d "$STORAGE" ]; then

  findFile "boot" "img" && return 0
  findFile "boot" "raw" && return 0
  findFile "boot" "iso" && return 0
  findFile "boot" "qcow2" && return 0
  findFile "custom" "iso" && return 0

  if hasDisk; then
    BOOT="none"
    return 0
  fi

fi

if [[ "$BOOT" != *"."* ]]; then
  if [ -z "$BOOT" ]; then
    error "No BOOT value specified!"
  else
    error "Invalid BOOT value specified, option \"$BOOT\" is not recognized!"
  fi
  exit 64
fi

if ! makeDir "$STORAGE"; then
  error "Failed to create directory \"$STORAGE\" !" && exit 33
fi

base=$(getBase "$BOOT")

case "${base,,}" in
  *".gz" | *".gzip" | *".xz" | *".7z" | *".zip" | *".rar" | *".lzma" | *".bz" | *".bz2" )
    info "Extracting $base..."
    html "Extracting image..." ;;
esac

case "${base,,}" in
  *".gz" | *".gzip" )

    gzip -dc "$STORAGE/$base" > "$STORAGE/${base%.*}"
    rm -f "$STORAGE/$base"
    base="${base%.*}"

    ;;
  *".xz" )

    xz -dc "$STORAGE/$base" > "$STORAGE/${base%.*}"
    rm -f "$STORAGE/$base"
    base="${base%.*}"

    ;;
  *".7z" | *".zip" | *".rar" | *".lzma" | *".bz" | *".bz2" )

    tmp="$STORAGE/extract"
    rm -rf "$tmp"

    if ! makeDir "$tmp"; then
      error "Failed to create directory \"$tmp\" !" && exit 33
    fi

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

case "${base,,}" in
  *".iso" | *".img" | *".raw" | *".qcow2" )

    ! setOwner "$STORAGE/$base" && error "Failed to set the owner for \"$STORAGE/$base\" !"
    detectType "$STORAGE/$base" && return 0
    error "Cannot read file \"${base}\"" && exit 63 ;;
esac

target_ext="img"
target_fmt="${DISK_FMT:-}"
[ -z "$target_fmt" ] && target_fmt="raw"
[[ "$target_fmt" != "raw" ]] && target_ext="qcow2"

case "${base,,}" in
  *".vdi" ) source_fmt="vdi" ;;
  *".vhd" ) source_fmt="vpc" ;;
  *".vhdx" ) source_fmt="vpc" ;;
  *".vmdk" ) source_fmt="vmdk" ;;
  * ) error "Unknown file extension, type \".${base/*./}\" is not recognized!" && exit 33 ;;
esac

dst="$STORAGE/${base%.*}.$target_ext"

! convertImage "$STORAGE/$base" "$source_fmt" "$dst" "$target_fmt" && exit 35

base=$(basename "$dst")

! setOwner "$STORAGE/$base" && error "Failed to set the owner for \"$STORAGE/$base\" !"
detectType "$STORAGE/$base" && return 0
error "Cannot convert file \"${base}\"" && exit 36

return 0
