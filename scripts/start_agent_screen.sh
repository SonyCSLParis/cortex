#!/usr/bin/env bash
# Start a Cortex agent inside a named session, idempotently.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CORTEX_DIR="${CORTEX_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd -P)}"
source "${CORTEX_DIR}/config/cortex_defaults.sh"
source "${CORTEX_DIR}/scripts/session_backend.sh"

ssh_auth_socket_usable() {
    local sock="$1"
    local rc=0
    [[ -n "${sock}" && -S "${sock}" ]] || return 1
    command -v ssh-add >/dev/null 2>&1 || return 1
    if command -v timeout >/dev/null 2>&1; then
        SSH_AUTH_SOCK="${sock}" timeout 2s ssh-add -l >/dev/null 2>&1 || rc=$?
    elif command -v gtimeout >/dev/null 2>&1; then
        SSH_AUTH_SOCK="${sock}" gtimeout 2s ssh-add -l >/dev/null 2>&1 || rc=$?
    else
        SSH_AUTH_SOCK="${sock}" ssh-add -l >/dev/null 2>&1 || rc=$?
    fi
    [[ "${rc}" -eq 0 ]]
}

file_mtime_epoch() {
    local path="$1"
    stat -c %Y "${path}" 2>/dev/null || stat -f %m "${path}" 2>/dev/null || printf '0\n'
}

list_ssh_auth_sockets() {
    local uid
    uid="$(id -u 2>/dev/null || true)"
    [[ -n "${uid}" ]] || return 1
    find /tmp -maxdepth 2 -type s -path '/tmp/ssh-*/agent.*' -uid "${uid}" 2>/dev/null \
        | while IFS= read -r sock; do
            [[ -n "${sock}" ]] || continue
            printf '%s %s\n' "$(file_mtime_epoch "${sock}")" "${sock}"
        done | sort -nr
}

resolve_ssh_auth_sock() {
    local current="${SSH_AUTH_SOCK:-}"
    local entry sock newest=""

    if ssh_auth_socket_usable "${current}"; then
        printf 'ready\t%s\n' "${current}"
        return 0
    fi

    while IFS= read -r entry; do
        sock="${entry#* }"
        [[ -n "${sock}" ]] || continue
        [[ -n "${newest}" ]] || newest="${sock}"
        if ssh_auth_socket_usable "${sock}"; then
            printf 'ready\t%s\n' "${sock}"
            return 0
        fi
    done < <(list_ssh_auth_sockets)

    if [[ -n "${current}" && -S "${current}" ]]; then
        printf 'fallback\t%s\n' "${current}"
        return 0
    fi
    if [[ -n "${newest}" ]]; then
        printf 'fallback\t%s\n' "${newest}"
        return 0
    fi
    return 1
}

refresh_launcher_ssh_auth_sock() {
    local resolution state resolved
    if resolution="$(resolve_ssh_auth_sock)"; then
        state="${resolution%%$'\t'*}"
        resolved="${resolution#*$'\t'}"
        export SSH_AUTH_SOCK="${resolved}"
        if [[ "${state}" == "ready" ]]; then
            printf 'ssh auth: using %s\n' "${resolved}" >&2
        else
            printf 'ssh auth: falling back to %s without ssh-add validation\n' "${resolved}" >&2
        fi
        return 0
    fi
    printf 'ssh auth: no usable ssh-agent socket found; remote SSH hops may fail\n' >&2
    return 1
}

usage() {
    cat <<'EOF'
Usage:
  bash scripts/start_agent_screen.sh [--backend screen|tmux] [--role node|worker|watch] [--name NAME] [--provider claude|codex] [--once] [--wake-seconds N] [--wait-seconds N] [--restart] [--dry-run] [-- start_agent/watch args...]

Examples:
  bash scripts/start_agent_screen.sh --role worker --name worker-1
  bash scripts/start_agent_screen.sh --role worker --name worker-1 --wake-seconds 1800
  CORTEX_RESEARCH_PROJECT=slap bash scripts/start_agent_screen.sh --role worker --name research-runner --restart
  bash scripts/start_agent_screen.sh --role node --name node-1
  bash scripts/start_agent_screen.sh --role watch --wake-seconds 1800

Starts the agent only when its session is absent. Use --restart to quit
an existing session first. Output stays visible in the session and is tee'd to
${CORTEX_DEFAULT_TMP_LOG_DIR}/<session>.log.
Project-bound `research-*` worker restarts require an explicit
`CORTEX_RESEARCH_PROJECT=<project>` in the caller environment so the
project runtime/RW scope is not silently dropped.

Default backend: ${CORTEX_DEFAULT_SESSION_BACKEND}. Override with
--backend or CORTEX_SESSION_BACKEND.
EOF
}

