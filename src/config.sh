#!/usr/bin/env bash
set -Eeuo pipefail

: "${USB:=""}"
: "${RNG:=""}"
: "${QMP:=""}"
: "${QGA:=""}"
: "${UUID:=""}"
: "${HPET:=""}"
: "${VMPORT:=""}"
: "${MONITOR:=""}"
: "${RAM_BACKEND:=""}"
: "${SOUND:="intel-hda"}"
: "${MOUSE:="usb-tablet"}"
: "${SERIAL:="mon:stdio"}"
: "${SMP:="$CPU_CORES,sockets=1,dies=1,cores=$CPU_CORES,threads=1"}"

msg="Configuring QEMU..."
enabled "$DEBUG" && echo "$msg"

# Sanitize variables
SMP=$(strip "$SMP")
USB=$(strip "$USB")
QMP=$(strip "$QMP")
QGA=$(strip "$QGA")
UUID=$(strip "$UUID")
HPET=$(strip "$HPET")
SOUND=$(strip "$SOUND")
MOUSE=$(strip "$MOUSE")
SERIAL=$(strip "$SERIAL")
VMPORT=$(strip "$VMPORT")
MONITOR=$(strip "$MONITOR")
RAM_BACKEND=$(strip "$RAM_BACKEND")

configureProcessor() {

  CPU_OPTS="-cpu $CPU_FLAGS -smp $SMP"

  return 0
}

configureMemory() {

  local ram
  ram=$(echo "${RAM_SIZE^^}" | sed 's/MB/M/g;s/GB/G/g;s/TB/T/g')

  RAM_OPTS="-m $ram"
  MEM_OPTS=""
  RAM_MACHINE_OPTS=""

  case "${RAM_BACKEND,,}" in
    "" ) ;;
    "memfd" )
      MEM_OPTS="-object memory-backend-memfd,id=ram,size=$ram,share=on"
      RAM_MACHINE_OPTS=",memory-backend=ram" ;;
    * )
      error "Invalid RAM_BACKEND value '$RAM_BACKEND', supported value is 'memfd'."
      exit 78 ;;
  esac

  return 0
}

normalizeSocket() {

  local value="$1"
  local backend="${value%%,*}"

  if [[ "$backend" == *.sock && "$backend" != *:* ]]; then
    value="unix:$value"
    [[ ",$value," == *,server=* ]] || value+=",server=on"
    if [[ ",$value," != *,wait=* ]] && [[ ",$value," != *,server=off,* ]]; then
      value+=",wait=off"
    fi
  fi

  echo "$value"
}

normalizePort() {

  local value="$1"
  local protocol="$2"

  if [[ "$value" =~ ^[0-9]+$ ]]; then
    value="$protocol:0.0.0.0:$value,server=on,wait=off"
  fi

  echo "$value"
}

configureSerial() {

  # Interactive graceful shutdown needs a socket-backed serial relay; otherwise
  # QEMU may own the terminal directly through the configured SERIAL backend.
  if enabled "${SHUTDOWN:-}" && interactive; then
    SERIAL_OPTS="-chardev socket,id=console0,path=$CONSOLE_SOCKET,reconnect-ms=1000"
    SERIAL_OPTS+=" -serial chardev:console0"
  else
    SERIAL=$(normalizePort "$SERIAL" "telnet")
    SERIAL=$(normalizeSocket "$SERIAL")
    SERIAL_OPTS="-serial $SERIAL"
  fi

  return 0
}

configureMonitor() {

  MON_OPTS=""

  # Keep the user monitor and the automation monitor separate; power
  # and boot-key helpers need a private socket they can control safely.
  if [ -n "${ACPI_SOCKET:-}" ]; then
    MON_OPTS+=" -monitor unix:$ACPI_SOCKET,server=on,wait=off,nodelay=on"
  fi

  if [ -n "$MONITOR" ]; then
    MONITOR=$(normalizePort "$MONITOR" "telnet")
    MONITOR=$(normalizeSocket "$MONITOR")
    MON_OPTS+=" -monitor $MONITOR"
  fi

  if [ -n "$QMP" ]; then
    QMP=$(normalizePort "$QMP" "tcp")
    QMP=$(normalizeSocket "$QMP")
    MON_OPTS+=" -qmp $QMP"
  fi

  ID_OPTS="-name ${APP// /-},process=$PROCESS"
  PID_OPTS="-pidfile $QEMU_PID"

  MON_OPTS="${MON_OPTS# }"
  return 0
}

configureGuestAgent() {

  QGA_OPTS=""

  [ -n "$QGA" ] || return 0

  local qga="$QGA"

  if [[ "$qga" =~ ^[0-9]+$ ]]; then

    qga="host=0.0.0.0,port=$qga,server=on,wait=off"

  else

    local backend="${qga%%,*}"

    if [[ "$backend" == *.sock && "$backend" != *:* ]]; then
      qga=$(normalizeSocket "$qga")
    elif [[ "$backend" != unix:*.sock ]]; then
      error "Invalid QGA value '$QGA', expected a Unix socket path ending in '.sock' or a TCP port."
      exit 78
    fi

    qga="path=${qga#unix:}"

  fi

  QGA_OPTS="-chardev socket,$qga,id=qga0"
  QGA_OPTS+=" -device virtio-serial"
  QGA_OPTS+=" -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0"

  return 0
}

