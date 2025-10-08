#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: "${GPU:="N"}"         # GPU passthrough
: "${VGA:="virtio"}"    # VGA adaptor
: "${DISPLAY:="web"}"   # Display type
: "${RENDERNODE:="/dev/dri/renderD128"}"  # Render node

port=$(( VNC_PORT - 5900 ))
[[ "$DISPLAY" == ":0" ]] && DISPLAY="web"

case "${DISPLAY,,}" in
  "vnc" )
    DISPLAY_OPTS="-display vnc=:$port -vga $VGA"
    ;;
  "web" )
    DISPLAY_OPTS="-display vnc=:$port,websocket=$WSS_PORT -vga $VGA"
    ;;
  "disabled" )
    DISPLAY_OPTS="-display none -vga $VGA"
    ;;
  "none" )
    DISPLAY_OPTS="-display none -vga none"
    ;;
  *)
    DISPLAY_OPTS="-display $DISPLAY -vga $VGA"
    ;;
esac

if [[ "$GPU" != [Yy1]* || "$ARCH" != "amd64" ]]; then
  return 0
fi

CPU_VENDOR=$(lscpu | awk '/Vendor ID/{print $3}')

if [[ "$CPU_VENDOR" != "GenuineIntel" ]]; then
  return 0
fi

msg="Configuring display drivers..."
html "$msg"
[[ "$DEBUG" == [Yy1]* ]] && echo "$msg"

[[ "${VGA,,}" == "virtio" ]] && VGA="virtio-vga-gl"
DISPLAY_OPTS="-display egl-headless,rendernode=$RENDERNODE"
DISPLAY_OPTS+=" -device $VGA"

[[ "${DISPLAY,,}" == "vnc" ]] && DISPLAY_OPTS+=" -vnc :$port"
[[ "${DISPLAY,,}" == "web" ]] && DISPLAY_OPTS+=" -vnc :$port,websocket=$WSS_PORT"

[ ! -d /dev/dri ] && mkdir -m 755 /dev/dri

# Extract the card number from the render node
CARD_NUMBER=$(echo "$RENDERNODE" | grep -oP '(?<=renderD)\d+')
CARD_DEVICE="/dev/dri/card$((CARD_NUMBER - 128))"

if [ ! -c "$CARD_DEVICE" ]; then
  if mknod "$CARD_DEVICE" c 226 $((CARD_NUMBER - 128)); then
    chmod 666 "$CARD_DEVICE"
  fi
fi

if [ ! -c "$RENDERNODE" ]; then
  if mknod "$RENDERNODE" c 226 "$CARD_NUMBER"; then
    chmod 666 "$RENDERNODE"
  fi
fi

addPackage "xserver-xorg-video-intel" "Intel GPU drivers"
addPackage "qemu-system-modules-opengl" "OpenGL module"

return 0
