#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: "${GPU:="N"}"         # GPU acceleration
: "${VGA:="virtio"}"    # VGA adaptor
: "${DISPLAY:="web"}"   # Display type
: "${LOSSY:="N"}"       # Lossy VNC compression
: "${VNC_PORT:="5900"}" # VNC port
: "${RENDERNODE:=""}"   # Render node

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

msg="Configuring display drivers..."
enabled "$DEBUG" && echo "$msg"

if [[ "$ARCH" != "amd64" ]]; then
  warn "GPU acceleration is only supported for the AMD64 platform, ignoring GPU=Y."
  return 0
fi

# Return the PCI vendor for a usable DRM render node. Any malformed, missing,
# inaccessible or disappearing node is rejected without aborting display setup.

gpuNodeVendor() {

  local node="$1"

  local render_name="${node##*/}"
  [[ "$render_name" =~ ^renderD[0-9]{3}$ ]] || return 1

  local render_number="${render_name#renderD}"
  (( 10#$render_number >= 128 )) || return 1
  [ -c "$node" ] || return 1

  local gpu_fd
  if ! { exec {gpu_fd}<>"$node"; } 2>/dev/null; then
    return 1
  fi

  { exec {gpu_fd}>&-; } 2>/dev/null || true

  local vendor_file="/sys/class/drm/${render_name}/device/vendor"
  [ -r "$vendor_file" ] || return 1

  if ! IFS= read -r GPU_VENDOR < "$vendor_file"; then
    return 1
  fi

  GPU_VENDOR="${GPU_VENDOR,,}"
  return 0
}

# NVIDIA uses the proprietary host driver injected by NVIDIA Container Toolkit
# rather than a Mesa Gallium driver from qemu-minimal. Require the complete EGL
# and GBM path before selecting an NVIDIA render node.

nvidiaGpuReady() {

  local modeset=""
  NVIDIA_REASON=""

  if ! compgen -G '/usr/lib/*/libEGL_nvidia.so.*' >/dev/null 2>&1 \
      && ! compgen -G '/usr/lib/libEGL_nvidia.so.*' >/dev/null 2>&1 \
      && ! compgen -G '/usr/lib64/libEGL_nvidia.so.*' >/dev/null 2>&1; then
    NVIDIA_REASON="the NVIDIA EGL driver is not available in the container"
    return 1
  fi

  if ! compgen -G '/usr/lib/*/libnvidia-egl-gbm.so.*' >/dev/null 2>&1 \
      && ! compgen -G '/usr/lib/libnvidia-egl-gbm.so.*' >/dev/null 2>&1 \
      && ! compgen -G '/usr/lib64/libnvidia-egl-gbm.so.*' >/dev/null 2>&1; then
    NVIDIA_REASON="the NVIDIA EGL GBM platform library is not available in the container"
    return 1
  fi

  if ! compgen -G '/usr/lib/*/gbm/nvidia-drm_gbm.so' >/dev/null 2>&1 \
      && [ ! -e /usr/lib/gbm/nvidia-drm_gbm.so ] \
      && [ ! -e /usr/lib64/gbm/nvidia-drm_gbm.so ]; then
    NVIDIA_REASON="the NVIDIA GBM backend is not available in the container"
    return 1
  fi

  if [ ! -r /usr/share/glvnd/egl_vendor.d/10_nvidia.json ] \
      || [ ! -r /usr/share/egl/egl_external_platform.d/15_nvidia_gbm.json ]; then
    NVIDIA_REASON="the NVIDIA EGL vendor configuration is not available in the container"
    return 1
  fi

  if [ ! -r /sys/module/nvidia_drm/parameters/modeset ] \
      || ! IFS= read -r modeset < /sys/module/nvidia_drm/parameters/modeset; then
    NVIDIA_REASON="the nvidia-drm KMS state cannot be determined"
    return 1
  fi

  case "${modeset,,}" in
    "y" | "1" ) ;;
    * )
      NVIDIA_REASON="nvidia-drm modesetting is disabled"
      return 1 ;;
  esac

  return 0
}

