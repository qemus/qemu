#!/usr/bin/env bash
set -Eeuo pipefail

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

bootFile() {

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

detectRawDiskMode() {

  local file="$1"
  local result=""
  local mode=""

  if [ ! -r "$file" ]; then
    error "Failed to read disk image \"$file\"!"
    return 1
  fi

  if ! result=$(LC_ALL=C sfdisk --json "$file" 2>/dev/null); then
    warn "No partition table detected in \"$file\", assuming legacy boot."
    BOOT_MODE="legacy"
    return 0
  fi

  if ! mode=$(jq -r '
      [.partitiontable.partitions[]? |
        ((.type // "") | ascii_downcase | sub("^0x"; ""))
      ] as $types |

      if any($types[];
        . == "ef" or
        . == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
      ) then
        "uefi"
      elif any($types[]; . == "ee") then
        "protective"
      else
        "legacy"
      end
    ' <<< "$result"); then
    error "Failed to parse disk partition table!"
    return 1
  fi

  case "$mode" in
    "uefi" ) ;;

    "protective" )
      warn "Protective MBR found but no valid GPT partition table was detected in \"$file\", keeping UEFI mode." ;;

    "legacy" )
      BOOT_MODE="legacy" ;;

    * )
      error "Failed to determine boot mode from disk partition table!"
      return 1 ;;
  esac

  return 0
}

isLegacyIso() {

  local file="$1"
  local result=""

  if ! result=$(LC_ALL=C xorriso \
      -no_rc \
      -indev "$file" \
      -report_el_torito plain 2>/dev/null); then
    error "Failed to read ISO file, invalid format!"
    return 2
  fi

  awk '
    $1 == "El" &&
    $2 == "Torito" &&
    $3 == "boot" &&
    $4 == "img" &&
    $5 == ":" {

      if ($7 == "BIOS" && $8 == "y")
        bios = 1

      if ($7 == "UEFI" && $8 == "y")
        uefi = 1
    }

    END {
      exit !(bios && !uefi)
    }
  ' <<< "$result"
}

readQcow2Sectors() {

  local file="$1"
  local skip="$2"
  local count="$3"
  local output="$4"

  rm -f "$output"

  if ! qemu-img dd \
      -f qcow2 \
      -O raw \
      bs=512 \
      skip="$skip" \
      count="$count" \
      "if=$file" \
      "of=$output" >/dev/null 2>&1; then
    return 1
  fi

  return 0
}

