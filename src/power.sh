#!/usr/bin/env bash
set -Eeuo pipefail

: "${SHUTDOWN:="Y"}"        # Graceful ACPI shutdown
: "${TIMEOUT:="13"}"        # QEMU termination timeout

# Configure QEMU for graceful shutdown

QEMU_END="$QEMU_DIR/qemu.end"

_trap() {
  local func="$1"; shift
  local sig
  TRAP_PID=$BASHPID

  for sig; do
    trap "$func $sig" "$sig"
  done
}

app() {
  if [[ "$APP" == "QEMU" ]]; then
    echo "the virtual machine" && return 0
  fi

  echo "$APP" && return 0
}

signalCode() {
  local sig="$1"

  case "$sig" in
    SIGHUP)  echo 129 ;;
    SIGINT)  echo 130 ;;
    SIGQUIT) echo 131 ;;
    SIGABRT) echo 134 ;;
    SIGTERM) echo 143 ;;
    *)       echo 0 ;;
  esac
}

displayReason() {
  local reason="$1"

  case "$reason" in
    129 ) echo "SIGHUP" ;;
    130 ) echo "SIGINT" ;;
    131 ) echo "SIGQUIT" ;;
    134 ) echo "SIGABRT" ;;
    143 ) echo "SIGTERM" ;;
    * ) echo "$reason" ;;
  esac
}

readQemuPid() {
  local -n _pid="$1"

  if [ ! -s "$QEMU_PID" ] || ! read -r _pid <"$QEMU_PID"; then
    return 1
  fi

  return 0
}

forceKillQemu() {
  local pid=""
  local reason="$1"
  local display

  if [ -s "$QEMU_PID" ]; then
    if read -r pid <"$QEMU_PID"; then
      if [ -n "$pid" ] && isAlive "$pid"; then
        display="$(displayReason "$reason")"
        error "Forcefully terminating $(app), reason: $display..."
        { disown "$pid" || :; kill -9 -- "$pid" || :; } 2>/dev/null
      fi
    fi
  fi
}

cleanupHelpers() {

  local pids=( "${TPM_PID:-}" "${WSD_PID:-}" "${WEB_PID:-}" \
               "${PASST_PID:-}" "${DNSMASQ_PID:-}" "${BALLOONING_PID:-}" )

  mKill "${pids[@]}"
  closeNetwork
}

finish() {

  local reason=$1

  touch "$QEMU_END"

  forceKillQemu "$reason"
  cleanupHelpers

  if ! waitPidFile "$QEMU_PID" 10; then
    warn "Timed out while waiting for $(app) to exit!"
  fi

  (( reason != 1 )) && echo && echo "❯ Shutdown completed!"
  exit "$reason"
}

normalizeTimeout() {

  local -n _term_grace="$1"
  local -n _cleanup_grace="$2"
  local -n _wait_until="$3"
  local -n _sigterm_at="$4"
  local min

  _term_grace=3      # seconds before loop ends to send SIGTERM
  _cleanup_grace=3   # seconds reserved after the loop for cleanup

  TIMEOUT=$(strip "$TIMEOUT")
  if [[ ! "$TIMEOUT" =~ ^[0-9]+$ ]]; then
    TIMEOUT=13
  fi

  if (( TIMEOUT >= 30 )); then
    _term_grace=5
    _cleanup_grace=5
  elif (( TIMEOUT >= 15 )); then
    _term_grace=4
    _cleanup_grace=4
  fi

  min=$((_term_grace + _cleanup_grace + 1))
  (( TIMEOUT < min )) && (( TIMEOUT = min ))

  _wait_until=$((TIMEOUT - _cleanup_grace))
  _sigterm_at=$((_wait_until - _term_grace))
}

sendAcpiShutdown() {

  # Send ACPI shutdown signal
  if [ -S "$QEMU_DIR/monitor.sock" ]; then
    nc -q 1 -w 1 -U "$QEMU_DIR/monitor.sock" &> /dev/null <<<'system_powerdown' || :
  fi
}

waitForShutdown() {

  local pid="$1"
  local name="$2"
  local cnt=0
  local sigterm_at=0
  local wait_until=0
  local term_grace=0
  local cleanup_grace=0
  local slp

  normalizeTimeout term_grace cleanup_grace wait_until sigterm_at

  while (( cnt <= wait_until )); do

    sleep 1 &
    slp=$!

    # Stop waiting if the process has exited
    ! isAlive "$pid" && break

    # Workaround for stale/zombie QEMU pid file
    [ ! -s "$QEMU_PID" ] && break

    if (( cnt == sigterm_at )); then
      info "${name^} is still running, sending SIGTERM... ($cnt/$wait_until)"
      kill -15 -- "$pid" 2>/dev/null || :
    elif (( cnt > 0 )); then
      info "Waiting for $name to shut down... ($cnt/$wait_until)"
    fi

    sendAcpiShutdown

    wait "$slp"
    (( cnt++ ))

  done
}

graceful_shutdown() {

  local sig="$1"
  local pid=""
  local code=0
  local name

  [[ $BASHPID != "$TRAP_PID" ]] && return

  code=$(signalCode "$sig")

  if [ -f "$QEMU_END" ]; then
    echo && info "Received $1 signal while already shutting down..."
    return
  fi

  set +e
  touch "$QEMU_END"
  echo && info "Received $1 signal, sending ACPI shutdown signal..."

  if ! readQemuPid pid; then
    warn "QEMU PID file ($QEMU_PID) does not exist?"
    finish "$code"
  fi

  if [ -z "$pid" ] || ! isAlive "$pid"; then
    warn "QEMU process with PID $pid does not exist?"
    finish "$code"
  fi

  name="$(app)"
  waitForShutdown "$pid" "$name"
  finish "$code"
}

! enabled "$SHUTDOWN" && return 0

_trap graceful_shutdown SIGTERM SIGHUP SIGABRT SIGQUIT

return 0
