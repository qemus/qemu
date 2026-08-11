#!/usr/bin/env bash
set -Eeuo pipefail

# Helper functions

info () { printf "%b%s%b" "\E[1;34m❯ \E[1;36m" "${1:-}" "\E[0m\n"; }
error () { printf "%b%s%b" "\E[1;31m❯ " "ERROR: ${1:-}" "\E[0m\n" >&2; }
warn () { printf "%b%s%b" "\E[1;31m❯ " "Warning: ${1:-}" "\E[0m\n" >&2; }

app() {

  local name="$APP"

  if [[ "$name" == "QEMU" ]]; then
    name="the virtual machine"
  fi

  echo "$name"
  return 0
}

_trap() {

  local func="$1"; shift
  local sig

  TRAP_PID=$BASHPID

  for sig; do
    # Capture the local callback and signal while registering the trap.
    # shellcheck disable=SC2064
    trap "$func $sig" "$sig"
  done

  return 0
}

signalCode() {

  local sig="$1"

  case "$sig" in
    SIGHUP)  echo 129 ;;
    SIGINT)  echo 130 ;;
    SIGQUIT) echo 131 ;;
    SIGABRT) echo 134 ;;
    SIGTERM) echo 143 ;;
    *)       echo 0 ;;
  esac

  return 0
}

displayReason() {

  local reason="$1"

  case "$reason" in
    129 ) echo "SIGHUP" ;;
    130 ) echo "SIGINT" ;;
    131 ) echo "SIGQUIT" ;;
    134 ) echo "SIGABRT" ;;
    143 ) echo "SIGTERM" ;;
    * )   echo "$reason" ;;
  esac

  return 0
}

readPidFile() {

  local -n _pid="$1"
  _pid=""

  if ! _pid=$(cat -- "$2" 2>/dev/null); then
    _pid=""
    return 1
  fi

  if [[ ! "$_pid" =~ ^[1-9][0-9]*$ ]]; then
    _pid=""
    return 1
  fi

  return 0
}

readQemuPid() {

  # Prefer the supervisor-created PID during startup; fall back to QEMU's own
  # pidfile once it becomes available.
  readPidFile "$1" "$QEMU_START_PID" && return 0
  readPidFile "$1" "$QEMU_PID"
}

qemuPidFile() {

  local -n _file="$1"

  _file="$QEMU_PID"
  [ -s "$QEMU_START_PID" ] && _file="$QEMU_START_PID"

  return 0
}

terminateQemu() {

  local file

  qemuPidFile file
  sKill "$file"

  return 0
}

waitQemuExit() {

  local timeout="${1:-10}"
  local file

  qemuPidFile file
  waitPidFile "$file" "$timeout"
}

waitQemuPid() {

  local cnt=0

  while ! readQemuPid "$1"; do
    sleep 0.02
    cnt=$((cnt + 1))
    (( cnt >= 50 )) && return 1
  done

  return 0
}

forceKillQemu() {

  local reason="$1"
  local pid display

  readQemuPid pid || return 0
  isAlive "$pid" || return 0

  display=$(displayReason "$reason")
  error "Forcefully terminating $(app), reason: $display..."
  { disown "$pid" || :; kill -9 -- "$pid" || :; } 2>/dev/null

  return 0
}

cleanupHelpers() {

  local var
  local pids=()

  for var in "${HELPER_PIDS[@]}"; do
    local value="${!var:-}"
    [ -n "$value" ] && pids+=( "$value" )
  done

  pids+=( "$@" )
  mKill "${pids[@]}"

  fKill "progress.sh"
  closeNetwork

  return 0
}

startConsole() {

  local output="${1:-/dev/tty}"
  local cnt=0

  rm -f -- "$CONSOLE_SOCKET" "$CONSOLE_PID"

  if ! stty -icanon -echo isig -ixon min 1 time 0 </dev/tty; then
    error "Failed to configure serial console terminal!"
    return 1
  fi

  (
    trap '' INT QUIT
    exec nc -lU "$CONSOLE_SOCKET" </dev/tty >"$output"
  ) &

  local pid="$!"
  echo "$pid" > "$CONSOLE_PID"

  while [ ! -S "$CONSOLE_SOCKET" ]; do

    if ! isAlive "$pid"; then
      rm -f -- "$CONSOLE_PID"
      error "Serial console relay exited unexpectedly!"
      return 1
    fi

    sleep 0.02
    cnt=$((cnt + 1))

    if (( cnt > 100 )); then
      error "Failed to start serial console relay!"
      return 1
    fi

  done

  return 0
}