backend="${CORTEX_SESSION_BACKEND:-${CORTEX_DEFAULT_SESSION_BACKEND}}"
role="node"
name=""
provider=""
once=0
restart=0
dry_run=0
wait_seconds=20
wake_seconds=""
extra_args=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --backend)
            [[ $# -ge 2 ]] || { echo "Missing value for --backend" >&2; exit 2; }
            backend="$2"
            shift 2
            ;;
        --role)
            [[ $# -ge 2 ]] || { echo "Missing value for --role" >&2; exit 2; }
            role="$2"
            shift 2
            ;;
        --name)
            [[ $# -ge 2 ]] || { echo "Missing value for --name" >&2; exit 2; }
            name="$2"
            shift 2
            ;;
        --provider)
            [[ $# -ge 2 ]] || { echo "Missing value for --provider" >&2; exit 2; }
            provider="$2"
            shift 2
            ;;
        --once)
            once=1
            shift
            ;;
        --restart)
            restart=1
            shift
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        --wait-seconds)
            [[ $# -ge 2 ]] || { echo "Missing value for --wait-seconds" >&2; exit 2; }
            wait_seconds="$2"
            shift 2
            ;;
        --wake-seconds)
            [[ $# -ge 2 ]] || { echo "Missing value for --wake-seconds" >&2; exit 2; }
            wake_seconds="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            extra_args=("$@")
            break
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "${role}" in
    node|worker|watch) ;;
    *)
        echo "Unsupported role: ${role} (expected node, worker, or watch)" >&2
        exit 2
        ;;
esac

backend="$(cortex_session_backend_resolve "${backend}")" || exit 2

if [[ ! "${wait_seconds}" =~ ^[0-9]+$ ]]; then
    echo "Invalid --wait-seconds value: ${wait_seconds}" >&2
    exit 2
fi

if [[ -n "${wake_seconds}" && ! "${wake_seconds}" =~ ^[0-9]+$ ]]; then
    echo "Invalid --wake-seconds value: ${wake_seconds}" >&2
    exit 2
fi

if [[ "${role}" == "worker" && -z "${name}" ]]; then
    echo "--name is required for worker starts" >&2
    exit 2
fi

if [[ -n "${wake_seconds}" && "${role}" == "node" ]]; then
    echo "--wake-seconds is supported only for worker and watch starts" >&2
    exit 2
fi

if [[ -n "${name}" && ! "${name}" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Invalid agent name: ${name}" >&2
    exit 2
fi

agent_id="${name}"
if [[ -z "${agent_id}" ]]; then
    if [[ "${role}" == "watch" ]]; then
        agent_id="watch"
    else
        agent_id="$(hostname)"
    fi
fi

case "${role}" in
    worker) session="worker_${agent_id}" ;;
    watch) session="watch" ;;
    node) session="node_${agent_id}" ;;
esac

agent_session_exists() {
    cortex_session_exists "${backend}" "${session}"
}

agent_status_text() {
    local status_file="${CORTEX_DIR}/agents/${agent_id}/status"
    tr -d '\r\n' < "${status_file}" 2>/dev/null || true
}

agent_heartbeat_age_seconds() {
    local heartbeat_file="${CORTEX_DIR}/agents/${agent_id}/heartbeat"
    local hb now
    [[ -f "${heartbeat_file}" ]] || return 1
    hb="$(tr -dc '0-9' < "${heartbeat_file}" 2>/dev/null || true)"
    [[ "${hb}" =~ ^[0-9]+$ ]] || return 1
    now="$(date -u +%s)"
    printf '%s\n' "$(( now - hb ))"
}

agent_heartbeat_is_fresh() {
    local age
    age="$(agent_heartbeat_age_seconds)" || return 1
    (( age <= CORTEX_DEFAULT_HEARTBEAT_ALIVE_SECONDS ))
}

clear_restart_heartbeat_residue_if_safe() {
    local heartbeat_file="${CORTEX_DIR}/agents/${agent_id}/heartbeat"
    local working_file="${CORTEX_DIR}/agents/${agent_id}/working"
    local status

    agent_session_exists && return 1
    agent_heartbeat_is_fresh || return 1
    [[ ! -e "${working_file}" ]] || return 1
    status="$(agent_status_text)"
    [[ "${status}" == "offline" ]] || return 1
    rm -f "${heartbeat_file}"
}

wait_for_restart_ready() {
    local deadline now
    deadline=$(( $(date -u +%s) + CORTEX_DEFAULT_AGENT_RESTART_WRAPPER_SLEEP_SECONDS + CORTEX_DEFAULT_HEARTBEAT_ALIVE_SECONDS ))

    while :; do
        now="$(date -u +%s)"
        if (( now > deadline )); then
            return 1
        fi
        if ! agent_session_exists; then
            clear_restart_heartbeat_residue_if_safe || true
            if ! agent_heartbeat_is_fresh; then
                return 0
            fi
        fi
        sleep 1
    done
}

agent_status_line() {
    local status_file="${CORTEX_DIR}/agents/${agent_id}/status"
    local heartbeat_file="${CORTEX_DIR}/agents/${agent_id}/heartbeat"
    local now hb status age="unknown"
    now="$(date -u +%s)"
    status="$(tr -d '\r\n' < "${status_file}" 2>/dev/null || printf '?')"
    hb="$(tr -dc '0-9' < "${heartbeat_file}" 2>/dev/null || true)"
    if [[ "${hb}" =~ ^[0-9]+$ && "${hb}" -gt 0 ]]; then
        age="$(( now - hb ))s"
    fi
    printf 'status=%s heartbeat_age=%s' "${status:-?}" "${age}"
}

agent_info_value() {
    local key="$1"
    local info_file="${CORTEX_DIR}/agents/${agent_id}/info"
    [[ -f "${info_file}" ]] || return 1
    awk -v key="${key}" '
        index($0, key ":") == 1 {
            value = substr($0, index($0, ":") + 1)
            sub(/^[[:space:]]+/, "", value)
            print value
            exit
        }
    ' "${info_file}"
}

research_restart_guard_reason() {
    local recorded_project="" state_dir=""

    [[ "${role}" == "worker" ]] || return 1
    [[ "${agent_id}" == research-* ]] || return 1
    [[ -n "${CORTEX_RESEARCH_PROJECT:-}" ]] && return 1

    recorded_project="$(agent_info_value "RESEARCH_PROJECT" 2>/dev/null || true)"
    if [[ -n "${recorded_project}" && "${recorded_project}" != "none" ]]; then
        printf 'current agent info records RESEARCH_PROJECT=%s' "${recorded_project}"
        return 0
    fi

    state_dir="$(agent_info_value "STATE_DIR" 2>/dev/null || true)"
    if [[ "${state_dir}" == "${CORTEX_DIR}/projects/"* || "${state_dir}" == */projects/* ]]; then
        printf 'current agent info records project-owned STATE_DIR=%s' "${state_dir}"
        return 0
    fi

    return 1
}

backup_manifest_has_target() {
    local manifest="$1"
    [[ -f "${manifest}" ]] || return 1
    awk -F '|' '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        NF == 3 && $1 ~ /[^[:space:]]/ && $2 ~ /[^[:space:]]/ && $3 ~ /[^[:space:]]/ { found=1 }
        END { exit !found }
    ' "${manifest}"
}

operational_remote_is_configured() {
    local expected="${CORTEX_DEFAULT_OPERATIONAL_REMOTE_URL:-}"
    local public_url="${CORTEX_DEFAULT_PUBLIC_REMOTE_URL:-}"
    local remote remote_url

    [[ -n "${expected}" ]] || return 1
    [[ "${expected}" != "${public_url}" ]] || return 1
    while IFS= read -r remote; do
        remote_url="$(git -C "${CORTEX_DIR}" remote get-url --push "${remote}" 2>/dev/null || true)"
        [[ "${remote_url}" == "${expected}" ]] && return 0
    done < <(git -C "${CORTEX_DIR}" remote 2>/dev/null)
    return 1
}

require_operational_worker_config() {
    local backup_targets="${BACKUP_TARGETS_FILE:-${CORTEX_DEFAULT_BACKUP_TARGETS_FILE}}"
    local backup_root_configured="${CORTEX_DEFAULT_BACKUP_ROOT_CONFIGURED:-0}"

    [[ "${role}" == "worker" ]] || return 0
    case "${agent_id}" in
        backup)
            [[ -n "${BACKUP_ROOT:-}" ]] && backup_root_configured=1
            if [[ "${backup_root_configured}" != "1" ]]; then
                printf 'CONFIGURATION_REQUIRED: backup worker needs an explicit backup root. Set CORTEX_DEFAULT_BACKUP_ROOT in environments/<env>/settings.env (or BACKUP_ROOT for this launch), then ask the user to configure it. No worker started.\n' >&2
                return 1
            fi
            if ! backup_manifest_has_target "${backup_targets}"; then
                printf 'CONFIGURATION_REQUIRED: backup worker needs an intentional backup manifest with at least one target. Configure environments/<env>/backup_targets.txt (or BACKUP_TARGETS_FILE for this launch), then ask the user to configure it. No worker started.\n' >&2
                return 1
            fi
            ;;
        commit)
            if ! operational_remote_is_configured; then
                printf 'CONFIGURATION_REQUIRED: commit worker needs CORTEX_DEFAULT_OPERATIONAL_REMOTE_URL in environments/<env>/settings.env, matching a configured private Git push remote and distinct from the public export remote. Ask the user to configure it. No worker started.\n' >&2
                return 1
            fi
            ;;
    esac
    return 0
}

if ! require_operational_worker_config; then
    exit 2
fi

start_args=(--role "${role}")
if [[ "${role}" != "watch" && -n "${name}" ]]; then
    start_args+=(--name "${name}")
fi
if [[ -n "${provider}" ]]; then
    start_args+=(--provider "${provider}")
fi
if (( once == 1 )); then
    start_args+=(--once)
fi
if [[ -n "${wake_seconds}" && "${role}" == "watch" ]]; then
    start_args+=(--interval "${wake_seconds}")
fi
if [[ "${#extra_args[@]}" -gt 0 ]]; then
    start_args+=("${extra_args[@]}")
fi

quoted_start_args=""
printf -v quoted_start_args '%q ' "${start_args[@]}"
log_name="$(printf '%s' "${session}" | sed -E 's/[^A-Za-z0-9._-]+/_/g')"
log_path="${CORTEX_DEFAULT_TMP_LOG_DIR}/${log_name}.log"
env_prefix=""
if [[ -n "${wake_seconds}" && "${role}" == "worker" ]]; then
    env_prefix="env WORKER_REVIEW_INTERVAL=$(printf '%q' "${wake_seconds}") "
fi
launch_cmd="cd $(printf '%q' "${CORTEX_DIR}") && exec > >(tee -a $(printf '%q' "${log_path}")) 2>&1; exec ${env_prefix}bash $(printf '%q' "${CORTEX_DEFAULT_START_AGENT_SCRIPT}") ${quoted_start_args}"

if (( dry_run == 1 )); then
    cortex_session_start_dry_run "${backend}" "${session}" "${launch_cmd}" "${CORTEX_DIR}"
    exit 0
fi

if ! cortex_session_backend_available "${backend}"; then
    printf '%s is not available\n' "${backend}" >&2
    exit 1
fi

refresh_launcher_ssh_auth_sock || true

if (( restart == 1 )) && agent_session_exists; then
    if guard_reason="$(research_restart_guard_reason)"; then
        printf 'Refusing to restart %s without explicit CORTEX_RESEARCH_PROJECT; %s.\n' \
            "${agent_id}" "${guard_reason}" >&2
        printf 'Relaunch with e.g. CORTEX_RESEARCH_PROJECT=<project> bash scripts/start_agent_screen.sh --role worker --name %s --restart\n' \
            "${agent_id}" >&2
        exit 2
    fi
    cortex_session_stop "${backend}" "${session}" || true
    if ! wait_for_restart_ready; then
        printf 'Failed to restart %s cleanly; old session state never became restart-safe (%s).\n' \
            "${session}" "$(agent_status_line)" >&2
        exit 1
    fi
fi

if (( restart == 0 )) && agent_session_exists; then
    printf '%s already running (%s)\n' "${session}" "$(agent_status_line)"
    exit 0
fi

start_epoch="$(date -u +%s)"
cortex_session_start "${backend}" "${session}" "${launch_cmd}" "${CORTEX_DIR}"

deadline=$(( start_epoch + wait_seconds ))
while (( $(date -u +%s) <= deadline )); do
    if [[ -f "${CORTEX_DIR}/agents/${agent_id}/heartbeat" ]]; then
        hb="$(tr -dc '0-9' < "${CORTEX_DIR}/agents/${agent_id}/heartbeat" 2>/dev/null || true)"
        now="$(date -u +%s)"
        if [[ "${hb}" =~ ^[0-9]+$ ]] \
           && (( hb >= start_epoch )) \
           && (( now - hb <= CORTEX_DEFAULT_HEARTBEAT_ALIVE_SECONDS )); then
            printf '%s started (%s)\n' "${session}" "$(agent_status_line)"
            exit 0
        fi
    fi
    sleep 1
done

if agent_session_exists; then
    printf '%s started; heartbeat not fresh after %ss (%s)\n' \
        "${session}" "${wait_seconds}" "$(agent_status_line)"
    exit 1
fi

printf '%s failed to start; %s session not found\n' "${session}" "${backend}" >&2
exit 1
