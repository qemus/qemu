#!/usr/bin/env bash
set -Eeuo pipefail

: "${UUID:=""}"
: "${HPET:="off"}"
: "${VMPORT:="off"}"
: "${SERIAL:="mon:stdio"}"
: "${SOUND:="-device intel-hda"}"
: "${USB:="qemu-xhci,id=xhci,p2=7,p3=7"}"
: "${MONITOR:="unix:$QEMU_DIR/monitor.sock,server,wait=off,nodelay"}"
: "${SMP:="$CPU_CORES,sockets=1,dies=1,cores=$CPU_CORES,threads=1"}"

msg="Configuring QEMU..."
html "$msg"
enabled "$DEBUG" && echo "$msg"

DEV_OPTS=""
AUDIO_OPTS=""
DEF_OPTS="-nodefaults"
SERIAL_OPTS="-serial $SERIAL"
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

  if [[ "${MACHINE,,}" == "pc"* ]]; then
    return 0
  fi

  DEV_OPTS="-object rng-random,id=objrng0,filename=/dev/urandom"
  DEV_OPTS+=" -device virtio-rng-pci,rng=objrng0,id=rng0,bus=pcie.0"

  if [[ "${BOOT_MODE,,}" != "windows"* ]] || enabled "${BALLOONING:-}"; then
    if ! enabled "${BALLOONING:-}"; then
      DEV_OPTS+=" -device virtio-balloon-pci,id=balloon0,bus=pcie.0"
    else
      MON_OPTS+=" -qmp unix:${BALLOONING_SOCKET},server,nowait"
      DEV_OPTS+=" -device virtio-balloon-pci,free-page-reporting=on,guest-stats-polling-interval=1,id=balloon0,bus=pcie.0"
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

  [ -n "$USB" ] && [[ "${USB,,}" != "no"* ]] && USB_OPTS="-device $USB -device usb-tablet"

  return 0
}

configureAudio() {

  disabled "${WEB:-}" && return 0
  ! enabled "${AUDIO:-N}" && return 0

  if [ -z "${AUDIO_FIFO:-}" ] || [ ! -p "$AUDIO_FIFO" ]; then
    warn "Audio support failed to initialize, ignoring AUDIO=Y."
    return 0
  fi

  AUDIO_OPTS+=" -audiodev wav,id=snd,path=$AUDIO_FIFO,out.frequency=48000,out.channels=2,out.format=s16"
  AUDIO_OPTS+=" $SOUND"
  AUDIO_OPTS+=" -device hda-output,audiodev=snd"

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
