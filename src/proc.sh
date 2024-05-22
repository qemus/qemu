#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: "${HV="Y"}"
: "${KVM:="Y"}"
: "${CPU_FLAGS:=""}"
: "${CPU_MODEL:=""}"
: "${DEF_MODEL:="qemu64"}"

[[ "${MACHINE,,}" == "pc-q35-2"* ]] && HV="N"

if [[ "${ARCH,,}" != "amd64" ]]; then
  KVM="N"
  warn "your CPU architecture is ${ARCH^^} and cannot provide KVM acceleration for x64 instructions, this will cause a major loss of performance."
fi

if [[ "$KVM" != [Nn]* ]]; then

  KVM_ERR=""

  if [ ! -e /dev/kvm ]; then
    KVM_ERR="(device file missing)"
  else
    if ! sh -c 'echo -n > /dev/kvm' &> /dev/null; then
      KVM_ERR="(no write access)"
    else
      flags=$(sed -ne '/^flags/s/^.*: //p' /proc/cpuinfo)
      if ! grep -qw "vmx\|svm" <<< "$flags"; then
        KVM_ERR="(vmx/svm disabled)"
      fi
    fi
  fi

  if [ -n "$KVM_ERR" ]; then
    KVM="N"
    if [[ "$OSTYPE" =~ ^darwin ]]; then
      warn "you are using MacOS which has no KVM support, this will cause a major loss of performance."
    else
      if grep -qi Microsoft /proc/version; then
        warn "you are using Windows 10 which has no KVM support, this will cause a major loss of performance."
      else
        error "KVM acceleration not available $KVM_ERR, this will cause a major loss of performance."
        error "See the FAQ on how to enable it, or continue without KVM by setting KVM=N (not recommended)."
        [[ "$DEBUG" != [Yy1]* ]] && exit 88
      fi
    fi
  fi

fi

if [[ "$KVM" != [Nn]* ]]; then

  CPU_FEATURES="kvm=on,l3-cache=on"
  KVM_OPTS=",accel=kvm -enable-kvm -global kvm-pit.lost_tick_policy=discard"

  if [ -z "$CPU_MODEL" ]; then
    CPU_MODEL="host"
    CPU_FEATURES="$CPU_FEATURES,migratable=no"
  fi

  if [ -e /sys/module/kvm/parameters/ignore_msrs ]; then
    if [ "$(cat /sys/module/kvm/parameters/ignore_msrs)" == "N" ]; then
      echo 1 | tee /sys/module/kvm/parameters/ignore_msrs > /dev/null 2>&1 || true
    fi
  fi

  if [[ "$HV" != [Nn]* ]] && [[ "${BOOT_MODE,,}" == "windows"* ]]; then

    HV_FEATURES="+hypervisor,hv_passthrough"

    if grep -qw "svm" <<< "$flags"; then

      # AMD processor

      if grep -qw "tsc_scale" <<< "$flags"; then
        HV_FEATURES="$HV_FEATURES,+invtsc"
      fi

      if ! grep -qw "avic" <<< "$flags"; then
        HV_FEATURES="$HV_FEATURES,-hv-avic"
      fi

      HV_FEATURES="$HV_FEATURES,-hv-evmcs"

    else

      # Intel processor

      vmx=$(sed -ne '/^vmx flags/s/^.*: //p' /proc/cpuinfo)

      if grep -qw "tsc_scaling" <<< "$vmx"; then
        HV_FEATURES="$HV_FEATURES,+invtsc"
      fi

      if ! grep -qw "apicv" <<< "$vmx"; then
        HV_FEATURES="$HV_FEATURES,-hv-apicv,-hv-evmcs"
      else
        if ! grep -qw "shadow_vmcs" <<< "$vmx"; then
          # Prevent eVMCS version range error on Atom CPU's
          HV_FEATURES="$HV_FEATURES,-hv-evmcs"
        fi
      fi

    fi

    [ -n "$CPU_FEATURES" ] && CPU_FEATURES="$CPU_FEATURES,"
    CPU_FEATURES="$CPU_FEATURES${HV_FEATURES}"

  fi

else

  KVM_OPTS=""
  CPU_FEATURES="l3-cache=on"

  if [[ "$ARCH" == "amd64" ]]; then
    KVM_OPTS=" -accel tcg,thread=multi"
  fi

  if [ -z "$CPU_MODEL" ]; then
    if [[ "$ARCH" == "amd64" ]]; then
      CPU_MODEL="max"
      CPU_FEATURES="$CPU_FEATURES,migratable=no"
    else
      CPU_MODEL="$DEF_MODEL"
    fi
  fi

  CPU_FEATURES="$CPU_FEATURES,+ssse3,+sse4.1,+sse4.2"

  if [[ "$HV" != [Nn]* ]] && [[ "${BOOT_MODE,,}" == "windows"* ]]; then
    CPU_FEATURES="$CPU_FEATURES,+hypervisor"
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
