#!/usr/bin/env bash
set -Eeuo pipefail

fKill "progress.sh"

if [[ "${DISPLAY,,}" == "vnc" ]]; then
  html "You can now connect to VNC on port $VNC_PORT." "0"
elif [[ "${DISPLAY,,}" != "web" ]]; then
  html "The virtual machine was booted successfully." "0"
fi

if enabled "$DEBUG"; then
  echo
  printf "QEMU arguments:\n\n    %s\n\n" "${ARGS// -/$'\n    -'}"
fi

# Must always remain the very last command
enableTrap

return 0
