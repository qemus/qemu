#!/usr/bin/env bash
set -Eeuo pipefail

[[ "${BALLOONING:-}" != [Yy1]* ]] && return 0

# By default, the VM is allocated the full amount of RAM configured via RAM_SIZE for its entire lifetime, but if you want
# the container to dynamically reclaim unused guest RAM based on host memory pressure, you can enable memory ballooning.
# It is also used to prevent the guest from exceeding the container's memory limit, even when the limit is changed at runtime.

# The following optional variables allow you to tune the ballooning behaviour:

# BALLOONING	                     N	          Set to Y to enable dynamic memory ballooning
# BALLOONING_MIN_MEM	             33%	      Minimum balloon target, as a percentage of guest max memory (e.g. 33%) or absolute size (e.g. 2G)
# BALLOONING_RAM_THRESHOLD.  	     80.0	      Target host RAM usage percentage; the PI controller aims to keep host usage at or below this value
# BALLOONING_RAM_THRESHOLD_HARD	     90.0	      Host RAM usage percentage above which the balloon target may drop below guest RAM usage, inducing guest memory pressure
# BALLOONING_PSI_PRESSURE	         10.0	      Host PSI avg10 stall percentage at which the PSI ceiling begins to lower the balloon target
# BALLOONING_PSI_PRESSURE_MAX	     50.0	      Host PSI avg10 stall percentage at which the PSI ceiling reaches the configured minimum balloon target
# BALLOONING_HYSTERESIS	             128M	      Minimum balloon target change required before a resize is applied, as a percentage (e.g. 2%) or absolute size (e.g. 256M)
# BALLOONING_KP.             	     0.5	      PI controller proportional gain; higher values react faster but may oscillate
# BALLOONING_KI.            	     0.05	      PI controller integral gain; higher values correct steady-state error faster but risk overshoot
# BALLOONING_INTERVAL.      	     5	          Polling interval in seconds

# Note: memory ballooning uses Linux PSI (/proc/pressure/memory) for progressive pressure detection. Between BALLOONING_PSI_PRESSURE and 
# BALLOONING_PSI_PRESSURE_MAX the PSI ceiling linearly lowers the maximum balloon target from guest max memory down to the configured minimum.
# If PSI is unavailable (kernel lacks CONFIG_PSI), both thresholds are silently skipped and ballooning continues using host memory usage alone.

# Warning: if the container memory limit is reduced at runtime below the guest VM's current memory usage, the container
# may be killed by the OOM killer if the ballooning driver cannot reclaim memory from the guest fast enough.

ballooning() {

    # Wait for qemu PID file to be created
    while [ ! -f "$QEMU_PID" ]; do
        sleep 1
    done

    BALLOON_ARGS=()
    [[ -n "${BALLOONING_MIN_MEM:-}" ]] && BALLOON_ARGS+=(--min-mem "$BALLOONING_MIN_MEM")
    [[ -n "${BALLOONING_PSI_PRESSURE:-}" ]] && BALLOON_ARGS+=(--psi-pressure "$BALLOONING_PSI_PRESSURE")
    [[ -n "${BALLOONING_PSI_PRESSURE_MAX:-}" ]] && BALLOON_ARGS+=(--psi-pressure-max "$BALLOONING_PSI_PRESSURE_MAX")
    [[ -n "${BALLOONING_RAM_THRESHOLD:-}" ]] && BALLOON_ARGS+=(--ram-threshold "$BALLOONING_RAM_THRESHOLD")
    [[ -n "${BALLOONING_RAM_THRESHOLD_HARD:-}" ]] && BALLOON_ARGS+=(--ram-threshold-hard "$BALLOONING_RAM_THRESHOLD_HARD")
    [[ -n "${BALLOONING_HYSTERESIS:-}" ]] && BALLOON_ARGS+=(--hysteresis "$BALLOONING_HYSTERESIS")
    [[ -n "${BALLOONING_KP:-}" ]] && BALLOON_ARGS+=(--kp "$BALLOONING_KP")
    [[ -n "${BALLOONING_KI:-}" ]] && BALLOON_ARGS+=(--ki "$BALLOONING_KI")
    [[ -n "${BALLOONING_INTERVAL:-}" ]] && BALLOON_ARGS+=(--interval "$BALLOONING_INTERVAL")
    local _ballooning_debug="${BALLOONING_DEBUG:-${DEBUG:-}}"
    if [[ "$_ballooning_debug" == [Yy1]* ]]; then
        BALLOON_ARGS+=(--debug)
    elif [[ -n "$_ballooning_debug" && "$_ballooning_debug" != [Nn0]* ]]; then
        BALLOON_ARGS+=(--debug "$_ballooning_debug")
    fi

    python3 ./balloon.py --qmp-sock "$QEMU_DIR/qemu-qmp-ballooning.sock" --qemu-pid-file "$QEMU_PID" "${BALLOON_ARGS[@]}"
}

msg="Starting memory ballooning monitor..."
info "$msg"

( ballooning ) &

return 0
