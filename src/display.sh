#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: "${GPU:="N"}"         # GPU acceleration
: "${VGA:="virtio"}"    # VGA adaptor
: "${DISPLAY:="web"}"   # Display type
: "${LOSSY:="N"}"       # Lossy VNC compression
: "${VNC_PORT:="5900"}" # VNC port
: "${RENDERNODE:="/dev/dri/renderD128"}"  # Render node

# Sanitize variables
VGA=$(strip "$VGA")
LOSSY=$(strip "$LOSSY")
DISPLAY=$(strip "$DISPLAY")
VNC_PORT=$(strip "$VNC_PORT")
RENDERNODE=$(strip "$RENDERNODE")
WSS_SOCKET="${WSS_SOCKET:-$QEMU_DIR/vnc-ws.sock}"

port=$(( VNC_PORT - 5900 ))

# Preserve the historic :0 setting as an alias for the managed web display.
[[ "$DISPLAY" == ":0" ]] && DISPLAY="web"

LOSSY_OPT=""
enabled "$LOSSY" && LOSSY_OPT=",lossy=on"

case "${DISPLAY,,}" in

  "vnc" )
    DISPLAY_OPTS="-display vnc=:${port}${LOSSY_OPT} -vga ${VGA}" ;;
  "web" )
    DISPLAY_OPTS="-display vnc=:${port},websocket=unix:${WSS_SOCKET}${LOSSY_OPT} -vga ${VGA}" ;;
  "disabled" )
    DISPLAY_OPTS="-display none -vga ${VGA}" ;;
  "none" )
    DISPLAY_OPTS="-display none -vga none" ;;
  *)
    DISPLAY_OPTS="-display ${DISPLAY} -vga ${VGA}" ;;

esac

enabled "$GPU" || return 0

if [[ "$ARCH" != "amd64" ]]; then
  warn "GPU acceleration is only supported for the AMD64 platform, ignoring GPU=Y."
  return 0
fi

RENDER_NAME="${RENDERNODE##*/}"

if [[ ! "$RENDER_NAME" =~ ^renderD([0-9]+)$ ]]; then
  warn "invalid render node '$RENDERNODE', ignoring GPU=Y."
  return 0
fi

CARD_NUMBER="${BASH_REMATCH[1]}"
VENDOR_FILE="/sys/class/drm/${RENDER_NAME}/device/vendor"

if [ ! -r "$VENDOR_FILE" ]; then
  warn "cannot determine the GPU vendor for '$RENDERNODE', ignoring GPU=Y."
  return 0
fi

GPU_VENDOR=$(< "$VENDOR_FILE")
case "${GPU_VENDOR,,}" in
  "0x8086" | "0x1002" ) ;;
  * )
    warn "GPU acceleration is only supported for Intel and AMD GPUs, ignoring GPU=Y."
    return 0 ;;
esac

case "${APP:-}" in
  "Windows" | "macOS" )
    warn "GPU acceleration is not supported for $APP, but feel free to experiment." ;;
esac

msg="Configuring display drivers..."
enabled "$DEBUG" && echo "$msg"

[[ "${VGA,,}" == "virtio" ]] && VGA="virtio-vga-gl"
DISPLAY_OPTS="-display egl-headless,rendernode=$RENDERNODE"
DISPLAY_OPTS+=" -device $VGA"

[[ "${DISPLAY,,}" == "vnc" ]] && DISPLAY_OPTS+=" -vnc :${port}${LOSSY_OPT}"
[[ "${DISPLAY,,}" == "web" ]] && DISPLAY_OPTS+=" -vnc :${port},websocket=unix:${WSS_SOCKET}${LOSSY_OPT}"

[ ! -d /dev/dri ] && mkdir -m 755 /dev/dri

# Derive the matching DRM card from the validated render node number.
CARD_DEVICE="/dev/dri/card$((CARD_NUMBER - 128))"

# Containers normally have no udev, so reconstruct the matching DRM card and
# render character devices from the render-node minor number when necessary.
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

if [ ! -c "$RENDERNODE" ] || [ ! -r "$RENDERNODE" ] || [ ! -w "$RENDERNODE" ]; then
  warn "render device '$RENDERNODE' is unavailable or inaccessible."
fi

return 0
