#!/usr/bin/env bash
set -Eeuo pipefail

: "${QMP:=""}"
: "${UUID:=""}"
: "${HPET:="off"}"
: "${VMPORT:="off"}"
: "${SOUND:="intel-hda"}"
: "${SERIAL:="mon:stdio"}"
: "${USB:="qemu-xhci,id=xhci,p2=7,p3=7"}"
: "${SMP:="$CPU_CORES,sockets=1,dies=1,cores=$CPU_CORES,threads=1"}"
: "${MONITOR:="unix:$QEMU_DIR/monitor.sock,server=on,wait=off,nodelay=on"}"

msg="Configuring QEMU..."
enabled "$DEBUG" && echo "$msg"

DEV_OPTS=""
AUDIO_OPTS=""
DEF_OPTS="-nodefaults"

configureProcessor() {

  CPU_OPTS="-cpu $CPU_FLAGS -smp $SMP"

  return 0
}

configureMemory() {

  RAM_OPTS=$(echo "-m ${RAM_SIZE^^}" | sed 's/MB/M/g;s/GB/G/g;s/TB/T/g')

  return 0
}

configureSerial() {

  # Interactive graceful shutdown needs a socket-backed serial relay; otherwise
  # QEMU may own the terminal directly through the configured SERIAL backend.
  if enabled "${SHUTDOWN:-}" && interactive; then
    SERIAL_OPTS="-chardev socket,id=console0,path=$CONSOLE_SOCKET,reconnect-ms=1000"
    SERIAL_OPTS+=" -serial chardev:console0"
  else
    SERIAL_OPTS="-serial $SERIAL"
  fi

  return 0
}

configureMonitor() {

  MON_OPTS=""
  [ -n "$QMP" ] && MON_OPTS+=" -qmp $QMP"
  [ -n "$MONITOR" ] && MON_OPTS+=" -monitor $MONITOR"

  # Keep the user monitor and the automation monitor separate; power and
  # boot-key helpers need a private socket they can control safely.
  if enabled "$SHUTDOWN" && [ -n "${ACPI_SOCKET:-}" ]; then
    MON_OPTS+=" -monitor unix:$ACPI_SOCKET,server=on,wait=off,nodelay=on"
  fi

  MON_OPTS+=" -name $PROCESS,process=$PROCESS,debug-threads=on"
  MON_OPTS+=" -pidfile $QEMU_PID"
  MON_OPTS="${MON_OPTS# }"

  return 0
}

configureMachine() {

  local smm="off"
  enabled "$SMM" && smm="on"

  MAC_OPTS="-machine type=${MACHINE},smm=${smm},graphics=off"
  disabled "$USB" && MAC_OPTS+=",usb=off"
  MAC_OPTS+=",vmport=${VMPORT},dump-guest-core=off,hpet=${HPET}${KVM_OPTS}"

  UUID=$(strip "$UUID")
  [ -n "$UUID" ] && MAC_OPTS+=" -uuid $UUID"
  [ -n "$SM_BIOS" ] && MAC_OPTS+=" $SM_BIOS"

  return 0
}

configureVirtioDevices() {

  local bus
  bus=$(getPciBus)

  DEV_OPTS="-object rng-random,id=objrng0,filename=/dev/urandom"
  DEV_OPTS+=" -device virtio-rng-pci,rng=objrng0,id=rng0,bus=$bus"

  # Windows receives no balloon device by default because the guest driver is not
  # guaranteed to be present; explicitly enabling ballooning opts into it.
  if [[ "${BOOT_MODE,,}" != "windows"* ]] || enabled "${BALLOONING:-}"; then
    if ! enabled "${BALLOONING:-}"; then
      DEV_OPTS+=" -device virtio-balloon-pci,id=balloon0,bus=$bus"
    else
      MON_OPTS+=" -qmp unix:${BALLOONING_SOCKET},server=on,wait=off"
      DEV_OPTS+=" -device virtio-balloon-pci,free-page-reporting=on,guest-stats-polling-interval=1,id=balloon0,bus=$bus"
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
  enabled "${AUDIO:-N}" || return 0

  if [ -z "${AUDIO_FIFO:-}" ] || [ ! -p "$AUDIO_FIFO" ]; then
    warn "Audio support failed to initialize, ignoring AUDIO=Y."
    return 0
  fi

  local sound="$SOUND"
  local model="${sound%%,*}"

  AUDIO_OPTS+=" -audiodev wav,id=snd,path=$AUDIO_FIFO,out.frequency=48000,out.channels=2,out.format=s16"

  # A USB audio device needs a compatible controller even when the main USB
  # setting uses EHCI or is disabled.
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

configureCompatibility() {

  CMP_OPTS=""

  case "${BOOT_MODE,,}" in
    "legacy" | "windows_legacy" | "custom" )
      return 0 ;;
  esac

  # OVMF guests receive the TianoCore memory-attribute compatibility switch;
  # legacy and custom firmware do not implement this fw_cfg option.
  CMP_OPTS="-fw_cfg name=opt/org.tianocore/UninstallMemAttrProtocol,string=y"

  return 0
}

buildArguments() {

  # Keep the final command as a normalized argument string because entry.sh
  # intentionally expands user-supplied ARGUMENTS together with generated flags.
  ARGS="$DEF_OPTS $CPU_OPTS $RAM_OPTS $MAC_OPTS $DISPLAY_OPTS $MON_OPTS $SERIAL_OPTS ${USB_OPTS:-} $NET_OPTS $DISK_OPTS $BOOT_OPTS $DEV_OPTS $AUDIO_OPTS $CMP_OPTS $ARGUMENTS"
  ARGS=$(echo "$ARGS" | sed 's/\t/ /g' | tr -s ' ')

  return 0
}

finalizeMemory

configureMemory
configureSerial
configureMonitor
configureMachine
configureProcessor

configureVirtioDevices
configureSharedFolder
configureUsb
configureAudio
configureCompatibility

buildArguments

return 0
