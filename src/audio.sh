#!/usr/bin/env bash
set -Eeuo pipefail

NOVNC="/usr/share/novnc"
NOVNC_HTML="$NOVNC/vnc.html"

AUDIO_RELAY="/run/audio.py"
AUDIO_LOG="/var/log/audio.log"
AUDIO_PID="$QEMU_DIR/audio.pid"
AUDIO_FIFO="$QEMU_DIR/audio.fifo"
AUDIO_SOCKET="$QEMU_DIR/audio.sock"

supportsAudio() {

  isQ35 && return 0

  case "${MACHINE,,}" in
    "pc" | "pc-i440fx-"* | "virt"* )
      return 0 ;;
  esac

  return 1
}

disableAudioControl() {

  if ! sed -i \
    -e '/id="noVNC_setting_audio"/ s/ disabled//' \
    -e '/id="noVNC_setting_audio"/ s/type="checkbox"/type="checkbox" disabled/' \
    "$NOVNC_HTML"
  then
    error "Failed to disable noVNC audio control!"
    return 1
  fi

  return 0
}

enableAudioControl() {

  if ! sed -i '/id="noVNC_setting_audio"/ s/type="checkbox" disabled/type="checkbox"/' "$NOVNC_HTML"; then
    error "Failed to enable noVNC audio control!"
    return 1
  fi

  return 0
}

stopAudioRelay() {

  local pid

  if readPidFile pid "$AUDIO_PID"; then
    pKill "$pid" 2

    if isAlive "$pid"; then
      kill -9 -- "$pid" 2>/dev/null || :
    fi
  fi

  rm -f -- "$AUDIO_PID" "$AUDIO_FIFO" "$AUDIO_SOCKET"
  return 0
}

startAudioRelay() {

  [ -f "$AUDIO_RELAY" ] || {
    error "Audio relay not found: $AUDIO_RELAY"
    return 1
  }

  if ! rm -f -- "$AUDIO_FIFO" "$AUDIO_SOCKET" "$AUDIO_LOG"; then
    error "Failed to clean up previous audio relay files!"
    return 1
  fi

  if ! mkfifo -m 0600 "$AUDIO_FIFO"; then
    error "Failed to create audio FIFO \"$AUDIO_FIFO\"!"
    return 1
  fi

  # QEMU writes a WAV stream into the FIFO; the relay strips its header and
  # exposes PCM through a Unix socket that websocketd streams to the browser.
  python3 "$AUDIO_RELAY" "$AUDIO_FIFO" "$AUDIO_SOCKET" \
    >"$AUDIO_LOG" 2>&1 &

  local pid=$!

  if ! echo "$pid" > "$AUDIO_PID"; then
    kill "$pid" 2>/dev/null || :
    stopAudioRelay
    return 1
  fi

  local i
  for (( i = 1; i < 25; i++ )); do

    if [ -S "$AUDIO_SOCKET" ] && isAlive "$pid"; then
      return 0
    fi

    if ! isAlive "$pid"; then
      break
    fi

    if (( i % 5 == 0 )); then
      echo "Waiting for audio relay to launch..."
    fi

    sleep 0.25

  done

  stopAudioRelay
  [ -s "$AUDIO_LOG" ] && cat "$AUDIO_LOG" >&2

  error "Failed to start audio relay!"
  return 1
}

# Keep the control disabled unless audio is successfully initialized below.
disableAudioControl || return 1
enabled "$AUDIO" || return 0

if disabled "${WEB:-}"; then
  AUDIO="N"
  return 0
fi

if ! supportsAudio; then
  AUDIO="N"
  warn "audio is not supported with machine type '$MACHINE', ignoring AUDIO=Y."
  return 0
fi

if startAudioRelay && startAudioServer; then
  enableAudioControl && return 0
fi

stopAudioServer || :
stopAudioRelay || :
disableAudioControl || :

AUDIO="N"

warn "Audio support failed to initialize, ignoring AUDIO=Y."
return 0
