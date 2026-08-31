#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CORTEX_DIR="${CORTEX_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd -P)}"
CONDUCTOR_DIR="${CORTEX_DIR}/agents/conductor"
CONDUCTOR_ACTIVE_SESSIONS_FILE="${CONDUCTOR_DIR}/active_sessions.tsv"
AGENT_ACTIVE_WINDOW_SECONDS=$((30 * 24 * 60 * 60))

COLOR_MODE="auto"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --color)
            COLOR_MODE="always"
            shift
            ;;
        --no-color)
            COLOR_MODE="never"
            shift
            ;;
        -h|--help)
            cat <<'EOF'
Usage:
  bash scripts/agent_roster.sh [--color|--no-color]

Print the Cortex startup roster as a standalone report.

Examples:
  bash scripts/agent_roster.sh
  watch -c 'bash scripts/agent_roster.sh --color'
EOF
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

source "${CORTEX_DIR}/config/cortex_defaults.sh"
source "${CORTEX_DIR}/scripts/session_backend.sh"
SESSION_BACKEND="$(cortex_session_backend_resolve "${CORTEX_SESSION_BACKEND:-${CORTEX_DEFAULT_SESSION_BACKEND}}")"

if [[ "${COLOR_MODE}" == "always" ]] || { [[ "${COLOR_MODE}" == "auto" ]] && [[ -t 1 ]]; }; then
    GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; GREY='\033[0;90m'
    BOLD='\033[1m'; RESET='\033[0m'
else
    GREEN=''; YELLOW=''; RED=''; GREY=''
    BOLD=''; RESET=''
fi

compact_age() {
    local age="${1:-0}"
    if (( age < 0 )); then
        printf '0s'
    elif (( age < 60 )); then
        printf '%ss' "${age}"
    elif (( age < 3600 )); then
        printf '%sm' "$((age / 60))"
    elif (( age < 86400 )); then
        printf '%sh' "$((age / 3600))"
    else
        printf '%sd' "$((age / 86400))"
    fi
}

file_mtime_epoch() {
    local path="$1"
    stat -c %Y "${path}" 2>/dev/null || stat -f %m "${path}" 2>/dev/null || printf '0\n'
}

# Recency signal that survives agent shutdown. `heartbeat` is only a liveness
# tick: scripts/start_agent.sh removes it in mark_agent_offline, so a cleanly stopped
# agent has none and the heartbeat cannot answer "did this agent operate
# recently". `status` and `log.md` persist, so their newest mtime is the
# agent's last operating time.
agent_last_activity_epoch() {
    local agent_dir="$1" newest=0 name mtime
    for name in status log.md heartbeat; do
        [[ -f "${agent_dir}/${name}" ]] || continue
        mtime="$(file_mtime_epoch "${agent_dir}/${name}")"
        [[ "${mtime}" =~ ^[0-9]+$ ]] || continue
        if (( mtime > newest )); then
            newest="${mtime}"
        fi
    done
    printf '%s' "${newest}"
}

agent_status_value() {
    local status_file="$1" raw
    [[ -f "${status_file}" ]] || { printf '?'; return 0; }
    raw="$(tr -d '\r\n' < "${status_file}" 2>/dev/null || true)"
    case "${raw}" in
        idle|busy|working|selfcheck|error|offline) printf '%s' "${raw}" ;;
        "") printf 'invalid(empty)' ;;
        *) printf 'invalid(%s)' "${raw}" ;;
    esac
}

agent_session_exists() {
    local session="$1"
    cortex_session_backend_available "${SESSION_BACKEND}" || return 1
    cortex_session_exists "${SESSION_BACKEND}" "${session}"
}

agent_info_field() {
    local info_file="$1" key="$2"
    awk -F: -v key="${key}" '$1 == key { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }' \
        "${info_file}" 2>/dev/null
}

agent_session_name() {
    local role="$1" agent_id="$2"
    case "${role}" in
        worker) printf 'worker_%s' "${agent_id}" ;;
        node) printf 'node_%s' "${agent_id}" ;;
        watch) printf 'watch' ;;
        *) return 1 ;;
    esac
}

conductor_active_session_count() {
    local count=0 row
    [[ -f "${CONDUCTOR_ACTIVE_SESSIONS_FILE}" ]] || { printf '0'; return 0; }
    while IFS=$'\t' read -r row; do
        [[ -n "${row}" ]] || continue
        [[ "${row}" == "session_id" ]] && continue
        count=$(( count + 1 ))
    done < "${CONDUCTOR_ACTIVE_SESSIONS_FILE}"
    printf '%s' "${count}"
}

