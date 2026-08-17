#!/usr/bin/env bash
set -Eeuo pipefail

# Helper functions

getAgent() {

  local browser_version

    # Advance the synthetic browser version periodically so download endpoints do
  # not reject a permanently stale user agent.
  browser_version="$((152 + ($(date +%s) - 1781568000) / 1209600))"
  echo "Mozilla/5.0 (X11; Linux x86_64; rv:${browser_version}.0) Gecko/20100101 Firefox/${browser_version}.0"

  return 0
}

delay() {

  local i
  local seconds="$1"
  local msg="Retrying failed download in X seconds..."

  info "${msg/X/$seconds}"

  for i in $(seq "$seconds" -1 1); do
    html "${msg/X/$i}"

    sleep 1 || {
      local rc=$?
      (( rc >= 129 )) && exit "$rc"
    }
  done

  return 0
}

updateAriaProgress() {

  local line="$1"
  local status_file="$2"
  local status_tmp="$3"

  [ -z "$status_file" ] && return 0

  if [[ "$line" == *" CN:"* &&
      "$line" =~ \#[[:xdigit:]]+[[:space:]]+([0-9]+)B/([0-9]+)B ]]; then
    local completed="${BASH_REMATCH[1]}"
    local total="${BASH_REMATCH[2]}"

    if ! printf '%s %s\n' "$completed" "$total" > "$status_tmp" ||
        ! mv -f -- "$status_tmp" "$status_file"; then
      rm -f -- "$status_tmp"
    fi
  fi

  return 0
}

showAriaLine() {

  local line="$1"
  local percent speed_size
  local current_size total_size

  [[ "$line" == *" CN:"* ]] || return 1

  if [[ ! "$line" =~ \#[[:xdigit:]]+[[:space:]]+([0-9]+)B/([0-9]+)B ]]; then
    return 1
  fi

  local current="${BASH_REMATCH[1]}"
  local total="${BASH_REMATCH[2]}"

  current_size=$(formatBytes "$current") || current_size="${current}B"
  total_size=$(formatBytes "$total") || total_size="${total}B"

  if (( total > 0 )); then
    local progress=$((current * 1000 / total))
    (( progress > 1000 )) && progress=1000

    printf -v percent '%d.%d' \
      "$((progress / 10))" \
      "$((progress % 10))"
  else
    percent="0.0"
  fi

  local output=$'\033[35m[ \033[0m'
  output+=$'\033[36m'"${percent}%"$'\033[0m'
  output+=" | $current_size / $total_size"

  if [[ "$line" =~ DL:([0-9]+)B ]]; then
    local speed="${BASH_REMATCH[1]}"
    speed_size=$(formatBytes "$speed") || speed_size="${speed}B"
    output+=$' | \033[32m'"$speed_size/s"$'\033[0m'
  fi

  if [[ "$line" =~ ETA:([^]]+) ]]; then
    local eta="${BASH_REMATCH[1]}"
    output+=$' | \033[33mETA '"$eta"$'\033[0m'
  fi

  output+=$'\033[35m ]\033[0m'

  printf '\r\033[K%s' "$output" >&2
  return 0
}

handleAriaLine() {

  local line="$1"
  local status_file="$2"
  local status_tmp="$3"
  local display="$4"

  updateAriaProgress "$line" "$status_file" "$status_tmp"

  [[ "$display" == "Y" ]] || return 1
  showAriaLine "$line"
}

filterAriaOutput() {

  local status_file="$1"
  local display="${2:-N}"
  local status_tmp="${status_file}.${BASHPID}"
  local char line="" shown="N"

  # Keep the filter alive while aria2 handles an interrupt gracefully.
  trap '' INT TERM

  # RETURN runs while status_tmp is still in the function's local scope.
  trap 'rm -f -- "$status_tmp"; trap - RETURN' RETURN

  # aria2 redraws one console line with carriage returns, so consume characters
  # rather than normal newline-delimited records.
  while IFS= read -r -N 1 char; do
    case "$char" in
      $'\r' | $'\n' )
        if handleAriaLine \
            "$line" \
            "$status_file" \
            "$status_tmp" \
            "$display"; then
          shown="Y"
        fi

        line="" ;;
      * )
        line+="$char" ;;
    esac
  done

  # Process a final unterminated console update.
  if [[ -n "$line" ]] &&
      handleAriaLine \
        "$line" \
        "$status_file" \
        "$status_tmp" \
        "$display"; then
    shown="Y"
  fi

  [[ "$shown" == "Y" ]] && printf '\n' >&2
  return 0
}

checkDownloadSpace() {

  local dest="$1"
  local expected="${2:-0}"
  local dir available
  local expected_size capacity_size

  [[ "$expected" =~ ^[1-9][0-9]*$ ]] || return 0

  dir=$(dirname -- "$dest")

  if [ ! -d "$dir" ]; then
    error "Failed to check free space because directory \"$dir\" does not exist!"
    return 1
  fi

  available=$(df --output=avail -B1 -- "$dir" 2>/dev/null |
    awk 'NR == 2 { print $1 }') || available=""

  if [[ ! "$available" =~ ^[0-9]+$ ]]; then
    error "Failed to check free space in $dir!"
    return 1
  fi

  local used=0

  # Existing blocks can be reused when the destination is resumed or replaced.
  if [ -f "$dest" ]; then
    used=$(du -sB1 -- "$dest" 2>/dev/null |
      awk 'NR == 1 { print $1 }') || used=""

    if [[ ! "$used" =~ ^[0-9]+$ ]]; then
      error "Failed to determine the allocated size of \"$dest\"!"
      return 1
    fi
  fi

  local capacity=$((available + used))

  if (( expected > capacity )); then
    expected_size=$(formatBytes "$expected") ||
      expected_size="$expected bytes"

    capacity_size=$(formatBytes "$capacity") ||
      capacity_size="$capacity bytes"

    error "Insufficient free disk space to download file, $expected_size required but only $capacity_size available!"
    return 1
  fi

  return 0
}

prepareNoCow() {

  local file="$1"
  local dir fs attributes

  dir=$(dirname -- "$file")

  if ! fs=$(stat -f -c %T "$dir"); then
    error "Failed to determine filesystem type of $dir."
    return 1
  fi

  [[ "${fs,,}" != "btrfs" ]] && return 0

  # NOCOW must be set before the first data extent is allocated. Existing
  # non-empty files cannot be changed retroactively, so only warn if needed.
  if [ -s "$file" ]; then
    attributes=$(lsattr "$file" 2>/dev/null || :)
    if [[ "$attributes" != *"C"* ]]; then
      warn "COW (copy on write) is not disabled for download file $file on ${fs^^}, and cannot be changed after data has been written!"
    fi
    return 0
  fi

  if [ ! -e "$file" ]; then
    if ! touch "$file"; then
      error "Failed to create $file."
      return 1
    fi
  fi

  { chattr +C "$file"; } || :

  attributes=$(lsattr "$file" 2>/dev/null || :)
  if [[ "$attributes" != *"C"* ]]; then
    error "Failed to disable COW for download file $file on ${fs^^} filesystem!"
  fi

  return 0
}

verifyNoCow() {

  local file="$1"
  local fs attributes

  if ! fs=$(stat -f -c %T "$file"); then
    warn "failed to determine filesystem type of \"$file\" !"
    return 0
  fi

  [[ "${fs,,}" != "btrfs" ]] && return 0

  attributes=$(lsattr "$file" 2>/dev/null || :)
  if [[ "$attributes" != *"C"* ]]; then
    warn "COW (copy on write) is not disabled for downloaded file $file on ${fs^^} filesystem!"
  fi

  return 0
}

startDownloadProgress() {

  local log_name="$1"
  local status_name="$2"
  local pid_name="$3"
  local dest="$4"
  local expected="$5"
  local message="$6"
  local output="$7"
  local interval="$8"
  local connections="$9"
  local progress_path="$dest"
  local progress_mode="apparent"
  local log_value status_value=""

  # A previous progress helper must never survive into a new download.
  fKill "progress.sh"

  if ! log_value=$(mktemp -p "$QEMU_DIR"); then
    error "Failed to create temporary download log!"
    return 2
  fi

  if (( connections > 1 )); then
    if ! status_value=$(mktemp -p "$QEMU_DIR"); then
      rm -f -- "$log_value"
      error "Failed to create temporary aria2 progress status!"
      return 2
    fi

    if ! printf '0 0\n' > "$status_value"; then
      rm -f -- "$log_value" "$status_value"
      error "Failed to initialize temporary aria2 progress status!"
      return 2
    fi

    progress_path="$status_value"
    progress_mode="counter"
  fi

  # Start progress.sh before opening the aria output pipe so it cannot
  # inherit the pipe's write descriptor and prevent the filter from exiting.
  /run/progress.sh \
    "$progress_path" \
    "$expected" \
    "$message ([P])..." \
    "$output" \
    "$interval" \
    "$progress_mode" \
    "$status_value" &

  local pid_value="$!"

  printf -v "$log_name" '%s' "$log_value"
  printf -v "$status_name" '%s' "$status_value"
  printf -v "$pid_name" '%s' "$pid_value"
  return 0
}

stopDownloadProgress() {

  local pid="$1"
  local status="$2"

  if [ -n "$pid" ]; then
    kill -TERM "$pid" 2>/dev/null || :
    wait "$pid" 2>/dev/null || :
  fi

  [ -n "$status" ] && rm -f -- "$status"
  return 0
}

downloadWithAria() {

  local rc_name="$1"
  local signal_name="$2"
  local status="$3"
  local aria_display="$4"
  local dest="$5"
  shift 5

  local aria_fd download_pid=""
  local int_trap term_trap total
  local cancel_signal_value=""

  # Use a dedicated descriptor for aria2 stderr so progress filtering can finish
  # independently and the downloader's exit status remains available.
  if ! exec {aria_fd}> >(filterAriaOutput "$status" "$aria_display"); then
    error "Failed to create aria2 output filter!"
    return 2
  fi

  local filter_pid="$!"
  int_trap=$(trap -p INT)
  term_trap=$(trap -p TERM)

  # Forward cancellation to aria2 while retaining the caller's original traps;
  # they are restored after the filter and downloader have exited.
  trap '
    cancel_signal_value="INT"
    [ -n "$download_pid" ] &&
      kill -INT -- "$download_pid" 2>/dev/null || :
  ' INT

  trap '
    cancel_signal_value="TERM"
    [ -n "$download_pid" ] &&
      kill -TERM -- "$download_pid" 2>/dev/null || :
  ' TERM

  (
    trap - INT TERM
    export LC_ALL=C
    exec "$@" 2>&"$aria_fd"
  ) &

  download_pid=$!

  # Cover a signal arriving between starting aria2 and recording its PID.
  if [ -n "$cancel_signal_value" ]; then
    kill -"$cancel_signal_value" -- "$download_pid" 2>/dev/null || :
  fi

  while true; do
    local rc_value=0
    wait "$download_pid" || rc_value=$?

    isAlive "$download_pid" || break
  done

  download_pid=""

  # Aria may exit successfully before emitting its final console update.
  # Use the completed file size instead of the asynchronously updated status
  # file, then send a final update through the existing output filter.
  if (( rc_value == 0 )) && [ -f "$dest" ]; then
    total=$(stat -c%s -- "$dest" 2>/dev/null) || total=""

    if [[ "$total" =~ ^[1-9][0-9]*$ ]]; then
      printf '\r#000000 %sB/%sB CN:0\r' \
        "$total" \
        "$total" >&"$aria_fd" || :
    fi
  fi

  exec {aria_fd}>&-
  wait "$filter_pid" 2>/dev/null || :

  if [ -n "$int_trap" ]; then
    eval "$int_trap"
  else
    trap - INT
  fi

  if [ -n "$term_trap" ]; then
    eval "$term_trap"
  else
    trap - TERM
  fi

  printf -v "$rc_name" '%s' "$rc_value"
  printf -v "$signal_name" '%s' "$cancel_signal_value"
  return 0
}

getDownloadFailureReason() {

  local connections="$1"
  local log="$2"
  local reason

  if (( connections > 1 )); then
    reason=$(sed -nE \
      -e 's/^[[:space:]]*->[[:space:]]*(\[[^]]+\][[:space:]]*)?(errorCode=[0-9]+[[:space:]]*)?(CUID#[0-9]+[[:space:]]*-[[:space:]]*)?//p' \
      -e 's/^.*\[ERROR\][[:space:]]*(CUID#[0-9]+[[:space:]]*-[[:space:]]*)?//p' \
      "$log" | tail -n 1)

    if [ -z "$reason" ]; then
      reason=$(awk 'NF { line=$0 } END { print line }' "$log")

      reason=$(sed -E \
        's/^(CUID#[0-9]+[[:space:]]*-[[:space:]]*)?//' \
        <<< "$reason")
    fi

  else

    reason=$(sed -n \
      -e 's/^wget: //p' \
      -e 's/^[0-9-]\{10\} [0-9:]\{8\} ERROR //p' \
      "$log" | tail -n 1)

  fi

  printf '%s' "$reason"
  return 0
}

handleDownloadCancellation() {

  local signal="$1"
  local connections="$2"
  local rc="$3"
  local log="$4"

  if [ -z "$signal" ] &&
      ! (( connections > 1 && rc == 7 )); then
    return 0
  fi

  rm -f -- "$log"

  case "${signal:-INT}" in
    TERM )
      kill -TERM "$BASHPID"
      exit 143 ;;
    * )
      kill -INT "$BASHPID"
      exit 130 ;;
  esac
}

