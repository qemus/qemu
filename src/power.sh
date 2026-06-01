#!/usr/bin/env bash
set -Eeuo pipefail

: "${SHUTDOWN:="Y"}"        # Graceful ACPI shutdown
: "${TIMEOUT:="13"}"        # QEMU termination timeout

# Configure QEMU for graceful shutdown

QEMU_END="$QEMU_DIR/qemu.end"

_trap() {
  local func="$1"; shift
  local sig
  for sig; do
    trap "$func $sig" "$sig"
  done
}

finish() {

  local pid=""
  local reason=$1
  local pids=( "$TPM_PID" "$WSD_PID" "$WEB_PID" "$PASST_PID" "$DNSMASQ_PID" )

  touch "$QEMU_END"

  if [ -s "$QEMU_PID" ]; then
    pid=$(<"$QEMU_PID")
    if [ -n "$pid" ] && isAlive "$pid"; then
      echo && error "Forcefully terminating QEMU, reason: $reason..."
      { kill -9 "$pid" || :; } 2>/dev/null
    fi
  fi

  mKill "${pids[@]}"

  closeNetwork

  while [ -s "$QEMU_PID" ] && [ -n "$pid" ] && isAlive "$pid"; do
    sleep 0.2
  done

  echo && echo "❯ Shutdown completed!"

  exit "$reason"
}

_graceful_shutdown() {

  local sig="$1"
  local code=0

  case "$sig" in
    SIGHUP)  code=129 ;;
    SIGINT)  code=130 ;;
    SIGQUIT) code=131 ;;
    SIGABRT) code=134 ;;
    SIGTERM) code=143 ;;
  esac

  if [ -f "$QEMU_END" ]; then
    echo && info "Received $1 while already shutting down..."
    return
  fi

  set +e
  touch "$QEMU_END"
  echo && info "Received $1, sending ACPI shutdown signal..."

  if [ ! -s "$QEMU_PID" ]; then
    warn "QEMU PID file does not exist?"
    finish "$code" && return "$code"
  fi

  local pid=""
  pid=$(<"$QEMU_PID")

  if [ -z "$pid" ] || ! isAlive "$pid"; then
    warn "QEMU process does not exist?"
    finish "$code" && return "$code"
  fi

  local cnt=0 abort=0 factor=2 offset=3 min max
  [ "$TIMEOUT" -ge 15 ] && factor=3 && offset=4
  [ "$TIMEOUT" -ge 30 ] && factor=4 && offset=5
  min=$((factor + offset + 1))
  [ "$TIMEOUT" -lt "$min" ] && TIMEOUT="$min"
  max=$(( TIMEOUT - offset ))
  abort=$(( max - factor ))

  while [ "$cnt" -le "$max" ]; do

    sleep 1 &
    local slp=$!

    ! isAlive "$pid" && break
    # Workaround for zombie pid
    [ ! -s "$QEMU_PID" ] && break

    if [ "$cnt" -ne "$abort" ]; then
      if [ "$cnt" -gt 0 ]; then
        info "Waiting for VM to shutdown... ($cnt/$max)"
      fi
    else
      info "QEMU is still running, sending SIGTERM... ($cnt/$max)"
      { kill -15 "$pid" || true; } 2>/dev/null
    fi

    # Send ACPI shutdown signal
    if [ -S "$QEMU_DIR/qmp.sock" ]; then
      nc -q 1 -w 1 -U "$QEMU_DIR/qmp.sock" > /dev/null <<<'system_powerdown' || :
    fi

    wait $slp
    (( cnt++ ))

  done

  finish "$code" && return "$code"
}

[[ "$SHUTDOWN" != [Yy1]* ]] && return 0
[ -n "${QEMU_TIMEOUT:-}" ] && TIMEOUT="$QEMU_TIMEOUT"

_trap _graceful_shutdown SIGTERM SIGHUP SIGINT SIGABRT SIGQUIT

return 0