stopConsole() {

  mKill "$CONSOLE_PID"

  return 0
}

startQemu() {

  rm -f -- "$QEMU_START_PID"

  (
    trap '' INT QUIT

    # setsid detaches QEMU from the interactive process group. The wrapper records
    # the actual QEMU PID and propagates its exit status to the parent shell.
    # shellcheck disable=SC2016
    exec setsid -f -w sh -c '
      file=$1
      shift

      "$@" &
      pid=$!
      printf "%s\n" "$pid" > "$file" || exit 1

      rc=0
      wait "$pid" 2>/dev/null || rc=$?
      exit "$rc"
    ' sh "$QEMU_START_PID" "$@"
  ) </dev/null &

  return 0
}

normalizeTimeout() {

  local default_timeout="${1:-13}"
  local term_grace=3      # seconds before loop ends to send SIGTERM
  local cleanup_grace=3   # seconds reserved after the loop for cleanup

  TIMEOUT=$(strip "$TIMEOUT")
  if [[ ! "$TIMEOUT" =~ ^[0-9]+$ ]]; then
    TIMEOUT="$default_timeout"
  fi

  if (( TIMEOUT >= 30 )); then
    term_grace=5
    cleanup_grace=5
  elif (( TIMEOUT >= 15 )); then
    term_grace=4
    cleanup_grace=4
  fi

  # Reserve separate portions of TIMEOUT for SIGTERM escalation and final helper
  # cleanup instead of spending the entire budget on ACPI waiting.
  local min=$((term_grace + cleanup_grace + 1))
  (( TIMEOUT < min )) && (( TIMEOUT = min ))

  wait_until=$((TIMEOUT - cleanup_grace))
  sigterm_at=$((wait_until - term_grace))

  return 0
}

sendAcpiShutdown() {

  [ ! -S "$ACPI_SOCKET" ] && return 0

  # Send ACPI shutdown signal
  nc -q 1 -w 1 -U "$ACPI_SOCKET" &> /dev/null <<<'system_powerdown' || :

  return 0
}

waitForShutdown() {

  local pid="$1"
  local name="$APP"
  local cnt=0

  if [[ "$name" == "QEMU" ]]; then
    name="the virtual machine"
  fi

  while (( cnt <= wait_until && SHUTDOWN_SKIP == 0 )); do

    sleep 1 &
    local slp="$!"

    # Stop waiting if the process has exited
    isAlive "$pid" || break

    # Workaround for stale/zombie QEMU pid file
    [ ! -s "$QEMU_START_PID" ] && [ ! -s "$QEMU_PID" ] && break

    if (( cnt == sigterm_at )); then
      info "${name^} is still running, sending SIGTERM... ($cnt/$wait_until)"
      kill -15 -- "$pid" 2>/dev/null || :
    elif (( cnt > 0 )); then
      info "Waiting for $name to shut down... ($cnt/$wait_until)"
    fi

    sendAcpiShutdown

    wait "$slp" || :
    (( cnt++ ))

  done

  return 0
}

hasFlag() {

  # Match a whitespace-delimited token in /proc/cpuinfo
  grep -m1 '^flags[[:space:]]*:' /proc/cpuinfo | grep -Fqw -- "$1"

}

hasFeature() {

  # Match a whitespace-delimited token in /proc/cpuinfo
  grep -m1 '^Features[[:space:]]*:' /proc/cpuinfo | grep -Fqw -- "$1"

}

isAmdCpu() {

  local vendor
  vendor=$(awk -F ': *' '/^vendor_id/{print $2; exit}' /proc/cpuinfo)

  [[ "$vendor" == "AuthenticAMD" ]]
}

