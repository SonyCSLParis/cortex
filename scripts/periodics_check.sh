#!/usr/bin/env bash
# =============================================================================
# periodics_check.sh — manifest + enforcement for Cortex's periodic jobs
#
# Single source of truth for anything that is supposed to run on a schedule or
# continuously. The *manifest* is the set of job_* functions below; the runner
# iterates them. Add a new periodic by adding a new job_* function — nothing
# else.
#
# Modes:
#   status   (default)  print one line per job with state; exit 0 if all ok
#   heal                restart only jobs that are down and safe to auto-start
#   help                show this header
#
# Wiring:
#   - cortex.sh calls `heal` then `status` at chat entry.
#   - scripts/watch.sh calls `heal` on every wake (active enforcement).
#
# Job contract — each job_<name> function supports three subcommands:
#   describe   — one-line prose (host, cadence, purpose)
#   check      — exit 0 if healthy/disabled, non-zero otherwise; print a
#                short reason. Optional: prefix the reason with
#                `STATE: <state>` to distinguish disabled/advisory/unreachable
#                from a real down daemon.
#   start      — attempt to restart; exit 0 on success. Optional: jobs that
#                need a human decision (e.g. watch mode) omit this.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CORTEX_DIR="${CORTEX_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd -P)}"
source "${CORTEX_DIR}/config/cortex_defaults.sh"
source "${CORTEX_DIR}/scripts/bash_compat.sh"
source "${CORTEX_DIR}/scripts/public_sync_lib.sh"

load_messenger_settings() {
    if [[ -r "${CORTEX_DEFAULT_SIGNAL_SECRETS_FILE}" ]]; then
        set -a
        # shellcheck disable=SC1090
        . "${CORTEX_DEFAULT_SIGNAL_SECRETS_FILE}"
        set +a
    fi
    if [[ -r "${CORTEX_DEFAULT_TELEGRAM_SECRETS_FILE}" ]]; then
        set -a
        # shellcheck disable=SC1090
        . "${CORTEX_DEFAULT_TELEGRAM_SECRETS_FILE}"
        set +a
    fi
    CORTEX_DEFAULT_SIGNAL_RELAY_HOST="${SIGNAL_RELAY_HOST:-${CORTEX_DEFAULT_SIGNAL_RELAY_HOST:-}}"
    CORTEX_DEFAULT_TELEGRAM_RELAY_HOST="${TELEGRAM_RELAY_HOST:-${CORTEX_DEFAULT_TELEGRAM_RELAY_HOST:-${CORTEX_DEFAULT_SIGNAL_RELAY_HOST}}}"
}
load_messenger_settings

# Ordered list of jobs (the manifest)
JOBS=(
    signal_inbox_daemon
    telegram_inbox_daemon
    sync_public_drift
)

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; GREY='\033[0;90m'; RESET='\033[0m'
use_color() { [[ -t 1 ]]; }
colored() { use_color && printf '%b%s%b' "$1" "$2" "$RESET" || printf '%s' "$2"; }

job_supports_start() {
    declare -f "job_$1" 2>/dev/null | grep -q '^[[:space:]]*start)'
}

state_color() {
    case "$1" in
        ok) printf '%s' "$GREEN" ;;
        disabled) printf '%s' "$GREY" ;;
        advisory) printf '%s' "$YELLOW" ;;
        down|unreachable|probe_error) printf '%s' "$RED" ;;
        *) printf '%s' "$RED" ;;
    esac
}

state_is_attention() {
    case "$1" in
        ok|disabled) return 1 ;;
        *) return 0 ;;
    esac
}

check_job_state() {
    local job="$1" reason rc state stripped

    reason=$("job_${job}" check 2>&1)
    rc=$?
    state="$(printf '%s\n' "${reason}" | sed -n 's/^STATE: //p' | head -n 1)"
    stripped="$(printf '%s\n' "${reason}" | sed '/^STATE: /d')"

    if [[ -z "${state}" ]]; then
        case "${rc}" in
            0) state="ok" ;;
            3) state="advisory" ;;
            4) state="unreachable" ;;
            *) state="down" ;;
        esac
    fi

    CHECK_STATE="${state}"
    CHECK_REASON="${stripped}"
    CHECK_RC="${rc}"
    return "${rc}"
}

# --- job: signal_inbox_daemon ------------------------------------------------
job_signal_inbox_daemon() {
    case "$1" in
        describe) echo "signal_inbox_daemon | host=${CORTEX_DEFAULT_SIGNAL_RELAY_HOST:-disabled} | cadence=always-on | Signal note-to-self → inboxes/signal" ;;
        check)
            if [[ -z "${CORTEX_DEFAULT_SIGNAL_RELAY_HOST:-}" ]]; then
                echo "STATE: disabled"
                echo "signal relay host unset (channel disabled)"
                return 0
            fi
            run_with_timeout 8s ssh -o BatchMode=yes -o ConnectTimeout=5 "${CORTEX_DEFAULT_SIGNAL_RELAY_HOST}" \
                'pgrep -f signal_inbox_daemon.py >/dev/null' 2>/dev/null
            local rc=$?
            if (( rc == 0 )); then
                return 0
            fi
            if (( rc != 1 )); then
                echo "STATE: unreachable"
                echo "probe failed for ${CORTEX_DEFAULT_SIGNAL_RELAY_HOST} (ssh/timeout rc=${rc})"
                return 4
            fi
            echo "not running on ${CORTEX_DEFAULT_SIGNAL_RELAY_HOST}"
            return 1
            ;;
        start)
            [[ -n "${CORTEX_DEFAULT_SIGNAL_RELAY_HOST:-}" ]] || { echo "signal relay host unset"; return 2; }
            ssh -o BatchMode=yes -o ConnectTimeout=10 "${CORTEX_DEFAULT_SIGNAL_RELAY_HOST}" \
                "bash \"${CORTEX_DEFAULT_SIGNAL_INBOX_DAEMON_SCRIPT}\" start" 2>&1
            ;;
        *) return 2 ;;
    esac
}

