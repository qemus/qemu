#!/usr/bin/env bash
set -Eeuo pipefail

getURL() {
  local id="${1/ /}"
  local ret="$2"
  local url=""
  local name=""

  case "${id,,}" in
    "alma" )
      name="AlmaLinux"
      url="https://repo.almalinux.org/almalinux/9/live/x86_64/AlmaLinux-9.5-x86_64-Live-GNOME.iso" ;;
    "alpine" )
      name="Alpine Linux"
      url="https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/alpine-virt-3.19.1-x86_64.iso" ;;
    "arch" )
      name="Arch Linux"
      url="https://geo.mirror.pkgbuild.com/iso/2025.03.01/archlinux-x86_64.iso" ;;
    "cachy" )
      name="CachyOS"
      url="https://cdn77.cachyos.org/ISO/desktop/250202/cachyos-desktop-linux-250202.iso" ;;
    "centos" )
      name="CentOS Stream"
      url="https://mirrors.xtom.de/centos-stream/10-stream/BaseOS/x86_64/iso/CentOS-Stream-10-latest-x86_64-dvd1.iso" ;;
    "debian" )
      name="Debian"
      url="https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/debian-live-12.9.0-amd64-gnome.iso" ;;
    "endeavour" )
      name="EndeavourOS"
      url="https://mirrors.gigenet.com/endeavouros/iso/EndeavourOS_Mercury-2025.02.08.iso" ;;
    "fedora" )
      name="Fedora Linux"
      url="https://download.fedoraproject.org/pub/fedora/linux/releases/41/Workstation/x86_64/iso/Fedora-Workstation-Live-x86_64-41-1.4.iso" ;;
    "gentoo" )
      name="Gentoo Linux"
      url="https://distfiles.gentoo.org/releases/amd64/autobuilds/20250309T170330Z/livegui-amd64-20250309T170330Z.iso" ;;
    "kali" )
      name="Kali Linux"
      url="https://cdimage.kali.org/kali-2024.4/kali-linux-2024.4-live-amd64.iso" ;;
    "kubuntu" )
      name="Kubuntu"
      url="https://cdimage.ubuntu.com/kubuntu/releases/24.10/release/kubuntu-24.10-desktop-amd64.iso" ;;
    "mint" )
      name="Linux Mint"
      url="https://mirrors.layeronline.com/linuxmint/stable/22.1/linuxmint-22.1-cinnamon-64bit.iso" ;;
    "manjaro" )
      name="Manjaro"
      url="https://download.manjaro.org/kde/24.2.1/manjaro-kde-24.2.1-241216-linux612.iso" ;;
    "mx" )
      name="MX Linux"
      url="https://mirror.umd.edu/mxlinux-iso/MX/Final/Xfce/MX-23.5_x64.iso" ;;
    "netbsd" )
      name="NetBSD"
      url="https://cdn.netbsd.org/pub/NetBSD/NetBSD-10.1/images/NetBSD-10.1-amd64.iso" ;;
    "nixos" )
      name="NixOS"
      url="https://channels.nixos.org/nixos-24.11/latest-nixos-gnome-x86_64-linux.iso" ;;
    "opensuse" )
      name="OpenSUSE"
      url="https://download.opensuse.org/distribution/leap/15.0/live/openSUSE-Leap-15.0-GNOME-Live-x86_64-Current.iso" ;;
    "oracle" )
      name="Oracle Linux"
      url="https://yum.oracle.com/ISOS/OracleLinux/OL9/u5/x86_64/OracleLinux-R9-U5-x86_64-boot.iso" ;;
    "rocky" )
      name="Rocky Linux"
      url="https://dl.rockylinux.org/pub/rocky/9/live/x86_64/Rocky-9-Workstation-x86_64-latest.iso" ;;
    "slack" )
      name="Slackware"
      url="https://slackware.nl/slackware-live/slackware64-15.0-live/slackware64-live-15.0.iso" ;;
    "tails" )
      name="Tails"
      url="https://download.tails.net/tails/stable/tails-amd64-6.13/tails-amd64-6.13.img" ;;
    "ubuntu" )
      name="Ubuntu Desktop"
      url="https://releases.ubuntu.com/24.04.2/ubuntu-24.04.2-desktop-amd64.iso" ;;
    "ubuntus" )
      name="Ubuntu Server"
      url="https://releases.ubuntu.com/24.04.2/ubuntu-24.04.2-live-server-amd64.iso" ;;
    "xubuntu" )
      name="Xubuntu"
      url="https://mirror.us.leaseweb.net/ubuntu-cdimage/xubuntu/releases/24.04/release/xubuntu-24.04.2-desktop-amd64.iso" ;;
  esac

  case "${ret,,}" in
    "name" ) echo "$name" ;;
    *) echo "$url";;
  esac

  return 0
}