detectQcow2Mode() {

  local file="$1"
  local found="N"
  local protective="N"
  local signature=""
  local tmp=""
  local type=""
  local offset=""
  local actual_size=0

  local entry_lba=""
  local entry_count=""
  local entry_size=""
  local entry_units=0
  local table_size=0
  local table_sectors=0
  local expected_size=0

  if ! tmp=$(mktemp "$QEMU_DIR/boot-mode.XXXXXX"); then
    error "Failed to create temporary boot detection file!"
    return 1
  fi

  if ! readQcow2Sectors "$file" 0 2 "$tmp"; then
    rm -f "$tmp"
    error "Failed to inspect QCOW2 image!"
    return 1
  fi

  if ! actual_size=$(stat -c%s -- "$tmp"); then
    rm -f "$tmp"
    error "Failed to determine QCOW2 inspection data size!"
    return 1
  fi

  if (( actual_size < 1024 )); then
    rm -f "$tmp"
    error "QCOW2 image is too small to contain a partition table!"
    return 1
  fi

  if ! signature=$(xxd -p -l 2 -s 510 "$tmp"); then
    rm -f "$tmp"
    error "Failed to inspect QCOW2 partition table!"
    return 1
  fi

  # Check the four MBR partition type fields.
  if [[ "$signature" == "55aa" ]]; then

    for offset in 450 466 482 498; do

      if ! type=$(xxd -p -l 1 -s "$offset" "$tmp"); then
        rm -f "$tmp"
        error "Failed to inspect QCOW2 partition table!"
        return 1
      fi

      case "$type" in
        "ef" )
          found="Y"
          break
          ;;
        "ee" )
          protective="Y"
          ;;
      esac

    done
  fi

  if [[ "$found" != "Y" ]]; then

    if ! signature=$(xxd -p -l 8 -s 512 "$tmp"); then
      rm -f "$tmp"
      error "Failed to inspect QCOW2 partition table!"
      return 1
    fi

    if [[ "$signature" != "4546492050415254" ]]; then

      if [[ "$protective" == "Y" ]]; then
        rm -f "$tmp"
        warn "Protective MBR found but the GPT header in \"$file\" is invalid, keeping UEFI mode."
        return 0
      fi

    else

      entry_lba=$(od -An -tu8 -j 584 -N 8 "$tmp" | tr -d '[:space:]') || {
        rm -f "$tmp"
        error "Failed to read GPT header!"
        return 1
      }

      entry_count=$(od -An -tu4 -j 592 -N 4 "$tmp" | tr -d '[:space:]') || {
        rm -f "$tmp"
        error "Failed to read GPT header!"
        return 1
      }

      entry_size=$(od -An -tu4 -j 596 -N 4 "$tmp" | tr -d '[:space:]') || {
        rm -f "$tmp"
        error "Failed to read GPT header!"
        return 1
      }

      if [[ ! "$entry_lba" =~ ^[0-9]+$ ||
            ! "$entry_count" =~ ^[0-9]+$ ||
            ! "$entry_size" =~ ^[0-9]+$ ]]; then
        rm -f "$tmp"
        error "Invalid GPT header!"
        return 1
      fi

      entry_units=$((entry_size / 128))

      if (( entry_lba < 2 ||
            entry_count < 1 ||
            entry_count > 131072 ||
            entry_size < 128 ||
            entry_size > 4096 ||
            entry_size % 128 != 0 ||
            (entry_units & (entry_units - 1)) != 0 )); then
        rm -f "$tmp"
        error "Invalid GPT partition entry array!"
        return 1
      fi

      table_size=$((entry_count * entry_size))

      # Protect against corrupt images requesting an excessive read.
      if (( table_size > 16777216 )); then
        rm -f "$tmp"
        error "GPT partition entry array is too large!"
        return 1
      fi

      table_sectors=$(((table_size + 511) / 512))
      expected_size=$((table_sectors * 512))

      if ! readQcow2Sectors \
          "$file" "$entry_lba" "$table_sectors" "$tmp"; then
        rm -f "$tmp"
        error "Failed to read GPT partition entries!"
        return 1
      fi

      if ! actual_size=$(stat -c%s -- "$tmp"); then
        rm -f "$tmp"
        error "Failed to determine GPT partition entry data size!"
        return 1
      fi

      if (( actual_size < expected_size )); then
        rm -f "$tmp"
        error "Failed to read the complete GPT partition entry array!"
        return 1
      fi

      # EFI System Partition GUID in GPT on-disk byte order.
      if xxd -p -c 16 -l "$table_size" "$tmp" |
          awk -v stride="$((entry_size / 16))" '
            (NR - 1) % stride == 0 &&
              tolower($0) == "28732ac11ff8d211ba4b00a0c93ec93b" {
              found = 1
            }
            END {
              exit !found
            }
          '; then

        found="Y"

      fi
    fi
  fi

  rm -f "$tmp"

  if [[ "$found" != "Y" ]]; then
    BOOT_MODE="legacy"
  fi

  return 0
}

detectDiskMode() {

  local file="$1"

  case "${file,,}" in
    *".qcow2" ) detectQcow2Mode "$file" || return 1 ;;
    * ) detectRawDiskMode "$file" || return 1 ;;
  esac

  return 0
}

detectType() {

  local file="$1"
  [ ! -s "$file" ] && return 1

  case "${file,,}" in
    *".iso" | *".img" | *".raw" | *".qcow2" ) ;;
    * ) return 1 ;;
  esac

  if [ -z "$BOOT_MODE" ]; then
    if [[ "${file,,}" != *".iso" ]]; then

      detectDiskMode "$file" || return 1

    else

      if isLegacyIso "$file"; then

        BOOT_MODE="legacy"

      else

        case $? in
          1 ) ;;          # UEFI, hybrid, or unknown
          * ) return 1 ;; # Failed to inspect the ISO
        esac

      fi
    fi
  fi

  bootFile "$file" && return 0
  return 1
}

