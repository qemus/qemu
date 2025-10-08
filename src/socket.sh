#!/usr/bin/env bash
set -Eeuo pipefail

path="/run/shm/msg.html"

inotifywait -m "$path" | 
  while read fp event fn; do 
    case "${event,,}" in
      "modify" ) cat "$path" ;;      
      "delete" ) echo "DONE" ;;
    esac
  done