moveFile() {

  local file="$1"
  local ext="${file##*.}"
  local dest="$STORAGE/boot.$ext"

  if [[ "$file" == "$dest" ]] || [[ "$file" == "/boot.$ext" ]]; then
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

  local dir=""
  local file="$1"

  [ ! -f "$file" ] && return 1
  [ ! -s "$file" ] && return 1

  case "${file,,}" in
    *".iso" | *".img" | *".raw" | *".qcow2" ) ;;
    * ) return 1 ;;
  esac

  if [ -n "$BOOT_MODE" ] || [[ "${file,,}" != *".iso" ]]; then
    ! moveFile "$file" && return 1
    return 0
  fi

  # Automaticly detect UEFI-compatible ISO's
  dir=$(isoinfo -f -i "$file")

  if [ -n "$dir" ]; then
    dir=$(echo "${dir^^}" | grep "^/EFI")
    [ -z "$dir" ] && BOOT_MODE="legacy"
  else
    error "Failed to read ISO file, invalid format!"
  fi

  ! moveFile "$file" && return 1
  return 0
}

downloadFile() {

  local url="$1"
  local base="$2"
  local name="$3"
  local msg rc total total_mb progress name

  local dest="$STORAGE/$base.tmp"
  rm -f "$dest"

  # Check if running with interactive TTY or redirected to docker log
  if [ -t 1 ]; then
    progress="--progress=bar:noscroll"
  else
    progress="--progress=dot:giga"
  fi

  if [ -z "$name" ]; then
    name="$base"
    msg="Downloading image"
  else
    msg="Downloading $name"
  fi

  info "Downloading $name..."
  html "$msg..."

  /run/progress.sh "$dest" "0" "$msg ([P])..." &

  { wget "$url" -O "$dest" -q --timeout=30 --no-http-keep-alive --show-progress "$progress"; rc=$?; } || :

  fKill "progress.sh"

  if (( rc == 0 )) && [ -f "$dest" ]; then
    total=$(stat -c%s "$dest")
    total_gb=$(formatBytes "$total")
    if [ "$total" -lt 100000 ]; then
      error "Invalid image file: is only $total_gb ?" && return 1
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
      if ! fallocate -l "$cur_size" "$tmp_file"; then
        error "Failed to allocate $cur_gb for image!"
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

  local file
  local ext="$1"
  local fname="boot.$ext"

  if [ -d "/$fname" ]; then
    warn "The file /$fname has an invalid path!"
  fi

  file=$(find / -maxdepth 1 -type f -iname "$fname" | head -n 1)
  [ ! -s "$file" ] && file=$(find "$STORAGE" -maxdepth 1 -type f -iname "$fname" | head -n 1)
  detectType "$file" && return 0

  return 1
}

findFile "iso" && return 0
findFile "img" && return 0
findFile "raw" && return 0
findFile "qcow2" && return 0

if [ -z "$BOOT" ] || [[ "$BOOT" == *"example.com/image.iso" ]]; then
  hasDisk && return 0
  error "No value specified for the BOOT variable." && exit 64
fi

url=$(getURL "$BOOT" "url")
name=$(getURL "$BOOT" "name")
[ -n "$url" ] && BOOT="$url"

if [[ "$BOOT" != *"."* ]]; then
  error "Invalid BOOT value specified, shortcut \"$BOOT\" is not recognized!" && exit 64
fi

if [[ "${BOOT,,}" != "http"* ]]; then
  error "Invalid BOOT value specified, \"$BOOT\" is not a valid URL!" && exit 64
fi

base=$(basename "${BOOT%%\?*}")
: "${base//+/ }"; printf -v base '%b' "${_//%/\\x}"
base=$(echo "$base" | sed -e 's/[^A-Za-z0-9._-]/_/g')

case "${base,,}" in

  *".iso" | *".img" | *".raw" | *".qcow2" )

    detectType "$STORAGE/$base" && return 0 ;;

  *".vdi" | *".vmdk" | *".vhd" | *".vhdx" )

    detectType "$STORAGE/${base%.*}.img" && return 0
    detectType "$STORAGE/${base%.*}.qcow2" && return 0 ;;

  *".gz" | *".gzip" | *".xz" | *".7z" | *".zip" | *".rar" | *".lzma" | *".bz" | *".bz2" )

    case "${base%.*}" in

      *".iso" | *".img" | *".raw" | *".qcow2" )

        detectType "$STORAGE/${base%.*}" && return 0 ;;

      *".vdi" | *".vmdk" | *".vhd" | *".vhdx" )

        find="${base%.*}"

        detectType "$STORAGE/${find%.*}.img" && return 0
        detectType "$STORAGE/${find%.*}.qcow2" && return 0 ;;

    esac ;;

  * ) error "Unknown file extension, type \".${base/*./}\" is not recognized!" && exit 33 ;;
esac

if ! downloadFile "$BOOT" "$base" "$name"; then
  rm -f "$STORAGE/$base.tmp" && exit 60
fi

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

case "${base,,}" in
  *".iso" | *".img" | *".raw" | *".qcow2" )
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
detectType "$STORAGE/$base" && return 0
error "Cannot convert file \"${base}\"" && exit 36
