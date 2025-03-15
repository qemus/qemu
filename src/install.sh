#!/usr/bin/env bash
set -Eeuo pipefail

getURL() {
  local id="${1/ /}"
  local url=""

  case "${id,,}" in
    "alma" )
      url="https://repo.almalinux.org/almalinux/9.5/isos/x86_64/AlmaLinux-9.5-x86_64-dvd.iso" ;;
    "alpine" )
      url="https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/alpine-virt-3.19.1-x86_64.iso" ;;
    "arch" )
      url="https://geo.mirror.pkgbuild.com/images/v20250301.315930/Arch-Linux-x86_64-basic.qcow2" ;;
    "cachy" )
      url="https://cdn77.cachyos.org/ISO/desktop/250202/cachyos-desktop-linux-250202.iso" ;;
    "centos" )
      url="https://mirrors.xtom.de/centos-stream/10-stream/BaseOS/x86_64/iso/CentOS-Stream-10-latest-x86_64-dvd1.iso" ;;
    "debian" )
      url="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-nocloud-amd64.qcow2" ;;
    "endeavour" )
      url="https://mirrors.gigenet.com/endeavouros/iso/EndeavourOS_Mercury-2025.02.08.iso" ;;
    "fedora" )
      url="https://download.fedoraproject.org/pub/fedora/linux/releases/41/Everything/x86_64/iso/Fedora-Everything-netinst-x86_64-41-1.4.iso" ;;
    "freebsd" )
      url="https://download.freebsd.org/releases/VM-IMAGES/14.2-RELEASE/amd64/Latest/FreeBSD-14.2-RELEASE-amd64.qcow2.xz" ;;
    "gentoo" )
      url="https://distfiles.gentoo.org/releases/amd64/autobuilds/20250309T170330Z/di-amd64-console-20250309T170330Z.qcow2" ;;
    "haiku" )
      url="https://mirrors.rit.edu/haiku/r1beta5/haiku-r1beta5-x86_64-anyboot.iso" ;;
    "kali" )
      url="https://cdimage.kali.org/kali-2024.4/kali-linux-2024.4-qemu-amd64.7z" ;;
    "kubuntu" )
      url="https://cdimage.ubuntu.com/kubuntu/releases/24.10/release/kubuntu-24.10-desktop-amd64.iso" ;;
    "mint" )
      url="https://mirrors.layeronline.com/linuxmint/stable/22.1/linuxmint-22.1-cinnamon-64bit.iso" ;;
    "manjaro" )
      url="https://download.manjaro.org/kde/24.2.1/manjaro-kde-24.2.1-241216-linux612.iso" ;;
    "mx" )
      url="https://mirror.umd.edu/mxlinux-iso/MX/Final/Xfce/MX-23.5_x64.iso" ;;
    "netbsd" )
      url="https://cdn.netbsd.org/pub/NetBSD/NetBSD-10.1/images/NetBSD-10.1-amd64.iso" ;;
    "nixos" )
      url="https://channels.nixos.org/nixos-24.11/latest-nixos-gnome-x86_64-linux.iso" ;;
    "openbsd" )
      url="https://cdn.openbsd.org/pub/OpenBSD/7.6/amd64/install76.iso" ;;
    "opensuse" )
      url="https://download.opensuse.org/tumbleweed/appliances/openSUSE-Tumbleweed-Minimal-VM.x86_64-1.0.0-kvm-and-xen-Snapshot20250313.qcow2" ;;
    "oracle" )
      url="https://yum.oracle.com/ISOS/OracleLinux/OL9/u5/x86_64/OracleLinux-R9-U5-x86_64-boot.iso" ;;
    "popos" )
      url="https://pop-iso.sfo2.cdn.digitaloceanspaces.com/22.04/amd64/intel/4/pop-os_22.04_amd64_intel_4.iso" ;;
    "rocky" )
      url="https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2" ;;
    "slack" )
      url="https://mirrors.slackware.com/slackware/slackware-iso/slackware64-15.0-iso/slackware64-15.0-install-dvd.iso" ;;
    "tails" )
      url="https://download.tails.net/tails/stable/tails-amd64-6.13/tails-amd64-6.13.img" ;;
    "tinycore" )
      url="http://www.tinycorelinux.net/15.x/x86/release/TinyCore-current.iso" ;;
    "ubuntu" )
      url="https://releases.ubuntu.com/24.04.2/ubuntu-24.04.2-desktop-amd64.iso" ;;
    "ubuntus" )
      url="https://releases.ubuntu.com/24.04.2/ubuntu-24.04.2-live-server-amd64.iso" ;;
    "xubuntu" )
      url="https://mirror.us.leaseweb.net/ubuntu-cdimage/xubuntu/releases/24.04/release/xubuntu-24.04.2-desktop-amd64.iso" ;;
    "zorin" )
      url="https://mirrors.edge.kernel.org/zorinos-isos/17/Zorin-OS-17.2-Core-64-bit.iso" ;;
  esac

  echo "$url"
  return 0
}

detectType() {

  local dir=""
  local file="$1"

  [ ! -f "$file" ] && return 1
  [ ! -s "$file" ] && return 1

  case "${file,,}" in
    *".iso" | *".img" | *".raw" | *".qcow2" )
      BOOT="$file" ;;
    * ) return 1 ;;
  esac

  [ -n "$BOOT_MODE" ] && return 0
  [[ "${file,,}" != *".iso" ]] && return 0

  # Automaticly detect UEFI-compatible ISO's
  dir=$(isoinfo -f -i "$file")

  if [ -z "$dir" ]; then
    BOOT=""
    error "Failed to read ISO file, invalid format!" && return 1
  fi

  dir=$(echo "${dir^^}" | grep "^/EFI")
  [ -z "$dir" ] && BOOT_MODE="legacy"

  return 0
}

downloadFile() {

  local url="$1"
  local base="$2"
  local msg rc total total_mb progress

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
  BOOT="alpine"
fi

url=$(getURL "$BOOT")

if [ -n "$url" ]; then
  BOOT="$url"
else
  if [[ "${url,,}" != *"."* ]]; then
    error "Invalid BOOT shortcut specified, value \"$url\" is not recognized!" && exit 64
  fi
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

if ! downloadFile "$BOOT" "$base"; then
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
error "Cannot read file \"${base}\"" && exit 36
