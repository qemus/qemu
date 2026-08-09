#!/usr/bin/env bash
set -Eeuo pipefail

lastmsg=""
transitioned="N"
path="/run/shm/msg.html"
dir=$(dirname -- "$path")
name=$(basename -- "$path")
page="$dir/index.html"
vnc="$dir/vnc-ws.sock"
vnc_name=$(basename -- "$vnc")

refresh() {

  [ ! -f "$path" ] && return 0
  [ ! -s "$path" ] && return 0

  msg=$(< "$path") || return 0
  msg="${msg%$'\n'}"

  [ -z "$msg" ] && return 0
  [[ "$msg" == "$lastmsg" ]] && return 0

  lastmsg="$msg"
  # The noVNC client consumes a tiny line protocol: s updates the status message
  # and c below requests a switch to the VNC canvas.
  echo "s: $msg"

  return 0
}

transition() {

  [[ "$transitioned" == "Y" ]] && return 0
  [ ! -S "$vnc" ] && return 0

  transitioned="Y"
  rm -f -- "$path" "$page"
  echo "c: vnc"

  return 0
}

refresh
transition

# Watch the directory rather than only the file because writers publish updates
# through atomic rename, which appears as moved_to.
inotifywait \
  -m -q \
  -e close_write,moved_to,create,delete \
  --format '%e %f' \
  "$dir" |
  while read -r event file; do

    if [[ "$file" == "$vnc_name" ]]; then
      case "${event,,}" in
        "create"* | "moved_to"* )
          transition ;;
      esac
      continue
    fi

    [[ "$file" == "$name" ]] || continue

    case "${event,,}" in
      "delete"* )
        transition ;;
      "close_write"* | "moved_to"* )
        refresh ;;
    esac

  done
