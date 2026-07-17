#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: "${HV:="Y"}"
: "${VMX:="N"}"
: "${CPU_FLAGS:=""}"
: "${CPU_MODEL:=""}"

# Sanitize variables
CPU_FLAGS=$(strip "$CPU_FLAGS")
CPU_MODEL=$(strip "$CPU_MODEL")

enabled "$DEBUG" && echo "Configuring KVM..."

isWindowsBoot() {

  [[ "${BOOT_MODE,,}" == "windows"* ]]

}

appendCpuFeature() {

  local feature="$1"

  if [ -z "$CPU_FEATURES" ]; then
    CPU_FEATURES="$feature"
  else
    CPU_FEATURES+=",$feature"
  fi

  return 0
}

trimSpaces() {

  local value="$1"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"

  echo "$value"
  return 0
}

removeCpuArgument() {

  local args=" ${ARGUMENTS:-} "

  while [[ "$args" =~ [[:space:]]-cpu([[:space:]][^[:space:]]+|=[^[:space:]]+)? ]]; do
    local cpu="${BASH_REMATCH[0]}"
    args="${args/$cpu/ }"
    warn "Ignoring '${cpu#" "}' from ARGUMENTS, use CPU_MODEL and CPU_FLAGS instead."
  done

  ARGUMENTS=$(trimSpaces "$args")

  return 0
}

configureKvmCpuModel() {

  CPU_FEATURES="kvm=on,l3-cache=on,+hypervisor"
  KVM_OPTS=",accel=kvm -enable-kvm -global kvm-pit.lost_tick_policy=discard"

  if [ -z "$CPU_MODEL" ]; then
    CPU_MODEL="host"
    CPU_FEATURES+=",migratable=no"
  fi

  if disabled "$VMX" && isWindowsBoot; then
    # Prevents a crash caused by a certain Windows update
    CPU_FEATURES+=",-vmx"
  fi

  return 0
}

configureKvmAmdFeatures() {

  # AMD processor
  if hasFlag "tsc_scale"; then
    CPU_FEATURES+=",+invtsc"
  fi

  if isWindowsBoot; then
    CPU_FEATURES+=",arch_capabilities=off"
  fi

  return 0
}

configureKvmIntelFeatures() {

  # Intel processor
  vmx=$(sed -ne '/^vmx flags/s/^.*: //p' /proc/cpuinfo)

  if grep -qw "tsc_scaling" <<< "$vmx"; then
    CPU_FEATURES+=",+invtsc"
  fi

  return 0
}

configureHyperVFeatures() {

  if ! isWindowsBoot || disabled "$HV"; then
    return 0
  fi

  HV_FEATURES="hv_passthrough"

  if isAmdCpu; then

    # AMD processor
    if ! hasFlag "avic"; then
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

  appendCpuFeature "$HV_FEATURES"

  return 0
}

configureKvm() {

  configureKvmCpuModel

  if isAmdCpu; then
    configureKvmAmdFeatures
  else
    configureKvmIntelFeatures
  fi

  configureHyperVFeatures

  return 0
}

configureTcgAmd64WindowsModel() {

  if isAmdCpu; then

    # AMD processor
    CPU_MODEL="EPYC"
    CPU_FEATURES+=",svm=off,arch_capabilities=off,-fxsr-opt,-misalignsse,-osvw,-topoext,-nrip-save,-xsavec,check"

  else

    # Intel processor
    CPU_MODEL="Skylake-Client-v4"
    CPU_FEATURES+=",vmx=off,-pcid,-tsc-deadline,-invpcid,-spec-ctrl,-xsavec,-xsaves,check"

  fi

  return 0
}

configureTcgCpuModel() {

  if [ -n "$CPU_MODEL" ]; then
    return 0
  fi

  if [[ "$ARCH" == "amd64" ]]; then

    if ! isWindowsBoot; then

      CPU_MODEL="max"
      CPU_FEATURES+=",migratable=no"

    else
      configureTcgAmd64WindowsModel
    fi

  else

    # Intel processor
    CPU_MODEL="Skylake-Client-v4"
    CPU_FEATURES+=",vmx=off,-pcid,-tsc-deadline,-invpcid,-spec-ctrl,-xsavec,-xsaves,check"

  fi

  return 0
}

configureTcg() {

  KVM_OPTS=""
  CPU_FEATURES="l3-cache=on,+hypervisor"

  if [[ "$ARCH" == "amd64" ]]; then
    KVM_OPTS=" -accel tcg,thread=multi"
  fi

  configureTcgCpuModel

  return 0
}

composeCpuFlags() {

  CPU_FLAGS="${CPU_MODEL}${CPU_FEATURES:+,$CPU_FEATURES}${CPU_FLAGS:+,$CPU_FLAGS}"

  return 0
}

removeCpuArgument

if ! disabled "$KVM"; then
  configureKvm
else
  configureTcg
fi

composeCpuFlags

return 0
