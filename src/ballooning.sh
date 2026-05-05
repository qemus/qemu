#!/usr/bin/env bash

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

    python3 ./ballooning.py --qmp-sock /run/shm/qemu-qmp-ballooning.sock --qemu-pid-file "$QEMU_PID" "${BALLOON_ARGS[@]}"
}

if [[ "${BALLOONING:-}" == [Yy1]* ]]; then
    ARGS+=" -qmp unix:/run/shm/qemu-qmp-ballooning.sock,server,nowait"

    if [[ -z "${QEMU_PID:-}" ]]; then
        # Check if ARGS already contains a -pidfile argument
        QEMU_PID=$(
            readarray -t _args < <(xargs -n1 <<< "$ARGS")
            pid_found=0
            for _arg in "${_args[@]}"; do
                if [[ $pid_found -eq 1 ]]; then
                    echo "$_arg"
                    break
                fi
                case "$_arg" in
                    -pidfile=*)
                        echo "${_arg#-pidfile=}"; 
                        break
                        ;;
                    -pidfile)
                        pid_found=1
                        ;;
                esac
            done
        )

        if [[ -z "${QEMU_PID:-}" ]]; then
            QEMU_PID="/run/shm/qemu.pid"
            ARGS+=" -pidfile $QEMU_PID"
        fi
        rm -f "$QEMU_PID"
    fi

    msg="Starting memory ballooning monitor"
    info "$msg" && html "$msg"

    ( ballooning ) &
fi