print_agent_roster() {
    local now session_count
    local agent_dir agent_id info_file role status hb hb_present hb_age hb_age_str inbox_n session_name session_state color
    local last_epoch last_age last_age_str

    now="$(date -u +%s)"
    session_count="$(conductor_active_session_count)"

    printf '%b\n' "${BOLD}AGENT ROSTER (active in last 30 days)${RESET}"
    printf '  %b green=running  %b red=stale/residue/error  %b yellow=degraded/inbox  %b grey=stopped cleanly / offline conductor\n' \
        "${GREEN}●${RESET}" "${RED}●${RESET}" "${YELLOW}●${RESET}" "${GREY}●${RESET}"

    printf '  %b\n' "${GREY}conductor             role=conductor  sessions=${session_count}  shared=inbox/tasks/log${RESET}"

    while IFS= read -r agent_dir; do
        [[ -d "${agent_dir}" ]] || continue
        agent_id="$(basename "${agent_dir}")"
        [[ "${agent_id}" == "conductor" ]] && continue

        info_file="${agent_dir}/info"
        role="$(agent_info_field "${info_file}" ROLE)"
        [[ -n "${role}" ]] || role="?"
        status="$(agent_status_value "${agent_dir}/status")"

        hb=0
        hb_present=0
        hb_age=0
        hb_age_str="none"
        if [[ -f "${agent_dir}/heartbeat" ]]; then
            hb="$(tr -dc '0-9' < "${agent_dir}/heartbeat" 2>/dev/null || echo 0)"
        fi
        if [[ "${hb}" =~ ^[0-9]+$ ]] && (( hb > 0 )); then
            hb_present=1
            hb_age=$(( now - hb ))
            hb_age_str="$(compact_age "${hb_age}")"
        fi

        # Keep the startup roster focused on agents that have operated recently.
        # Membership uses the persistent last-activity signal rather than the
        # heartbeat, which a cleanly exiting agent deletes.
        last_epoch="$(agent_last_activity_epoch "${agent_dir}")"
        (( last_epoch > 0 )) || continue
        last_age=$(( now - last_epoch ))
        (( last_age >= 0 )) || last_age=0
        (( last_age <= AGENT_ACTIVE_WINDOW_SECONDS )) || continue
        last_age_str="$(compact_age "${last_age}")"

        inbox_n=$(find "${agent_dir}/inbox" -maxdepth 1 -name '*.msg' -type f 2>/dev/null | wc -l | tr -d ' ')
        session_name=""
        session_state="n/a"
        if [[ "${role}" == "?" ]]; then
            if [[ "${agent_id}" == "watch" ]]; then
                role="watch"
            elif agent_session_exists "worker_${agent_id}"; then
                role="worker"
            elif agent_session_exists "node_${agent_id}"; then
                role="node"
            fi
        fi
        if session_name="$(agent_session_name "${role}" "${agent_id}" 2>/dev/null)"; then
            if agent_session_exists "${session_name}"; then
                session_state="up"
            else
                session_state="down"
            fi
        fi

        # A missing heartbeat means "exited cleanly", not "broken", so the live
        # session decides between running, leftover residue, and stopped.
        color="${GREEN}"
        if [[ "${status}" == "error" || "${status}" == invalid* ]]; then
            color="${RED}"
        elif [[ "${session_state}" == "up" ]]; then
            if (( hb_present == 0 )) || (( hb_age > CORTEX_DEFAULT_HEARTBEAT_ALIVE_SECONDS )); then
                color="${RED}"
            elif [[ "${status}" == "offline" || "${status}" == "?" ]]; then
                color="${YELLOW}"
            fi
        elif (( hb_present == 1 )); then
            if (( hb_age > CORTEX_DEFAULT_HEARTBEAT_ALIVE_SECONDS )); then
                color="${RED}"
            else
                color="${YELLOW}"
            fi
        else
            color="${GREY}"
        fi

        if [[ "${inbox_n}" -gt 0 && "${color}" == "${GREEN}" ]]; then
            color="${YELLOW}"
        fi

        printf '  %b%-20s%b role=%-10s %s=%-4s hb=%-6s last=%-6s status=%-14s inbox=%s\n' \
            "${color}" "${agent_id}" "${RESET}" "${role}" "${SESSION_BACKEND}" "${session_state}" "${hb_age_str}" "${last_age_str}" "${status}" "${inbox_n}"
    done < <(find "${CORTEX_DIR}/agents" -mindepth 1 -maxdepth 1 -type d | sort)
}

print_agent_roster
