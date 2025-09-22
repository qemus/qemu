#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: "${HV="Y"}"
: "${KVM:="Y"}"
: "${VMX:="N"}"
: "${CPU_FLAGS:=""}"
: "${CPU_MODEL:=""}"

if [[ "${ARCH,,}" != "amd64" ]]; then
  KVM="N"
  warn "your CPU architecture is ${ARCH^^} and cannot provide KVM acceleration for x64 instructions, this will cause a major loss of performance."
fi

if [[ "$KVM" != [Nn]* ]]; then

  KVM_ERR=""

  if [ ! -e /dev/kvm ]; then
    KVM_ERR="(/dev/kvm is missing)"
  else
    if ! sh -c 'echo -n > /dev/kvm' &> /dev/null; then
      KVM_ERR="(/dev/kvm is unwriteable)"
    else
      flags=$(sed -ne '/^flags/s/^.*: //p' /proc/cpuinfo)
      if ! grep -qw "vmx\|svm" <<< "$flags"; then
        KVM_ERR="(not enabled in BIOS)"
      fi
    fi
  fi

  if [ -n "$KVM_ERR" ]; then
    KVM="N"
    if [[ "$OSTYPE" =~ ^darwin ]]; then
      warn "you are using macOS which has no KVM support, this will cause a major loss of performance."
    else
      kernel=$(uname -a)
      case "${kernel,,}" in
        *"microsoft"* )
          error "Please bind '/dev/kvm' as a volume in the optional container settings when using Docker Desktop." ;;
        *"synology"* )
          error "Please make sure that Synology VMM (Virtual Machine Manager) is installed and that '/dev/kvm' is binded to this container." ;;
        *)
          error "KVM acceleration is not available $KVM_ERR, this will cause a major loss of performance."
          error "See the FAQ for possible causes, or continue without it by adding KVM: \"N\" (not recommended)." ;;
      esac
      [[ "$DEBUG" != [Yy1]* ]] && exit 88
    fi
  fi

fi

if [[ "$KVM" != [Nn]* ]]; then

  CPU_FEATURES="kvm=on,l3-cache=on,+hypervisor"
  KVM_OPTS=",accel=kvm -enable-kvm -global kvm-pit.lost_tick_policy=discard"

  if [ -z "$CPU_MODEL" ]; then
    CPU_MODEL="host"
    CPU_FEATURES+=",migratable=no"
  fi

  if [[ "$VMX" == [Nn]* && "${BOOT_MODE,,}" == "windows"* ]]; then
    CPU_FEATURES+=",-vmx"
  fi

  vendor=$(lscpu | awk '/Vendor ID/{print $3}')

  if [[ "$vendor" == "AuthenticAMD" ]]; then

    # AMD processor

    if grep -qw "tsc_scale" <<< "$flags"; then
      CPU_FEATURES+=",+invtsc"
    fi

    if [[ "${BOOT_MODE,,}" == "windows"* ]]; then
      CPU_FEATURES+=",arch_capabilities=off"
    fi

  else

    # Intel processor

    vmx=$(sed -ne '/^vmx flags/s/^.*: //p' /proc/cpuinfo)

    if grep -qw "tsc_scaling" <<< "$vmx"; then
      CPU_FEATURES+=",+invtsc"
    fi

  fi

  if [[ "$HV" != [Nn]* && "${BOOT_MODE,,}" == "windows"* ]]; then

    HV_FEATURES="hv_passthrough"

    if [[ "$vendor" == "AuthenticAMD" ]]; then

      # AMD processor

      if ! grep -qw "avic" <<< "$flags"; then
        HV_FEATURES+=",-hv-avic"
      fi

      HV_FEATURES+=",-hv-evmcs"

    else

      # Intel processor

      if ! grep -qw "apicv" <<< "$vmx"; then
        HV_FEATURES+=",-hv-apicv,-hv-evmcs"
      else
        if ! grep -qw "shadow_vmcs" <<< "$vmx"; then
          # Prevent eVMCS version range error on Atom CPU's
          HV_FEATURES+=",-hv-evmcs"
        fi
      fi

    fi

    [ -n "$CPU_FEATURES" ] && CPU_FEATURES+=","
    CPU_FEATURES+="${HV_FEATURES}"

  fi

else

  KVM_OPTS=""
  CPU_FEATURES="l3-cache=on,+hypervisor"

  if [[ "$ARCH" == "amd64" ]]; then
    KVM_OPTS=" -accel tcg,thread=multi"
  fi

  if [ -z "$CPU_MODEL" ]; then
    if [[ "$ARCH" == "amd64" ]]; then
     if [[ "${BOOT_MODE,,}" != "windows"* ]]
       CPU_MODEL="max"
       CPU_FEATURES+=",migratable=no"
     else
       CPU_MODEL="Skylake-Client-v4"
       CPU_FEATURES+=",-pcid,-tsc-deadline,-invpcid,-spec-ctrl,-xsavec,-xsaves,check"
     fi
    else
      CPU_MODEL="qemu64"
      CPU_FEATURES+=",+aes,+popcnt,+pni,+sse4.1,+sse4.2,+ssse3,+avx,+avx2,+bmi1,+bmi2,+f16c,+fma,+abm,+movbe,+xsave"
    fi
  fi

fi

if [[ "$ARGUMENTS" == *"-cpu host,"* ]]; then

  args="${ARGUMENTS} "
  prefix="${args/-cpu host,*/}"
  suffix="${args/*-cpu host,/}"
  param="${suffix%% *}"
  suffix="${suffix#* }"
  args="${prefix}${suffix}"
  ARGUMENTS="${args::-1}"

  if [ -z "$CPU_FLAGS" ]; then
    CPU_FLAGS="$param"
  else
    CPU_FLAGS+=",$param"
  fi

else

  if [[ "$ARGUMENTS" == *"-cpu host"* ]]; then
    ARGUMENTS="${ARGUMENTS//-cpu host/}"
  fi

fi

if [ -z "$CPU_FLAGS" ]; then
  if [ -z "$CPU_FEATURES" ]; then
    CPU_FLAGS="$CPU_MODEL"
  else
    CPU_FLAGS="$CPU_MODEL,$CPU_FEATURES"
  fi
else
  if [ -z "$CPU_FEATURES" ]; then
    CPU_FLAGS="$CPU_MODEL,$CPU_FLAGS"
  else
    CPU_FLAGS="$CPU_MODEL,$CPU_FEATURES,$CPU_FLAGS"
  fi
fi

return 0