configureMachine() {

  local usb=""
  local smm="off"
  local hpet="off"
  local vmport="off"

  enabled "$SMM" && smm="on"
  disabled "$SMM" && smm="off"

  enabled "$HPET" && hpet="on"
  disabled "$HPET" && hpet="off"

  enabled "$VMPORT" && vmport="on"
  disabled "$VMPORT" && vmport="off"

  disabled "$USB" && usb=",usb=off"

  MAC_OPTS="-machine type=${MACHINE},smm=${smm},graphics=off${usb}"
  MAC_OPTS+="$RAM_MACHINE_OPTS,vmport=${vmport},dump-guest-core=off,hpet=${hpet}${KVM_OPTS}"

  [ -n "$UUID" ] && ID_OPTS+=" -uuid $UUID"
  [ -n "$SM_BIOS" ] && ID_OPTS+=" $SM_BIOS"

  return 0
}

configureDevices() {

  local bus
  bus=$(getPciBus)

  DEV_OPTS=""

  if [ -n "$MOUSE" ] && [[ "${MOUSE,,}" != "usb"* ]]; then
    DEV_OPTS+=" -device $MOUSE"
  fi

  if ! disabled "$RNG" && [[ "${BOOT_MODE,,}" != "windows_legacy" ]]; then
    DEV_OPTS+=" -object rng-random,id=objrng0,filename=/dev/urandom"
    DEV_OPTS+=" -device virtio-rng-pci,rng=objrng0,id=rng0,bus=$bus"
  fi

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

  DEV_OPTS="${DEV_OPTS# }"

  return 0
}

configureSharedFolder() {

  if [ -d "/shared" ] && [[ "${BOOT_MODE,,}" != "windows"* ]]; then
    DEV_OPTS+=" -fsdev local,id=fsdev0,path=/shared,security_model=none"
    DEV_OPTS+=" -device virtio-9p-pci,id=fs0,fsdev=fsdev0,mount_tag=shared"
  fi

  DEV_OPTS="${DEV_OPTS# }"

  return 0
}

configureUsb() {

  USB_OPTS=""

  if enabled "$USB" || [ -z "$USB" ]; then
    USB="qemu-xhci,id=xhci,p2=7,p3=7"
  fi

  if ! disabled "$USB"; then
    USB_OPTS="-device $USB"
    if [[ "${MOUSE,,}" == "usb"* ]]; then
      USB_OPTS+=" -device $MOUSE"
    fi
  fi

  return 0
}

configureAudio() {

  AUDIO_OPTS=""

  disabled "${WEB:-}" && return 0
  enabled "${AUDIO:-N}" || return 0

  if [ -z "${AUDIO_FIFO:-}" ] || [ ! -p "$AUDIO_FIFO" ]; then

    disableAudio

    warn "Audio support failed to initialize, ignoring AUDIO=Y."
    return 0
  fi

  local sound="$SOUND"
  local model="${sound%%,*}"

  AUDIO_OPTS+=" -audiodev wav,id=snd,path=$AUDIO_FIFO,out.frequency=48000,out.channels=2,out.format=s16"

  # A USB audio device needs a compatible controller.
  if [[ "$model" == usb-* ]]; then

    if disabled "$USB"; then

      AUDIO_OPTS=""
      disableAudio

      warn "Cannot initialize audio device $model as USB is disabled, ignoring AUDIO=Y."
      return 0
    fi

    case "${USB,,}" in

      *xhci*|*ohci*|*uhci*) ;;

      *ehci*)

        AUDIO_OPTS+=" -device pci-ohci,id=audio-ohci"
        [[ ",$sound," == *,bus=* ]] || sound+=",bus=audio-ohci.0" ;;

      *)

        AUDIO_OPTS+=" -device qemu-xhci,id=audio-xhci"
        [[ ",$sound," == *,bus=* ]] || sound+=",bus=audio-xhci.0" ;;

    esac

  fi

  case "$model" in

    intel-hda|ich9-intel-hda)

      AUDIO_OPTS+=" -device $sound"
      AUDIO_OPTS+=" -device hda-output,audiodev=snd" ;;

    *)

      [[ ",$sound," == *,audiodev=* ]] || sound+=",audiodev=snd"
      AUDIO_OPTS+=" -device $sound" ;;

  esac

  return 0
}

configureCompatibility() {

  CMP_OPTS=""

  case "${BOOT_MODE,,}" in
    "legacy" | "windows_legacy" )
      return 0 ;;
  esac

  # OVMF guests receive the TianoCore memory-attribute compatibility switch;
  # legacy and custom firmware do not implement this fw_cfg option.
  CMP_OPTS="-fw_cfg name=opt/org.tianocore/UninstallMemAttrProtocol,string=y"

  return 0
}

buildArguments() {

  ARGS="-nodefaults $MEM_OPTS $MAC_OPTS $CPU_OPTS $RAM_OPTS $ID_OPTS $PID_OPTS $DISPLAY_OPTS $MON_OPTS $SERIAL_OPTS $QGA_OPTS $USB_OPTS $NET_OPTS $DISK_OPTS $BOOT_OPTS $DEV_OPTS $AUDIO_OPTS $CMP_OPTS $ARGUMENTS"

  # Collapse whitespace after optional argument groups are assembled so
  # empty features do not leave malformed spacing in the final command.
  ARGS=$(echo "$ARGS" | sed 's/\t/ /g' | tr -s ' ')

  return 0
}

finalizeMemory

configureMemory
configureSerial
configureMonitor
configureGuestAgent
configureMachine
configureProcessor

configureDevices
configureSharedFolder
configureUsb
configureAudio
configureCompatibility

buildArguments

return 0
