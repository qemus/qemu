#!/usr/bin/env bash
set -Eeuo pipefail

NOVNC=/usr/share/novnc

cp -f /var/www/js/audio.js "$NOVNC/audio-plugin.js"
grep -q audio-plugin.js "$NOVNC/vnc.html" || \
  sed -i 's#</head>#    <script src="audio-plugin.js"></script>\n</head>#' "$NOVNC/vnc.html"
if ! grep -q noVNC_setting_audio "$NOVNC/vnc.html"; then
  python3 - "$NOVNC/vnc.html" <<'PY'
import sys
f=sys.argv[1]; s=open(f).read()
a='''                            <li>
                                <label>
                                    <input id="noVNC_setting_show_dot" type="checkbox"'''
b='''                            <li>
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
if a in s: open(f,'w').write(s.replace(a,b,1))
PY
fi

NGINX=/etc/nginx/sites-enabled/web.conf

if [ -f "$NGINX" ] && ! grep -q 'location = /audio' "$NGINX"; then
  python3 - "$NGINX" <<'PY'
import sys
f=sys.argv[1]; s=open(f).read()
blk='''
    location = /audio {
      proxy_http_version 1.1;
      proxy_set_header Connection 'upgrade';
      proxy_set_header Upgrade $http_upgrade;
      proxy_buffering off;
      proxy_read_timeout 3600s;
      proxy_send_timeout 3600s;
      proxy_pass http://127.0.0.1:8007/;
    }
'''
i=s.rstrip().rfind('}')
open(f,'w').write(s[:i]+blk+'\n}\n')
PY
  nginx -s reload 2>/dev/null || true
fi

rm -f /run/audio.fifo
mkfifo /run/audio.fifo

nohup python3 /run/audio.py >/run/audio_relay.log 2>&1 & disown

printf '#!/bin/sh\nexec nc 127.0.0.1 4712\n' > /run/audio_pipe.sh
chmod +x /run/audio_pipe.sh

nohup websocketd --port=8007 --binary=true /run/audio_pipe.sh >/run/audio_ws.log 2>&1 & disown
