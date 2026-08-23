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

VGA_OPT="-vga ${VGA}"
if [[ "${VGA,,}" == "std,"* ]]; then
  VGA_OPT="-device VGA,${VGA#*,}"
fi

case "${DISPLAY,,}" in

  "vnc" )
    DISPLAY_OPTS="-display vnc=:${port}${LOSSY_OPT} ${VGA_OPT}" ;;
  "web" )
    DISPLAY_OPTS="-display vnc=:${port},websocket=unix:${WSS_SOCKET}${LOSSY_OPT} ${VGA_OPT}" ;;
  "disabled" )
    DISPLAY_OPTS="-display none ${VGA_OPT}" ;;
  "none" )
    DISPLAY_OPTS="-display none -vga none" ;;
  *)
    DISPLAY_OPTS="-display ${DISPLAY} ${VGA_OPT}" ;;

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

# Venus requires a Vulkan userspace driver in addition to the normal EGL/GBM
# rendering path. Keep this separate so normal VirGL/OpenGL does not require Vulkan.

venusEnabled() {

  [[ ",${VGA,,}," =~ ,venus=(on|true|yes|1), ]]
}

vulkanLibraryAvailable() {

  local library="$1"

  compgen -G "/usr/lib/*/${library}" >/dev/null 2>&1 \
    || [ -e "/usr/lib/${library}" ] \
    || [ -e "/usr/lib64/${library}" ]
}

vulkanManifestAvailable() {

  local manifest="$1"

  compgen -G "/etc/vulkan/icd.d/${manifest}*.json" >/dev/null 2>&1 \
    || compgen -G "/usr/share/vulkan/icd.d/${manifest}*.json" >/dev/null 2>&1
}

mesaVulkanReady() {

  local vendor="$1"
  local library manifest
  VULKAN_REASON=""

  if ! vulkanLibraryAvailable "libvulkan.so.1"; then
    VULKAN_REASON="the Vulkan loader is not available in the container"
    return 1
  fi

  case "$vendor" in
    "0x8086" )
      for library in libvulkan_intel.so libvulkan_intel_hasvk.so; do
        if ! vulkanLibraryAvailable "$library"; then
          VULKAN_REASON="the Intel Vulkan driver library '$library' is not available in the container"
          return 1
        fi
      done

      for manifest in intel_icd intel_hasvk_icd; do
        if ! vulkanManifestAvailable "$manifest"; then
          VULKAN_REASON="the Intel Vulkan ICD '$manifest' is not available in the container"
          return 1
        fi
      done ;;

    "0x1002" )
      if ! vulkanLibraryAvailable "libvulkan_radeon.so"; then
        VULKAN_REASON="the AMD Vulkan driver library 'libvulkan_radeon.so' is not available in the container"
        return 1
      fi

      if ! vulkanManifestAvailable "radeon_icd"; then
        VULKAN_REASON="the AMD Vulkan ICD 'radeon_icd' is not available in the container"
        return 1
      fi ;;
  esac

  return 0
}

# NVIDIA uses the proprietary host driver injected by NVIDIA Container Toolkit
# rather than a Mesa Gallium driver from qemu-minimal. Require the complete EGL
# and GBM path before selecting an NVIDIA render node. Venus additionally needs
# the Vulkan loader, NVIDIA ICD and NVIDIA Vulkan userspace libraries.

nvidiaDriverVersion() {

  local data=""
  NVIDIA_DRIVER_VERSION=""

  if [ -r /proc/driver/nvidia/version ]; then
    data="$(head -n 1 /proc/driver/nvidia/version 2>/dev/null || true)"
  elif [ -r /sys/module/nvidia/version ]; then
    data="$(cat /sys/module/nvidia/version 2>/dev/null || true)"
  fi

  if [[ "$data" =~ ([0-9]{3,})\.([0-9]+)(\.[0-9]+)? ]]; then
    NVIDIA_DRIVER_VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}${BASH_REMATCH[3]:-}"
    return 0
  fi

  return 1
}

