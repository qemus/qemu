#!/bin/sh

set -eu

VERSION_VNC="${1:?noVNC version must be specified}"
ARCHIVE="/tmp/novnc.tar.gz"
SOURCE_DIR="/tmp/noVNC-${VERSION_VNC}"
INSTALL_DIR="/usr/share/novnc"
UI_FILE="${SOURCE_DIR}/app/ui.js"
HTML_FILE="${SOURCE_DIR}/vnc.html"

mkdir -p "$INSTALL_DIR"

wget \
  "https://github.com/novnc/noVNC/archive/refs/tags/v${VERSION_VNC}.tar.gz" \
  -O "$ARCHIVE" \
  -q \
  --timeout=10

tar -xf "$ARCHIVE" -C /tmp/

if [ ! -f "$UI_FILE" ]; then
  echo "ERROR: noVNC UI file not found: $UI_FILE" >&2
  exit 1
fi

if [ ! -f "$HTML_FILE" ]; then
  echo "ERROR: noVNC HTML file not found: $HTML_FILE" >&2
  exit 1
fi

python3 - "$UI_FILE" "$HTML_FILE" <<'PY'
import re
import sys
from pathlib import Path

ui_file = Path(sys.argv[1])
html_file = Path(sys.argv[2])

ui = ui_file.read_text(encoding="utf-8")
html = html_file.read_text(encoding="utf-8")


def replace_once(content, original, replacement, description):
    count = content.count(original)

    if count != 1:
        raise SystemExit(
            f"ERROR: expected one {description}, found {count}"
        )

    return content.replace(original, replacement, 1)


def replace_pattern_once(content, pattern, replacement, description):
    content, count = re.subn(
        pattern,
        replacement,
        content,
        count=1,
        flags=re.MULTILINE | re.DOTALL,
    )

    if count != 1:
        raise SystemExit(
            f"ERROR: expected one {description}, found {count}"
        )

    return content


beforeunload_pattern = (
    r'^[ \t]*window\.addEventListener\('
    r'["\']beforeunload["\'],[ \t]*UI\.handleBeforeUnload'
    r'\);[ \t]*\n'
)

ui = replace_pattern_once(
    ui,
    beforeunload_pattern,
    "",
    "noVNC beforeunload handler",
)

autoconnect = '''        if (autoconnect === 'true' || autoconnect == '1') {
            autoconnect = true;
            UI.connect();
'''

patched_autoconnect = '''        if (autoconnect === 'true' || autoconnect == '1') {
            autoconnect = true;
            UI.inhibitReconnect = false;
            UI.connect();
'''

ui = replace_once(
    ui,
    autoconnect,
    patched_autoconnect,
    "noVNC autoconnect block",
)

reconnect_pattern = (
    r'^    reconnect\(\)[ \t]*\{.*?'
    r'^    \},[ \t]*\n'
    r'(?=[ \t]*\n^    cancelReconnect\(\)[ \t]*\{)'
)

patched_reconnect = '''    async reconnect() {
        UI.reconnectCallback = null;

        // if reconnect has been disabled in the meantime, do nothing.
        if (UI.inhibitReconnect) {
            return;
        }

        try {
            const path = window.location.pathname
                .replace(/[^/]*$/, '')
                .replace(/\\/$/, '');
            const response = await fetch(
                `${path}/msg.html?_=${Date.now()}`,
                {
                    cache: 'no-store',
                },
            );

            if (response.ok) {
                window.location.reload();
                return;
            }
        } catch (err) {
            Log.Warn("Failed to check for message page: " + err);
        }

        // Recheck in case reconnecting was disabled during the request.
        if (UI.inhibitReconnect) {
            return;
        }

        UI.connect(null, UI.reconnectPassword, true);
    },
'''

ui = replace_pattern_once(
    ui,
    reconnect_pattern,
    patched_reconnect,
    "noVNC reconnect function",
)

connect_signature = '''    connect(event, password) {
'''

patched_connect_signature = '''    connect(event, password, reconnecting = false) {
'''

ui = replace_once(
    ui,
    connect_signature,
    patched_connect_signature,
    "noVNC connect function signature",
)

connecting_state = '''        UI.updateVisualState('connecting');
'''

patched_connecting_state = '''        UI.updateVisualState(
            reconnecting ? 'reconnecting' : 'connecting'
        );
'''

ui = replace_once(
    ui,
    connecting_state,
    patched_connecting_state,
    "noVNC connecting visual state",
)

clipboard_unhide = '''            document.getElementById('noVNC_clipboard_button')
                .classList.remove('noVNC_hidden');
'''

ui = replace_once(
    ui,
    clipboard_unhide,
    "",
    "noVNC clipboard unhide operation",
)

original_favicon = (
    '<link rel="icon" type="image/x-icon" '
    'href="app/images/icons/novnc.ico">'
)

patched_favicon = (
    '<link rel="icon" type="image/svg+xml" '
    'href="app/images/favicon.svg">'
)

html = replace_once(
    html,
    original_favicon,
    patched_favicon,
    "noVNC favicon",
)

original_logo = (
    '<p class="noVNC_logo" translate="no">'
    '<span>no</span>VNC</p>'
)

patched_logo = (
    '<img class="noVNC_logo" '
    'src="app/images/favicon.svg" '
    'alt="Logo" '
    'style="display: block; width: 50%; height: auto; '
    'margin: 0 auto 20px;">'
)

html = replace_once(
    html,
    original_logo,
    patched_logo,
    "noVNC logo",
)

original_clipboard = (
    '<input type="image" alt="Clipboard" '
    'src="app/images/clipboard.svg"\n'
    '                id="noVNC_clipboard_button" '
    'class="noVNC_button"\n'
    '                title="Clipboard">'
)

patched_clipboard = (
    '<input type="image" alt="Clipboard" '
    'src="app/images/clipboard.svg"\n'
    '                id="noVNC_clipboard_button" '
    'class="noVNC_button noVNC_hidden"\n'
    '                title="Clipboard">'
)

html = replace_once(
    html,
    original_clipboard,
    patched_clipboard,
    "noVNC clipboard button",
)

audio_script = '    <script src="audio-plugin.js"></script>\n'

if audio_script not in html:
    html = replace_once(
        html,
        '</head>',
        f'{audio_script}</head>',
        "noVNC closing head tag",
    )

audio_marker = '''                            <li>
                                <label>
                                    <input id="noVNC_setting_show_dot" type="checkbox"'''

audio_controls = '''                            <li id="noVNC_setting_audio_row" hidden>
                                <label>
                                    <input id="noVNC_setting_audio" type="checkbox"
                                           class="toggle">
                                    Audio
                                </label>
                            </li>
                            <li id="noVNC_setting_audio_separator" hidden><hr></li>
                            <li>
                                <label>
                                    <input id="noVNC_setting_show_dot" type="checkbox"'''

html = replace_once(
    html,
    audio_marker,
    audio_controls,
    "noVNC settings menu",
)

ui_file.write_text(ui, encoding="utf-8")
html_file.write_text(html, encoding="utf-8")
PY

cd "$SOURCE_DIR"
mv app core vendor package.json ./*.html "$INSTALL_DIR"

ln -sf /var/www/js/audio.js "$INSTALL_DIR/audio-plugin.js"
