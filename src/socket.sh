#!/usr/bin/env bash
set -Eeuo pipefail

lastmsg=""
path="/run/shm/msg.html"
dir=$(dirname -- "$path")
name=$(basename -- "$path")

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

refresh

# Watch the directory rather than only the file because writers publish updates
# through atomic rename, which appears as moved_to.
inotifywait \
  -m -q \
  -e close_write,moved_to,delete \
  --format '%e %f' \
  "$dir" |
  while read -r event file; do

    [[ "$file" == "$name" ]] || continue

    case "${event,,}" in
      "delete"* )
        echo "c: vnc" ;;
      "close_write"* | "moved_to"* )
        refresh ;;
    esac

  done