nvidiaVulkanReady() {

  local icd=""
  local major minor

  if ! nvidiaDriverVersion; then
    NVIDIA_REASON="the NVIDIA driver version cannot be determined"
    return 1
  fi

  [[ "$NVIDIA_DRIVER_VERSION" =~ ^([0-9]+)\.([0-9]+) ]] || return 1
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"

  if (( major < 570 || (major == 570 && minor < 86) )); then
    NVIDIA_REASON="NVIDIA driver $NVIDIA_DRIVER_VERSION is older than the 570.86 minimum required by Venus"
    return 1
  fi

  if ! compgen -G '/usr/lib/*/libvulkan.so.1' >/dev/null 2>&1 \
      && [ ! -e /usr/lib/libvulkan.so.1 ] \
      && [ ! -e /usr/lib64/libvulkan.so.1 ]; then
    NVIDIA_REASON="the Vulkan loader is not available in the container"
    return 1
  fi

  for icd in /etc/vulkan/icd.d/nvidia_icd*.json /usr/share/vulkan/icd.d/nvidia_icd*.json; do
    [ -r "$icd" ] && break
    icd=""
  done

  if [ -z "$icd" ]; then
    NVIDIA_REASON="the NVIDIA Vulkan ICD is not available in the container"
    return 1
  fi

  if ! compgen -G '/usr/lib/*/libGLX_nvidia.so.*' >/dev/null 2>&1 \
      && ! compgen -G '/usr/lib/*/nvidia/*/libGLX_nvidia.so.*' >/dev/null 2>&1 \
      && ! compgen -G '/usr/lib/nvidia/*/libGLX_nvidia.so.*' >/dev/null 2>&1 \
      && ! compgen -G '/usr/lib/libGLX_nvidia.so.*' >/dev/null 2>&1 \
      && ! compgen -G '/usr/lib64/nvidia/*/libGLX_nvidia.so.*' >/dev/null 2>&1 \
      && ! compgen -G '/usr/lib64/libGLX_nvidia.so.*' >/dev/null 2>&1; then
    NVIDIA_REASON="the NVIDIA Vulkan driver library is not available in the container"
    return 1
  fi

  if ! compgen -G '/usr/lib/*/libnvidia-glvkspirv.so.*' >/dev/null 2>&1 \
      && ! compgen -G '/usr/lib/*/nvidia/*/libnvidia-glvkspirv.so.*' >/dev/null 2>&1 \
      && ! compgen -G '/usr/lib/nvidia/*/libnvidia-glvkspirv.so.*' >/dev/null 2>&1 \
      && ! compgen -G '/usr/lib/libnvidia-glvkspirv.so.*' >/dev/null 2>&1 \
      && ! compgen -G '/usr/lib64/nvidia/*/libnvidia-glvkspirv.so.*' >/dev/null 2>&1 \
      && ! compgen -G '/usr/lib64/libnvidia-glvkspirv.so.*' >/dev/null 2>&1; then
    NVIDIA_REASON="the NVIDIA Vulkan SPIR-V compiler library is not available in the container"
    return 1
  fi

  return 0
}

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

  if venusEnabled && ! nvidiaVulkanReady; then
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
VULKAN_NODE=""
VULKAN_REASON=""
fail="falling back to software rendering."

if [ -n "$RENDERNODE" ]; then

  if ! gpuNodeVendor "$RENDERNODE"; then
    warn "GPU render node '$RENDERNODE' is unavailable or inaccessible; $fail"
    return 0
  fi

  case "$GPU_VENDOR" in
    "0x8086" | "0x1002" )
      if venusEnabled && ! mesaVulkanReady "$GPU_VENDOR"; then
        warn "GPU at $RENDERNODE cannot be used for Venus because $VULKAN_REASON; $fail"
        return 0
      fi ;;
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
        if ! venusEnabled || mesaVulkanReady "$GPU_VENDOR"; then
          RENDERNODE="$node"
          break
        fi
        VULKAN_NODE="$node" ;;
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
    elif [ -n "$VULKAN_NODE" ] && [ -n "$VULKAN_REASON" ]; then
      warn "GPU at $VULKAN_NODE cannot be used for Venus because $VULKAN_REASON; $fail"
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

modernVirtioGpuGuest() {

  [[ "${APP,,}" == "qemu" ]] && return 0

  return 1
}

hostBlobsSupported() {

  local version major minor
  version="$(uname -r)"

  [[ "$version" =~ ^([0-9]+)\.([0-9]+) ]] || return 1
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"

  (( major > 6 || (major == 6 && minor >= 13) ))
}

case "${VGA,,}" in
  "virtio" )
    if ! modernVirtioGpuGuest; then
      VGA="virtio-vga-gl"
    elif hostBlobsSupported; then
      VGA="virtio-vga-gl,hostmem=8G,blob=true"

      case "$GPU_VENDOR" in
        "0x8086" | "0x1002" )
          if mesaVulkanReady "$GPU_VENDOR"; then
            VGA+=",venus=true"
          else
            warn "Vulkan acceleration could not be enabled because $VULKAN_REASON; continuing with OpenGL 4.6."
          fi ;;
        "0x10de" )
          if nvidiaVulkanReady; then
            VGA+=",venus=true"
          else
            warn "Vulkan acceleration could not be enabled because $NVIDIA_REASON; continuing with OpenGL 4.6."
          fi ;;
      esac
    else
      echo
      info "Host kernel $(uname -r) does not support virtio-gpu host blobs; OpenGL is limited to 4.3."
      info "Upgrade the host kernel to 6.13 or newer to enable OpenGL 4.6 and Vulkan acceleration."
      echo
      VGA="virtio-vga-gl"
    fi ;;
  "std,"* ) VGA="VGA,${VGA#*,}" ;;
esac

DISPLAY_OPTS="-display egl-headless,rendernode=$RENDERNODE"
DISPLAY_OPTS+=" -device $VGA"

[[ "${DISPLAY,,}" == "vnc" ]] && DISPLAY_OPTS+=" -vnc :${port}${LOSSY_OPT}"
[[ "${DISPLAY,,}" == "web" ]] && DISPLAY_OPTS+=" -vnc :${port},websocket=unix:${WSS_SOCKET}${LOSSY_OPT}"

return 0