isQ35() {

  local machine="${1:-${MACHINE:-q35}}"

  case "${machine,,}" in
    q35|pc-q35*) return 0 ;;
  esac

  return 1
}

getPciBus() {

  local machine="${1:-${MACHINE:-q35}}"

  if [ -n "${PCI_BUS:-}" ]; then
    echo "$PCI_BUS"
    return 0
  fi

  case "${machine,,}" in
    pc|pc-i440fx*) echo "pci.0" ;;
    *)             echo "pcie.0" ;;
  esac

  return 0
}

interactive() {

  # Reopening /dev/tty verifies that the terminal is genuinely usable, not just
  # that stdin happens to report itself as a TTY.
  [ -t 0 ] && : 2>/dev/null </dev/tty >/dev/tty

}

containerID() {

  local id
  id=$(hostname -s 2>/dev/null || true)

  if [ -z "$id" ] && [ -s /etc/machine-id ]; then
    id=$(< /etc/machine-id)
  fi

  if [ -z "$id" ] && [ -r /proc/sys/kernel/random/boot_id ]; then
    id=$(< /proc/sys/kernel/random/boot_id)
  fi

  [ -z "$id" ] && id="unknown"

  echo "$id"
  return 0
}

strip() {

  local value="${1:-}"

  # Remove surrounding whitespace
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"

  # Remove leading/trailing single/double quotes
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"

  # Remove surrounding whitespace again
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"

  printf '%s' "$value"
}

enabled() {

  local value
  value=$(strip "${1:-}")

  case "${value,,}" in
    y|yes|true|1|on|enable|enabled) return 0 ;;
    *) return 1 ;;
  esac
}

disabled() {

  local value
  value=$(strip "${1:-}")

  case "${value,,}" in
    n|no|none|false|0|off|disable|disabled) return 0 ;;
    *) return 1 ;;
  esac
}

isAlive() {

  local pid="$1"
  local info state threads

  [ -z "$pid" ] && return 1

  info=$(ps -o state=,nlwp= -p "$pid" 2>/dev/null) || return 1
  read -r state threads <<< "$info" || return 1

  [[ "$state" == "Z" && "$threads" == "1" ]] && return 1

  return 0
}

waitPid() {

  local pid="$1"
  local timeout="${2:-10}"
  local deadline=$((SECONDS + timeout))

  while [ -n "$pid" ] && isAlive "$pid"; do
    (( SECONDS >= deadline )) && return 1
    sleep 0.2
  done

  return 0
}

waitPidFile() {

  local pid
  local file="$1"
  local timeout="${2:-10}"
  local deadline=$((SECONDS + timeout))

  readPidFile pid "$file" || return 0

  while [ -s "$file" ] && isAlive "$pid"; do
    (( SECONDS >= deadline )) && return 1
    sleep 0.2
  done

  rm -f -- "$file"
  return 0
}

pKill() {

  local pid="$1"
  local timeout="${2:-10}"

  { kill -15 -- "$pid" || :; } 2>/dev/null

  if ! waitPid "$pid" "$timeout"; then
    warn "Timed out while waiting for PID $pid"
  fi

  return 0
}

fWait() {

  local name="$1"
  local timeout="${2:-10}"
  local deadline=$((SECONDS + timeout))
  local pid alive

  [ -z "$name" ] && return 0

  while :; do

    alive=0

    while read -r pid; do
      if isAlive "$pid"; then
        alive=1
        break
      fi
    done < <(pgrep -f "$name" 2>/dev/null || :)

    (( alive == 0 )) && break

    if (( SECONDS >= deadline )); then
      warn "Timed out while waiting for process: $name"
      break
    fi

    sleep 0.2
  done

  return 0
}

fKill() {

  local name="$1"
  local timeout="${2:-10}"

  [ -z "$name" ] && return 0

  { pkill -f "$name" || :; } 2>/dev/null
  fWait "$name" "$timeout"

  return 0
}

sKill() {

  local pid
  local file="$1"

  readPidFile pid "$file" || return 0

  if isAlive "$pid"; then
    { kill -15 -- "$pid" || :; } 2>/dev/null
  fi

  return 0
}

