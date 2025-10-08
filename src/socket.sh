#!/usr/bin/env bash
set -Eeuo pipefail

info="/run/shm/msg.html"

tail -fn +0 "$info" --pid=$$ &
