#!/usr/bin/env bash
set -Eeuo pipefail

lastmsg=""
lastcmd=""
path="/run/shm/msg.html"
dir=$(dirname -- "$path")
name=$(basename -- "$path")
command="$dir/status.cmd"
command_name=$(basename -- "$command")

refresh() {

  [ ! -f "$path" ] && return 0
  [ ! -s "$path" ] && return 0

  msg=$(< "$path") || return 0
  msg="${msg%$'\n'}"

  [ -z "$msg" ] && return 0
  [[ "$msg" == "$lastmsg" ]] && return 0

  lastmsg="$msg"
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

refresh
refreshCommand

# Watch the directory rather than only the file because writers
# publish updates through atomic rename, which appears as moved_to.
inotifywait \
  -m -q \
  -e close_write,moved_to,delete \
  --format '%e %f' \
  "$dir" |
  while read -r event file; do

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
        echo "c: vnc" ;;
      "close_write"* | "moved_to"* )
        refresh ;;
    esac

  done
