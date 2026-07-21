#!/usr/bin/env bash
set -Eeuo pipefail

: "${SHUTDOWN:="Y"}"        # Graceful ACPI shutdown
: "${TIMEOUT:="13"}"        # QEMU termination timeout

# Configure QEMU for graceful shutdown

SHUTDOWN_SKIP=0
SHUTDOWN_SIGNAL=0

QEMU_END="$QEMU_DIR/qemu.end"
CONSOLE_PID="$QEMU_DIR/console.pid"
CONSOLE_SOCKET="$QEMU_DIR/console.sock"
QEMU_START_PID="$QEMU_DIR/qemu.start.pid"

finish() {

  local reason=$1 failed=0

  if [ ! -f "$QEMU_END" ] && (( reason != 0 )); then
    failed=1
  fi

  touch "$QEMU_END"

  forceKillQemu "$reason"
  cleanupHelpers

  if ! waitQemuExit 10; then
    warn "Timed out while waiting for $(app) to exit!"
  fi

  echo

  if (( failed == 0 )); then
    echo "❯ Shutdown completed!"
  else
    error "QEMU exited unexpectedly!"
  fi

  exit "$reason"
}

gracefulShutdown() {

  local sig="$1"
  local pid="" code=0

  [[ $BASHPID != "$TRAP_PID" ]] && return

  code=$(signalCode "$sig")

  if [ -f "$QEMU_END" ]; then

    if (( code == 130 && SHUTDOWN_SIGNAL == code )); then
      SHUTDOWN_SKIP=1
      echo && info "Received SIGINT again, forcing shutdown..."
      return
    fi

    echo && info "Received $sig signal while already shutting down..."
    return
  fi

  set +e
  SHUTDOWN_SIGNAL=$code

  touch "$QEMU_END"
  echo && info "Received $sig signal, sending ACPI shutdown signal..."

  if ! readQemuPid pid; then
    if ! interactive || ! waitQemuPid pid; then
      warn "QEMU PID file does not exist?"
      finish "$code"
    fi
  fi

  if [ -z "$pid" ] || ! isAlive "$pid"; then
    warn "QEMU process with PID $pid does not exist?"
    finish "$code"
  fi

  normalizeTimeout 13
  waitForShutdown "$pid"

  finish "$code"
}

! enabled "$SHUTDOWN" && return 0

if interactive; then
  _trap gracefulShutdown SIGINT
fi

_trap gracefulShutdown SIGTERM SIGHUP SIGABRT SIGQUIT

return 0
