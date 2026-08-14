#!/usr/bin/env bash
set -Eeuo pipefail

fKill "progress.sh"

if [[ "${DISPLAY,,}" == "web" ]]; then

  [ ! -f "$INFO" ] && error "File $INFO not found."
  [ ! -f "$PAGE" ] && error "File $PAGE not found."

else

  if [[ "${DISPLAY,,}" == "vnc" ]]; then
    html "You can now connect to VNC on port $VNC_PORT." "0"
  else
    html "The virtual machine was booted successfully." "0"
  fi

fi

if enabled "$DEBUG"; then
  echo
  printf "QEMU arguments:\n\n    %s\n\n" "${ARGS// -/$'\n    -'}"
fi

# Must always remain the very last command
enableTrap

return 0
