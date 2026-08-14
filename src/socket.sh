#!/usr/bin/env bash
set -Eeuo pipefail

lastmsg=""
lastcmd=""
path="/run/shm/msg.html"
dir=$(dirname -- "$path")
name=$(basename -- "$path")
command="$dir/status.cmd"
command_name=$(basename -- "$command")
marker="$dir/status.vnc"
page="$dir/index.html"
page_name=$(basename -- "$page")
vnc="$dir/vnc-ws.sock"
vnc_name=$(basename -- "$vnc")

if [ -f "$marker" ]; then
  msg="Warning: status client connected after switching to VNC."

  if ! printf '%s\n' "$msg" >> /proc/1/fd/2; then
    printf '%s\n' "$msg" >&2
  fi
fi

warnStale() {

  local file="$1"
  local msg="Warning: $file was recreated after switching to VNC."

  if ! printf '%s\n' "$msg" >> /proc/1/fd/2; then
    printf '%s\n' "$msg" >&2
  fi

  return 0
}

cleanupStale() {

  [ ! -f "$marker" ] && return 0

  if [ -f "$page" ]; then
    rm -f -- "$page" || return 1
    warnStale "$page_name"
  fi

  if [ -f "$path" ]; then
    rm -f -- "$path" || return 1
    warnStale "$name"
  fi

  return 0
}

refresh() {

  [ -f "$marker" ] && return 0
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

  if [ -f "$marker" ]; then
    cleanupStale || return 1
    echo "c: vnc"
    return 0
  fi

  [ ! -S "$vnc" ] && return 0

  rm -f -- "$path" "$page" || return 1
  : > "$marker" || return 1
  echo "c: vnc"

  return 0
}

transition
refresh
refreshCommand

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

    if [[ "$file" == "$page_name" ]]; then
      case "${event,,}" in
        "close_write"* | "moved_to"* )
          [ -f "$marker" ] && cleanupStale ;;
      esac
      continue
    fi

    [[ "$file" == "$name" ]] || continue

    case "${event,,}" in
      "delete"* )
        [ ! -f "$marker" ] && transition ;;
      "close_write"* | "moved_to"* )
        if [ -f "$marker" ]; then
          cleanupStale
        else
          refresh
        fi ;;
    esac

  done
