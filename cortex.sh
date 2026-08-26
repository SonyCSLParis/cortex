#!/usr/bin/env bash
# =============================================================================
# cortex.sh — Cortex chat conductor launcher + fleet status dashboard
# Prints agent / watch / inbox state, then drops into the chosen provider as the chat
# conductor. Chat and the watch agent coexist — no lock is acquired here. To stop
# a running watch from chat, use `bash "${CORTEX_DEFAULT_WATCH_SCRIPT}" --stop`.
# =============================================================================

if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CORTEX_DIR="${CORTEX_DIR:-${SCRIPT_DIR}}"
CONDUCTOR_DIR="${CORTEX_DIR}/agents/conductor"
CONDUCTOR_INBOX="${CONDUCTOR_DIR}/inbox"
CONDUCTOR_ARCHIVE="${CONDUCTOR_DIR}/archive"
CONDUCTOR_SESSIONS_DIR="${CONDUCTOR_DIR}/sessions"
CONDUCTOR_ACTIVE_SESSIONS_FILE="${CONDUCTOR_DIR}/active_sessions.tsv"
CONDUCTOR_STATUS_FILE="${CONDUCTOR_DIR}/status"
CONDUCTOR_HEARTBEAT_FILE="${CONDUCTOR_DIR}/heartbeat"
CONDUCTOR_INFO_FILE="${CONDUCTOR_DIR}/info"
USER_ROUTER_FILE="${CORTEX_DIR}/user.instruct"
USER_INSTRUCT_FILE=""
SETUP_INSTRUCT_FILE="${CORTEX_DIR}/setup.instruct"
CONDUCTOR_HEARTBEAT_INTERVAL="${CONDUCTOR_HEARTBEAT_INTERVAL:-10}"
NOW=$(date +%s)
CONDUCTOR_HEARTBEAT_PID=""
PROMPT_LOG_SYNC_PID=""
PROMPT_LOG_SYNC_INTERVAL="${CORTEX_PROMPT_LOG_SYNC_INTERVAL:-5}"
CONDUCTOR_SESSION_LABEL="${CORTEX_CONDUCTOR_LABEL:-}"
CONDUCTOR_SESSION_ID=""
CONDUCTOR_SESSION_DIR=""
CONDUCTOR_SESSION_STATUS_FILE=""
CONDUCTOR_SESSION_HEARTBEAT_FILE=""
CONDUCTOR_SESSION_INFO_FILE=""
CONDUCTOR_CLI_VERSION="unknown"
SCREEN_SESSION_LISTING=""

source "${CORTEX_DIR}/scripts/watch_lock.sh"
source "${CORTEX_DIR}/config/cortex_defaults.sh"
source "${CORTEX_DIR}/scripts/user_context.sh"
source "${CORTEX_DIR}/scripts/usage_lib.sh"

PROVIDER="${CORTEX_CONDUCTOR_PROVIDER:-codex}"
PROVIDER_EXPLICIT=0
MODEL="${CORTEX_CONDUCTOR_MODEL:-}"
CONDUCTOR_TIER="${CORTEX_CONDUCTOR_TIER:-}"
PERMISSION_MODE="${CORTEX_CONDUCTOR_PERMISSION_MODE:-provider-default}"
CLAUDE_EFFORT_EXPLICIT=0
[[ -n "${CLAUDE_EFFORT+x}" ]] && CLAUDE_EFFORT_EXPLICIT=1
CLAUDE_EFFORT="${CLAUDE_EFFORT:-low}"
CODEX_REASONING_EFFORT_EXPLICIT=0
[[ -n "${CODEX_REASONING_EFFORT+x}" ]] && CODEX_REASONING_EFFORT_EXPLICIT=1
CODEX_REASONING_EFFORT="${CODEX_REASONING_EFFORT:-medium}"
RESUME_LAST=0
INIT_ONLY=0
BOOTSTRAP_USER=""
BOOTSTRAP_ENV=""
SKIP_INIT=0
STARTUP_CHECKS=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            cat <<'EOF'
Usage:
  bash "${CORTEX_DEFAULT_CONDUCTOR_SCRIPT}" [--provider codex|claude] [--tier weak|medium|strong] [--model MODEL] [--permission MODE]
  bash "${CORTEX_DEFAULT_CONDUCTOR_SCRIPT}" --resume [--provider codex|claude] [--tier weak|medium|strong] [--model MODEL] [--permission MODE]
  bash "${CORTEX_DEFAULT_CONDUCTOR_SCRIPT}" [--label NAME]
  bash "${CORTEX_DEFAULT_CONDUCTOR_SCRIPT}" --init [--user NAME] [--env NAME]

Shows fleet + watch + inbox state, then drops into the chosen provider CLI
as the chat conductor. Default fresh-session provider is codex. With
`--resume`, Cortex reuses the last conductor provider and resumes that
provider's most recent conductor chat context. Chat coexists with a running
watch agent — no mutual-exclusion lock. To stop a running watch from chat, run:
  bash "${CORTEX_DEFAULT_WATCH_SCRIPT}" --stop

Session control:
  --resume          Resume the latest conductor chat using the last provider;
                    ignores --provider if both are given.
  --label NAME      Optional label for this conductor window (letters,
                    numbers, dot, underscore, hyphen only).
  --startup-checks  Run the startup-checks routine (log/tasks review, inbox
                    drain, worker-liveness, next-step suggestions) instead of
                    the default minimal startup routine (read instruction files
                    + a short greeting, no operational checks).

Provider and model selection:
  --provider VALUE  Conductor provider to launch. Accepted:
                      codex, claude
  --tier LEVEL      Apply a shared model/effort tier. Accepted:
                      weak, medium, strong
                    Aliases:
                      low -> weak, high -> strong
                    With --resume, overrides the resumed session's provider
                    defaults for model/effort. Explicit --model still wins.
  --model VERSION   Short version alias for the provider's model. Accepted:
                      claude: fable-5, sonnet-5, 4.8 (Opus), 4.7, 4.6
                      codex:  5.6, 5.6-sol, 5.6-terra, 5.6-luna, 5.5, 5.4
                    Full provider model ids are also accepted. Defaults to the
                    provider's own default when omitted.
  --permission MODE Select conductor provider permission behavior. Accepted:
                      default, auto-review, full-access
                    Codex supports every mode. Claude supports verified modes
                    default and full-access only. When omitted, keep the
                    provider's configured/default behavior.
  --permission-all  Compatibility shorthand for --permission full-access.
                    Codex uses
                    --dangerously-bypass-approvals-and-sandbox; Claude uses
                    --dangerously-skip-permissions. Cortex safety rules still
                    apply.
  --permission-default
                    Compatibility shorthand for --permission default; can
                    override CORTEX_CONDUCTOR_PERMISSION_MODE.

