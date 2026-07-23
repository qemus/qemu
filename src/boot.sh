#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables
: "${BIOS:=""}"         # BIOS file
: "${TPM:="N"}"         # Disable TPM
: "${SMM:="N"}"         # Disable SMM
: "${LOGO:="Y"}"        # Enable logo
: "${CLEAR:="N"}"       # Persist NVRAM

BOOT_DESC=""
BOOT_OPTS=""

configureBootMode() {

  SECURE="off"
  enabled "$SMM" && SECURE="on"
  [ -n "$BIOS" ] && BOOT_MODE="custom"

  case "${BOOT_MODE,,}" in
    "uefi" | "" )
      BOOT_MODE="uefi"
      ROM="OVMF_CODE_4M.fd"
      VARS="OVMF_VARS_4M.fd"
      ;;
    "secure" )
      SECURE="on"
      BOOT_DESC=" securely"
      ROM="OVMF_CODE_4M.secboot.fd"
      VARS="OVMF_VARS_4M.secboot.fd"
      ;;
    "windows" | "windows_plain" )
      ROM="OVMF_CODE_4M.fd"
      VARS="OVMF_VARS_4M.fd"
      ;;
    "windows_secure" )
      TPM="Y"
      SECURE="on"
      BOOT_DESC=" securely"
      ROM="OVMF_CODE_4M.ms.fd"
      VARS="OVMF_VARS_4M.ms.fd"
      ;;
    "windows_legacy" )
      HV="N"
      SECURE="on"
      BOOT_DESC=" (legacy)"
      [ -z "${USB:-}" ] && USB="usb-ehci,id=ehci"
      ;;
    "legacy" )
      BOOT_DESC=" with SeaBIOS"
      ;;
    "custom" )
      BIOS=$(strip "$BIOS")
      if [ -z "$BIOS" ]; then
        error "BOOT_MODE is custom but BIOS is empty!"
        exit 33
      fi
      BOOT_OPTS="-bios $BIOS"
      BOOT_DESC=" with custom BIOS file"
      ;;
    *)
      error "Unknown BOOT_MODE, value \"${BOOT_MODE}\" is not recognized!"
      exit 33
      ;;
  esac

  return 0
}

addWindowsBootOptions() {

  if [[ "${BOOT_MODE,,}" == "windows"* ]]; then
    BOOT_OPTS+=" -rtc base=localtime"
    BOOT_OPTS+=" -global ICH9-LPC.disable_s3=1"
    BOOT_OPTS+=" -global ICH9-LPC.disable_s4=1"
  fi

  return 0
}

clearNvram() {

  DEST="$STORAGE/${BOOT_MODE,,}"

  if enabled "$CLEAR"; then
    # Clear NVRAM (helps to fix corruptions)
    rm -f "$DEST.rom" "$DEST.vars" "$DEST.tpm"
  fi

  return 0
}

prepareUefiRom() {

  local logo

  if [ -e "$DEST.rom" ] && [ ! -f "$DEST.rom" ]; then
    error "UEFI boot path \"$DEST.rom\" is not a regular file!"
    exit 44
  fi

  [ -s "$DEST.rom" ] && return 0

  [ ! -s "$OVMF/$ROM" ] && error "UEFI boot file ($OVMF/$ROM) not found!" && exit 44

  logo="/var/www/img/${PROCESS,,}.ffs"
  [ ! -s "$logo" ] && logo="/var/www/img/qemu.ffs"
  [ ! -s "$logo" ] && LOGO="N"

  rm -f "$DEST.tmp"

  if disabled "$LOGO"; then
    if ! cp "$OVMF/$ROM" "$DEST.tmp"; then
      rm -f "$DEST.tmp"
      error "Failed to copy UEFI boot file to $DEST.tmp" && exit 44
    fi
  else
    if ! /run/utk.bin "$OVMF/$ROM" replace_ffs LogoDXE "$logo" save "$DEST.tmp"; then
      warn "failed to add custom logo to BIOS!"
      rm -f "$DEST.tmp"

      if ! cp "$OVMF/$ROM" "$DEST.tmp"; then
        rm -f "$DEST.tmp"
        error "Failed to copy UEFI boot file to $DEST.tmp" && exit 44
      fi
    fi
  fi

  if ! mv "$DEST.tmp" "$DEST.rom"; then
    rm -f "$DEST.tmp"
    error "Failed to move UEFI boot file to $DEST.rom" && exit 44
  fi

  ! setOwner "$DEST.rom" && warn "failed to set the owner for \"$DEST.rom\" !"

  return 0
}

prepareUefiVars() {

  if [ -e "$DEST.vars" ] && [ ! -f "$DEST.vars" ]; then
    error "UEFI vars path \"$DEST.vars\" is not a regular file!"
    exit 44
  fi

  [ -s "$DEST.vars" ] && return 0

  [ ! -s "$OVMF/$VARS" ] && error "UEFI vars file ($OVMF/$VARS) not found!" && exit 45

  rm -f "$DEST.tmp"

  if ! cp "$OVMF/$VARS" "$DEST.tmp"; then
    rm -f "$DEST.tmp"
    error "Failed to copy UEFI vars file to $DEST.tmp" && exit 45
  fi

  if ! mv "$DEST.tmp" "$DEST.vars"; then
    rm -f "$DEST.tmp"
    error "Failed to move UEFI vars file to $DEST.vars" && exit 45
  fi

  ! setOwner "$DEST.vars" && warn "failed to set the owner for \"$DEST.vars\" !"

  return 0
}

