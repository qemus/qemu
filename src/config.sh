#!/usr/bin/env bash
set -Eeuo pipefail

: "${UUID:=""}"
: "${HPET:="off"}"
: "${VMPORT:="off"}"
: "${SERIAL:="mon:stdio"}"
: "${USB:="qemu-xhci,id=xhci,p2=7,p3=7"}"
: "${MONITOR:="telnet:localhost:7100,server,nowait,nodelay"}"
: "${SMP:="$CPU_CORES,sockets=1,dies=1,cores=$CPU_CORES,threads=1"}"

DEV_OPTS=""
DEF_OPTS="-nodefaults"
SERIAL_OPTS="-serial $SERIAL"
CPU_OPTS="-cpu $CPU_FLAGS -smp $SMP"
RAM_OPTS=$(echo "-m ${RAM_SIZE^^}" | sed 's/MB/M/g;s/GB/G/g;s/TB/T/g')
MON_OPTS="-monitor $MONITOR -name $PROCESS,process=$PROCESS,debug-threads=on"
MAC_OPTS="-machine type=${MACHINE},smm=${SECURE},graphics=off,vmport=${VMPORT},dump-guest-core=off,hpet=${HPET}${KVM_OPTS}"

[ -n "$UUID" ] && MAC_OPTS+=" -uuid $UUID"
[ -n "$SM_BIOS" ] && MAC_OPTS+=" $SM_BIOS"

if [[ "${MACHINE,,}" != "pc"* ]]; then
  DEV_OPTS="-object rng-random,id=objrng0,filename=/dev/urandom"
  DEV_OPTS+=" -device virtio-rng-pci,rng=objrng0,id=rng0,bus=pcie.0"
  if [[ "${BOOT_MODE,,}" != "windows"* ]]; then
    DEV_OPTS+=" -device virtio-balloon-pci,id=balloon0,bus=pcie.0"
  fi
fi

if [ -d "/shared" ] && [[ "${BOOT_MODE,,}" != "windows"* ]]; then
  DEV_OPTS+=" -fsdev local,id=fsdev0,path=/shared,security_model=none"
  DEV_OPTS+=" -device virtio-9p-pci,id=fs0,fsdev=fsdev0,mount_tag=shared"
fi

[ -n "$USB" ] && [[ "${USB,,}" != "no"* ]] && USB_OPTS="-device $USB -device usb-tablet"

ARGS="$DEF_OPTS $CPU_OPTS $RAM_OPTS $MAC_OPTS $DISPLAY_OPTS $MON_OPTS $SERIAL_OPTS ${USB_OPTS:-} $NET_OPTS $DISK_OPTS $BOOT_OPTS $DEV_OPTS $ARGUMENTS"
ARGS=$(echo "$ARGS" | sed 's/\t/ /g' | tr -s ' ')

if [[ "${DISPLAY,,}" == "web" ]]; then
  [ ! -f "$INFO" ] && error "File $INFO not found?!"
  rm -f "$INFO"
  [ ! -f "$PAGE" ] && error "File $PAGE not found?!"
  rm -f "$PAGE"
else
  if [[ "${DISPLAY,,}" == "vnc" ]]; then
    html "You can now connect to VNC on port 5900." "0"
  else
    html "The virtual machine was booted successfully." "0"
  fi
fi

# Check available memory as the very last step

if [[ "$RAM_CHECK" != [Nn]* ]]; then

  RAM_AVAIL=$(free -b | grep -m 1 Mem: | awk '{print $7}')
  AVAIL_MEM=$(formatBytes "$RAM_AVAIL")

  if (( (RAM_WANTED + RAM_SPARE) > RAM_AVAIL )); then
    msg="Your configured RAM_SIZE of ${RAM_SIZE/G/ GB} is too high for the $AVAIL_MEM of memory available, please set a lower value."
    [[ "${FS,,}" != "zfs" ]] && error "$msg" && exit 17
    info "$msg"
  else
    if (( (RAM_WANTED + (RAM_SPARE * 3)) > RAM_AVAIL )); then
      msg="your configured RAM_SIZE of ${RAM_SIZE/G/ GB} is very close to the $AVAIL_MEM of memory available, please consider a lower value."
      if [[ "${FS,,}" != "zfs" ]]; then
        warn "$msg"
      else
        info "$msg"
      fi
    fi
  fi

fi

if [[ "$DEBUG" == [Yy1]* ]]; then
  printf "Arguments:\n\n%s\n\n" "${ARGS// -/$'\n-'}"
fi

return 0
