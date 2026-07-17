#!/usr/bin/env bash
set -Eeuo pipefail

NOVNC="/usr/share/novnc"
NOVNC_HTML="$NOVNC/vnc.html"
AUDIO_RELAY="/run/audio.py"
AUDIO_LOG="/var/log/audio.log"
AUDIO_PID="$QEMU_DIR/audio.pid"
AUDIO_FIFO="$QEMU_DIR/audio.fifo"
AUDIO_SOCKET="$QEMU_DIR/audio.sock"
AUDIO_PLUGIN="/var/www/js/audio.js"

supportsAudio() {

  case "${MACHINE,,}" in
    q35|virt) return 0 ;;
  esac

  return 1
}

installAudioPlugin() {

  [ -f "$AUDIO_PLUGIN" ] || {
    echo "Audio plugin not found: $AUDIO_PLUGIN" >&2
    return 1
  }

  [ -f "$NOVNC_HTML" ] || {
    echo "noVNC page not found: $NOVNC_HTML" >&2
    return 1
  }

  cp -f "$AUDIO_PLUGIN" "$NOVNC/audio-plugin.js"

  if ! grep -Fq 'src="audio-plugin.js"' "$NOVNC_HTML"; then
    sed -i 's#</head>#    <script src="audio-plugin.js"></script>\n</head>#' "$NOVNC_HTML"
  fi

  if grep -Fq 'id="noVNC_setting_audio"' "$NOVNC_HTML"; then
    return 0
  fi

  python3 - "$NOVNC_HTML" <<'PY'
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

  return 0
}

startAudioRelay() {

  [ -f "$AUDIO_RELAY" ] || {
    echo "Audio relay not found: $AUDIO_RELAY" >&2
    return 1
  }

  rm -f "$AUDIO_FIFO" "$AUDIO_SOCKET" "$AUDIO_LOG"
  mkfifo -m 0600 "$AUDIO_FIFO"

  python3 "$AUDIO_RELAY" "$AUDIO_FIFO" "$AUDIO_SOCKET" \
    >"$AUDIO_LOG" 2>&1 &

  local pid=$!

  if ! echo "$pid" > "$AUDIO_PID"; then
    kill "$pid" 2>/dev/null || :
    return 1
  fi

  sleep 0.1

  if ! isAlive "$pid"; then
    rm -f "$AUDIO_PID" "$AUDIO_SOCKET"
    [ -s "$AUDIO_LOG" ] && cat "$AUDIO_LOG" >&2
    error "Failed to start audio relay!"
    return 1
  fi

  return 0
}

! enabled "$AUDIO" && return 0

if disabled "${WEB:-}"; then
  AUDIO="N"
  return 0
fi

if ! supportsAudio; then
  AUDIO="N"
  warn "audio is not supported with machine type '$MACHINE', ignoring AUDIO=Y."
  return 0
fi

if installAudioPlugin; then
  if startAudioRelay; then
    if startAudioServer; then
      return 0
    fi
  fi
fi

AUDIO="N"
warn "Audio support failed to initialize, ignoring AUDIO=Y."
return 0