downloadToFile() {

  if (( $# < 3 )); then
    error "downloadToFile requires a URL, destination and message."
    return 2
  fi

  local url="$1"
  local dest="$2"
  local message="$3"
  local expected="${4:-0}"
  local connections="${5:-1}"
  local resume="${6:-Y}"
  local request=()

  if (( $# > 6 )); then
    shift 6
    request=("$@")
  fi

  local progress=()
  local wget_resume=()
  local aria_display="N"
  local aria_resume="false"
  local allocation="none"
  local default_interval=536870912
  local interval="$default_interval"
  local progress_pid status log
  local dir file option rc run_rc=0
  local agent custom_agent="N"
  local output="" reason=""
  local cancel_signal=""
  local probe=""

  if [[ ! "$connections" =~ ^[1-9][0-9]*$ ]]; then
    error "Invalid connection count: $connections"
    return 2
  fi

  if [[ ! "$expected" =~ ^[0-9]+$ ]]; then
    expected=0
  fi

  dir=$(dirname -- "$dest")

  if [ ! -d "$dir" ]; then
    error "Download destination directory \"$dir\" does not exist!"
    return 2
  fi

  if ! checkDownloadSpace "$dest" "$expected"; then
    return 2
  fi

  if ! prepareNoCow "$dest"; then
    return 2
  fi

  if (( expected > 0 )); then
    interval=$(((expected + 9) / 10))
  fi

  if enabled "$resume"; then
    wget_resume=( --continue )
    aria_resume="true"
  fi

  # Allow callers such as macOS recovery to provide a protocol-specific
  # user agent while applying the normal browser agent everywhere else.
  for option in "${request[@]}"; do
    case "$option" in
      --user-agent | --user-agent=* | -U | -U* )
        custom_agent="Y"
        break ;;
    esac
  done

  if [[ "$custom_agent" != "Y" ]]; then
    if ! agent=$(getAgent) || [ -z "$agent" ]; then
      error "Failed to generate a download user agent!"
      return 2
    fi

    request=( --user-agent "$agent" "${request[@]}" )
  fi

  if (( connections > 1 )); then
    if ! command -v aria2c >/dev/null; then
      error "aria2c is required when using multiple download connections."
      return 1
    fi

    # Test the destination filesystem directly instead of maintaining an
    # incomplete filesystem blacklist. Unsupported filesystems fall back to
    # no preallocation while retaining multi-connection downloads.
    if command -v fallocate >/dev/null &&
        probe=$(mktemp -p "$dir" .fallocate.XXXXXX 2>/dev/null); then

      if fallocate -l 1048576 "$probe" 2>/dev/null; then
        allocation="falloc"
      fi

      rm -f -- "$probe" || :
    fi

  elif ! command -v wget >/dev/null; then
    error "The wget command was not found."
    return 2
  fi

  # Use the downloader's progress display in a terminal
  # and progress.sh in container logs and the web viewer.
  if [ -t 0 ] && [ -t 2 ]; then
    if (( connections > 1 )); then
      aria_display="Y"
    else
      progress=( --show-progress --progress=bar:noscroll )
    fi
  else
    output="log"
  fi

  html "$message..."

  startDownloadProgress \
    log \
    status \
    progress_pid \
    "$dest" \
    "$expected" \
    "$message" \
    "$output" \
    "$interval" \
    "$connections" || {
      rc=$?
      html "Download failed (code $rc)."
      return "$rc"
    }

  enabled "${DEBUG:-N}" && echo "Downloading: $url"

  if (( connections > 1 )); then

    file=$(basename -- "$dest")

    downloadWithAria \
      rc \
      cancel_signal \
      "$status" \
      "$aria_display" \
      "$dest" \
      aria2c \
      --no-conf=true \
      --dir="$dir" \
      --out="$file" \
      --split="$connections" \
      --max-connection-per-server="$connections" \
      --file-allocation="$allocation" \
      --continue="$aria_resume" \
      --always-resume=false \
      --allow-overwrite=true \
      --auto-file-renaming=false \
      --max-tries=2 \
      --retry-wait=2 \
      --lowest-speed-limit=10K \
      --connect-timeout=30 \
      --timeout=30 \
      --async-dns=false \
      --follow-metalink=false \
      --follow-torrent=false \
      --stderr=true \
      --summary-interval=0 \
      --show-console-readout=true \
      --truncate-console-readout=true \
      --download-result=hide \
      --console-log-level=error \
      --enable-color=false \
      --human-readable=false \
      --log="$log" \
      --log-level=error \
      "${request[@]}" \
      -- "$url" || run_rc=$?

  else

    {
      LC_ALL=C wget \
        --output-document="$dest" \
        "${wget_resume[@]}" \
        --no-verbose \
        --timeout=30 \
        --no-http-keep-alive \
        "${progress[@]}" \
        --output-file="$log" \
        "${request[@]}" \
        -- "$url"

      rc=$?
    } || :

  fi

  stopDownloadProgress "$progress_pid" "$status"

  if (( run_rc != 0 )); then
    rm -f -- "$log"

    if (( run_rc >= 129 )); then
      exit "$run_rc"
    fi

    html "Download failed (code $run_rc)."
    return "$run_rc"
  fi

  # Aria normally returns 7 after cancellation, but a concurrent download
  # error can take precedence. Track the signal so cancellation is not retried.
  handleDownloadCancellation "$cancel_signal" "$connections" "$rc" "$log"

  if (( rc >= 129 )); then
    rm -f -- "$log"
    exit "$rc"
  fi

  if (( rc != 0 )); then
    reason=$(getDownloadFailureReason "$connections" "$log")
  fi

  if (( rc != 0 )) && enabled "${DEBUG:-N}" && [ -s "$log" ]; then
    printf '\n' >&2
    cat "$log" >&2
  fi

  rm -f -- "$log"

  if (( rc == 0 )) && [ -f "$dest" ]; then
    # Aria normally removes this itself after successful completion.
    rm -f -- "$dest.aria2"
    verifyNoCow "$dest"
    html "Download completed successfully..."
    return 0
  fi

  local failure="Failed to download $url"

  if (( connections == 1 && rc == 3 )); then
    failure="$failure because the file could not be written (disk full?)."
  elif (( connections > 1 && rc == 9 )); then
    failure="$failure because there was insufficient free disk space."
  elif [ -n "$reason" ]; then
    failure="$failure : ${reason%.}."
  elif (( rc == 0 )); then
    failure="$failure because no output file was created."
  else
    failure="$failure with exit status $rc."
  fi

  html "$failure"
  error "$failure"

  if (( connections == 1 && rc == 3 )) ||
      (( connections > 1 && rc == 9 )); then
    return 2
  fi

  return 1
}

validateDownloadMinimum() {

  local dest="$1"
  local minimum="${2:-0}"
  local actual actual_size minimum_size

  if [[ ! "$minimum" =~ ^[0-9]+$ ]]; then
    error "Invalid minimum download size: $minimum"
    return 2
  fi

  (( minimum == 0 )) && return 0

  if ! actual=$(stat -c%s -- "$dest" 2>/dev/null); then

    error "Failed to determine downloaded file size: $dest"

  elif (( actual < minimum )); then

    actual_size=$(formatBytes "$actual") ||
      actual_size="$actual bytes"

    minimum_size=$(formatBytes "$minimum") ||
      minimum_size="$minimum bytes"

    error "Downloaded file is only $actual_size, but at least $minimum_size was expected."

  else

    return 0

  fi

  # The failed result must not be resumed during the next attempt.
  if ! rm -f -- "$dest" "$dest.aria2"; then
    error "Failed to remove invalid download \"$dest\"!"
    return 2
  fi

  return 1
}

downloadRetry() {

  if (( $# < 5 )); then
    error "downloadRetry requires a destination, connection count, delay, description and minimum size."
    return 2
  fi

  local dest="$1"
  local connections="$2"
  local seconds="$3"
  local description="$4"
  local minimum="$5"
  shift 5

  if [[ ! "$connections" =~ ^[1-9][0-9]*$ ]] ||
      (( connections > 16 )); then
    error "The CONNECTIONS value must be between 1 and 16!"
    return 2
  fi

  if [[ ! "$seconds" =~ ^[0-9]+$ ]]; then
    error "Invalid retry delay: $seconds"
    return 2
  fi

  if [[ ! "$minimum" =~ ^[0-9]+$ ]]; then
    error "Invalid minimum download size: $minimum"
    return 2
  fi

  # Retry policy intentionally starts clean: deterministic validation failures
  # and stale aria metadata must never be resumed as if they were valid data.
  # Always start without stale partial or aria control files.
  if ! rm -f -- "$dest" "$dest.aria2"; then
    error "Failed to remove previous download \"$dest\"!"
    return 2
  fi

  # Try the configured number of connections first.
  if downloadFile "$@" "$connections"; then

    if validateDownloadMinimum "$dest" "$minimum"; then
      return 0
    else
      local rc=$?
    fi

  else

    local rc=$?

  fi

  delay "$seconds"

  # A multi-connection partial file can contain non-sequential
  # ranges and cannot safely be resumed by Wget.
  if (( connections > 1 )); then

    if ! rm -f -- "$dest" "$dest.aria2"; then
      error "Failed to remove partial download \"$dest\"!"
      return 2
    fi

  fi

  info "Retrying $description with a single connection..."

  # Retry using single-connection Wget.
  if downloadFile "$@" "1"; then

    if validateDownloadMinimum "$dest" "$minimum"; then
      return 0
    else
      local rc=$?
    fi

  else

    local rc=$?

  fi

  if ! rm -f -- "$dest" "$dest.aria2"; then
    warn "failed to remove failed download \"$dest\"!"
  fi

  return "$rc"
}

return 0
