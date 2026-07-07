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

  return 0
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

  local reason="$1"
  local pid=""
  local display

  ! readQemuPid pid && return 0
  ! isAlive "$pid" && return 0
  
  display=$(displayReason "$reason")
  error "Forcefully terminating $(app), reason: $display..."
  { disown "$pid" || :; kill -9 -- "$pid" || :; } 2>/dev/null

  return 0
}

cleanupHelpers() {

  local pids=( "${TPM_PID:-}" "${WSD_PID:-}" "${WEB_PID:-}" \
               "${PASST_PID:-}" "${DNSMASQ_PID:-}" "${BALLOONING_PID:-}" )

  mKill "${pids[@]}"

  closeNetwork
  return 0
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

  local term_grace=3      # seconds before loop ends to send SIGTERM
  local cleanup_grace=3   # seconds reserved after the loop for cleanup
  local min

  TIMEOUT=$(strip "$TIMEOUT")
  if [[ ! "$TIMEOUT" =~ ^[0-9]+$ ]]; then
    TIMEOUT=13
  fi

  if (( TIMEOUT >= 30 )); then
    term_grace=5
    cleanup_grace=5
  elif (( TIMEOUT >= 15 )); then
    term_grace=4
    cleanup_grace=4
  fi

  min=$((term_grace + cleanup_grace + 1))
  (( TIMEOUT < min )) && (( TIMEOUT = min ))

  wait_until=$((TIMEOUT - cleanup_grace))
  sigterm_at=$((wait_until - term_grace))

  return 0
}

sendAcpiShutdown() {

  [ ! -S "$QEMU_DIR/monitor.sock" ] && return 0

  # Send ACPI shutdown signal
  nc -q 1 -w 1 -U "$QEMU_DIR/monitor.sock" &> /dev/null <<<'system_powerdown' || :

  return 0
}

waitForShutdown() {

  local pid="$1"
  local name="$APP"
  local cnt=0
  local slp

  if [[ "$name" == "QEMU" ]]; then
    name="the virtual machine"
  fi
  
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

  return 0
}

graceful_shutdown() {

  local sig="$1"
  local pid=""
  local code=0

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

  normalizeTimeout
  waitForShutdown "$pid"

  finish "$code"
}

! enabled "$SHUTDOWN" && return 0

_trap graceful_shutdown SIGTERM SIGHUP SIGABRT SIGQUIT

return 0
