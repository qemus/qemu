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
    "cachy" | "cachyos" )
      name="CachyOS"
      url="https://cdn77.cachyos.org/ISO/desktop/250202/cachyos-desktop-linux-250202.iso" ;;
    "centos" )
      name="CentOS Stream"
      url="https://mirrors.xtom.de/centos-stream/10-stream/BaseOS/x86_64/iso/CentOS-Stream-10-latest-x86_64-dvd1.iso" ;;
    "debian" )
      name="Debian"
      url="https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/debian-live-12.9.0-amd64-gnome.iso" ;;
    "endeavour" | "endeavouros" )
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
    "macos" | "osx" )
      error "To install macOS use: https://github.com/dockur/macos" && exit 34 ;;
    "mint" | "linuxmint" )
      name="Linux Mint"
      url="https://mirrors.layeronline.com/linuxmint/stable/22.1/linuxmint-22.1-cinnamon-64bit.iso" ;;
    "manjaro" )
      name="Manjaro"
      url="https://download.manjaro.org/kde/24.2.1/manjaro-kde-24.2.1-241216-linux612.iso" ;;
    "mx" )
      name="MX Linux"
      url="https://mirror.umd.edu/mxlinux-iso/MX/Final/Xfce/MX-23.5_x64.iso" ;;
    "nixos" )
      name="NixOS"
      url="https://channels.nixos.org/nixos-24.11/latest-nixos-gnome-x86_64-linux.iso" ;;
    "opensuse" | "suse" )
      name="OpenSUSE"
      url="https://download.opensuse.org/distribution/leap/15.0/live/openSUSE-Leap-15.0-GNOME-Live-x86_64-Current.iso" ;;
    "oracle" )
      name="Oracle Linux"
      url="https://yum.oracle.com/ISOS/OracleLinux/OL9/u5/x86_64/OracleLinux-R9-U5-x86_64-boot.iso" ;;
    "rocky" )
      name="Rocky Linux"
      url="https://dl.rockylinux.org/pub/rocky/9/live/x86_64/Rocky-9-Workstation-x86_64-latest.iso" ;;
    "slack" | "slackware" )
      name="Slackware"
      url="https://slackware.nl/slackware-live/slackware64-15.0-live/slackware64-live-15.0.iso" ;;
    "tails" )
      name="Tails"
      url="https://download.tails.net/tails/stable/tails-amd64-6.13/tails-amd64-6.13.img" ;;
    "ubuntu" | "ubuntu-desktop" )
      name="Ubuntu Desktop"
      url="https://releases.ubuntu.com/24.04.2/ubuntu-24.04.2-desktop-amd64.iso" ;;
    "ubuntus" | "ubuntu-server")
      name="Ubuntu Server"
      url="https://releases.ubuntu.com/24.04.2/ubuntu-24.04.2-live-server-amd64.iso" ;;
    "windows" )
      error "To install Windows use: https://github.com/dockur/windows" && exit 34 ;;
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

return 0
