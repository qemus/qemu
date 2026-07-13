#!/usr/bin/env bash
set -Eeuo pipefail

NOVNC="/usr/share/novnc"
NOVNC_HTML="$NOVNC/vnc.html"
AUDIO_RELAY="/run/audio.py"
AUDIO_FIFO="/run/audio.fifo"
AUDIO_PIPE="/run/audio-pipe.sh"
AUDIO_PLUGIN="/var/www/js/audio.js"

RELAY_PORT="4712"

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

  rm -f "$AUDIO_FIFO"
  mkfifo -m 0600 "$AUDIO_FIFO"

  python3 "$AUDIO_RELAY" >/var/log/audio-relay.log 2>&1 &

  return 0
}

startAudioServer() {

  cat > "$AUDIO_PIPE" <<EOF
#!/bin/sh
exec nc 127.0.0.1 $RELAY_PORT
EOF

  chmod 0700 "$AUDIO_PIPE"

  websocketd \
    --address=127.0.0.1 \
    --port="$WEBSOCKET_PORT" \
    --binary=true \
    "$AUDIO_PIPE" \
    >/var/log/audio-websocket.log 2>&1 &

  return 0
}

disabled "${WEB:-}" && return 0

installAudioPlugin

startAudioRelay
startAudioServer