mKill() {

  local timeout=10
  local files=("$@")

  for file in "${files[@]}"; do
    sKill "$file"
  done

  for file in "${files[@]}"; do
    if ! waitPidFile "$file" "$timeout"; then
      warn "Timed out while waiting for PID file: $file"
    fi
  done

  return 0
}

finiteMemoryLimit() {

  local limit="$1"
  # cgroup v1 commonly reports this enormous sentinel for an unlimited memory
  # limit; compare as decimal strings to avoid shell integer overflow.
  local sentinel="4611686018427387904"
  local i

  [[ "$limit" =~ ^[0-9]+$ ]] || return 1

  (( ${#limit} < ${#sentinel} )) && return 0
  (( ${#limit} > ${#sentinel} )) && return 1

  for (( i=0; i<${#sentinel}; i++ )); do
    local left="${limit:i:1}"
    local right="${sentinel:i:1}"

    (( left < right )) && return 0
    (( left > right )) && return 1
  done

  return 1
}

getMemoryInfo() {

  local host_total
  local host_avail
  local limit=""
  local current=""

  host_total=$(free -b | awk '/^Mem:/ {print $2; exit}')
  host_avail=$(free -b | awk '/^Mem:/ {print $7; exit}')

  RAM_TOTAL="$host_total"
  RAM_AVAIL="$host_avail"

  if [ -r /sys/fs/cgroup/memory.max ] && [ -r /sys/fs/cgroup/memory.current ]; then
    limit=$(< /sys/fs/cgroup/memory.max)
    current=$(< /sys/fs/cgroup/memory.current)
  elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ] && [ -r /sys/fs/cgroup/memory/memory.usage_in_bytes ]; then
    limit=$(< /sys/fs/cgroup/memory/memory.limit_in_bytes)
    current=$(< /sys/fs/cgroup/memory/memory.usage_in_bytes)
  fi

  # Use the tighter of host availability and the container's remaining cgroup
  # allowance so RAM sizing cannot exceed either boundary.
  if finiteMemoryLimit "$limit" && [[ "$current" =~ ^[0-9]+$ ]]; then
    (( limit < RAM_TOTAL )) && RAM_TOTAL="$limit"

    local available=$(( limit - current ))
    (( available < 0 )) && available=0
    (( available < RAM_AVAIL )) && RAM_AVAIL="$available"
  fi

  return 0
}

setOwner() {

  local file="$1"
  local dir uid gid

  [ ! -f "$file" ] && return 1

  dir=$(dirname -- "$file")
  # Generated files inherit ownership from their containing bind mount so they
  # remain manageable by the host user.
  uid=$(stat -c '%u' "$dir") || return 1
  gid=$(stat -c '%g' "$dir") || return 1

  chown "$uid:$gid" "$file" || return 1

  return 0
}

makeDir() {

  local path="$1"
  local dir uid gid

  [ -d "$path" ] && return 0
  mkdir -p "$path" || return 1

  dir=$(dirname -- "$path")

  if ! uid=$(stat -c '%u' "$dir") || ! gid=$(stat -c '%g' "$dir"); then
    warn "failed to determine the owner for \"$path\"."
    return 0
  fi

  if ! chown "$uid:$gid" "$path"; then
    warn "failed to set the owner for \"$path\"."
    return 0
  fi

  return 0
}

stateFile() {

  local name="$1"
  local prefix="${2:-$PROCESS}"

  # A name containing a slash is already an explicit path; simple names are
  # namespaced by process under the storage directory.
  [[ "$name" == */* ]] && printf '%s\n' "$name" && return 0

  printf '%s/%s.%s\n' "$STORAGE" "$prefix" "$name"
  return 0
}

writeFile() {

  local txt="$1"
  local path="$2"

  if ! printf '%s\n' "$txt" > "$path"; then
    error "Failed to write file \"$path\" !"
    return 1
  fi

  if ! setOwner "$path"; then
    warn "failed to set the owner for \"$path\"."
  fi

  return 0
}

writeAtomic() {

  local path="$1"
  local content="$2"
  local tmp="${path}.${BASHPID}.tmp"

  if ! printf '%s\n' "$content" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi

  if ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    return 1
  fi

  return 0
}

readFile() {

  local path="$1"
  local value

  [ -s "$path" ] || return 0

  value=$(<"$path") || return 1
  value="${value//[![:print:]]/}"

  printf '%s\n' "$value"
  return 0
}

writeState() {

  local name="$1"
  local value="$2"
  local prefix="${3:-$PROCESS}"
  local path

  [ -z "$value" ] && return 0

  path=$(stateFile "$name" "$prefix") || return 1
  writeFile "$value" "$path"

  return $?
}

readState() {

  local name="$1"
  local prefix="${2:-$PROCESS}"
  local path

  path=$(stateFile "$name" "$prefix") || return 1
  readFile "$path"

  return $?
}

restoreState() {

  local var="$1"
  local name="$2"
  local force="${3:-N}"
  local prefix="${4:-$PROCESS}"
  local value

  # Persisted state fills only unset variables by default, preserving explicit
  # environment choices unless the caller requests a forced restore.
  if ! enabled "$force"; then
    [ -z "${!var:-}" ] || return 0
  fi

  value=$(readState "$name" "$prefix") || return 1
  [ -n "$value" ] || return 0

  printf -v "$var" '%s' "$value" || return 1
  return 0
}

mergeState() {

  local var="$1"
  local name="$2"
  local separator="${3:-,}"
  local prefix="${4:-$PROCESS}"
  local current="${!var:-}"
  
  local value
  value=$(readState "$name" "$prefix") || return 1

  [ -n "$value" ] || return 0

  # Put current configuration first so user-provided flags precede and therefore
  # take priority over supplemental values restored from state.
  if [ -n "$current" ]; then
    value="$current$separator$value"
  fi

  printf -v "$var" '%s' "$value" || return 1
  return 0
}

removeState() {

  local name="$1"
  local prefix="${2:-$PROCESS}"
  local path

  path=$(stateFile "$name" "$prefix") || return 1
  rm -f -- "$path"

  return $?
}

escape () {

  local s=${1//&/\&amp;}
  s=${s//</\&lt;}
  s=${s//>/\&gt;}
  s=${s//'"'/\&quot;}

  printf -- %s "$s"

  return 0
}

escapeXML() {

  printf '%s' "$1" | sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\&apos;/g"

  return 0
}

html() {

  local title
  local body
  local script="${2:-}"
  local footer

  title=$(escape "$APP")
  title="<title>$title</title>"
  footer=$(escape "$FOOTER1")

  body=$(escape "$1")
  if [[ "$body" == *"..." ]]; then
    body="<p class=\"loading\">${body/.../}</p>"
  fi

  local HTML
  HTML=$(<"$TEMPLATE")
  HTML="${HTML/\[1\]/$title}"
  HTML="${HTML/\[2\]/$script}"
  HTML="${HTML/\[3\]/$body}"
  HTML="${HTML/\[4\]/$footer}"
  HTML="${HTML/\[5\]/$FOOTER2}"

  # Publish both the complete page and the live message atomically because the
  # web server and websocket helper may read them concurrently.
  writeAtomic "$PAGE" "$HTML" || return 1
  writeAtomic "$INFO" "$body" || return 1

  return 0
}

cpu() {

  local ret
  local cpu=""

  ret=$(lscpu)

  if grep -qi "model name" <<< "$ret"; then
    cpu=$(echo "$ret" | grep -m 1 -i 'model name' | cut -f 2 -d ":" | awk '{$1=$1}1' | sed 's# @.*##g' | sed s/"(R)"//g | sed 's/[^[:alnum:] ]\+/ /g' | sed 's/  */ /g')
  fi

  if [ -z "${cpu// /}" ] && grep -qi "model:" <<< "$ret"; then
    cpu=$(echo "$ret" | grep -m 1 -i 'model:' | cut -f 2 -d ":" | awk '{$1=$1}1' | sed 's# @.*##g' | sed s/"(R)"//g | sed 's/[^[:alnum:] ]\+/ /g' | sed 's/  */ /g')
  fi

  cpu="${cpu// CPU/}"
  cpu="${cpu// [0-9][0-9][0-9] Core}"
  cpu="${cpu// [0-9][0-9] Core}"
  cpu="${cpu// [0-9] Core}"
  cpu="${cpu//[0-9][0-9]th Gen }"
  cpu="${cpu//[0-9]th Gen }"
  cpu="${cpu// Processor/}"
  cpu="${cpu// Quad core/}"
  cpu="${cpu// Dual core/}"
  cpu="${cpu// Octa core/}"
  cpu="${cpu// Hexa core/}"
  cpu="${cpu// Core TM/ Core}"
  cpu="${cpu// with Radeon Graphics/}"
  cpu="${cpu// with Radeon Vega Graphics/}"
  cpu="${cpu// with Radeon Vega Mobile Gfx/}"
  cpu="${cpu// w Radeon [0-9][0-9][0-9]M Graphics/}"

  [ -z "${cpu// /}" ] && cpu="Unknown"

  echo "$cpu"
  return 0
}

baseDir() {

  local path="${1%/}"

  [[ -z "$path" || "$path" == "/" ]] && {
    echo "/"
    return 0
  }

  path="${path#/}"
  path="${path%%/*}"

  echo "/$path"
  return 0
}

formatBytes() {

  local result

  if ! result=$(numfmt --to=iec --suffix=B "$1" | sed -r 's/([A-Z])/ \1/' | sed 's/ B/ bytes/g;'); then
    return 1
  fi

  local unit="${result//[0-9. ]}"
  result="${result//[a-zA-Z ]/}"

  if [[ "${2:-}" == "up" ]]; then
    if [[ "$result" == *"."* ]]; then
      result="${result%%.*}"
      result=$((result+1))
    fi
  else
    if [[ "${2:-}" == "down" ]]; then
      result="${result%%.*}"
    fi
  fi

  echo "$result $unit"
  return 0
}

getDisk() {

  local path
  local format="${DISK_FMT:-}"
  local name="${DISK_NAME:-data}"

  enabled "${DISK_DISABLE:-}" && return 1

  # Disk discovery prefers an explicitly configured block device, then legacy
  # device paths, and finally managed image files.
  if [ -n "${DEVICE:-}" ]; then
    [ -b "$DEVICE" ] || return 1
    printf '%s\n' "$DEVICE"
    return 0
  fi

  for path in "/disk" "/disk1" "/dev/disk1"; do
    if [ -b "$path" ]; then
      printf '%s\n' "$path"
      return 0
    fi
  done

  case "${format,,}" in
    raw)
      path="$STORAGE/$name.img"
      if [ ! -f "$path" ] || [ ! -s "$path" ]; then
        path="$STORAGE/$name.qcow2"
      fi ;;
    *)
      path="$STORAGE/$name.qcow2"
      if [ ! -f "$path" ] || [ ! -s "$path" ]; then
        path="$STORAGE/$name.img"
      fi ;;
  esac

  if [ ! -f "$path" ] || [ ! -s "$path" ]; then
    return 1
  fi

  printf '%s\n' "$path"
  return 0
}

hasDisk() {

  getDisk >/dev/null
  return $?

}

hasData() {

  local path
  local rc=0 tmp=""
  local bytes=102400

  path=$(getDisk) || return 1
  local source="$path"

  if [[ "${path,,}" == *.qcow2 ]]; then

    tmp=$(mktemp) || {
      warn "failed to create a temporary file while inspecting \"$path\"."
      return 0
    }

    if ! qemu-img dd -f qcow2 -O raw bs="$bytes" count=1 \
        "if=$path" "of=$tmp" >/dev/null 2>&1; then
      rm -f "$tmp"
      warn "failed to inspect disk \"$path\", assuming it contains data."
      return 0
    fi

    source="$tmp"

  fi

  # Treat a disk as empty only when its first 100 KiB are all zero. Inspection
  # failures are conservative and assume data is present to prevent replacement.
  cmp -s -n "$bytes" "$source" /dev/zero || rc=$?
  [ -n "$tmp" ] && rm -f "$tmp"

  case "$rc" in
    0) return 1 ;;
    1) return 0 ;;
  esac

  warn "failed to inspect disk \"$path\", assuming it contains data."
  return 0
}

return 0
