#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  bash scripts/prompt_log_sync_daemon.sh --cwd <repo> --session-dir <session-dir> [--interval <seconds>] [--parent-pid <pid>]

Runs a session-local prompt/final-answer sync loop for one conductor session.
The daemon performs one initial sync, repeats on the given interval, and does
one final catch-up on TERM/INT before exiting. With --parent-pid it also does
a final sync and exits once that process is gone, so a hard-killed launcher
does not leave the daemon orphaned forever.
EOF
}

CWD=""
SESSION_DIR=""
INTERVAL="${CORTEX_PROMPT_LOG_SYNC_INTERVAL:-5}"
PARENT_PID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cwd)
            CWD="${2:-}"
            shift 2
            ;;
        --session-dir)
            SESSION_DIR="${2:-}"
            shift 2
            ;;
        --interval)
            INTERVAL="${2:-}"
            shift 2
            ;;
        --parent-pid)
            PARENT_PID="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[[ -n "${CWD}" && -n "${SESSION_DIR}" ]] || {
    usage >&2
    exit 2
}
[[ "${INTERVAL}" =~ ^[0-9]+$ && "${INTERVAL}" -gt 0 ]] || {
    echo "Invalid --interval: ${INTERVAL}" >&2
    exit 2
}
[[ -z "${PARENT_PID}" || "${PARENT_PID}" =~ ^[0-9]+$ ]] || {
    echo "Invalid --parent-pid: ${PARENT_PID}" >&2
    exit 2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SYNC_PY="${SCRIPT_DIR}/prompt_log_sync.py"
LOG_PATH="${SESSION_DIR}/prompt_log.txt"
STATE_PATH="${SESSION_DIR}/.prompt_log_state.json"

[[ -f "${SYNC_PY}" ]] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
if [[ ! -d "${SESSION_DIR}" ]]; then
    echo "prompt_log_sync_daemon.sh: missing session dir: ${SESSION_DIR}" >&2
    exit 0
fi

sync_once() {
    python3 "${SYNC_PY}" \
        --cwd "${CWD}" \
        --session-dir "${SESSION_DIR}" \
        --log-path "${LOG_PATH}" \
        --state-path "${STATE_PATH}" >/dev/null 2>&1 || true
}

cleanup() {
    sync_once
}

signal_exit() {
    trap - EXIT INT TERM
    cleanup
    exit 0
}

trap cleanup EXIT
trap signal_exit INT TERM

parent_alive() {
    [[ -z "${PARENT_PID}" ]] && return 0
    kill -0 "${PARENT_PID}" 2>/dev/null
}

sync_once
while parent_alive; do
    sleep "${INTERVAL}"
    sync_once
done
# Parent died without stopping us: the EXIT trap performs the final sync.