delay() {

  local i
  local delay="$1"
  local msg="Retrying failed download in X seconds..."

  info "${msg/X/$delay}"

  for i in $(seq "$delay" -1 1); do
    html "${msg/X/$i}"
    sleep 1
  done

  return 0
}

downloadFile() {

  local url="$1"
  local base="$2"
  local name="$3"
  local expected="${4:-0}"
  local dest="$STORAGE/$base"
  local msg rc total size log
  local reason=""
  local progress=()
  local output=""

  # Use Wget's progress bar in a terminal and progress.sh in container logs.
  if [ -t 1 ]; then
    progress=( --show-progress --progress=bar:noscroll )
  else
    output="log"
  fi

  if [ -z "$name" ]; then
    msg="Downloading image"
    info "Downloading $base..."
  else
    msg="Downloading $name"
    info "Downloading $name..."
  fi

  html "$msg..."
  log=$(mktemp)

  /run/progress.sh "$dest" "$expected" "$msg ([P])..." "$output" &

  {
    LC_ALL=C wget "$url" -O "$dest" --continue --no-verbose --timeout=30 \
      --no-http-keep-alive "${progress[@]}" --output-file="$log"
    rc=$?
  } || :

  fKill "progress.sh"

  if (( rc != 0 )); then
    reason=$(sed -n \
      -e 's/^wget: //p' \
      -e 's/^[0-9-]\{10\} [0-9:]\{8\} ERROR //p' \
      "$log" | tail -n 1)
  fi

  rm -f "$log"

  if (( rc == 0 )) && [ -f "$dest" ]; then

    if ! total=$(stat -c%s "$dest"); then
      error "Failed to determine downloaded file size: $dest"
      return 1
    fi

    size=$(formatBytes "$total") || return 1

    if [ "$total" -lt 100000 ]; then
      error "Invalid image file: is only $size ?"
      return 1
    fi

    return 0
  fi

  msg="Failed to download $url"

  if (( rc == 3 )); then
    error "$msg because the file could not be written (disk full?)."
  elif [ -n "$reason" ]; then
    error "$msg: ${reason%.}."
  else
    error "$msg with exit status $rc."
  fi

  return 1
}

downloadWithRetries() {

  local url="$1"
  local base="$2"
  local name="$3"

  rm -f "$STORAGE/$base"

  downloadFile "$url" "$base" "$name" && return 0
  delay 5
  downloadFile "$url" "$base" "$name" && return 0
  delay 10
  downloadFile "$url" "$base" "$name" && return 0

  rm -f "$STORAGE/$base"
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
    if ! mv -f "$source_file" "$dst_file"; then
      error "Failed to move converted image to $dst_file."
      return 1
    fi
    return 0
  fi

  local tmp_file="$dst_file.tmp"
  dir=$(dirname "$tmp_file")

  rm -f "$tmp_file"

  if [ -n "$ALLOCATE" ] && ! disabled "$ALLOCATE"; then

    # Check free diskspace
    if ! src_size=$(qemu-img info "$source_file" -f "$source_fmt" | grep '^virtual size: ' | sed 's/.*(\(.*\) bytes)/\1/'); then
      error "Failed to determine virtual size of $source_file."
      return 1
    fi

    if ! space=$(df --output=avail -B 1 "$dir" | tail -n 1); then
      error "Failed to check free space in $dir."
      return 1
    fi

    if (( src_size > space )); then
      space_gb=$(formatBytes "$space")
      error "Not enough free space to convert image in $dir, it has only $space_gb available..." && return 1
    fi
  fi

  base=$(basename "$source_file")
  info "Converting $base..."
  html "Converting image..."

  local conv_flags="-p"

  if [ -z "$ALLOCATE" ] || disabled "$ALLOCATE"; then
    disk_param="preallocation=off"
  else
    disk_param="preallocation=falloc"
  fi

  fs=$(stat -f -c %T "$dir")
  [[ "${fs,,}" == "btrfs" ]] && disk_param+=",nocow=on"

  if [[ "$dst_fmt" != "raw" ]]; then
    if [ -z "$ALLOCATE" ] || disabled "$ALLOCATE"; then
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
    if [ -n "$ALLOCATE" ] && ! disabled "$ALLOCATE"; then
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

  if ! mv "$tmp_file" "$dst_file"; then
    error "Failed to move converted image to $dst_file."
    return 1
  fi

  if ! rm -f "$source_file"; then
    error "Failed to remove old image $source_file."
    return 1
  fi

  if [[ "${fs,,}" == "btrfs" ]]; then
    fa=$(lsattr "$dst_file")
    if [[ "$fa" != *"C"* ]]; then
      error "Failed to disable COW for image on ${fs^^} filesystem!"
    fi
  fi

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

    hasData && return 1

    error "The bind $dir maps to a file that does not exist!"
    exit 37
  fi

  file=$(find / -maxdepth 1 -type f -iname "$fname" -print -quit)
  [ ! -s "$file" ] && file=$(find "$STORAGE" -maxdepth 1 -type f -iname "$fname" -print -quit)

  detectType "$file" && return 0

  return 1
}

