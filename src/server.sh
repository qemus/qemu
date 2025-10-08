#!/usr/bin/env bash
set -Eeuo pipefail

: "${VNC_PORT:="5900"}"    # VNC port
: "${MON_PORT:="7100"}"    # Monitor port
: "${WEB_PORT:="8006"}"    # Webserver port
: "${WSD_PORT:="8004"}"    # Websockets port
: "${WSS_PORT:="5700"}"    # Websockets port

if (( VNC_PORT < 5900 )); then
  warn "VNC port cannot be set lower than 5900, ignoring value $VNC_PORT."
  VNC_PORT="5900"
fi

cp -r /var/www/* /run/shm
rm -f /var/run/websocketd.pid

html "Starting $APP for $ENGINE..."

if [[ "${WEB:-}" != [Nn]* ]]; then

  mkdir -p /etc/nginx/sites-enabled
  cp /etc/nginx/default.conf /etc/nginx/sites-enabled/web.conf

  user="admin"
  [ -n "${USER:-}" ] && user="${USER:-}"

  if [ -n "${PASS:-}" ]; then

    # Set password
    echo "$user:{PLAIN}${PASS:-}" > /etc/nginx/.htpasswd

    sed -i "s/auth_basic off/auth_basic \"NoVNC\"/g" /etc/nginx/sites-enabled/web.conf

  fi

  sed -i "s/listen 8006 default_server;/listen $WEB_PORT default_server;/g" /etc/nginx/sites-enabled/web.conf
  sed -i "s/proxy_pass http:\/\/127.0.0.1:5700\/;/proxy_pass http:\/\/127.0.0.1:$WSS_PORT\/;/g" /etc/nginx/sites-enabled/web.conf
  sed -i "s/proxy_pass http:\/\/127.0.0.1:8004\/;/proxy_pass http:\/\/127.0.0.1:$WSD_PORT\/;/g" /etc/nginx/sites-enabled/web.conf

  # shellcheck disable=SC2143
  if [ -f /proc/net/if_inet6 ] && [ -n "$(ifconfig -a | grep inet6)" ]; then

    sed -i "s/listen $WEB_PORT default_server;/listen [::]:$WEB_PORT default_server ipv6only=off;/g" /etc/nginx/sites-enabled/web.conf

  fi

  # Start webserver
  nginx -e stderr

  # Start websocket server
  websocketd --address 127.0.0.1 --port="$WSD_PORT" /run/socket.sh >/var/log/websocketd.log &
  echo "$!" > /var/run/websocketd.pid

fi

return 0
