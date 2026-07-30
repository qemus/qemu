#!/usr/bin/env bash
set -Eeuo pipefail

NOVNC="/usr/share/novnc"
NOVNC_HTML="$NOVNC/vnc.html"
NOVNC_BACKUP="$NOVNC_HTML.bak"

AUDIO_RELAY="/run/audio.py"
AUDIO_LOG="/var/log/audio.log"
AUDIO_PID="$QEMU_DIR/audio.pid"
AUDIO_FIFO="$QEMU_DIR/audio.fifo"
AUDIO_SOCKET="$QEMU_DIR/audio.sock"
AUDIO_PLUGIN="/var/www/js/audio.js"

supportsAudio() {

  isQ35 && return 0

  case "${MACHINE,,}" in
    pc|pc-i440fx-*|virt)
      return 0
      ;;
  esac

  return 1
}

installAudioPlugin() {

  [ -f "$AUDIO_PLUGIN" ] || {
    error "Audio plugin not found: $AUDIO_PLUGIN"
    return 1
  }

  [ -f "$NOVNC_HTML" ] || {
    error "noVNC page not found: $NOVNC_HTML"
    return 1
  }

  if ! cp -f "$AUDIO_PLUGIN" "$NOVNC/audio-plugin.js"; then
    error "Failed to install audio plugin!"
    return 1
  fi

  if ! grep -Fq 'src="audio-plugin.js"' "$NOVNC_HTML"; then
    if ! sed -i \
      's#</head>#    <script src="audio-plugin.js"></script>\n</head>#' \
      "$NOVNC_HTML"; then
      error "Failed to add audio plugin to noVNC page!"
      return 1
    fi
  fi

  if grep -Fq 'id="noVNC_setting_audio"' "$NOVNC_HTML"; then
    return 0
  fi

  if ! python3 - "$NOVNC_HTML" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
content = path.read_text()

marker = '''                            <li>
                                <label>
                                    <input id="noVNC_setting_show_dot" type="checkbox"'''

replacement = '''                            <li>
                                <label>
                                    <input id="noVNC_setting_audio" type="checkbox"
                                           class="toggle">
                                    Audio
                                </label>
                            </li>
                            <li><hr></li>
                            <li>
                                <label>
                                    <input id="noVNC_setting_show_dot" type="checkbox"'''

if marker not in content:
    raise SystemExit("Unable to locate the noVNC settings menu")

path.write_text(content.replace(marker, replacement, 1))
PY
  then
    error "Failed to add audio controls to noVNC page!"
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

backupHtml() {

  local tmp="$NOVNC_BACKUP.tmp"

  [ -f "$NOVNC_BACKUP" ] && return 0

  rm -f -- "$tmp"

  if ! cp -p -- "$NOVNC_HTML" "$tmp"; then
    rm -f -- "$tmp"
    error "Failed to backup noVNC html!"
    return 1
  fi

  if ! mv -f -- "$tmp" "$NOVNC_BACKUP"; then
    rm -f -- "$tmp"
    error "Failed to save noVNC html backup!"
    return 1
  fi

  return 0
}

restoreHtml() {

  [ -f "$NOVNC_BACKUP" ] || return 0

  if ! cp -p -- "$NOVNC_BACKUP" "$NOVNC_HTML"; then
    error "Failed to restore noVNC html!"
    return 1
  fi

  return 0
}

restoreHtml || return 1
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

if backupHtml &&
  installAudioPlugin &&
  startAudioRelay &&
  startAudioServer
then
  return 0
fi

stopAudioServer || :
stopAudioRelay || :
restoreHtml || :

AUDIO="N"

warn "Audio support failed to initialize, ignoring AUDIO=Y."
return 0
