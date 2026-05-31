#!/usr/bin/env bash
set -Eeuo pipefail

: "${SHUTDOWN:="N"}"        # Graceful ACPI shutdown
: "${QEMU_TIMEOUT:="110"}"  # QEMU Termination timeout

# Configure QEMU for graceful shutdown

QEMU_TERM=""
QEMU_LOG="$QEMU_DIR/qemu.log"
QEMU_OUT="$QEMU_DIR/qemu.out"
QEMU_END="$QEMU_DIR/qemu.end"

_trap() {
  local func="$1"; shift
  local sig
  for sig; do
    trap "$func $sig" "$sig"
  done
}

finish() {

  local pid
  local reason=$1
  local pids=( "/var/run/tpm.pid" )

  touch "$QEMU_END"

  if [ -s "$QEMU_PID" ]; then

    pid=$(<"$QEMU_PID")

    if isAlive "$pid"; then
      echo && error "Forcefully terminating QEMU, reason: $reason..."
      { kill -9 "$pid" || true; } 2>/dev/null
    fi

  fi

  for pid in "${pids[@]}"; do
      if [[ -s "$pid" ]]; then 
          pKill "$(<"$pid")"
      fi
      rm -f "$pid"
  done 

  closeNetwork

  sleep 0.5
  echo "❯ Shutdown completed!"

  exit "$reason"
}

terminal() {

  local dev=""

  if [ -s "$QEMU_OUT" ]; then

    local msg
    msg=$(<"$QEMU_OUT")

    if [ -n "$msg" ]; then

      if [[ "${msg,,}" != "char"* ||  "$msg" != *"serial0)" ]]; then
        echo "$msg"
      fi

      dev="${msg#*/dev/p}"
      dev="/dev/p${dev%% *}"

    fi
  fi

  if [ ! -c "$dev" ]; then
    dev=$(echo 'info chardev' | nc -q 1 -w 1 localhost "$MON_PORT" | tr -d '\000')
    dev="${dev#*serial0}"
    dev="${dev#*pty:}"
    dev="${dev%%$'\n'*}"
    dev="${dev%%$'\r'*}"
  fi

  if [ ! -c "$dev" ]; then
    error "Device '$dev' not found!"
    finish 34 && return 34
  fi

  QEMU_TERM="$dev"
  return 0
}

_graceful_shutdown() {

  local sig="$1"
  local code=0

  case "$sig" in
    SIGTERM) code=143 ;;
    SIGINT)  code=130 ;;
    SIGHUP)  code=129 ;;
    SIGABRT) code=134 ;;
    SIGQUIT) code=131 ;;
  esac

  if [ -f "$QEMU_END" ]; then
    info "Received $1 while already shutting down..."
    return
  fi

  set +e
  touch "$QEMU_END"
  info "Received $1, sending ACPI shutdown signal..."

  if [ ! -s "$QEMU_PID" ]; then
    error "QEMU PID file does not exist?"
    finish "$code" && return "$code"
  fi

  local pid=""
  pid=$(<"$QEMU_PID")

  if ! isAlive "$pid"; then
    error "QEMU process does not exist?"
    finish "$code" && return "$code"
  fi

  local cnt=0 abort=0 factor=2 offset=1

  [ "$QEMU_TIMEOUT" -ge 10 ] && factor=5

  if [ "$QEMU_TIMEOUT" -lt $((factor + offset + 1)) ]; then
    QEMU_TIMEOUT=$((factor + offset + 1))
  fi

  abort=$(( QEMU_TIMEOUT - factor - offset ))

  while [ "$cnt" -lt $(( QEMU_TIMEOUT - offset )) ]; do
  
    ! isAlive "$pid" && break
    # Workaround for zombie pid
    [ ! -s "$QEMU_PID" ] && break

    if [ "$cnt" -ne "$abort" ]; then
      if [ "$cnt" -gt 0 ]; then
        info "Waiting for VM to shutdown... ($cnt/$QEMU_TIMEOUT)"
      fi
    else
      info "QEMU is still running, sending SIGTERM... ($cnt/$QEMU_TIMEOUT)"
      { kill -15 "$pid" || true; } 2>/dev/null
    fi

    # Send ACPI shutdown signal
    echo 'system_powerdown' | nc -q 1 -w 1 localhost "$MON_PORT" > /dev/null

    sleep 1
    (( cnt++ ))

  done

  finish "$code" && return "$code"
}

[[ "$SHUTDOWN" != [Yy1]* ]] && return 0

touch "$QEMU_LOG"

SERIAL="pty"
MONITOR="telnet:localhost:$MON_PORT,server,nowait,nodelay -daemonize -D $QEMU_LOG"

_trap _graceful_shutdown SIGTERM SIGHUP SIGINT SIGABRT SIGQUIT

return 0