findBootFile() {

  findFile "boot" "img" && return 0
  findFile "boot" "raw" && return 0
  findFile "boot" "iso" && return 0
  findFile "boot" "qcow2" && return 0
  findFile "custom" "iso" && return 0

  return 1
}

findArchiveImage() {

  local tmp="$1"
  local base="$2"
  local img=""
  local ext
  local exts=( iso img raw qcow2 vdi vhd vhdx vmdk )

  case "${base%.*}" in
    *".iso" | *".img" | *".raw" | *".qcow2" | *".vdi" | *".vhd" | *".vhdx" | *".vmdk" )
      if [ -s "$tmp/${base%.*}" ]; then
        img="$tmp/${base%.*}"
      fi
      ;;
  esac

  if [ -z "$img" ]; then
    for ext in "${exts[@]}"; do
      if [ -s "$tmp/${base%.*}.$ext" ]; then
        img="$tmp/${base%.*}.$ext"
        break
      fi
    done
  fi

  if [ -z "$img" ]; then
    for ext in "${exts[@]}"; do
      img=$(find "$tmp" -type f -iname "*.$ext" -print -quit)
      [ -n "$img" ] && break
    done
  fi

  echo "$img"
  return 0
}

findBootFile && return 0

if hasData; then

  if [ -z "$BOOT_MODE" ]; then

    disk=$(getDisk) || {
      error "Failed to locate data disk!"
      exit 63
    }

    detectDiskMode "$disk" || exit 63
  fi

  BOOT="none"
  return 0

fi

BOOT=$(strip "$BOOT")

if [ -z "$BOOT" ] || [[ "$BOOT" == *"example.com/"* ]]; then

  BOOT="alpine"
  warn "no value specified for the BOOT variable, defaulting to \"${BOOT}\"."

fi

if ! hasDisk; then

  folder=$(getFolder "$BOOT")
  STORAGE="$STORAGE/$folder"

  if [ -d "$STORAGE" ]; then

    findBootFile && return 0

    if hasData; then

      if [ -z "$BOOT_MODE" ]; then

        disk=$(getDisk) || {
          error "Failed to locate data disk!"
          exit 63
        }

        detectDiskMode "$disk" || exit 63
      fi

      BOOT="none"
      return 0

    fi

  fi
fi

name=$(getURL "$BOOT" "name") || exit 34

if [ -n "$name" ]; then

  msg="Retrieving latest $name version..."
  info "$msg" && html "$msg..."

  url=$(getURL "$BOOT" "url") || exit 34

  [ -n "$url" ] && BOOT="$url"

fi

if [[ "$BOOT" != *"."* ]]; then
  if [ -z "$BOOT" ]; then
    error "No BOOT value specified!"
  else
    error "Invalid BOOT value specified, option \"$BOOT\" is not recognized!"
  fi
  exit 64
fi

if [[ "${BOOT,,}" != "http"* ]]; then
  error "Invalid BOOT value specified, \"$BOOT\" is not a valid URL!" && exit 64
fi

