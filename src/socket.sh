#!/usr/bin/env bash
set -Eeuo pipefail

lastmsg=""
lastcmd=""
transitioned="N"
path="/run/shm/msg.html"
dir=$(dirname -- "$path")
name=$(basename -- "$path")
command="$dir/status.cmd"
command_name=$(basename -- "$command")
page="$dir/index.html"
vnc="$dir/vnc-ws.sock"
vnc_name=$(basename -- "$vnc")

writeAtomic() {

  local file="$1"
  local value="$2"
  local tmp="${file}.tmp.$$"

  if ! printf '%s\n' "$value" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi

  if ! mv -f -- "$tmp" "$file"; then
    rm -f -- "$tmp"
    return 1
  fi

  return 0
}

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

refreshCommand() {

  [ ! -f "$command" ] && return 0
  [ ! -s "$command" ] && return 0

  cmd=$(< "$command") || return 0
  cmd="${cmd%$'\n'}"

  [ -z "$cmd" ] && return 0
  [[ "$cmd" == "$lastcmd" ]] && return 0

  lastcmd="$cmd"
  echo "c: $cmd"

  return 0
}

transition() {

  [[ "$transitioned" == "Y" ]] && return 0
  [ ! -S "$vnc" ] && return 0

  transitioned="Y"
  rm -f -- "$path" "$page"

  writeAtomic "$command" "vnc" || return 1
  refreshCommand

  return 0
}

refresh
refreshCommand
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

    if [[ "$file" == "$command_name" ]]; then
      case "${event,,}" in
        "close_write"* | "moved_to"* )
          refreshCommand ;;
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
