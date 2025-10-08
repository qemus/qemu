#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: "${HV="Y"}"
: "${VMX:="N"}"
: "${CPU_FLAGS:=""}"
: "${CPU_MODEL:=""}"

[[ "$DEBUG" == [Yy1]* ]] && echo "Configuring KVM..."

vendor=$(lscpu | awk '/Vendor ID/{print $3}')
flags=$(sed -ne '/^flags/s/^.*: //p' /proc/cpuinfo)

if [[ "$KVM" != [Nn]* ]]; then

  CPU_FEATURES="kvm=on,l3-cache=on,+hypervisor"
  KVM_OPTS=",accel=kvm -enable-kvm -global kvm-pit.lost_tick_policy=discard"

  if [ -z "$CPU_MODEL" ]; then
    CPU_MODEL="host"
    CPU_FEATURES+=",migratable=no"
  fi

  if [[ "$VMX" == [Nn]* && "${BOOT_MODE,,}" == "windows"* ]]; then
    # Prevents a crash caused by a certain Windows update
    CPU_FEATURES+=",-vmx"
  fi

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

  if [[ "${BOOT_MODE,,}" == "windows"* && "$HV" != [Nn]* ]]; then

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
        if [[ "$CPU" == "Intel Atom "* || "$CPU" == "Intel Celeron "* || "$CPU" == "Intel Pentium "* ]]; then
          # Prevent eVMCS version range error on budget CPU's
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

     if [[ "${BOOT_MODE,,}" != "windows"* ]]; then

       CPU_MODEL="max"
       CPU_FEATURES+=",migratable=no"

     else
       if [[ "$vendor" == "AuthenticAMD" ]]; then

         # AMD processor
         CPU_MODEL="EPYC"
         CPU_FEATURES+=",svm=off,arch_capabilities=off,-fxsr-opt,-misalignsse,-osvw,-topoext,-nrip-save,-xsavec,check"

       else

         # Intel processor
         CPU_MODEL="Skylake-Client-v4"
         CPU_FEATURES+=",vmx=off,-pcid,-tsc-deadline,-invpcid,-spec-ctrl,-xsavec,-xsaves,check"

       fi
     fi

    else

      # Intel processor
      CPU_MODEL="Skylake-Client-v4"
      CPU_FEATURES+=",vmx=off,-pcid,-tsc-deadline,-invpcid,-spec-ctrl,-xsavec,-xsaves,check"

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
