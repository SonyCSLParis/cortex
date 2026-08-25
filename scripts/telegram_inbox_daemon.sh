#!/usr/bin/env bash
# =============================================================================
# telegram_inbox_daemon.sh — launch the Telegram→inbox daemon in a session.
#
# Companion to scripts/signal_inbox_daemon.sh; the Python script does the
# actual work. Sources the bot token + chat_id from
# `CORTEX_DEFAULT_TELEGRAM_SECRETS_FILE` (gitignored) before launch so the
# daemon never needs to read or print them itself.
#
# Usage:
#   bash "${CORTEX_DEFAULT_TELEGRAM_INBOX_DAEMON_SCRIPT}" [start|stop|restart|status|foreground] [-- ...daemon args]
#
# Defaults:
#   - session backend:     CORTEX_DEFAULT_SESSION_BACKEND
#   - session name:        CORTEX_DEFAULT_TELEGRAM_INBOX_SESSION
#   - target inbox:        $CORTEX_DIR/inboxes/telegram
#   - log file:            $CORTEX_DIR/logs/telegram_inbox_daemon.log
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CORTEX_DIR="${CORTEX_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd -P)}"
source "${CORTEX_DIR}/config/cortex_defaults.sh"
source "${CORTEX_DIR}/scripts/session_backend.sh"
SCRIPT_DIR="${CORTEX_DIR}/scripts"
DAEMON="${SCRIPT_DIR}/telegram_inbox_daemon.py"
LOG_FILE="${CORTEX_DIR}/logs/telegram_inbox_daemon.log"
SECRETS_FILE="${TELEGRAM_SECRETS_FILE:-${CORTEX_DEFAULT_TELEGRAM_SECRETS_FILE}}"
SESSION="${TELEGRAM_INBOX_SESSION:-${CORTEX_DEFAULT_TELEGRAM_INBOX_SESSION}}"
SESSION_BACKEND="$(cortex_session_backend_resolve "${CORTEX_SESSION_BACKEND:-${CORTEX_DEFAULT_SESSION_BACKEND}}")"

usage() {
    sed -n '2,18p' "$0"
}

require_secrets() {
    if [[ ! -r "${SECRETS_FILE}" ]]; then
        echo "missing or unreadable secrets file: ${SECRETS_FILE}" >&2
        echo "expected to define TELEGRAM_BOT_TOKEN (and TELEGRAM_USER_CHAT_ID)" >&2
        exit 2
    fi
    set -a
    # shellcheck disable=SC1090
    . "${SECRETS_FILE}"
    set +a
    if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
        echo "TELEGRAM_BOT_TOKEN not set in ${SECRETS_FILE}" >&2
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

    # Build the command string. The session sources the secrets file
    # itself so the env vars are scoped to the daemon and never leak to a
    # user's shell history. Output is teed via process-substitution per the
    # Cortex screen-output convention.
    local forwarded=("$@")
    local cmd
    printf -v cmd 'set -a; . %q; set +a; exec > >(tee -a %q) 2>&1; exec %q' \
        "${SECRETS_FILE}" "${LOG_FILE}" "${DAEMON}"
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
