#!/usr/bin/env bash
set -Eeuo pipefail

pipe() {
  local code="99"
  msg="Failed to connect to $1, reason:"

  curl --disable --silent --max-time 10 --fail --location "${1}" || {
    code="$?"
  }

  case "${code,,}" in
    "6" ) error "$msg could not resolve host!" ;;
    "7" ) error "$msg no internet connection available!" ;;
    "28" ) error "$msg connection timed out!" ;;
    "99" ) return 0 ;;
    *) error "$msg $code" ;;
  esac

  return 1
}

getURL() {
  local id="${1/ /}"
  local ret="$2"
  local url=""
  local arm=
  local name=""

  case "${id,,}" in
    "alma" | "almalinux" | "alma-linux" )
      name="AlmaLinux"
      url="https://repo.almalinux.org/almalinux/9/live/x86_64/AlmaLinux-9.5-x86_64-Live-GNOME.iso"
      arm="https://repo.almalinux.org/almalinux/9/live/aarch64/AlmaLinux-9.5-aarch64-Live-GNOME.iso" ;;
    "alpine" | "alpinelinux" | "alpine-linux" )
      name="Alpine Linux"
      url="https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/alpine-virt-3.19.1-x86_64.iso"
      arm="https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/aarch64/alpine-virt-3.19.1-aarch64.iso" ;;
    "arch" | "archlinux" | "arch-linux" )
      name="Arch Linux"
      url="https://geo.mirror.pkgbuild.com/iso/2025.03.01/archlinux-x86_64.iso" ;;
    "cachy" | "cachyos" )
      name="CachyOS"
      url="https://cdn77.cachyos.org/ISO/desktop/250202/cachyos-desktop-linux-250202.iso" ;;
    "centos" | "centosstream" | "centos-stream" )
      name="CentOS Stream"
      url="https://mirrors.xtom.de/centos-stream/10-stream/BaseOS/x86_64/iso/CentOS-Stream-10-latest-x86_64-dvd1.iso"
      arm="https://mirrors.xtom.de/centos-stream/10-stream/BaseOS/aarch64/iso/CentOS-Stream-10-latest-aarch64-dvd1.iso" ;;
    "debian" )
      name="Debian"
      version=$(pipe "https://cdimage.debian.org/debian-cd/") || exit 65
      version=$(echo "$version" | grep '\.[0-9]/' | cut -d'>' -f 9 | cut -d'/' -f 1)
      url="https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/debian-live-$version-amd64-standard.iso"
      arm="https://cdimage.debian.org/debian-cd/current/arm64/iso-dvd/debian-$version-arm64-DVD-1.iso" ;;
    "endeavour" | "endeavouros" )
      name="EndeavourOS"
      url="https://mirrors.gigenet.com/endeavouros/iso/EndeavourOS_Mercury-2025.02.08.iso" ;;
    "fedora" | "fedoralinux" | "fedora-linux" )
      name="Fedora Linux"
      url="https://download.fedoraproject.org/pub/fedora/linux/releases/41/Workstation/x86_64/iso/Fedora-Workstation-Live-x86_64-41-1.4.iso"
      arm="https://eu.edge.kernel.org/fedora/releases/41/Workstation/aarch64/images/Fedora-Workstation-41-1.4.aarch64.raw.xz" ;;
    "gentoo" | "gentoolinux" | "gentoo-linux" )
      name="Gentoo Linux"
      url="https://distfiles.gentoo.org/releases/amd64/autobuilds/20250309T170330Z/livegui-amd64-20250309T170330Z.iso"
      arm="https://distfiles.gentoo.org/releases/arm64/autobuilds/20250309T234826Z/di-arm64-cloudinit-20250309T234826Z.qcow2" ;;
    "kali" | "kalilinux" | "kali-linux" )
      name="Kali Linux"
      url="https://cdimage.kali.org/kali-2024.4/kali-linux-2024.4-live-amd64.iso"
      arm="https://cdimage.kali.org/kali-2024.4/kali-linux-2024.4-live-arm64.iso" ;;
    "kubuntu" )
      name="Kubuntu"
      url="https://cdimage.ubuntu.com/kubuntu/releases/24.10/release/kubuntu-24.10-desktop-amd64.iso" ;;
    "lmde" )
      name="Linux Mint Debian Edition"
      url="https://mirror.rackspace.com/linuxmint/iso/debian/lmde-6-cinnamon-64bit.iso" ;;
    "macos" | "osx" )
      name="macOS"
      error "To install $name use: https://github.com/dockur/macos" && return 1 ;;
    "mint" | "linuxmint" | "linux-mint" )
      name="Linux Mint"
      url="https://mirrors.layeronline.com/linuxmint/stable/22.1/linuxmint-22.1-cinnamon-64bit.iso" ;;
    "manjaro" )
      name="Manjaro"
      url="https://download.manjaro.org/kde/24.2.1/manjaro-kde-24.2.1-241216-linux612.iso" ;;
    "mx" | "mxlinux" | "mx-linux" )
      name="MX Linux"
      url="https://mirror.umd.edu/mxlinux-iso/MX/Final/Xfce/MX-23.5_x64.iso" ;;
    "nixos" )
      name="NixOS"
      url="https://channels.nixos.org/nixos-24.11/latest-nixos-gnome-x86_64-linux.iso"
      arm="https://channels.nixos.org/nixos-24.11/latest-nixos-gnome-aarch64-linux.iso" ;;
    "opensuse" | "open-suse" | "suse" )
      name="OpenSUSE"
      url="https://download.opensuse.org/distribution/leap/15.0/live/openSUSE-Leap-15.0-GNOME-Live-x86_64-Current.iso" ;;
    "oracle" | "oraclelinux" | "oracle-linux" )
      name="Oracle Linux"
      url="https://yum.oracle.com/ISOS/OracleLinux/OL9/u5/x86_64/OracleLinux-R9-U5-x86_64-boot.iso"
      arm="https://yum.oracle.com/ISOS/OracleLinux/OL9/u5/aarch64/OracleLinux-R9-U5-aarch64-boot-uek.iso" ;;
    "rocky" | "rockylinux" | "rocky-linux" )
      name="Rocky Linux"
      url="https://dl.rockylinux.org/pub/rocky/9/live/x86_64/Rocky-9-Workstation-x86_64-latest.iso"
      arm="https://dl.rockylinux.org/pub/rocky/9/live/aarch64/Rocky-9-Workstation-aarch64-latest.iso" ;;
    "slack" | "slackware" )
      name="Slackware"
      url="https://slackware.nl/slackware-live/slackware64-15.0-live/slackware64-live-15.0.iso" ;;
    "tails" )
      name="Tails"
      url="https://download.tails.net/tails/stable/tails-amd64-6.13/tails-amd64-6.13.img" ;;
    "ubuntu" | "ubuntu-desktop" )
      name="Ubuntu Desktop"
      url="https://releases.ubuntu.com/24.04.2/ubuntu-24.04.2-desktop-amd64.iso"
      arm="https://cdimage.ubuntu.com/ubuntu/releases/24.10/release/ubuntu-24.10-desktop-arm64.iso" ;;
    "ubuntus" | "ubuntu-server")
      name="Ubuntu Server"
      url="https://releases.ubuntu.com/24.04.2/ubuntu-24.04.2-live-server-amd64.iso"
      arm="https://cdimage.ubuntu.com/releases/24.04/release/ubuntu-24.04.2-live-server-arm64.iso" ;;
    "windows" )
      name="Windows"
      error "To install $name use: https://github.com/dockur/windows" && return 1 ;;
    "xubuntu" )
      name="Xubuntu"
      url="https://mirror.us.leaseweb.net/ubuntu-cdimage/xubuntu/releases/24.04/release/xubuntu-24.04.2-desktop-amd64.iso" ;;
  esac

  if [[ "${ARCH,,}" != "arm64" ]]; then
    if [ -n "$name" ] && [ -z "$url" ]; then
      error "No image for $name available!"
      return 1
    fi
  else
    if [ -n "$name" ] && [ -z "$arm" ]; then
      error "No image for $name is available for ARM64 yet! "
      return 1
    fi
  fi

  case "${ret,,}" in
    "test" )
      ;;
    "name" )
      echo "$name"
      ;;
    *)
      if [[ "${ARCH,,}" != "arm64" ]]; then
        echo "$url"
      else
        echo "$arm"
      fi ;;
  esac

  return 0
}

return 0