GPU_VENDOR=""
NVIDIA_NODE=""
NVIDIA_REASON=""
fail="falling back to software rendering."

if [ -n "$RENDERNODE" ]; then

  if ! gpuNodeVendor "$RENDERNODE"; then
    warn "GPU render node '$RENDERNODE' is unavailable or inaccessible; $fail"
    return 0
  fi

  case "$GPU_VENDOR" in
    "0x8086" | "0x1002" ) ;;
    "0x10de" )
      if ! nvidiaGpuReady; then
        warn "NVIDIA GPU at $RENDERNODE cannot be used for hardware rendering because $NVIDIA_REASON; $fail"
        return 0
      fi ;;
    * )
      warn "unsupported GPU at $RENDERNODE; $fail"
      return 0 ;;
  esac

else

  for node in /dev/dri/renderD*; do

    if ! gpuNodeVendor "$node"; then
      continue
    fi

    case "$GPU_VENDOR" in
      "0x8086" | "0x1002" )
        RENDERNODE="$node"
        break ;;
      "0x10de" )
        NVIDIA_NODE="$node"
        if nvidiaGpuReady; then
          RENDERNODE="$node"
          break
        fi ;;
    esac

  done

  if [ -z "$RENDERNODE" ]; then

    if [ -n "$NVIDIA_NODE" ] && [ -n "$NVIDIA_REASON" ]; then
      warn "NVIDIA GPU at $NVIDIA_NODE cannot be used for hardware rendering because $NVIDIA_REASON; $fail"
    else
      warn "no usable GPU render node found; $fail"
    fi

    return 0
  fi

fi

# Re-read the selected node after auto-detection so the vendor name and device
# number below are based on the final render node and survive hotplug races.
if ! gpuNodeVendor "$RENDERNODE"; then
  warn "GPU render node '$RENDERNODE' became unavailable; $fail"
  return 0
fi

RENDER_NAME="${RENDERNODE##*/}"
CARD_NUMBER="${RENDER_NAME#renderD}"

case "$GPU_VENDOR" in
  "0x8086" ) GPU_NAME="Intel" ;;
  "0x1002" ) GPU_NAME="AMD" ;;
  "0x10de" ) GPU_NAME="NVIDIA" ;;
  * ) GPU_NAME="GPU" ;;
esac

info "Hardware rendering enabled on $GPU_NAME render node $RENDERNODE."

if [ ! -d /dev/dri ]; then
  mkdir -m 755 /dev/dri 2>/dev/null || true
fi

# Derive the matching DRM card from the validated render node number.
CARD_DEVICE="/dev/dri/card$((10#$CARD_NUMBER - 128))"

# Containers normally have no udev, so reconstruct the matching DRM card and
# render character devices from the render-node minor number when necessary.
if [ ! -c "$CARD_DEVICE" ]; then
  if mknod "$CARD_DEVICE" c 226 $((10#$CARD_NUMBER - 128)) 2>/dev/null; then
    chmod 666 "$CARD_DEVICE" 2>/dev/null || true
  fi
fi

if [ ! -c "$RENDERNODE" ]; then
  if mknod "$RENDERNODE" c 226 "$((10#$CARD_NUMBER))" 2>/dev/null; then
    chmod 666 "$RENDERNODE" 2>/dev/null || true
  fi
fi

if ! gpuNodeVendor "$RENDERNODE"; then
  warn "GPU render node '$RENDERNODE' became unavailable; $fail"
  return 0
fi

[[ "${VGA,,}" == "virtio" ]] && VGA="virtio-vga-gl"
DISPLAY_OPTS="-display egl-headless,rendernode=$RENDERNODE"
DISPLAY_OPTS+=" -device $VGA"

[[ "${DISPLAY,,}" == "vnc" ]] && DISPLAY_OPTS+=" -vnc :${port}${LOSSY_OPT}"
[[ "${DISPLAY,,}" == "web" ]] && DISPLAY_OPTS+=" -vnc :${port},websocket=unix:${WSS_SOCKET}${LOSSY_OPT}"

return 0