if ! makeDir "$STORAGE"; then
  error "Failed to create directory \"$STORAGE\" !" && exit 33
fi

find "$STORAGE" -maxdepth 1 -type f \( -iname '*.rom' -or -iname '*.vars' \) -delete
find "$STORAGE" -maxdepth 1 -type f -iname 'qemu.*' -delete

base=$(getBase "$BOOT")

if ! downloadWithRetries "$BOOT" "$base" "$name"; then
  exit 60
fi

case "${base,,}" in

  *".gz" | *".gzip" | *".xz" | *".7z" | *".zip" | *".rar" | *".lzma" | *".bz" | *".bz2" )

    info "Extracting $base..."
    html "Extracting image..." ;;

esac

case "${base,,}" in

  *".gz" | *".gzip" )

    out="$STORAGE/${base%.*}"
    tmp="$out.tmp"

    rm -f "$tmp"

    if ! gzip -dc "$STORAGE/$base" > "$tmp"; then
      rm -f "$tmp"
      error "Failed to extract archive: $base" && exit 32
    fi

    if ! mv -f "$tmp" "$out"; then
      rm -f "$tmp"
      error "Failed to move extracted image to $out" && exit 32
    fi

    rm -f "$STORAGE/$base"
    base="${base%.*}"
    ;;

  *".xz" )

    out="$STORAGE/${base%.*}"
    tmp="$out.tmp"

    rm -f "$tmp"

    if ! xz -dc "$STORAGE/$base" > "$tmp"; then
      rm -f "$tmp"
      error "Failed to extract archive: $base" && exit 32
    fi

    if ! mv -f "$tmp" "$out"; then
      rm -f "$tmp"
      error "Failed to move extracted image to $out" && exit 32
    fi

    rm -f "$STORAGE/$base"
    base="${base%.*}"
    ;;

  *".7z" | *".zip" | *".rar" | *".lzma" | *".bz" | *".bz2" )

    tmp="$STORAGE/extract"
    rm -rf "$tmp"

    if ! makeDir "$tmp"; then
      error "Failed to create directory \"$tmp\" !" && exit 33
    fi

    if ! 7z x "$STORAGE/$base" -o"$tmp" > /dev/null; then
      rm -rf "$tmp"
      error "Failed to extract archive: $base" && exit 32
    fi

    rm -f "$STORAGE/$base"

    img=$(findArchiveImage "$tmp" "$base")

    if [ ! -s "$img" ] || [ ! -f "$img" ]; then
      rm -rf "$tmp"
      error "Cannot find any image file in archive: .${BOOT/*./}" && exit 32
    fi

    base=$(basename "$img")

    if ! mv "$img" "$STORAGE/$base"; then
      rm -rf "$tmp"
      error "Failed to move extracted image to $STORAGE/$base" && exit 32
    fi

    rm -rf "$tmp"
    ;;

esac

case "${base,,}" in

  *".iso" | *".img" | *".raw" | *".qcow2" )

    ! setOwner "$STORAGE/$base" && warn "failed to set the owner for \"$STORAGE/$base\" !"
    detectType "$STORAGE/$base" && return 0
    error "Cannot read file \"${base}\"" && exit 63 ;;

esac

target_ext="img"
target_fmt="${DISK_FMT:-raw}"
target_fmt="${target_fmt,,}"
[[ "$target_fmt" != "raw" ]] && target_ext="qcow2"

case "${base,,}" in
  *".vdi" ) source_fmt="vdi" ;;
  *".vhd" ) source_fmt="vpc" ;;
  *".vhdx" ) source_fmt="vhdx" ;;
  *".vmdk" ) source_fmt="vmdk" ;;
  * ) error "Unknown file extension, type \".${base/*./}\" is not recognized!" && exit 33 ;;
esac

dst="$STORAGE/${base%.*}.$target_ext"

! convertImage "$STORAGE/$base" "$source_fmt" "$dst" "$target_fmt" && exit 35

base=$(basename "$dst")

! setOwner "$STORAGE/$base" && warn "failed to set the owner for \"$STORAGE/$base\" !"
detectType "$STORAGE/$base" && return 0
error "Cannot convert file \"${base}\"" && exit 36

return 0
