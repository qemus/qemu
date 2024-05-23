#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables
: "${TPM:="N"}"         # Disable TPM
: "${SMM:="N"}"         # Disable SMM
: "${BOOT_MODE:="legacy"}"  # Boot mode

BOOT_DESC=""
BOOT_OPTS=""

if [[ "${BOOT_MODE,,}" == "windows"* ]]; then

  BOOT_OPTS="-rtc base=localtime"
  BOOT_OPTS="$BOOT_OPTS -global ICH9-LPC.disable_s3=1"
  BOOT_OPTS="$BOOT_OPTS -global ICH9-LPC.disable_s4=1"

fi

SECURE="off"
[[ "$SMM" == [Yy1]* ]] && SECURE="on"

case "${BOOT_MODE,,}" in
  uefi)
    BOOT_DESC=" with UEFI"
    ROM="OVMF_CODE_4M.fd"
    VARS="OVMF_VARS_4M.fd"
    ;;
  secure)
    SECURE="on"
    BOOT_DESC=" securely"
    ROM="OVMF_CODE_4M.secboot.fd"
    VARS="OVMF_VARS_4M.secboot.fd"
    ;;
  windows | windows_plain)
    ROM="OVMF_CODE_4M.fd"
    VARS="OVMF_VARS_4M.fd"
    ;;
  windows_secure)
    TPM="Y"
    SECURE="on"
    BOOT_DESC=" securely"
    ROM="OVMF_CODE_4M.ms.fd"
    VARS="OVMF_VARS_4M.ms.fd"
    ;;
  windows_legacy)
    BOOT_DESC=" (legacy)"
    USB="usb-ehci,id=ehci"
    ;;
  legacy)
    BOOT_OPTS=""
    ;;
  *)
    info "Unknown boot mode '${BOOT_MODE}', defaulting to 'legacy'"
    BOOT_MODE="legacy"
    ;;
esac

if [[ "${BOOT_MODE,,}" != *"legacy" ]]; then

  OVMF="/usr/share/OVMF"
  DEST="$STORAGE/${BOOT_MODE,,}"

  if [ ! -s "$DEST.rom" ] || [ ! -f "$DEST.rom" ]; then
    [ ! -s "$OVMF/$ROM" ] || [ ! -f "$OVMF/$ROM" ] && error "UEFI boot file ($OVMF/$ROM) not found!" && exit 44
    cp "$OVMF/$ROM" "$DEST.rom"
  fi

  if [ ! -s "$DEST.vars" ] || [ ! -f "$DEST.vars" ]; then
    [ ! -s "$OVMF/$VARS" ] || [ ! -f "$OVMF/$VARS" ]&& error "UEFI vars file ($OVMF/$VARS) not found!" && exit 45
    cp "$OVMF/$VARS" "$DEST.vars"
  fi

  if [[ "${BOOT_MODE,,}" == "secure" ]] || [[ "${BOOT_MODE,,}" == "windows_secure" ]]; then
    BOOT_OPTS="$BOOT_OPTS -global driver=cfi.pflash01,property=secure,value=on"
  fi

  BOOT_OPTS="$BOOT_OPTS -drive file=$DEST.rom,if=pflash,unit=0,format=raw,readonly=on"
  BOOT_OPTS="$BOOT_OPTS -drive file=$DEST.vars,if=pflash,unit=1,format=raw"

fi

if [[ "$TPM" == [Yy1]* ]]; then

  rm -rf /run/shm/tpm
  rm -f /var/run/tpm.pid
  mkdir -p /run/shm/tpm
  chmod 755 /run/shm/tpm

  if ! swtpm socket -t -d --tpmstate dir=/run/shm/tpm --ctrl type=unixio,path=/run/swtpm-sock --pid file=/var/run/tpm.pid --tpm2; then
    error "Failed to start TPM emulator, reason: $?" && exit 19
  fi

  for (( i = 1; i < 20; i++ )); do

    [ -S "/run/swtpm-sock" ] && break

    if (( i % 10 == 0 )); then
      echo "Waiting for TPM emulator to become available..."
    fi

    sleep 0.1

  done

  if [ ! -S "/run/swtpm-sock" ]; then
    error "TPM socket not found? Disabling TPM module..."
  else
    BOOT_OPTS="$BOOT_OPTS -chardev socket,id=chrtpm,path=/run/swtpm-sock"
    BOOT_OPTS="$BOOT_OPTS -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0"
  fi

fi

return 0
