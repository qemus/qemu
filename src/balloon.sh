#!/usr/bin/env bash
set -Eeuo pipefail

: "${BALLOONING:="N"}"
: "${BALLOONING_DEBUG:="N"}"
: "${BALLOONING_PID:="$QEMU_DIR/balloon.pid"}"
: "${BALLOONING_SOCKET:="$QEMU_DIR/qemu-qmp-ballooning.sock"}"

rm -f "$BALLOONING_PID" "$BALLOONING_SOCKET"

! enabled "$BALLOONING" && return 0

# Memory ballooning dynamically adjusts guest memory based on host pressure and container memory limits. 
# See the docs/ballooning.md documentation for behavior, configuration, tuning options, and important caveats.

waitForQemuPid() {

  # Wait until QEMU has published a non-empty PID file.
  while [ ! -s "$QEMU_PID" ]; do
    [ -f "$QEMU_END" ] && return 1
    sleep 1
  done

  return 0
}

buildBalloonArgs() {
  BALLOON_ARGS=()

  [[ -n "${BALLOONING_MIN_MEM:-}" ]] && BALLOON_ARGS+=(--min-mem "$BALLOONING_MIN_MEM")
  [[ -n "${BALLOONING_PSI_PRESSURE:-}" ]] && BALLOON_ARGS+=(--psi-pressure "$BALLOONING_PSI_PRESSURE")
  [[ -n "${BALLOONING_PSI_PRESSURE_MAX:-}" ]] && BALLOON_ARGS+=(--psi-pressure-max "$BALLOONING_PSI_PRESSURE_MAX")
  [[ -n "${BALLOONING_RAM_THRESHOLD:-}" ]] && BALLOON_ARGS+=(--ram-threshold "$BALLOONING_RAM_THRESHOLD")
  [[ -n "${BALLOONING_RAM_THRESHOLD_HARD:-}" ]] && BALLOON_ARGS+=(--ram-threshold-hard "$BALLOONING_RAM_THRESHOLD_HARD")
  [[ -n "${BALLOONING_HYSTERESIS:-}" ]] && BALLOON_ARGS+=(--hysteresis "$BALLOONING_HYSTERESIS")
  [[ -n "${BALLOONING_KP:-}" ]] && BALLOON_ARGS+=(--kp "$BALLOONING_KP")
  [[ -n "${BALLOONING_KI:-}" ]] && BALLOON_ARGS+=(--ki "$BALLOONING_KI")
  [[ -n "${BALLOONING_INTERVAL:-}" ]] && BALLOON_ARGS+=(--interval "$BALLOONING_INTERVAL")

  if enabled "$BALLOONING_DEBUG"; then
    BALLOON_ARGS+=(--debug)
  elif [[ -n "$BALLOONING_DEBUG" ]] && ! disabled "$BALLOONING_DEBUG"; then
    BALLOON_ARGS+=(--debug "$BALLOONING_DEBUG")
  fi

  return 0
}

startBalloonMonitor() {
  local pid

  python3 ./balloon.py --qmp-sock "$BALLOONING_SOCKET" --qemu-pid-file "$QEMU_PID" "${BALLOON_ARGS[@]}" &
  pid="$!"
  echo "$pid" > "$BALLOONING_PID"
  wait "$pid" || :
  rm -f -- "$BALLOONING_PID"

  return 0
}

balloon() {

  waitForQemuPid || return 0
  buildBalloonArgs
  startBalloonMonitor

  return 0
}

msg="Starting memory ballooning monitor..."
enabled "$DEBUG" && echo "$msg"

( balloon ) &

return 0
