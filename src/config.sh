#!/usr/bin/env bash
set -Eeuo pipefail

: "${UUID:=""}"
: "${HPET:="off"}"
: "${VMPORT:="off"}"
: "${SOUND:="intel-hda"}"
: "${SERIAL:="mon:stdio"}"
: "${USB:="qemu-xhci,id=xhci,p2=7,p3=7"}"
: "${MONITOR:="unix:$QEMU_DIR/monitor.sock,server,wait=off,nodelay"}"
: "${SMP:="$CPU_CORES,sockets=1,dies=1,cores=$CPU_CORES,threads=1"}"

msg="Configuring QEMU..."
html "$msg"
enabled "$DEBUG" && echo "$msg"

DEV_OPTS=""
AUDIO_OPTS=""
DEF_OPTS="-nodefaults"

if enabled "${SHUTDOWN:-}" && interactive; then
  SERIAL_OPTS="-chardev socket,id=console0,path=$CONSOLE_SOCKET,reconnect-ms=1000"
  SERIAL_OPTS+=" -serial chardev:console0"
else
  SERIAL_OPTS="-serial $SERIAL"
fi

CPU_OPTS="-cpu $CPU_FLAGS -smp $SMP"
RAM_OPTS=$(echo "-m ${RAM_SIZE^^}" | sed 's/MB/M/g;s/GB/G/g;s/TB/T/g')
MON_OPTS="-monitor $MONITOR -name $PROCESS,process=$PROCESS,debug-threads=on -pidfile $QEMU_PID"
MAC_OPTS="-machine type=${MACHINE},smm=${SECURE},graphics=off,vmport=${VMPORT},dump-guest-core=off,hpet=${HPET}${KVM_OPTS}"

configureMachineOptions() {

  UUID=$(strip "$UUID")
  [ -n "$UUID" ] && MAC_OPTS+=" -uuid $UUID"
  [ -n "$SM_BIOS" ] && MAC_OPTS+=" $SM_BIOS"

  return 0
}

configureVirtioDevices() {

  local BUS="${PCI_BUS:-pcie.0}"
  [[ -z "${PCI_BUS:-}" && ( "${MACHINE,,}" == pc || "${MACHINE,,}" == pc-i440fx* ) ]] && BUS="pci.0"

  DEV_OPTS="-object rng-random,id=objrng0,filename=/dev/urandom"
  DEV_OPTS+=" -device virtio-rng-pci,rng=objrng0,id=rng0,bus=$BUS"

  if [[ "${BOOT_MODE,,}" != "windows"* ]] || enabled "${BALLOONING:-}"; then
    if ! enabled "${BALLOONING:-}"; then
      DEV_OPTS+=" -device virtio-balloon-pci,id=balloon0,bus=$BUS"
    else
      MON_OPTS+=" -qmp unix:${BALLOONING_SOCKET},server,nowait"
      DEV_OPTS+=" -device virtio-balloon-pci,free-page-reporting=on,guest-stats-polling-interval=1,id=balloon0,bus=$BUS"
    fi
  fi

  return 0
}

configureSharedFolder() {

  if [ -d "/shared" ] && [[ "${BOOT_MODE,,}" != "windows"* ]]; then
    DEV_OPTS+=" -fsdev local,id=fsdev0,path=/shared,security_model=none"
    DEV_OPTS+=" -device virtio-9p-pci,id=fs0,fsdev=fsdev0,mount_tag=shared"
  fi

  return 0
}

configureUsb() {

  if ! disabled "$USB" && [ -n "$USB" ]; then
    USB_OPTS="-device $USB -device usb-tablet"
  fi

  return 0
}

configureAudio() {

  disabled "${WEB:-}" && return 0
  ! enabled "${AUDIO:-N}" && return 0

  if [ -z "${AUDIO_FIFO:-}" ] || [ ! -p "$AUDIO_FIFO" ]; then
    warn "Audio support failed to initialize, ignoring AUDIO=Y."
    return 0
  fi

  local sound="$SOUND"
  local model="${sound%%,*}"

  AUDIO_OPTS+=" -audiodev wav,id=snd,path=$AUDIO_FIFO,out.frequency=48000,out.channels=2,out.format=s16"

  if [[ "$model" == usb-* ]]; then
    case "${USB,,}" in
      *xhci*|*ohci*|*uhci*)
        ;;
      *ehci*)
        AUDIO_OPTS+=" -device pci-ohci,id=audio-ohci"
        [[ ",$sound," == *,bus=* ]] || sound+=",bus=audio-ohci.0"
        ;;
      *)
        AUDIO_OPTS+=" -device qemu-xhci,id=audio-xhci"
        [[ ",$sound," == *,bus=* ]] || sound+=",bus=audio-xhci.0"
        ;;
    esac
  fi

  case "$model" in
    intel-hda|ich9-intel-hda)
      AUDIO_OPTS+=" -device $sound"
      AUDIO_OPTS+=" -device hda-output,audiodev=snd"
      ;;
    *)
      [[ ",$sound," == *,audiodev=* ]] || sound+=",audiodev=snd"
      AUDIO_OPTS+=" -device $sound"
      ;;
  esac

  return 0
}

buildArguments() {

  ARGS="$DEF_OPTS $CPU_OPTS $RAM_OPTS $MAC_OPTS $DISPLAY_OPTS $MON_OPTS $SERIAL_OPTS ${USB_OPTS:-} $NET_OPTS $DISK_OPTS $BOOT_OPTS $DEV_OPTS $AUDIO_OPTS $ARGUMENTS"
  ARGS=$(echo "$ARGS" | sed 's/\t/ /g' | tr -s ' ')

  return 0
}

configureMachineOptions
configureVirtioDevices
configureSharedFolder

configureUsb
configureAudio

buildArguments

return 0