configureUefi() {

  case "${BOOT_MODE,,}" in
    "uefi" | "secure" | "windows" | "windows_plain" | "windows_secure" )

      OVMF="/usr/share/OVMF"

      prepareUefiRom
      prepareUefiVars

      if [[ "${BOOT_MODE,,}" == "secure" || "${BOOT_MODE,,}" == "windows_secure" ]]; then
        BOOT_OPTS+=" -global driver=cfi.pflash01,property=secure,value=on"
      fi

      BOOT_OPTS+=" -drive file=$DEST.rom,if=pflash,unit=0,format=raw,readonly=on"
      BOOT_OPTS+=" -drive file=$DEST.vars,if=pflash,unit=1,format=raw"

      ;;
  esac

  return 0
}

enableIgnoreMsrs() {

  MSRS="/sys/module/kvm/parameters/ignore_msrs"
  [ ! -e "$MSRS" ] && return 0
  
  result=$(<"$MSRS")
  result="${result//[![:print:]]/}"
  
  if [[ "$result" == "0" || "${result^^}" == "N" ]]; then
    echo 1 | tee "$MSRS" > /dev/null 2>&1 || true
  fi

  return 0
}

checkClocksource() {

  CLOCKSOURCE="tsc"
  [[ "${ARCH,,}" == "arm64" ]] && CLOCKSOURCE="arch_sys_counter"
  CLOCK="/sys/devices/system/clocksource/clocksource0/current_clocksource"

  if [ ! -f "$CLOCK" ]; then
    warn "file \"$CLOCK\" cannot be found?"
    return 0
  fi
  
  result=$(<"$CLOCK")
  result="${result//[![:print:]]/}"
  
  case "${result,,}" in
    "${CLOCKSOURCE,,}" ) ;;
    "kvm-clock" ) info "Nested KVM virtualization detected.." ;;
    "hyperv_clocksource_tsc_page" ) info "Nested Hyper-V virtualization detected.." ;;
    "hpet" ) warn "unsupported clock source ﻿detected﻿: '$result'. Please﻿ ﻿set host clock source to '$CLOCKSOURCE'." ;;
    *) warn "unexpected clock source ﻿detected﻿: '$result'. Please﻿ ﻿set host clock source to '$CLOCKSOURCE'." ;;
  esac

  return 0
}

detectSmbiosSerial() {

  SM_BIOS=""
  PS="/sys/class/dmi/id/product_serial"

  if [ -r "$PS" ]; then

    BIOS_SERIAL=$(<"$PS")
    BIOS_SERIAL="${BIOS_SERIAL//[![:alnum:]]/}"

    if [ -n "$BIOS_SERIAL" ]; then
      SM_BIOS="-smbios type=1,serial=$BIOS_SERIAL"
    fi

  fi

  return 0
}

stopTpm() {

  local pid=""

  if [ -s "$TPM_PID" ] && read -r pid < "$TPM_PID" && [ -n "$pid" ]; then
    pKill "$pid" 2

    if isAlive "$pid"; then
      kill -9 -- "$pid" 2>/dev/null || :
    fi
  fi

  rm -f "$TPM_PID" "$TPM_SOCKET"
  return 0
}

startTpm() {

  local i=0
  local rc=0

  SWTPM="/run/swtpm"
  TPM_PID="/var/run/tpm.pid"
  TPM_SOCKET="/tmp/swtpm.sock"

  rm -f "$TPM_PID" "$TPM_SOCKET"

  if ! enabled "$TPM"; then
    return 0
  fi

  msg="Starting TPM emulator..."
  html "$msg"
  enabled "$DEBUG" && echo "$msg"

  # Workaround to circumvent AppArmor profile
  if [ ! -x "$SWTPM" ]; then
    if ! cp /usr/bin/swtpm "$SWTPM"; then
      error "Failed to copy TPM emulator, disabling TPM."
      return 0
    fi
  fi

  { "$SWTPM" socket -t -d --tpm2 \
      --tpmstate "backend-uri=file://$DEST.tpm" \
      --ctrl "type=unixio,path=$TPM_SOCKET" \
      --pid "file=$TPM_PID"
    rc=$?
  } || :

  if (( rc != 0 )); then
    stopTpm
    error "Failed to start TPM emulator, reason: $rc"
    return 0
  fi

  for (( i = 1; i < 25; i++ )); do

    [ -S "$TPM_SOCKET" ] && break

    if (( i % 5 == 0 )); then
      echo "Waiting for TPM emulator to launch..."
    fi

    sleep 0.25

  done

  if [ ! -S "$TPM_SOCKET" ]; then
    stopTpm
    error "TPM socket ($TPM_SOCKET) not found? Disabling TPM module..."
    return 0
  fi

  BOOT_OPTS+=" -chardev socket,id=chrtpm,path=$TPM_SOCKET"
  BOOT_OPTS+=" -tpmdev emulator,id=tpm0,chardev=chrtpm"
  BOOT_OPTS+=" -device tpm-tis,tpmdev=tpm0"

  return 0
}

msg="Configuring boot..."
html "$msg"
enabled "$DEBUG" && echo "$msg"

configureBootMode
addWindowsBootOptions

clearNvram
configureUefi
enableIgnoreMsrs
checkClocksource
detectSmbiosSerial

startTpm

return 0
