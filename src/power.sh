#!/usr/bin/env bash
set -Eeuo pipefail

: "${SHUTDOWN:="N"}"        # Graceful ACPI shutdown
: "${QEMU_TIMEOUT:="110"}"  # QEMU Termination timeout

# Configure QEMU for graceful shutdown

QEMU_TERM=""
QEMU_PTY="$QEMU_DIR/qemu.pty"
QEMU_LOG="$QEMU_DIR/qemu.log"
QEMU_OUT="$QEMU_DIR/qemu.out"
QEMU_END="$QEMU_DIR/qemu.end"

_trap() {
  func="$1" ; shift
  for sig ; do
    trap "$func $sig" "$sig"
  done
}

finish() {

  local pid
  local cnt=0
  local reason=$1
  local pids=( "/var/run/tpm.pid" )

  touch "$QEMU_END"

  if [ -s "$QEMU_PID" ]; then

    pid=$(<"$QEMU_PID")
    echo && error "Forcefully terminating QEMU, reason: $reason..."
    { kill -15 "$pid" || true; } 2>/dev/null

    while isAlive "$pid"; do

      sleep 1
      (( cnt++ ))

      # Workaround for zombie pid
      [ ! -s "$QEMU_PID" ] && break

      if [ "$cnt" -eq 5 ]; then
        echo && error "QEMU did not terminate itself, forcefully killing process..."
        { kill -9 "$pid" || true; } 2>/dev/null
      fi

    done

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

  local code=$?

  set +e

  if [ -f "$QEMU_END" ]; then
    info "Received $1 while already shutting down..."
    return
  fi

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

  # Send ACPI shutdown signal
  echo 'system_powerdown' | nc -q 1 -w 1 localhost "$MON_PORT" > /dev/null

  local cnt=0
  while [ "$cnt" -lt "$QEMU_TIMEOUT" ]; do

    sleep 1
    (( cnt++ ))

    ! isAlive "$pid" && break
    # Workaround for zombie pid
    [ ! -s "$QEMU_PID" ] && break

    info "Waiting for VM to shutdown... ($cnt/$QEMU_TIMEOUT)"

    # Send ACPI shutdown signal
    echo 'system_powerdown' | nc -q 1 -w 1 localhost "$MON_PORT" > /dev/null

  done

  if [ "$cnt" -ge "$QEMU_TIMEOUT" ]; then
    error "Shutdown timeout reached, aborting..."
  fi

  finish "$code" && return "$code"
}

[[ "$SHUTDOWN" != [Yy1]* ]] && return 0

rm -f "$QEMU_DIR/qemu.*"
touch "$QEMU_LOG"

SERIAL="pty"
MONITOR="telnet:localhost:$MON_PORT,server,nowait,nodelay -daemonize -D $QEMU_LOG"

_trap _graceful_shutdown SIGTERM SIGHUP SIGINT SIGABRT SIGQUIT

return 0