First-run setup:
  --init            Create local user/environment/conductor state and exit.
  --user NAME       User profile name for --init or first-run prompts.
  --env NAME        Environment name for --init or first-run prompts.
  --no-init         Do not prompt for first-run setup.
EOF
            exit 0
            ;;
        --init)
            INIT_ONLY=1
            shift
            ;;
        --user)
            [[ $# -ge 2 ]] || { echo "Missing value for --user" >&2; exit 2; }
            BOOTSTRAP_USER="$2"
            shift 2
            ;;
        --env)
            [[ $# -ge 2 ]] || { echo "Missing value for --env" >&2; exit 2; }
            BOOTSTRAP_ENV="$2"
            shift 2
            ;;
        --no-init)
            SKIP_INIT=1
            shift
            ;;
        --startup-checks)
            STARTUP_CHECKS=1
            shift
            ;;
        --provider)
            [[ $# -ge 2 ]] || { echo "Missing value for --provider" >&2; exit 2; }
            PROVIDER="$2"
            PROVIDER_EXPLICIT=1
            shift 2
            ;;
        --resume)
            RESUME_LAST=1
            shift
            ;;
        --model)
            [[ $# -ge 2 ]] || { echo "Missing value for --model" >&2; exit 2; }
            MODEL="$2"
            shift 2
            ;;
        --tier)
            [[ $# -ge 2 ]] || { echo "Missing value for --tier" >&2; exit 2; }
            CONDUCTOR_TIER="$2"
            shift 2
            ;;
        --permission-all)
            PERMISSION_MODE="full-access"
            shift
            ;;
        --permission-default)
            PERMISSION_MODE="default"
            shift
            ;;
        --permission)
            [[ $# -ge 2 ]] || { echo "Missing value for --permission" >&2; exit 2; }
            PERMISSION_MODE="$2"
            shift 2
            ;;
        --label)
            [[ $# -ge 2 ]] || { echo "Missing value for --label" >&2; exit 2; }
            CONDUCTOR_SESSION_LABEL="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; GREY='\033[0;90m'
BOLD='\033[1m'; RESET='\033[0m'

iso8601_now_local() {
    local raw
    raw="$(date '+%Y-%m-%dT%H:%M:%S%z')" || return 1
    printf '%s:%s\n' "${raw:0:${#raw}-2}" "${raw:${#raw}-2}"
}

sanitize_dashboard_text() {
    printf '%s' "$1" | tr '\000-\010\013\014\016-\037\177' '?'
}

atomic_write() {
    local dest="$1"
    local tmp="${dest}.tmp"
    cat > "${tmp}"
    mv "${tmp}" "${dest}"
}

cortex_bootstrap_name_ok() {
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

cortex_runtime_name_fragment() {
    local value="${1:-unknown}"
    value="$(printf '%s' "${value}" | tr -cs 'A-Za-z0-9._-' '-')"
    value="${value#-}"
    value="${value%-}"
    printf '%s\n' "${value:-unknown}"
}

cortex_bootstrap_default_user() {
    local candidate="${USER:-}"
    [[ -n "${candidate}" ]] || candidate="$(whoami 2>/dev/null || echo user)"
    candidate="${candidate// /-}"
    if cortex_bootstrap_name_ok "${candidate}"; then
        printf '%s\n' "${candidate}"
    else
        printf 'user\n'
    fi
}

cortex_bootstrap_prompt() {
    local label="$1" default_value="$2" value=""
    while true; do
        printf '%s [%s]: ' "${label}" "${default_value}" >&2
        IFS= read -r value
        value="${value:-${default_value}}"
        if cortex_bootstrap_name_ok "${value}"; then
            printf '%s\n' "${value}"
            return 0
        fi
        printf 'Use only letters, numbers, dot, underscore, and hyphen.\n' >&2
    done
}

cortex_env_profile_relpath() {
    [[ -r "${CORTEX_DEFAULT_ENV_POINTER_FILE}" ]] || return 1
    grep -Eo 'environments/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\.instruct' \
        "${CORTEX_DEFAULT_ENV_POINTER_FILE}" | head -n 1
}

cortex_env_profile_exists() {
    local relpath
    relpath="$(cortex_env_profile_relpath 2>/dev/null || true)"
    [[ -n "${relpath}" && -f "${CORTEX_DIR}/${relpath}" ]]
}

cortex_first_run_setup_needed() {
    cortex_user_load "${CORTEX_DIR}" >/dev/null 2>&1 || return 0
    cortex_env_profile_exists || return 0
    [[ -f "${CONDUCTOR_DIR}/tasks.md" ]] || return 0
    [[ -f "${CONDUCTOR_DIR}/log.md" ]] || return 0
    [[ -f "${CONDUCTOR_DIR}/logbook.md" ]] || return 0
    return 1
}

cortex_bootstrap_write_if_missing() {
    local path="$1"
    shift
    [[ ! -e "${path}" ]] || return 0
    mkdir -p "$(dirname "${path}")"
    atomic_write "${path}" "$@"
}

cortex_bootstrap_state() {
    local user_name="$1" env_name="$2"
    local user_dir="${CORTEX_DIR}/users/${user_name}"
    local env_dir="${CORTEX_DIR}/environments/${env_name}"

    cortex_bootstrap_name_ok "${user_name}" || {
        echo "Invalid user name: ${user_name}" >&2
        return 2
    }
    cortex_bootstrap_name_ok "${env_name}" || {
        echo "Invalid environment name: ${env_name}" >&2
        return 2
    }

    mkdir -p \
        "${CONDUCTOR_INBOX}" \
        "${CONDUCTOR_ARCHIVE}" \
        "${CONDUCTOR_SESSIONS_DIR}" \
        "${CONDUCTOR_DIR}/history" \
        "${CORTEX_DIR}/agents/watch/inbox" \
        "${CORTEX_DIR}/agents/watch/archive" \
        "${CORTEX_DIR}/inboxes/signal" \
        "${CORTEX_DIR}/inboxes/telegram" \
        "${CORTEX_DIR}/broadcast" \
        "${CORTEX_DIR}/logs" \
        "${user_dir}" \
        "${env_dir}"

    cortex_bootstrap_write_if_missing "${CORTEX_DIR}/user.instruct" <<EOF
# Default-user routing note

The default user of this Cortex checkout is ${user_name}. User-specific
durable instructions live in \`users/${user_name}/${user_name}.instruct\`.

Keep private contact identifiers and user-specific preferences in the
per-user file, not in root \`user.instruct\`.
EOF

    cortex_bootstrap_write_if_missing "${user_dir}/${user_name}.instruct" <<EOF
# ${user_name} User Profile

Durable preferences, contact identifiers, and user-specific operating rules
for this Cortex checkout belong here.
EOF

    cortex_bootstrap_write_if_missing "${user_dir}/tasks.md" <<'EOF'
# User Tasks

## Open
## Doing
## Blocked
## Done
## Cancelled
EOF

    cortex_bootstrap_write_if_missing "${user_dir}/ideas.md" <<'EOF'
# User Ideas

Speculative ideas and low-commitment thoughts can be kept here until promoted
to a task or project note.
EOF

    cortex_bootstrap_write_if_missing "${CORTEX_DIR}/environment.instruct" <<EOF
# Default-environment routing note

The default environment of this Cortex checkout is ${env_name}.
Environment-specific durable instructions live in
\`environments/${env_name}/${env_name}.instruct\`.

Keep private hostnames, backup roots, remotes, and deployment-specific paths in
the environment directory, not in generic framework files.
EOF

    cortex_bootstrap_write_if_missing "${env_dir}/${env_name}.instruct" <<EOF
# ${env_name} Environment

Private infrastructure facts for this Cortex checkout belong here: hosts,
storage roots, relay machines, backup locations, and deployment-specific
gotchas.
EOF

    cortex_bootstrap_write_if_missing "${env_dir}/settings.env" <<'EOF'
# Local environment runtime overrides.
# Uncomment and set values when this checkout needs a different default or an
# optional service. Keep credentials in agents/conductor/secrets/, not here.
#
# CORTEX_CONDUCTOR_PROVIDER=codex
# CORTEX_AGENT_PROVIDER=claude
# CORTEX_CONDUCTOR_PERMISSION_MODE=default
# CORTEX_DEFAULT_BACKUP_ROOT="${CORTEX_DEFAULT_ROOT}/backups"
# BACKUP_KEEP=7
# SIGNAL_RELAY_HOST=
# TELEGRAM_RELAY_HOST=
# CORTEX_DEFAULT_PUBLIC_REMOTE_URL=
# CORTEX_DEFAULT_PUBLIC_BRANCH=main
EOF

    cortex_bootstrap_write_if_missing "${env_dir}/backup_targets.txt" <<'EOF'
# Backup manifest: label|mode|path
# Modes: repo_worktree, source_tree, path
cortex_worktree|repo_worktree|.
EOF

    cortex_bootstrap_write_if_missing "${CONDUCTOR_DIR}/tasks.md" <<'EOF'
# Conductor Tasks

## Open
## Doing
## Blocked
## Done
## Cancelled
EOF

    cortex_bootstrap_write_if_missing "${CONDUCTOR_DIR}/log.md" <<EOF
[$(iso8601_now_local)] conductor | INIT: initialized local Cortex checkout for user=${user_name} env=${env_name}
EOF

    cortex_bootstrap_write_if_missing "${CONDUCTOR_DIR}/logbook.md" <<'EOF'
# Cortex Conductor Logbook

Durable experiment, training, data-work, and framework-development notes go
here when they need to survive beyond the current chat.
EOF

    cortex_bootstrap_write_if_missing "${CONDUCTOR_DIR}/logbook.summary.md" <<'EOF'
# Cortex Conductor Logbook Summary

No durable logbook entries have been summarized yet.
EOF

    cortex_bootstrap_write_if_missing "${CORTEX_DIR}/agents/watch/watch.txt" <<'EOF'
# Watch Mission

Add unattended monitoring instructions here before starting the watch agent.
EOF

    CORTEX_DEFAULT_ENV_NAME="${env_name}"
    CORTEX_DEFAULT_ENV_DIR="${env_dir}"
    CORTEX_DEFAULT_ENV_SETTINGS_FILE="${env_dir}/settings.env"
    CORTEX_DEFAULT_BACKUP_TARGETS_FILE="${env_dir}/backup_targets.txt"
    export CORTEX_DEFAULT_ENV_NAME CORTEX_DEFAULT_ENV_DIR CORTEX_DEFAULT_ENV_SETTINGS_FILE CORTEX_DEFAULT_BACKUP_TARGETS_FILE
}

cortex_maybe_bootstrap() {
    local user_name="${BOOTSTRAP_USER}" env_name="${BOOTSTRAP_ENV}"

    if (( INIT_ONLY )); then
        [[ -n "${user_name}" ]] || user_name="$(cortex_bootstrap_default_user)"
        [[ -n "${env_name}" ]] || env_name="local"
        cortex_bootstrap_state "${user_name}" "${env_name}"
        echo "Initialized Cortex checkout for user=${user_name} env=${env_name}."
        return 0
    fi

    cortex_first_run_setup_needed || return 0
    (( SKIP_INIT == 0 )) || return 0
    if [[ -t 0 && -t 1 ]]; then
        echo "First-run Cortex setup"
        [[ -n "${user_name}" ]] || user_name="$(cortex_bootstrap_prompt "User name" "$(cortex_bootstrap_default_user)")"
        [[ -n "${env_name}" ]] || env_name="$(cortex_bootstrap_prompt "Environment name" "local")"
        cortex_bootstrap_state "${user_name}" "${env_name}"
        echo "Initialized Cortex checkout for user=${user_name} env=${env_name}."
    fi
}

cortex_maybe_bootstrap
if (( INIT_ONLY )); then
    exit 0
fi

if cortex_user_load "${CORTEX_DIR}"; then
    USER_INSTRUCT_FILE="${CORTEX_USER_INSTRUCT}"
fi

cortex_projects_initialized() {
    [[ -d "${CORTEX_DIR}/projects" ]] || return 1
    local project_dir
    while IFS= read -r -d '' project_dir; do
        return 0
    done < <(find "${CORTEX_DIR}/projects" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print0 2>/dev/null)
    return 1
}

cortex_conductor_prompt() {
    local prompt="Read CONDUCTOR.md and follow it."
    if (( STARTUP_CHECKS )); then
        prompt="${prompt} At startup, perform the startup-checks routine."
    else
        prompt="${prompt} At startup, perform the minimal startup routine."
    fi
    if ! cortex_projects_initialized && [[ -f "${SETUP_INSTRUCT_FILE}" ]]; then
        prompt="${prompt} No Cortex projects are initialized yet; also read setup.instruct and follow it during startup."
    fi
    printf '%s\n' "${prompt}"
}

cortex_provider_permission_args() {
    local provider="$1" mode="$2"

    case "${mode}" in
        provider-default) ;;
        default)
            [[ "${provider}" == "claude" ]] && return 0
            [[ "${provider}" == "codex" ]] || return 1
            printf '%s\n' --sandbox workspace-write --ask-for-approval on-request -c 'approvals_reviewer="user"'
            ;;
        auto-review)
            [[ "${provider}" == "codex" ]] && {
                printf '%s\n' --sandbox workspace-write --ask-for-approval on-request --enable guardian_approval -c 'approvals_reviewer="guardian_subagent"'
                return 0
            }
            return 1
            ;;
        full-access|all)
            [[ "${provider}" == "codex" ]] && {
                printf '%s\n' --dangerously-bypass-approvals-and-sandbox
                return 0
            }
            [[ "${provider}" == "claude" ]] && {
                printf '%s\n' --dangerously-skip-permissions
                return 0
            }
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

shell_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

cortex_prompt_log_sync_once() {
    local script_path="${CORTEX_DIR}/scripts/prompt_log_sync.py"
    [[ -n "${CONDUCTOR_SESSION_DIR:-}" ]] || return 0
    [[ -f "${script_path}" ]] || return 0
    command -v python3 >/dev/null 2>&1 || return 0

    local -a cmd=(
        python3 "${script_path}"
        --cwd "${CORTEX_DIR}"
        --session-dir "${CONDUCTOR_SESSION_DIR}"
        --log-path "${CONDUCTOR_SESSION_PROMPT_LOG}"
        --state-path "${CONDUCTOR_SESSION_PROMPT_STATE}"
    )
    "${cmd[@]}" >/dev/null 2>&1 || true
}

start_prompt_log_sync() {
    local daemon_script="${CORTEX_DIR}/scripts/prompt_log_sync_daemon.sh"
    [[ -n "${CONDUCTOR_SESSION_DIR:-}" ]] || return 0
    if [[ ! -d "${CONDUCTOR_SESSION_DIR}" ]]; then
        printf 'WARN  prompt-log sync skipped; missing session dir: %s\n' "${CONDUCTOR_SESSION_DIR}" >&2
        return 0
    fi
    [[ -f "${daemon_script}" ]] || {
        cortex_prompt_log_sync_once
        return 0
    }
    bash "${daemon_script}" \
        --cwd "${CORTEX_DIR}" \
        --session-dir "${CONDUCTOR_SESSION_DIR}" \
        --interval "${PROMPT_LOG_SYNC_INTERVAL}" \
        --parent-pid "$$" </dev/null >/dev/null 2>&1 &
    PROMPT_LOG_SYNC_PID="$!"
}

stop_prompt_log_sync() {
    if [[ -n "${PROMPT_LOG_SYNC_PID}" ]]; then
        kill "${PROMPT_LOG_SYNC_PID}" 2>/dev/null || true
        wait "${PROMPT_LOG_SYNC_PID}" 2>/dev/null || true
        PROMPT_LOG_SYNC_PID=""
    fi
    cortex_prompt_log_sync_once
}

cortex_usage_last_conductor_provider() {
    local ledger
    ledger="$(cortex_usage_ledger_path)"
    [[ -f "${ledger}" ]] || return 1
    awk -F '\t' '
        NR == 1 { next }
        $4 == "conductor" && $5 == "conductor" && $6 == "interactive" &&
        $15 == "cortex:conductor" && ($7 == "claude" || $7 == "codex") {
            provider = $7
        }
        END {
            if (provider != "") {
                print provider
            } else {
                exit 1
            }
        }
    ' "${ledger}"
}

cortex_last_conductor_provider() {
    local provider=""
    if [[ -f "${CONDUCTOR_INFO_FILE}" ]]; then
        provider="$(
            awk '
                /^PROVIDER:[[:space:]]*/ {
                    sub(/^PROVIDER:[[:space:]]*/, "", $0)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
                    print tolower($0)
                    exit
                }
            ' "${CONDUCTOR_INFO_FILE}" 2>/dev/null || true
        )"
    fi
    case "${provider}" in
        claude|codex)
            printf '%s\n' "${provider}"
            return 0
            ;;
    esac

    provider="$(cortex_usage_last_conductor_provider 2>/dev/null || true)"
    case "${provider}" in
        claude|codex)
            printf '%s\n' "${provider}"
            return 0
            ;;
    esac
    return 1
}

run_conductor_provider() {
    local -a command=("$@")
    local usage_file rc=0 model="${MODEL:-provider-default}" started_epoch ended_epoch
    local usage_codex_home=""
    usage_file="$(mktemp 2>/dev/null || echo "/tmp/cortex_conductor_usage_$$_${RANDOM}")"

    started_epoch="$(date -u +%s)"
    if command -v script >/dev/null 2>&1 && [[ -t 0 && -t 1 ]]; then
        if script -h 2>&1 | grep -qE '(^|[[:space:]])-c([[:space:],]|$)'; then
            local command_line="" arg
            for arg in "${command[@]}"; do
                [[ -z "${command_line}" ]] || command_line+=" "
                command_line+="$(shell_quote "${arg}")"
            done
            script -q -e -c "${command_line}" "${usage_file}" || rc=$?
        else
            script -q -e "${usage_file}" "${command[@]}" || rc=$?
        fi
    else
        # Avoid changing interactive TTY behavior just to capture accounting.
        "${command[@]}" || rc=$?
    fi
    ended_epoch="$(date -u +%s)"

    if [[ -s "${usage_file}" ]]; then
        if [[ "${PROVIDER}" == "codex" ]]; then
            usage_codex_home="${CODEX_HOME:-${HOME}/.codex}"
            CORTEX_USAGE_CODEX_HOME="${usage_codex_home}" \
                cortex_usage_record_from_file \
                    "${usage_file}" "conductor" "conductor" "interactive" \
                    "${PROVIDER}" "${model}" "cortex:conductor" \
                    "${started_epoch}" "${ended_epoch}" "${CORTEX_DIR}" || true
        else
            cortex_usage_record_from_file \
                "${usage_file}" "conductor" "conductor" "interactive" \
                "${PROVIDER}" "${model}" "cortex:conductor" \
                "${started_epoch}" "${ended_epoch}" "${CORTEX_DIR}" || true
        fi
    fi
    rm -f "${usage_file}"
    return "${rc}"
}

normalize_conductor_tier() {
    local raw="${1:-}"
    case "$(printf '%s' "${raw}" | tr '[:upper:]' '[:lower:]')" in
        weak|low)
            printf 'weak\n'
            ;;
        medium|med|mid)
            printf 'medium\n'
            ;;
        strong|high)
            printf 'strong\n'
            ;;
        *)
            return 1
            ;;
    esac
}

resolve_conductor_model_name() {
    local provider="$1" requested="$2"
    case "${provider}/${requested}" in
        claude/fable-5) printf 'claude-fable-5\n' ;;
        claude/sonnet-5) printf 'claude-sonnet-5\n' ;;
        claude/4.8) printf 'claude-opus-4-8\n' ;;
        claude/4.7) printf 'claude-opus-4-7\n' ;;
        claude/4.6) printf 'claude-sonnet-4-6\n' ;;
        codex/5.6) printf 'gpt-5.6\n' ;;
        codex/5.6-sol) printf 'gpt-5.6-sol\n' ;;
        codex/5.6-terra) printf 'gpt-5.6-terra\n' ;;
        codex/5.6-luna) printf 'gpt-5.6-luna\n' ;;
        codex/5.5)  printf 'gpt-5.5\n' ;;
        codex/5.4)  printf 'gpt-5.4\n' ;;
        claude/claude-*) printf '%s\n' "${requested}" ;;
        codex/gpt-*) printf '%s\n' "${requested}" ;;
        *)
            return 1
            ;;
    esac
}

apply_conductor_model_tier() {
    local tier="${1:-}"
    local up
    up="$(printf '%s' "${tier}" | tr '[:lower:]' '[:upper:]')"
    local codex_model_var="CORTEX_DEFAULT_TIER_${up}_CODEX_MODEL"
    local claude_model_var="CORTEX_DEFAULT_TIER_${up}_CLAUDE_MODEL"
    local codex_reasoning_var="CORTEX_DEFAULT_TIER_${up}_CODEX_REASONING"
    local claude_effort_var="CORTEX_DEFAULT_TIER_${up}_CLAUDE_EFFORT"
    if [[ -z "${!codex_model_var:-}" ]]; then
        echo "Unknown --tier '${tier}' (expected weak|medium|strong, aliases low|high)." >&2
        exit 2
    fi
    [[ -n "${MODEL}" ]] || {
        if [[ "${PROVIDER}" == "codex" ]]; then
            MODEL="${!codex_model_var}"
        else
            MODEL="${!claude_model_var}"
        fi
    }
    [[ "${CODEX_REASONING_EFFORT_EXPLICIT}" -eq 0 ]] && CODEX_REASONING_EFFORT="${!codex_reasoning_var}"
    [[ "${CLAUDE_EFFORT_EXPLICIT}" -eq 0 ]] && CLAUDE_EFFORT="${!claude_effort_var}"
}

if (( RESUME_LAST )); then
    PROVIDER="$(cortex_last_conductor_provider 2>/dev/null || true)"
    if [[ -z "${PROVIDER}" ]]; then
        echo "Cannot resume: unable to determine the last conductor provider from ${CONDUCTOR_INFO_FILE} or the user usage ledger." >&2
        exit 1
    fi
    if (( PROVIDER_EXPLICIT )); then
        echo "Warning: --provider is ignored with --resume; resuming last conductor provider ${PROVIDER}." >&2
    fi
fi

case "${PROVIDER}" in
    claude|codex) ;;
    *)
        echo "Unsupported provider: ${PROVIDER} (expected claude or codex)" >&2
        exit 2
        ;;
esac

if [[ -n "${CONDUCTOR_TIER}" ]]; then
    CONDUCTOR_TIER="$(normalize_conductor_tier "${CONDUCTOR_TIER}")" || {
        echo "Unknown --tier '${CONDUCTOR_TIER}' (expected weak|medium|strong, aliases low|high)." >&2
        exit 2
    }
fi

if [[ -n "${MODEL}" ]]; then
    MODEL="$(resolve_conductor_model_name "${PROVIDER}" "${MODEL}")" || {
        echo "Unknown --model '${MODEL}' for provider ${PROVIDER}." >&2
        echo "Accepted aliases: claude → fable-5, sonnet-5, 4.8, 4.7, 4.6" >&2
        echo "                  codex → 5.6, 5.6-sol, 5.6-terra, 5.6-luna, 5.5, 5.4" >&2
        echo "Full provider model ids are also accepted." >&2
        exit 2
    }
fi

if [[ -n "${CONDUCTOR_TIER}" ]]; then
    apply_conductor_model_tier "${CONDUCTOR_TIER}"
fi

CLAUDE_EFFORT_SESSION="provider-default"
if [[ -n "${CONDUCTOR_TIER}" || "${CLAUDE_EFFORT_EXPLICIT}" -eq 1 ]]; then
    CLAUDE_EFFORT_SESSION="${CLAUDE_EFFORT}"
fi
CODEX_REASONING_EFFORT_SESSION="provider-default"
if [[ -n "${CONDUCTOR_TIER}" || "${CODEX_REASONING_EFFORT_EXPLICIT}" -eq 1 ]]; then
    CODEX_REASONING_EFFORT_SESSION="${CODEX_REASONING_EFFORT}"
fi

case "${PERMISSION_MODE}" in
    provider-default|default|auto-review|full-access|all) ;;
    *)
        echo "Unsupported permission mode: ${PERMISSION_MODE} (expected default, auto-review, or full-access)" >&2
        exit 2
        ;;
esac

PERMISSION_ARGS=()
PERMISSION_ARG_COUNT=0
permission_args_output="$(cortex_provider_permission_args "${PROVIDER}" "${PERMISSION_MODE}")" || {
    echo "Permission mode '${PERMISSION_MODE}' is not supported for provider ${PROVIDER}." >&2
    [[ "${PROVIDER}" == "claude" ]] && echo "Verified Claude modes are default and full-access." >&2
    exit 2
}
if [[ -n "${permission_args_output}" ]]; then
    while IFS= read -r permission_arg; do
        [[ -n "${permission_arg}" ]] || continue
        PERMISSION_ARGS[${PERMISSION_ARG_COUNT}]="${permission_arg}"
        PERMISSION_ARG_COUNT=$(( PERMISSION_ARG_COUNT + 1 ))
    done <<< "${permission_args_output}"
fi

if ! command -v "${PROVIDER}" >/dev/null 2>&1; then
    echo "Provider CLI not found: ${PROVIDER}" >&2
    echo "Install it, put it on PATH, or choose another provider with --provider codex|claude." >&2
    exit 127
fi

if [[ -n "${CONDUCTOR_SESSION_LABEL}" ]] && ! cortex_bootstrap_name_ok "${CONDUCTOR_SESSION_LABEL}"; then
    echo "Invalid --label value: ${CONDUCTOR_SESSION_LABEL}" >&2
    echo "Use only letters, numbers, dot, underscore, and hyphen." >&2
    exit 2
fi

CONDUCTOR_CLI_VERSION="$("${PROVIDER}" --version 2>/dev/null | head -1 || echo unknown)"

conductor_now() {
    date -u +%s
}

conductor_status_write() {
    local path="$1" value="$2"
    printf '%s\n' "${value}" | atomic_write "${path}"
}

conductor_info_field() {
    local file="$1" key="$2"
    awk -F: -v key="${key}" '$1 == key {
        sub(/^[^:]*:[[:space:]]*/, "")
        print
        exit
    }' "${file}" 2>/dev/null
}

conductor_session_init() {
    local host_fragment
    host_fragment="$(cortex_runtime_name_fragment "$(hostname 2>/dev/null || echo host)")"
    CONDUCTOR_SESSION_ID="$(date -u +%Y%m%dT%H%M%SZ)_${host_fragment}_$$_${RANDOM}"
    CONDUCTOR_SESSION_DIR="${CONDUCTOR_SESSIONS_DIR}/${CONDUCTOR_SESSION_ID}"
    CONDUCTOR_SESSION_STATUS_FILE="${CONDUCTOR_SESSION_DIR}/status"
    CONDUCTOR_SESSION_HEARTBEAT_FILE="${CONDUCTOR_SESSION_DIR}/heartbeat"
    CONDUCTOR_SESSION_INFO_FILE="${CONDUCTOR_SESSION_DIR}/info"
    CONDUCTOR_SESSION_PROMPT_LOG="${CONDUCTOR_SESSION_DIR}/prompt_log.txt"
    CONDUCTOR_SESSION_PROMPT_STATE="${CONDUCTOR_SESSION_DIR}/.prompt_log_state.json"
}

write_conductor_session_info() {
    atomic_write "${CONDUCTOR_SESSION_INFO_FILE}" <<EOF
AGENT_ID:     conductor
ROLE:         conductor
RUN_MODE:     interactive
SESSION_ID:   ${CONDUCTOR_SESSION_ID}
SESSION_LABEL:${CONDUCTOR_SESSION_LABEL:-none}
AGGREGATE:    no
IP:           $(hostname -I 2>/dev/null | awk '{print $1}' || echo unknown)
USER:         $(whoami 2>/dev/null || echo unknown)
REGISTERED:   $(date -u '+%Y-%m-%d %H:%M:%S UTC')
EPOCH:        $(date -u +%s)
PROVIDER:     ${PROVIDER}
MODEL:        ${MODEL:-provider-default}
MODEL_TIER:   ${CONDUCTOR_TIER:-none}
CLAUDE_EFFORT: ${CLAUDE_EFFORT_SESSION}
CODEX_REASONING_EFFORT: ${CODEX_REASONING_EFFORT_SESSION}
PERMISSION_MODE: ${PERMISSION_MODE}
CLI_VERSION:  ${CONDUCTOR_CLI_VERSION}
INBOX:        ${CONDUCTOR_INBOX}
ARCHIVE:      ${CONDUCTOR_ARCHIVE}
SESSIONS_DIR: ${CONDUCTOR_SESSIONS_DIR}
USER_NAME:    ${CORTEX_USER_NAME:-unknown}
USER_HOME:    ${CORTEX_USER_HOME:-unknown}
USER_INSTRUCT:${CORTEX_USER_INSTRUCT:-unknown}
PROMPT_LOG:   ${CONDUCTOR_SESSION_PROMPT_LOG}
PROMPT_STATE: ${CONDUCTOR_SESSION_PROMPT_STATE}
EOF
}

refresh_conductor_runtime() {
    local now active_n=0 aggregate_status="offline" aggregate_heartbeat=0
    local session_dir session_id status heartbeat age info_file status_file heartbeat_file session_epoch
    local provider cli_version label user_name user_home user_instruct registered ip user
    local primary_provider="unknown" primary_cli_version="unknown" primary_label="none"
    local primary_user_name="unknown" primary_user_home="unknown" primary_user_instruct="unknown"
    local primary_registered="unknown" primary_ip="unknown" primary_user="unknown"
    local primary_session_id="none" primary_epoch=0 primary_heartbeat=0 primary_status="offline"
    local latest_any_provider="unknown" latest_any_cli_version="unknown" latest_any_label="none"
    local latest_any_user_name="unknown" latest_any_user_home="unknown" latest_any_user_instruct="unknown"
    local latest_any_registered="unknown" latest_any_ip="unknown" latest_any_user="unknown"
    local latest_any_session_id="none" latest_any_epoch=0 latest_any_heartbeat=0
    local active_lines

    now="$(conductor_now)"
    mkdir -p "${CONDUCTOR_SESSIONS_DIR}"
    active_lines=$'session_id\tstatus\tage_seconds\tprovider\tlabel\tuser_name\tstarted_epoch\tregistered\n'

    shopt -s nullglob
    for session_dir in "${CONDUCTOR_SESSIONS_DIR}"/*; do
        [[ -d "${session_dir}" ]] || continue
        session_id="$(basename "${session_dir}")"
        info_file="${session_dir}/info"
        status_file="${session_dir}/status"
        heartbeat_file="${session_dir}/heartbeat"
        [[ -f "${info_file}" && -f "${status_file}" && -f "${heartbeat_file}" ]] || continue
        status="$(tr -d '\r\n' < "${status_file}" || true)"
        [[ -n "${status}" ]] || status="unknown"
        heartbeat="$(cat "${heartbeat_file}" 2>/dev/null || echo 0)"
        [[ "${heartbeat}" =~ ^[0-9]+$ ]] || heartbeat=0
        age=$(( now - heartbeat ))
        (( age >= 0 )) || age=0
        session_epoch="$(conductor_info_field "${info_file}" EPOCH)"
        [[ "${session_epoch}" =~ ^[0-9]+$ ]] || session_epoch=0
        provider="$(conductor_info_field "${info_file}" PROVIDER)"
        [[ -n "${provider}" ]] || provider="unknown"
        cli_version="$(conductor_info_field "${info_file}" CLI_VERSION)"
        [[ -n "${cli_version}" ]] || cli_version="unknown"
        label="$(conductor_info_field "${info_file}" SESSION_LABEL)"
        [[ -n "${label}" ]] || label="none"
        user_name="$(conductor_info_field "${info_file}" USER_NAME)"
        [[ -n "${user_name}" ]] || user_name="unknown"
        user_home="$(conductor_info_field "${info_file}" USER_HOME)"
        [[ -n "${user_home}" ]] || user_home="unknown"
        user_instruct="$(conductor_info_field "${info_file}" USER_INSTRUCT)"
        [[ -n "${user_instruct}" ]] || user_instruct="unknown"
        registered="$(conductor_info_field "${info_file}" REGISTERED)"
        [[ -n "${registered}" ]] || registered="unknown"
        ip="$(conductor_info_field "${info_file}" IP)"
        [[ -n "${ip}" ]] || ip="unknown"
        user="$(conductor_info_field "${info_file}" USER)"
        [[ -n "${user}" ]] || user="unknown"

        if (( session_epoch > latest_any_epoch || (session_epoch == latest_any_epoch && heartbeat >= latest_any_heartbeat) )); then
            latest_any_epoch="${session_epoch}"
            latest_any_heartbeat="${heartbeat}"
            latest_any_provider="${provider}"
            latest_any_cli_version="${cli_version}"
            latest_any_label="${label}"
            latest_any_user_name="${user_name}"
            latest_any_user_home="${user_home}"
            latest_any_user_instruct="${user_instruct}"
            latest_any_registered="${registered}"
            latest_any_ip="${ip}"
            latest_any_user="${user}"
            latest_any_session_id="${session_id}"
        fi

        if [[ "${status}" != "offline" ]] && (( heartbeat > 0 )) && (( age <= CORTEX_DEFAULT_HEARTBEAT_ALIVE_SECONDS )); then
            active_n=$(( active_n + 1 ))
            active_lines+="${session_id}"$'\t'"${status}"$'\t'"${age}"$'\t'"${provider}"$'\t'"${label}"$'\t'"${user_name}"$'\t'"${session_epoch}"$'\t'"${registered}"$'\n'
            if (( session_epoch > primary_epoch || (session_epoch == primary_epoch && heartbeat >= primary_heartbeat) )); then
                primary_epoch="${session_epoch}"
                primary_heartbeat="${heartbeat}"
                primary_status="${status}"
                primary_provider="${provider}"
                primary_cli_version="${cli_version}"
                primary_label="${label}"
                primary_user_name="${user_name}"
                primary_user_home="${user_home}"
                primary_user_instruct="${user_instruct}"
                primary_registered="${registered}"
                primary_ip="${ip}"
                primary_user="${user}"
                primary_session_id="${session_id}"
            fi
        fi
    done
    shopt -u nullglob

    atomic_write "${CONDUCTOR_ACTIVE_SESSIONS_FILE}" <<EOF
${active_lines%$'\n'}
EOF

    if (( active_n > 0 )); then
        aggregate_status="${primary_status}"
        case "${aggregate_status}" in
            idle|busy|working|selfcheck|error) ;;
            *) aggregate_status="idle" ;;
        esac
        aggregate_heartbeat="${primary_heartbeat}"
    else
        aggregate_status="offline"
        aggregate_heartbeat="${latest_any_heartbeat}"
        primary_provider="${latest_any_provider}"
        primary_cli_version="${latest_any_cli_version}"
        primary_label="${latest_any_label}"
        primary_user_name="${latest_any_user_name}"
        primary_user_home="${latest_any_user_home}"
        primary_user_instruct="${latest_any_user_instruct}"
        primary_registered="${latest_any_registered}"
        primary_ip="${latest_any_ip}"
        primary_user="${latest_any_user}"
        primary_session_id="${latest_any_session_id}"
        primary_epoch="${latest_any_epoch}"
    fi
    (( aggregate_heartbeat > 0 )) || aggregate_heartbeat="${now}"

    conductor_status_write "${CONDUCTOR_STATUS_FILE}" "${aggregate_status}"
    printf '%s\n' "${aggregate_heartbeat}" | atomic_write "${CONDUCTOR_HEARTBEAT_FILE}"
    atomic_write "${CONDUCTOR_INFO_FILE}" <<EOF
AGENT_ID:     conductor
ROLE:         conductor
RUN_MODE:     interactive
AGGREGATE:    yes
ACTIVE_SESSIONS: ${active_n}
SESSION_ID:   ${primary_session_id}
SESSION_LABEL:${primary_label}
REGISTERED:   ${primary_registered}
EPOCH:        ${primary_epoch}
PROVIDER:     ${primary_provider}
CLI_VERSION:  ${primary_cli_version}
IP:           ${primary_ip}
USER:         ${primary_user}
INBOX:        ${CONDUCTOR_INBOX}
ARCHIVE:      ${CONDUCTOR_ARCHIVE}
SESSIONS_DIR: ${CONDUCTOR_SESSIONS_DIR}
ACTIVE_SESSIONS_FILE: ${CONDUCTOR_ACTIVE_SESSIONS_FILE}
USER_NAME:    ${primary_user_name}
USER_HOME:    ${primary_user_home}
USER_INSTRUCT:${primary_user_instruct}
UPDATED:      $(date -u '+%Y-%m-%d %H:%M:%S UTC')
EOF
}

set_conductor_status() {
    conductor_status_write "${CONDUCTOR_SESSION_STATUS_FILE}" "$1"
    refresh_conductor_runtime
}

refresh_conductor_heartbeat() {
    printf '%s\n' "$(conductor_now)" | atomic_write "${CONDUCTOR_SESSION_HEARTBEAT_FILE}"
    refresh_conductor_runtime
}

conductor_parallel_session_warning() {
    local session_id status age provider label other_n=0 line
    local details=()

    [[ -f "${CONDUCTOR_ACTIVE_SESSIONS_FILE}" ]] || return 0
    while IFS=$'\t' read -r session_id status age provider label _; do
        [[ "${session_id}" == "session_id" ]] && continue
        [[ -n "${session_id}" ]] || continue
        [[ "${session_id}" == "${CONDUCTOR_SESSION_ID}" ]] && continue
        other_n=$(( other_n + 1 ))
        line="${provider:-unknown}"
        [[ -n "${label:-}" && "${label}" != "none" ]] && line="${line}/${label}"
        details+=("${session_id} (${line}, ${age}s old, status=${status:-unknown})")
    done < "${CONDUCTOR_ACTIVE_SESSIONS_FILE}"

    if (( other_n > 0 )); then
        printf '%b\n' "${YELLOW}${BOLD}NOTE${RESET}  ${other_n} other conductor session(s) already active."
        printf '      Shared inbox/tasks/log still apply: %s\n\n' "$(IFS='; '; printf '%s' "${details[*]}")"
    fi
}

start_conductor_heartbeat() {
    # Self-terminate if the launcher dies without running its cleanup trap
    # (SIGKILL, crash, lost terminal). Same belt-and-braces pattern as
    # start_work_heartbeat in scripts/start_agent.sh; without it an orphaned
    # loop keeps refreshing the heartbeat forever and the dead session still
    # counts as active.
    local parent_pid=$$
    (
        while kill -0 "${parent_pid}" 2>/dev/null; do
            refresh_conductor_heartbeat
            sleep "${CONDUCTOR_HEARTBEAT_INTERVAL}"
        done
        # Parent vanished without cleanup: mark this session offline ourselves
        # and refresh the aggregate so active-session counts drop right away.
        conductor_status_write "${CONDUCTOR_SESSION_STATUS_FILE}" "offline" 2>/dev/null || true
        refresh_conductor_runtime 2>/dev/null || true
    ) </dev/null >/dev/null 2>&1 &
    CONDUCTOR_HEARTBEAT_PID="$!"
}

stop_conductor_heartbeat() {
    [[ -n "${CONDUCTOR_HEARTBEAT_PID}" ]] || return 0
    kill "${CONDUCTOR_HEARTBEAT_PID}" 2>/dev/null || true
    wait "${CONDUCTOR_HEARTBEAT_PID}" 2>/dev/null || true
    CONDUCTOR_HEARTBEAT_PID=""
}

cleanup() {
    stop_prompt_log_sync
    stop_conductor_heartbeat
    if [[ -d "${CONDUCTOR_SESSION_DIR}" ]]; then
        conductor_status_write "${CONDUCTOR_SESSION_STATUS_FILE}" "offline"
        printf '%s\n' "$(conductor_now)" | atomic_write "${CONDUCTOR_SESSION_HEARTBEAT_FILE}"
    fi
    if [[ -d "${CONDUCTOR_DIR}" ]]; then
        refresh_conductor_runtime
    fi
}

signal_exit() {
    trap - EXIT INT TERM HUP
    cleanup
    exit 130
}

conductor_session_init
mkdir -p "${CONDUCTOR_INBOX}" "${CONDUCTOR_ARCHIVE}" "${CONDUCTOR_SESSION_DIR}"
write_conductor_session_info
set_conductor_status "idle"
refresh_conductor_heartbeat
start_conductor_heartbeat
export CORTEX_CONDUCTOR_SESSION_ID="${CONDUCTOR_SESSION_ID}"
export CORTEX_CONDUCTOR_SESSION_LABEL="${CONDUCTOR_SESSION_LABEL:-none}"
trap cleanup EXIT
# HUP included: a closed terminal must run cleanup too, otherwise the session
# is left marked idle (the heartbeat ticker's parent-check is the fallback).
trap signal_exit INT TERM HUP
start_prompt_log_sync

# ── Operator view ─────────────────────────────────────────────────────────────
if [[ -x "${CORTEX_DIR}/scripts/periodics_check.sh" ]]; then
    periodic_heal_output="$(bash "${CORTEX_DIR}/scripts/periodics_check.sh" heal 2>&1 || true)"
fi

if [[ -x "${CORTEX_DIR}/scripts/agent_roster.sh" ]]; then
    bash "${CORTEX_DIR}/scripts/agent_roster.sh" --color
    echo
else
    echo -e "${RED}missing scripts/agent_roster.sh${RESET}"
fi

echo -e "\n${BOLD}OPERATOR VIEW${RESET}"
if [[ -n "${periodic_heal_output:-}" ]] && [[ "${periodic_heal_output}" != "all auto-start periodics healthy" ]]; then
    printf 'periodic auto-heal: %s\n' "$(printf '%s' "${periodic_heal_output}" | head -n 1)"
    if [[ "$(printf '%s' "${periodic_heal_output}" | wc -l)" -gt 1 ]]; then
        printf '%s\n' "${periodic_heal_output}" | tail -n +2 | sed 's/^/  /'
    fi
fi
if [[ -x "${CORTEX_DIR}/scripts/cortex_ops_snapshot.sh" ]]; then
    bash "${CORTEX_DIR}/scripts/cortex_ops_snapshot.sh"
else
    echo -e "  ${RED}missing scripts/cortex_ops_snapshot.sh${RESET}"
fi

echo
printf 'Conductor session: %s' "${CONDUCTOR_SESSION_ID}"
if [[ -n "${CONDUCTOR_SESSION_LABEL}" ]]; then
    printf ' (%s)' "${CONDUCTOR_SESSION_LABEL}"
fi
printf '\n\n'

conductor_parallel_session_warning

if [[ ! -f "${USER_ROUTER_FILE}" ]]; then
    echo -e "${YELLOW}${BOLD}NOTE${RESET}  missing user router note — create ${USER_ROUTER_FILE} and point it at users/<user>/<user>.instruct."
    echo
elif [[ -z "${USER_INSTRUCT_FILE}" ]]; then
    echo -e "${YELLOW}${BOLD}NOTE${RESET}  ${USER_ROUTER_FILE} does not point at a valid users/<user>/<user>.instruct profile."
    echo
fi

# ── Launch conductor chat session ────────────────────────────────────────────────
cd "${CORTEX_DIR}"
LAUNCH_ARGS=("${PROVIDER}")
if [[ -n "${MODEL}" ]]; then
    LAUNCH_ARGS[${#LAUNCH_ARGS[@]}]="--model"
    LAUNCH_ARGS[${#LAUNCH_ARGS[@]}]="${MODEL}"
fi
case "${PROVIDER}" in
    claude)
        if [[ -n "${CONDUCTOR_TIER}" || "${CLAUDE_EFFORT_EXPLICIT}" -eq 1 ]]; then
            LAUNCH_ARGS[${#LAUNCH_ARGS[@]}]="--effort"
            LAUNCH_ARGS[${#LAUNCH_ARGS[@]}]="${CLAUDE_EFFORT}"
        fi
        ;;
    codex)
        if [[ -n "${CONDUCTOR_TIER}" || "${CODEX_REASONING_EFFORT_EXPLICIT}" -eq 1 ]]; then
            LAUNCH_ARGS[${#LAUNCH_ARGS[@]}]="-c"
            LAUNCH_ARGS[${#LAUNCH_ARGS[@]}]="model_reasoning_effort=\"${CODEX_REASONING_EFFORT}\""
        fi
        ;;
esac
permission_arg_i=0
while (( permission_arg_i < PERMISSION_ARG_COUNT )); do
    LAUNCH_ARGS[${#LAUNCH_ARGS[@]}]="${PERMISSION_ARGS[${permission_arg_i}]}"
    permission_arg_i=$(( permission_arg_i + 1 ))
done

if (( RESUME_LAST )); then
    case "${PROVIDER}" in
        codex)
            run_conductor_provider "${LAUNCH_ARGS[@]}" resume --last
            ;;
        claude)
            run_conductor_provider "${LAUNCH_ARGS[@]}" --continue
            ;;
    esac
else
    run_conductor_provider "${LAUNCH_ARGS[@]}" "$(cortex_conductor_prompt)"
fi
exit $?
