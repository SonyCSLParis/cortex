#!/usr/bin/env bash
# Lock helpers used by the watch agent. The lock lives at
# agents/watch/lock/ and serves two purposes: preventing a second watch
# session from starting on top of a running one, and carrying the
# stop_requested / wake_now signal files. The lock is watch-exclusive,
# not a chat/watch mutex.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CORTEX_DIR="${CORTEX_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd -P)}"
WATCH_LOCK_DIR="${CORTEX_DIR}/agents/watch/lock"
WATCH_LOCK_META="${WATCH_LOCK_DIR}/meta"
WATCH_LOCK_HEARTBEAT="${WATCH_LOCK_DIR}/heartbeat"
WATCH_LOCK_STOP="${WATCH_LOCK_DIR}/stop_requested"
WATCH_LOCK_TICK_INTERVAL="${WATCH_LOCK_TICK_INTERVAL:-15}"
WATCH_LOCK_STALE_AFTER="${WATCH_LOCK_STALE_AFTER:-90}"

WATCH_LOCK_TOKEN="${WATCH_LOCK_TOKEN:-}"
WATCH_LOCK_TICKER_PID="${WATCH_LOCK_TICKER_PID:-}"

watch_lock_now() {
    date -u +%s
}

watch_lock_hostname() {
    hostname 2>/dev/null || echo unknown
}

watch_lock_exists() {
    [[ -d "${WATCH_LOCK_DIR}" ]]
}

watch_lock_read_meta() {
    [[ -f "${WATCH_LOCK_META}" ]] || return 1
    # shellcheck disable=SC1090
    source "${WATCH_LOCK_META}"
}

watch_lock_heartbeat_age() {
    local hb now
    hb="$(cat "${WATCH_LOCK_HEARTBEAT}" 2>/dev/null || echo 0)"
    now="$(watch_lock_now)"
    echo $(( now - hb ))
}

watch_lock_is_stale() {
    [[ "$(watch_lock_heartbeat_age)" -gt "${WATCH_LOCK_STALE_AFTER}" ]]
}

watch_lock_write_meta() {
    local mode="$1" provider="$2" interval="$3" watch_summary="$4" token="$5"
    mkdir -p "$(dirname "${WATCH_LOCK_DIR}")"
    cat > "${WATCH_LOCK_META}.tmp" <<EOF
MODE=$(printf '%q' "${mode}")
HOST=$(printf '%q' "$(watch_lock_hostname)")
PID=$(printf '%q' "$$")
USER_NAME=$(printf '%q' "${USER:-$(whoami 2>/dev/null || echo unknown)}")
START_TS=$(printf '%q' "$(watch_lock_now)")
PROVIDER=$(printf '%q' "${provider}")
INTERVAL=$(printf '%q' "${interval}")
WATCH_SUMMARY=$(printf '%q' "${watch_summary}")
TOKEN=$(printf '%q' "${token}")
EOF
    mv "${WATCH_LOCK_META}.tmp" "${WATCH_LOCK_META}"
}

watch_lock_refresh() {
    local token_in_meta=""
    [[ -n "${WATCH_LOCK_TOKEN}" ]] || return 1
    [[ -f "${WATCH_LOCK_META}" ]] || return 1
    # shellcheck disable=SC1090
    source "${WATCH_LOCK_META}"
    token_in_meta="${TOKEN:-}"
    [[ "${token_in_meta}" == "${WATCH_LOCK_TOKEN}" ]] || return 1
    mkdir -p "${WATCH_LOCK_DIR}"
    printf '%s\n' "$(watch_lock_now)" > "${WATCH_LOCK_HEARTBEAT}.tmp"
    mv "${WATCH_LOCK_HEARTBEAT}.tmp" "${WATCH_LOCK_HEARTBEAT}"
}

watch_lock_acquire() {
    local mode="$1" provider="${2:-n/a}" interval="${3:-0}" watch_summary="${4:-}"
    local token
    token="$(watch_lock_hostname)-$$-$(watch_lock_now)-${RANDOM}"
    mkdir -p "$(dirname "${WATCH_LOCK_DIR}")"
    if ! mkdir "${WATCH_LOCK_DIR}" 2>/dev/null; then
        return 1
    fi
    WATCH_LOCK_TOKEN="${token}"
    export WATCH_LOCK_TOKEN
    watch_lock_write_meta "${mode}" "${provider}" "${interval}" "${watch_summary}" "${token}"
    watch_lock_refresh
}

watch_lock_force_clear() {
    rm -rf "${WATCH_LOCK_DIR}"
}

watch_lock_release() {
    local token_in_meta=""
    if [[ -f "${WATCH_LOCK_META}" ]]; then
        # shellcheck disable=SC1090
        source "${WATCH_LOCK_META}"
        token_in_meta="${TOKEN:-}"
    fi
    if [[ -n "${WATCH_LOCK_TOKEN}" && "${token_in_meta}" == "${WATCH_LOCK_TOKEN}" ]]; then
        rm -rf "${WATCH_LOCK_DIR}"
    fi
}

watch_lock_request_stop() {
    [[ -d "${WATCH_LOCK_DIR}" ]] || return 0
    printf '%s\n' "$(watch_lock_now)" > "${WATCH_LOCK_STOP}.tmp"
    mv "${WATCH_LOCK_STOP}.tmp" "${WATCH_LOCK_STOP}"
}

watch_lock_stop_requested() {
    [[ -f "${WATCH_LOCK_STOP}" ]]
}

watch_lock_start_ticker() {
    local interval="${1:-${WATCH_LOCK_TICK_INTERVAL}}"
    (
        while true; do
            watch_lock_refresh || exit 0
            sleep "${interval}"
        done
    ) &
    WATCH_LOCK_TICKER_PID="$!"
    export WATCH_LOCK_TICKER_PID
}

watch_lock_stop_ticker() {
    if [[ -n "${WATCH_LOCK_TICKER_PID}" ]]; then
        kill "${WATCH_LOCK_TICKER_PID}" 2>/dev/null || true
        wait "${WATCH_LOCK_TICKER_PID}" 2>/dev/null || true
        WATCH_LOCK_TICKER_PID=""
        export WATCH_LOCK_TICKER_PID
    fi
}