# --- job: telegram_inbox_daemon ---------------------------------------------
job_telegram_inbox_daemon() {
    case "$1" in
        describe) echo "telegram_inbox_daemon | host=${CORTEX_DEFAULT_TELEGRAM_RELAY_HOST:-disabled} | cadence=always-on | Telegram bot DMs → inboxes/telegram" ;;
        check)
            # Skip silently if the secrets file is missing — Telegram is
            # optional infrastructure; absent config is a deliberate state,
            # not a failure.
            if [[ ! -r "${CORTEX_DEFAULT_TELEGRAM_SECRETS_FILE}" ]]; then
                echo "STATE: disabled"
                echo "telegram secrets file absent (channel disabled)"
                return 0
            fi
            if [[ -z "${CORTEX_DEFAULT_TELEGRAM_RELAY_HOST:-}" ]]; then
                echo "STATE: disabled"
                echo "telegram relay host unset (channel disabled)"
                return 0
            fi
            run_with_timeout 8s ssh -o BatchMode=yes -o ConnectTimeout=5 "${CORTEX_DEFAULT_TELEGRAM_RELAY_HOST}" \
                'pgrep -f telegram_inbox_daemon.py >/dev/null' 2>/dev/null
            local rc=$?
            if (( rc == 0 )); then
                return 0
            fi
            if (( rc != 1 )); then
                echo "STATE: unreachable"
                echo "probe failed for ${CORTEX_DEFAULT_TELEGRAM_RELAY_HOST} (ssh/timeout rc=${rc})"
                return 4
            fi
            echo "not running on ${CORTEX_DEFAULT_TELEGRAM_RELAY_HOST}"
            return 1
            ;;
        start)
            [[ -n "${CORTEX_DEFAULT_TELEGRAM_RELAY_HOST:-}" ]] || { echo "telegram relay host unset"; return 2; }
            ssh -o BatchMode=yes -o ConnectTimeout=10 "${CORTEX_DEFAULT_TELEGRAM_RELAY_HOST}" \
                "bash \"${CORTEX_DEFAULT_TELEGRAM_INBOX_DAEMON_SCRIPT}\" start" 2>&1
            ;;
        *) return 2 ;;
    esac
}

# --- job: sync_public_drift --------------------------------------------------
job_sync_public_drift() {
    case "$1" in
        describe) echo "sync_public_drift | host=local | cadence=after framework commits | public branch lag check" ;;
        check)
            cd "$CORTEX_DIR" || { echo "cannot cd to $CORTEX_DIR"; return 1; }
            local public_ref
            if ! public_ref="$(public_sync_available_ref)"; then
                echo "STATE: disabled"
                echo "public remote not configured"
                return 0
            fi
            local last_sync_sha
            last_sync_sha="$(public_sync_last_source_sha "${public_ref}" || true)"
            if [[ -z "$last_sync_sha" ]]; then
                echo "STATE: probe_error"
                echo "could not read last sync sha from ${public_ref}"
                return 4
            fi
            local drift
            drift="$(public_framework_drift_log "${last_sync_sha}" master || true)"
            if [[ -n "$drift" ]]; then
                local n
                n=$(printf '%s\n' "$drift" | wc -l)
                echo "STATE: advisory"
                echo "${n} commit(s) touch framework files since last public sync (${last_sync_sha:0:8})"
                return 3
            fi
            return 0
            ;;
        # No auto-start: pushing to public is a human-approved action.
        *) return 2 ;;
    esac
}

# --- runner ------------------------------------------------------------------
run_status() {
    local all_ok=0
    for job in "${JOBS[@]}"; do
        local describe reason state color
        describe=$("job_${job}" describe)
        check_job_state "${job}" || true
        reason="${CHECK_REASON}"
        state="${CHECK_STATE}"
        color="$(state_color "${state}")"
        state_is_attention "${state}" && all_ok=1
        printf '  %s  %-26s %s\n' "$(colored "$color" "$state")" "$job" "${describe#*| }"
        [[ -n "$reason" && "$state" != "ok" ]] && printf '       %s\n' "$(colored "$GREY" "$reason")"
    done
    return "$all_ok"
}

run_heal() {
    local any_action=0 all_ok=0
    for job in "${JOBS[@]}"; do
        job_supports_start "${job}" || continue
        check_job_state "${job}" || true
        [[ "${CHECK_STATE}" == "ok" || "${CHECK_STATE}" == "disabled" ]] && continue
        [[ "${CHECK_STATE}" == "down" ]] || { all_ok=1; continue; }
        any_action=1
        local reason
        "job_${job}" start >/dev/null 2>&1 </dev/null
        check_job_state "${job}" || true
        reason="${CHECK_REASON}"
        if [[ "${CHECK_STATE}" == "ok" ]]; then
            echo "healed: ${job}"
        else
            echo "heal attempted but still ${CHECK_STATE}: ${job}: ${reason}"
            all_ok=1
        fi
    done
    (( any_action == 0 && all_ok == 0 )) && echo "all auto-start periodics healthy"
    return "$all_ok"
}

main() {
    local action="${1:-status}"
    case "$action" in
        status) run_status ;;
        heal)   run_heal ;;
        help|-h|--help) sed -n '2,26p' "$0" ;;
        *) echo "unknown action: $action" >&2; exit 2 ;;
    esac
}

main "$@"
