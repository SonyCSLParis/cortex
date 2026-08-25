#!/usr/bin/env bash
# =============================================================================
# signal_inbox_daemon.sh — launch the Signal→inbox daemon in a session
#
# The Python script does the actual work; this wrapper exists so the daemon
# follows Cortex's convention for long-lived jobs: a detached session, with
# stdout/stderr mirrored via `tee` so attach always shows live output
# and history (see `conductor.instruct`, "When launching long-lived work inside
# screen ...").
#
# Usage:
#   bash "${CORTEX_DEFAULT_SIGNAL_INBOX_DAEMON_SCRIPT}" [start|stop|status|foreground] [-- ...daemon args]
#
# Defaults:
#   - session backend:     CORTEX_DEFAULT_SESSION_BACKEND
#   - session name:        CORTEX_DEFAULT_SIGNAL_INBOX_SESSION
#   - target inbox:        $CORTEX_DIR/inboxes/signal
#   - log file:            $CORTEX_DIR/logs/signal_inbox_daemon.log
#
# Extra args after `--` are forwarded to signal_inbox_daemon.py, e.g.:
#   bash ... start -- --inbox agents/${CORTEX_DEFAULT_SIGNAL_RELAY_HOST}/inbox --sender-id signal-${CORTEX_DEFAULT_SIGNAL_RELAY_HOST}
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CORTEX_DIR="${CORTEX_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd -P)}"
source "${CORTEX_DIR}/config/cortex_defaults.sh"
source "${CORTEX_DIR}/scripts/session_backend.sh"
SCRIPT_DIR="${CORTEX_DIR}/scripts"
DAEMON="${SCRIPT_DIR}/signal_inbox_daemon.py"
LOG_FILE="${CORTEX_DIR}/logs/signal_inbox_daemon.log"
SESSION="${SIGNAL_INBOX_SESSION:-${CORTEX_DEFAULT_SIGNAL_INBOX_SESSION}}"
SESSION_BACKEND="$(cortex_session_backend_resolve "${CORTEX_SESSION_BACKEND:-${CORTEX_DEFAULT_SESSION_BACKEND}}")"
SECRETS_FILE="${SIGNAL_SECRETS_FILE:-${CORTEX_DEFAULT_SIGNAL_SECRETS_FILE}}"
RELAY_HOST="${SIGNAL_RELAY_HOST:-${CORTEX_DEFAULT_SIGNAL_RELAY_HOST}}"
source "${CORTEX_DIR}/scripts/user_context.sh"

usage() {
    sed -n '2,20p' "$0"
}

ensure_hostname() {
    if [[ "$(hostname)" != "${RELAY_HOST}" ]]; then
        echo "refusing to run: signal-cli account lives on ${RELAY_HOST}, current host is $(hostname)" >&2
        exit 2
    fi
}

require_secrets() {
    if [[ -r "${SECRETS_FILE}" ]]; then
        set -a
        # shellcheck disable=SC1090
        . "${SECRETS_FILE}"
        set +a
    fi
    RELAY_HOST="${SIGNAL_RELAY_HOST:-${RELAY_HOST:-}}"
    if [[ -z "${SIGNAL_ACCOUNT:-}" ]] && cortex_user_load "${CORTEX_DIR}" && [[ -r "${CORTEX_USER_INSTRUCT}" ]]; then
        SIGNAL_ACCOUNT="$(
            sed -n "s/^- User's Signal number: //p" "${CORTEX_USER_INSTRUCT}" | head -n 1
        )"
        SIGNAL_RECIPIENT="${SIGNAL_RECIPIENT:-${SIGNAL_ACCOUNT}}"
    fi
    if [[ -z "${SIGNAL_ACCOUNT:-}" ]]; then
        echo "SIGNAL_ACCOUNT not set in ${SECRETS_FILE} or the resolved users/<user>/<user>.instruct profile" >&2
        exit 2
    fi
    if [[ -z "${RELAY_HOST:-}" ]]; then
        echo "SIGNAL_RELAY_HOST not set in ${SECRETS_FILE} or the environment" >&2
        exit 2
    fi
}

is_running() {
    cortex_session_backend_available "${SESSION_BACKEND}" || return 1
    cortex_session_exists "${SESSION_BACKEND}" "${SESSION}"
}

cmd_status() {
    if is_running; then
        echo "running: ${SESSION_BACKEND} session '${SESSION}'"
        echo "log:     ${LOG_FILE}"
        echo "attach:  $(cortex_session_attach_hint "${SESSION_BACKEND}" "${SESSION}")"
        return 0
    fi
    echo "not running"
    return 1
}

cmd_start() {
    require_secrets
    ensure_hostname
    if is_running; then
        echo "already running in ${SESSION_BACKEND} session '${SESSION}'"
        cmd_status
        return 0
    fi

    mkdir -p "$(dirname "${LOG_FILE}")"

    if [[ ! -x "${DAEMON}" ]]; then
        chmod +x "${DAEMON}" || true
    fi

    if ! cortex_session_backend_available "${SESSION_BACKEND}"; then
        echo "${SESSION_BACKEND} is not available" >&2
        return 1
    fi

    local forwarded=("$@")
    local cmd
    if [[ -r "${SECRETS_FILE}" ]]; then
        printf -v cmd 'set -a; . %q; set +a; exec > >(tee -a %q) 2>&1; exec %q' \
            "${SECRETS_FILE}" "${LOG_FILE}" "${DAEMON}"
    else
        printf -v cmd 'export SIGNAL_ACCOUNT=%q SIGNAL_RECIPIENT=%q; exec > >(tee -a %q) 2>&1; exec %q' \
            "${SIGNAL_ACCOUNT}" "${SIGNAL_RECIPIENT:-${SIGNAL_ACCOUNT}}" "${LOG_FILE}" "${DAEMON}"
    fi
    for arg in "${forwarded[@]}"; do
        printf -v cmd '%s %q' "${cmd}" "${arg}"
    done

    cortex_session_start "${SESSION_BACKEND}" "${SESSION}" "${cmd}" "${CORTEX_DIR}"
    sleep 1
    if is_running; then
        echo "started ${SESSION_BACKEND} session '${SESSION}'"
        cmd_status
    else
        echo "failed to start; check ${LOG_FILE}" >&2
        return 1
    fi
}

cmd_stop() {
    if ! is_running; then
        echo "not running"
        return 0
    fi
    echo "stopping ${SESSION_BACKEND} session '${SESSION}'"
    cortex_session_stop "${SESSION_BACKEND}" "${SESSION}" || true
    sleep 1
    if is_running; then
        echo "session did not exit cleanly; inspect ${SESSION_BACKEND} sessions and kill manually" >&2
        return 1
    fi
    echo "stopped"
}

cmd_foreground() {
    require_secrets
    ensure_hostname
    mkdir -p "$(dirname "${LOG_FILE}")"
    exec "${DAEMON}" "$@" 2>&1 | tee -a "${LOG_FILE}"
}

main() {
    local action="${1:-status}"
    shift || true

    local forwarded=()
    if [[ "${1:-}" == "--" ]]; then
        shift
        forwarded=("$@")
    else
        forwarded=("$@")
    fi

    case "${action}" in
        start)      cmd_start "${forwarded[@]}" ;;
        stop)       cmd_stop ;;
        restart)    cmd_stop || true; cmd_start "${forwarded[@]}" ;;
        status)     cmd_status ;;
        foreground) cmd_foreground "${forwarded[@]}" ;;
        -h|--help|help) usage ;;
        *) echo "unknown action: ${action}" >&2; usage; exit 1 ;;
    esac
}

main "$@"
