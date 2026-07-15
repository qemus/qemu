#!/usr/bin/env bash
set -Eeuo pipefail

: "${VNC_PORT:="5900"}"    # VNC port
: "${WEB_PORT:="8006"}"    # Webserver port
: "${WSD_PORT:="8004"}"    # Websockets port
: "${AUX_PORT:="8003"}"    # Audio streaming
: "${WSS_PORT:="5700"}"    # Websockets port

# Sanitize port variables
VNC_PORT=$(strip "$VNC_PORT")
WEB_PORT=$(strip "$WEB_PORT")
WSD_PORT=$(strip "$WSD_PORT")
AUX_PORT=$(strip "$AUX_PORT")
WSS_PORT=$(strip "$WSS_PORT")

WEB_PID="/run/nginx.pid"
WSD_PID="$QEMU_DIR/websocketd.pid"
AUX_PID="$QEMU_DIR/audio-websocketd.pid"

validateVncPort() {

  if (( VNC_PORT < 5900 )); then
    warn "VNC port cannot be set lower than 5900, ignoring value $VNC_PORT."
    VNC_PORT="5900"
  fi

  return 0
}

prepareWebFiles() {

  cp -r /var/www/* "$QEMU_DIR" || return 1
  rm -f "$WSD_PID" "$AUX_PID" "$WEB_PID" || return 1

  return 0
}

configureAuthentication() {
  local user pass

  if ! enabled "${PROTECT:-}" && [ -z "${PASS:-}" ]; then
    return 0
  fi

  user="Docker"
  pass="admin"

  USERNAME=$(strip "${USERNAME:-}")
  [ -n "${USERNAME:-}" ] && user="$USERNAME"
  [ -n "${PASSWORD:-}" ] && pass="$PASSWORD"

  # Backwards compatibility
  [ -n "${PASS:-}" ] && pass="$PASS"

  # Set password
  echo "$user:{PLAIN}$pass" > /etc/nginx/.htpasswd

  sed -i "s/auth_basic off/auth_basic \"NoVNC\"/g" /etc/nginx/sites-enabled/web.conf
}

configureWebPorts() {
  sed -i "s/listen 8006 default_server;/listen $WEB_PORT default_server;/g" /etc/nginx/sites-enabled/web.conf
  sed -i "s/proxy_pass http:\/\/127.0.0.1:5700\/;/proxy_pass http:\/\/127.0.0.1:$WSS_PORT\/;/g" /etc/nginx/sites-enabled/web.conf
  sed -i "s/proxy_pass http:\/\/127.0.0.1:8004\/;/proxy_pass http:\/\/127.0.0.1:$WSD_PORT\/;/g" /etc/nginx/sites-enabled/web.conf
  sed -i "s/proxy_pass http:\/\/127.0.0.1:8003\/;/proxy_pass http:\/\/127.0.0.1:$AUX_PORT\/;/g" /etc/nginx/sites-enabled/web.conf
}

configureIpv6Listen() {

  # shellcheck disable=SC2143
  if [ -f /proc/net/if_inet6 ] && [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" != "1" ]] && [ -n "$(ifconfig -a | grep inet6)" ]; then

    sed -i "s/listen $WEB_PORT default_server;/listen [::]:$WEB_PORT default_server ipv6only=off;/g" /etc/nginx/sites-enabled/web.conf

  fi
}

configureWebServer() {

  mkdir -p /etc/nginx/sites-enabled
  cp /etc/nginx/default.conf /etc/nginx/sites-enabled/web.conf

  configureAuthentication
  configureWebPorts
  configureIpv6Listen
}

startWebServer() {

  # Start webserver
  nginx -e stderr || return 1

  return 0
}

startWebsocketServer() {

  local log="/var/log/websocketd.log"
  rm -f "$log"

  # Start websocket server
  websocketd --address 127.0.0.1 --port="$WSD_PORT" /run/socket.sh > "$log" 2>&1 &
  local pid=$!

  if ! echo "$pid" > "$WSD_PID"; then
    kill "$pid" 2>/dev/null || :
    return 1
  fi

  sleep 0.1

  if ! isAlive "$pid"; then
    rm -f "$WSD_PID"
    [ -s "$log" ] && cat "$log" >&2
    error "Failed to start websocket server!"
    return 1
  fi

  return 0
}

startAudioServer() {

  local log="/var/log/audio-websocket.log"
  rm -f "$log"

  cat > "$AUDIO_PIPE" <<EOF
#!/bin/sh
exec nc 127.0.0.1 $RELAY_PORT
EOF

  chmod 0700 "$AUDIO_PIPE"

  # Start audio websocket server
  websocketd \
    --address 127.0.0.1 \
    --port="$AUX_PORT" \
    --binary=true \
    "$AUDIO_PIPE" \
    > "$log" 2>&1 &

  local pid=$!

  if ! echo "$pid" > "$AUX_PID"; then
    kill "$pid" 2>/dev/null || :
    return 1
  fi

  sleep 0.1

  if ! isAlive "$pid"; then
    rm -f "$AUX_PID"
    [ -s "$log" ] && cat "$log" >&2
    error "Failed to start audio websocket server!"
    return 1
  fi

  return 0
}

validateVncPort
prepareWebFiles

html "Starting $APP for $ENGINE..."

if ! disabled "${WEB:-}"; then
  configureWebServer || return 1
  startWebServer || return 1
  startWebsocketServer || return 1
fi

return 0
