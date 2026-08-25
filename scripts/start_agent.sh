#!/usr/bin/env bash
# =============================================================================
# scripts/start_agent.sh — Cortex agent bootstrap
# Starts either a node agent (default), an elevated worker agent, or the
# elevated watch agent.
#
# Usage:
#   bash "${CORTEX_DEFAULT_START_AGENT_SCRIPT}"                                 # node (default)
#   bash "${CORTEX_DEFAULT_START_AGENT_SCRIPT}" --role node --provider claude  # explicit
#   bash "${CORTEX_DEFAULT_START_AGENT_SCRIPT}" --role worker --name fix-1 --provider codex --once
#   bash "${CORTEX_DEFAULT_START_AGENT_SCRIPT}" --role worker --name worker-1 --provider codex
#   bash "${CORTEX_DEFAULT_START_AGENT_SCRIPT}" --role watch --interval 1800    # watch agent
#
#   bash "${CORTEX_DEFAULT_START_AGENT_SCRIPT}" --name host-a-2
#   CODEX_MODEL=gpt-5.4-mini CODEX_REASONING_EFFORT=medium \
#     bash "${CORTEX_DEFAULT_START_AGENT_SCRIPT}" --provider codex
#   CLAUDE_EFFORT=medium bash "${CORTEX_DEFAULT_START_AGENT_SCRIPT}" --provider claude
#   # or daemonize:
#   nohup bash "${CORTEX_DEFAULT_START_AGENT_SCRIPT}" --provider codex >> "${CORTEX_DEFAULT_LOGS_DIR}/$(hostname).log" 2>&1 &
#
# Roles:
#   node   (default) — read/compute-only agent registered under agents/$(hostname)/
#                      (or --name NAME). Runs the poll loop and accepts COMMANDs.
#   worker           — elevated task-execution agent using the same inbox/response
#                      runtime as node, but with full host permissions and a
#                      stricter destructive-action prompt contract. Requires
#                      --name (or AGENT_NAME) so worker instances are explicit.
#   watch            — elevated-permission agent living at agents/watch/.
#                      Runs an interval loop, can queue COMMANDs and send Signal.
#                      `--role watch` execs scripts/watch.sh with the remaining
#                      args; see `bash scripts/watch.sh --help` for its flags.
#
# By default a node's agent id equals $(hostname). To run more than one
# agent on the same server, pass --name (or set AGENT_NAME in the environment)
# so each instance gets its own agents/{id}/ directory, inbox, archive, and
# log file. Worker launches require an explicit name. Names must be unique
# across the whole fleet and match [A-Za-z0-9._-]+ .
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# ── PATH: ensure agent CLIs are findable regardless of how the script was launched
_cortex_nvm_bin=""
if [[ -d "$HOME/.nvm/versions/node" ]]; then
    _cortex_nvm_best_major=-1
    _cortex_nvm_best_minor=-1
    _cortex_nvm_best_patch=-1
    for _cortex_nvm_candidate in "$HOME"/.nvm/versions/node/v*/bin; do
        [[ -d "${_cortex_nvm_candidate}" ]] || continue
        _cortex_nvm_version="${_cortex_nvm_candidate%/bin}"
        _cortex_nvm_version="${_cortex_nvm_version##*/v}"
        _cortex_nvm_major="${_cortex_nvm_version%%.*}"
        _cortex_nvm_rest="${_cortex_nvm_version#*.}"
        _cortex_nvm_minor="${_cortex_nvm_rest%%.*}"
        _cortex_nvm_patch="${_cortex_nvm_rest##*.}"
        [[ "${_cortex_nvm_major}" =~ ^[0-9]+$ ]] || continue
        [[ "${_cortex_nvm_minor}" =~ ^[0-9]+$ ]] || continue
        [[ "${_cortex_nvm_patch}" =~ ^[0-9]+$ ]] || continue
        if (( _cortex_nvm_major > _cortex_nvm_best_major )) \
            || (( _cortex_nvm_major == _cortex_nvm_best_major && _cortex_nvm_minor > _cortex_nvm_best_minor )) \
            || (( _cortex_nvm_major == _cortex_nvm_best_major && _cortex_nvm_minor == _cortex_nvm_best_minor && _cortex_nvm_patch > _cortex_nvm_best_patch )); then
            _cortex_nvm_best_major="${_cortex_nvm_major}"
            _cortex_nvm_best_minor="${_cortex_nvm_minor}"
            _cortex_nvm_best_patch="${_cortex_nvm_patch}"
            _cortex_nvm_bin="${_cortex_nvm_candidate}"
        fi
    done
    if [[ -n "${_cortex_nvm_bin}" ]]; then
        PATH=":${PATH}:"
        PATH="${PATH//:${_cortex_nvm_bin}:/:}"
        PATH="${PATH#:}"
        PATH="${PATH%:}"
        export PATH="${_cortex_nvm_bin}${PATH:+:${PATH}}"
    fi
fi
for _p in \
    "$HOME/.local/bin" \
    "$HOME/.npm/bin" \
    "$HOME/.npm-global/bin" \
    "$HOME/anaconda3/bin" \
    "$HOME/anaconda3/condabin" \
    "/usr/local/bin"; do
    [[ ":$PATH:" != *":${_p}:"* ]] && export PATH="${PATH}:${_p}"
done
# honour nvm if present
[[ -s "$HOME/.nvm/nvm.sh" ]] && source "$HOME/.nvm/nvm.sh" --no-use
unset _p _cortex_nvm_bin _cortex_nvm_best_major _cortex_nvm_best_minor _cortex_nvm_best_patch
unset _cortex_nvm_candidate _cortex_nvm_version _cortex_nvm_major _cortex_nvm_rest _cortex_nvm_minor _cortex_nvm_patch

usage() {
    cat <<'EOF'
Usage:
  bash "${CORTEX_DEFAULT_START_AGENT_SCRIPT}" [--role node|worker|watch] [--name NAME] [--provider claude|codex] [--once]
  bash "${CORTEX_DEFAULT_START_AGENT_SCRIPT}" --role watch [watch.sh flags...]

Options:
  --role VALUE       Agent role. Default: node. Legacy compatibility alias is
                     retained for older launches. Use `worker` for an elevated
                     task executor, or `watch` to start the elevated watch
                     agent (execs scripts/watch.sh with any remaining args).
  --name NAME        Agent id (also env: AGENT_NAME). Default: $(hostname).
                     Required for worker-role launches and when running more
                     than one node on the same server. Must match
                     [A-Za-z0-9._-]+.
  --provider VALUE   Agent CLI to run for inbox commands and broadcasts.
                     Default: claude
  --once             Exit after successfully processing one personal inbox
                     COMMAND. Useful for one-shot worker launches.
Env:
  CLAUDE_EFFORT      Claude effort level for node/worker CLI calls.
                     Default: low
  CLAUDE_MODEL       Claude model override. Default: provider default.
  CODEX_MODEL        Model passed to `codex exec` for codex nodes.
                     Default: gpt-5.4-mini; worker-specific overrides
                     come from the role-owned metadata / shell files
                     under `roles/`.
  CODEX_REASONING_EFFORT
                     Codex `model_reasoning_effort` override for supported models.
                     Default: medium
  FALLBACK_PROVIDER  Optional fallback CLI (`claude` or `codex`) when the
                     primary provider is cooling down or fails.
  PROVIDER_FAILURE_COOLDOWN_SECONDS
                     Cooldown applied after quota/auth failures before retrying
                     the same provider. Default:
                     CORTEX_DEFAULT_PROVIDER_FAILURE_COOLDOWN_SECONDS
  AGENT_REGISTER_NOTIFY
                     Set to 1/yes/true/always to send a startup STATUS message
                     to the conductor. Default: local log only.
  WORKER_REVIEW_INTERVAL
                     Periodic persistent-worker check cadence in seconds.
                     Default: 0 (disabled); persistent worker cadence
                     defaults come from the role-owned metadata / shell
                     files under `roles/`.
  WORKER_REVIEW_TIMEOUT
                     Timeout for periodic worker checks. Default: 600
                     Worker-specific overrides come from the role-owned
                     metadata / shell files under `roles/`.
  CORTEX_WORKER_BWRAP_RW
                     Colon-separated extra paths writable inside worker bwrap.
                     Default: unset (only agents/{id}/ is writable;
                     worker-owned role logic may append additional paths).
  CORTEX_WORKER_SANDBOX_BACKEND
                     Worker sandbox backend selection. Default: auto, which
                     prefers `bwrap` and falls back to `macos-direct` on
                     Darwin when `bwrap` is unavailable.
  CORTEX_RESEARCH_PROJECT
                     For research-cycle workers, name of the project
                     under `projects/` the cluster is working on (for
                     example `example_project`). When set and the
                     directory exists, `projects/<name>/` is appended to
                     CORTEX_WORKER_BWRAP_RW so the worker can read/write
                     the active project tree. If
                     `projects/<name>/research_runtime.env` exists, its
                     simple KEY=value entries are exported before worker
                     commands run; project-owned entries may also declare
                     CORTEX_RESEARCH_PROJECT_RO_PATHS for extra read-only
                     sandbox binds. Default: unset.
  BACKUP_ROOT         Snapshot root used by the role-owned snapshot
                     helper under `roles/operational/`.
                     Default: CORTEX_DEFAULT_BACKUP_ROOT
  BACKUP_KEEP         Snapshot retention count used by the role-owned
                     snapshot helper under `roles/operational/`.
                     Default: 7
  BACKUP_TARGETS_FILE
                     Manifest file used by the role-owned snapshot
                     helper under `roles/operational/`.
                     Default: CORTEX_DEFAULT_BACKUP_TARGETS_FILE
                     (normally environments/<env>/backup_targets.txt)
  -h, --help         Show this help text.
EOF
}

# ── Config ────────────────────────────────────────────────────────────────────
CORTEX_DIR="${CORTEX_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd -P)}"
source "${CORTEX_DIR}/config/cortex_defaults.sh"
source "${CORTEX_DIR}/scripts/bash_compat.sh"
source "${CORTEX_DIR}/scripts/session_backend.sh"
source "${CORTEX_DIR}/scripts/user_context.sh"
source "${CORTEX_DIR}/scripts/usage_lib.sh"
source "${CORTEX_DIR}/roles/common.sh"
source "${CORTEX_DIR}/roles/sandbox.sh"
source "${CORTEX_DIR}/roles/node.sh"
source "${CORTEX_DIR}/roles/watch.sh"
source "${CORTEX_DIR}/roles/worker.sh"

# Apply the named model tier (weak|medium|strong) to this agent's provider
# defaults. Explicit launch-time model/effort overrides win; role tiers win
# over the final weak fallback. Tier tuples live in config/cortex_defaults.sh.
apply_model_tier() {
    local tier="${1:-}"
    local up
    up="$(printf '%s' "${tier}" | tr '[:lower:]' '[:upper:]')"
    local codex_model_var="CORTEX_DEFAULT_TIER_${up}_CODEX_MODEL"
    local claude_model_var="CORTEX_DEFAULT_TIER_${up}_CLAUDE_MODEL"
    local codex_reasoning_var="CORTEX_DEFAULT_TIER_${up}_CODEX_REASONING"
    local claude_effort_var="CORTEX_DEFAULT_TIER_${up}_CLAUDE_EFFORT"
    if [[ -z "${!codex_model_var:-}" ]]; then
        echo "apply_model_tier: unknown tier '${tier}' (expected weak|medium|strong)" >&2
        exit 2
    fi
    [[ -n "${FALLBACK_PROVIDER}" ]] || FALLBACK_PROVIDER="claude"
    [[ -n "${CODEX_MODEL}" ]] || CODEX_MODEL="${!codex_model_var}"
    [[ -n "${CLAUDE_MODEL}" ]] || CLAUDE_MODEL="${!claude_model_var}"
    [[ "${CODEX_REASONING_EFFORT_EXPLICIT}" -eq 0 ]] && CODEX_REASONING_EFFORT="${!codex_reasoning_var}"
    [[ "${CLAUDE_EFFORT_EXPLICIT}" -eq 0 ]] && CLAUDE_EFFORT="${!claude_effort_var}"
    MODEL_TIER_APPLIED=1
}
DEFAULT_COMMAND_TIMEOUT_SECONDS=1800
DEFAULT_SELFCHECK_TIMEOUT_SECONDS=180
DEFAULT_WORKER_REVIEW_INTERVAL_DISABLED=0
DEFAULT_WORKER_REVIEW_INTERVAL_SHORT=900
DEFAULT_WORKER_REVIEW_INTERVAL_HOURLY=3600
DEFAULT_WORKER_REVIEW_INTERVAL_6H=21600
DEFAULT_WORKER_REVIEW_INTERVAL_12H=43200
DEFAULT_WORKER_REVIEW_INTERVAL_DAILY=86400
DEFAULT_WORKER_REVIEW_TIMEOUT_SECONDS=600
DEFAULT_WORKER_REVIEW_TIMEOUT_SHORT_SECONDS=900
DEFAULT_WORKER_REVIEW_TIMEOUT_LONG_SECONDS=1200
DEFAULT_WORKER_REVIEW_TIMEOUT_RESEARCH_SECONDS=1800
DEFAULT_BACKUP_KEEP=7
DEFAULT_PROVIDER_FAILURE_COOLDOWN_SECONDS="${CORTEX_DEFAULT_PROVIDER_FAILURE_COOLDOWN_SECONDS}"

# ── Role dispatch ─────────────────────────────────────────────────────────────
# `--role watch` delegates to scripts/watch.sh. `--role` must be the first flag
# when used. Without `--role` (or `--role node`) we fall through to the shared
# node/worker bootstrap below. Compatibility alias retained for older launches.
AGENT_ROLE="node"
if [[ "${1:-}" == "--role" ]]; then
    [[ $# -ge 2 ]] || { echo "Missing value for --role" >&2; exit 2; }
    AGENT_ROLE="$2"
    shift 2
fi
case "${AGENT_ROLE}" in
    node|worker|slave)
        ;;  # continue below (compatibility alias retained for older launches)
    watch)
        watch_exec_role "$@"
        ;;
    *)
        echo "Unsupported role: ${AGENT_ROLE} (expected node, worker, or watch)" >&2
        exit 2
        ;;
esac
[[ "${AGENT_ROLE}" == "slave" ]] && AGENT_ROLE="node"

AGENT_ID="${AGENT_NAME:-$(hostname)}"
AGENT_NAME_EXPLICIT=0
[[ -n "${AGENT_NAME:-}" ]] && AGENT_NAME_EXPLICIT=1
BROADCAST_DIR="${CORTEX_DIR}/broadcast"
CONDUCTOR_INBOX="${CORTEX_DIR}/agents/conductor/inbox"
COMMON_INSTRUCT="${CORTEX_DIR}/roles/all.instruct"
USER_INSTRUCT=""
SELFCHECK_TEMPLATE="${CORTEX_DIR}/roles/self_check.instruct"
INSTRUCT_TEAM_TEMPLATE=""
INSTRUCT_OVERRIDE_TEMPLATE=""
POLL_INTERVAL=10
# Watchdog timeouts (seconds) for the provider CLI. A hung `claude`/`codex`
# would otherwise silently park the agent with a full inbox while the
# background heartbeat ticker keeps the conductor seeing "alive". Override via
# env if a specific fleet legitimately needs longer runs.
COMMAND_TIMEOUT="${COMMAND_TIMEOUT:-${DEFAULT_COMMAND_TIMEOUT_SECONDS}}"     # per COMMAND/BROADCAST
SELFCHECK_TIMEOUT="${SELFCHECK_TIMEOUT:-${DEFAULT_SELFCHECK_TIMEOUT_SECONDS}}"  # per self-check
AGENT_PROVIDER="claude"
AGENT_PROVIDER_EXPLICIT=0
AGENT_CLI="claude"
CLAUDE_EFFORT_EXPLICIT=0
[[ -n "${CLAUDE_EFFORT+x}" ]] && CLAUDE_EFFORT_EXPLICIT=1
CLAUDE_EFFORT="${CLAUDE_EFFORT:-low}"
CLAUDE_MODEL="${CLAUDE_MODEL-}"
CODEX_MODEL="${CODEX_MODEL-}"
CODEX_REASONING_EFFORT_EXPLICIT=0
[[ -n "${CODEX_REASONING_EFFORT+x}" ]] && CODEX_REASONING_EFFORT_EXPLICIT=1
CODEX_REASONING_EFFORT="${CODEX_REASONING_EFFORT:-medium}"
MODEL_TIER_APPLIED=0
FALLBACK_PROVIDER="${FALLBACK_PROVIDER-}"
PROVIDER_FAILURE_COOLDOWN_SECONDS="${PROVIDER_FAILURE_COOLDOWN_SECONDS:-${DEFAULT_PROVIDER_FAILURE_COOLDOWN_SECONDS}}"
AGENT_REGISTER_NOTIFY="${AGENT_REGISTER_NOTIFY:-0}"
WORKER_REVIEW_INTERVAL="${WORKER_REVIEW_INTERVAL-}"
WORKER_REVIEW_TIMEOUT="${WORKER_REVIEW_TIMEOUT:-600}"
BACKUP_ROOT="${BACKUP_ROOT:-${CORTEX_DEFAULT_BACKUP_ROOT}}"
BACKUP_KEEP="${BACKUP_KEEP:-${DEFAULT_BACKUP_KEEP}}"
BACKUP_TARGETS_FILE="${BACKUP_TARGETS_FILE:-${CORTEX_DEFAULT_BACKUP_TARGETS_FILE}}"
CORTEX_WORKER_SANDBOX_BACKEND="${CORTEX_WORKER_SANDBOX_BACKEND:-auto}"
RUN_ONCE=0

if cortex_user_load "${CORTEX_DIR}"; then
    USER_INSTRUCT="${CORTEX_USER_INSTRUCT}"
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)
            [[ $# -ge 2 ]] || { echo "Missing value for --name" >&2; usage >&2; exit 2; }
            AGENT_ID="$2"
            AGENT_NAME_EXPLICIT=1
            shift 2
            ;;
        --provider)
            [[ $# -ge 2 ]] || { echo "Missing value for --provider" >&2; usage >&2; exit 2; }
            AGENT_PROVIDER="$2"
            AGENT_PROVIDER_EXPLICIT=1
            shift 2
            ;;
        --once)
            RUN_ONCE=1
            shift
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
role_apply_defaults

case "${AGENT_PROVIDER}" in
    claude|codex)
        AGENT_CLI="${AGENT_PROVIDER}"
        ;;
    *)
        echo "Unsupported provider: ${AGENT_PROVIDER} (expected claude or codex)" >&2
        exit 2
        ;;
esac

case "${FALLBACK_PROVIDER:-}" in
    ""|claude|codex)
        ;;
    *)
        echo "Unsupported fallback provider: ${FALLBACK_PROVIDER} (expected claude, codex, or empty)" >&2
        exit 2
        ;;
esac

role_select_instruction_templates
role_set_run_mode
role_validate_launch

AGENT_DIR="${CORTEX_DIR}/agents/${AGENT_ID}"
AGENT_STATE_DIR="${AGENT_DIR}"
resolved_state_dir="$(role_resolve_state_dir || true)"
if [[ -n "${resolved_state_dir}" ]]; then
    AGENT_STATE_DIR="${resolved_state_dir}"
fi
INBOX="${AGENT_DIR}/inbox"
ARCHIVE="${AGENT_DIR}/archive"
LOG_FILE="${AGENT_STATE_DIR}/log.md"
WORKER_LOGBOOK="${AGENT_STATE_DIR}/logbook.md"
WORKER_REVIEW_LAST_FILE="${AGENT_DIR}/worker_review_last_ts"
WORKER_REVIEW_NOTIFY_STATE="${AGENT_DIR}/worker_review_notify_state"
WORKER_NEXT_WAKE_AT_FILE="${AGENT_DIR}/worker_next_wake_at"
WORKER_NEXT_WAKE_REASON_FILE="${AGENT_DIR}/worker_next_wake_reason"
PROVIDER_FAILURE_STATE="${AGENT_DIR}/provider_failure_state"
SELFCHECK_LAST_FILE="${AGENT_DIR}/selfcheck_last_ts"
STATUSREPORT_LAST_FILE="${AGENT_DIR}/statusreport_last_ts"
STATUSREPORT_SNAPSHOT="${AGENT_DIR}/status_latest.snapshot"
PROMPT_CONTEXT_SNAPSHOT="${AGENT_DIR}/prompt_context_latest.snapshot"
SELFCHECK_SNAPSHOT="${AGENT_DIR}/selfcheck_latest.snapshot"
SELFCHECK_PREVIOUS="${AGENT_DIR}/selfcheck_previous.snapshot"
CURRENT_COMMAND_FROM=""
CURRENT_COMMAND_BODY_RAW=""
STUDENT_RW_ALLOW_SENSITIVE="0"
declare -a STUDENT_ROUND_RW_PATHS=()
COMMIT_RW_ALLOW_HOOKS="0"
declare -a COMMIT_COMMAND_RW_PATHS=()
declare -a ACTIVE_CODEX_STAGE_HOMES=()
RUNTIME_CLEANED_UP=0
WORKER_SANDBOX_BACKEND="n/a"
PRIMARY_PROVIDER_PREFLIGHT="n/a"
FALLBACK_PROVIDER_PREFLIGHT="n/a"

# Refuse to start if another instance is already running under the same id —
# a heartbeat older than the shared alive threshold is treated as dead and we take over.
if [[ -f "${AGENT_DIR}/heartbeat" ]]; then
    _hb="$(cat "${AGENT_DIR}/heartbeat" 2>/dev/null || echo 0)"
    _age=$(( $(date -u +%s) - _hb ))
    if (( _age <= CORTEX_DEFAULT_HEARTBEAT_ALIVE_SECONDS )); then
        echo "Agent '${AGENT_ID}' appears to already be running (heartbeat ${_age}s old)." >&2
        echo "If this is wrong, wait >${CORTEX_DEFAULT_HEARTBEAT_ALIVE_SECONDS}s for the heartbeat to stale out, or pick a different --name." >&2
        exit 2
    fi
    unset _hb _age
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
log() {
    local ts; ts="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "[${ts}] ${AGENT_ID}: $*" | tee -a "${LOG_FILE}"
}

rand4() { head -c 2 /dev/urandom | xxd -p; }

new_msg_id() { echo "$(date -u +%s)_$(rand4)"; }

# Atomic write: build in .tmp then rename
write_msg() {
    local dest="$1"; shift
    local tmp="${dest}.tmp"
    cat > "${tmp}"
    mv "${tmp}" "${dest}"
}

write_text_file_atomic() {
    local dest="$1" text="$2"
    local tmp="${dest}.tmp"
    printf '%s\n' "${text}" > "${tmp}" || {
        rm -f "${tmp}"
        return 1
    }
    mv "${tmp}" "${dest}" || {
        rm -f "${tmp}"
        return 1
    }
}

write_epoch_file_atomic() {
    local dest="$1" epoch="$2"
    write_text_file_atomic "${dest}" "${epoch}"
}

current_billing_model() {
    if [[ "${AGENT_PROVIDER}" == "codex" ]]; then
        printf '%s\n' "${CODEX_MODEL}"
    else
        printf '%s\n' "${CLAUDE_MODEL:-provider-default}"
    fi
}

current_input_price_per_1m() {
    local model prices input_price output_price
    model="$(current_billing_model)"
    prices="$(cortex_usage_price_pair "${AGENT_PROVIDER}" "${model}" 2>/dev/null || true)"
    [[ -n "${prices}" ]] || return 1
    read -r input_price output_price <<< "${prices}"
    [[ -n "${input_price}" ]] || return 1
    printf '%s\n' "${input_price}"
}

record_prompt_context_snapshot() {
    local prompt_kind="$1" prompt_text="$2"
    local snapshot_file="${PROMPT_CONTEXT_SNAPSHOT}"
    local tmp_file="${snapshot_file}.tmp"
    local ts_local ts_utc billing_model input_price
    ts_local="$(date '+%Y-%m-%dT%H:%M:%S%:z')"
    ts_utc="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    billing_model="$(current_billing_model)"
    input_price="$(current_input_price_per_1m 2>/dev/null || true)"
    if ! command -v python3 >/dev/null 2>&1; then
        return 0
    fi
    if ! printf '%s' "${prompt_text}" | PROMPT_KIND="${prompt_kind}" PROMPT_TS_LOCAL="${ts_local}" PROMPT_TS_UTC="${ts_utc}" BILLING_PROVIDER="${AGENT_PROVIDER}" BILLING_MODEL="${billing_model}" INPUT_USD_PER_1M="${input_price}" python3 /dev/fd/3 3<<'PY' > "${tmp_file}"; then
import os, sys
text = sys.stdin.read()
bytes_n = len(text.encode("utf-8"))
chars_n = len(text)
lines_n = text.count("\n") + (1 if text and not text.endswith("\n") else 0)
approx_tokens = (bytes_n + 3) // 4
input_price_raw = os.environ.get("INPUT_USD_PER_1M", "").strip()
print(f"KIND: {os.environ.get('PROMPT_KIND', 'unknown')}")
print(f"UPDATED_LOCAL: {os.environ.get('PROMPT_TS_LOCAL', '')}")
print(f"UPDATED_UTC: {os.environ.get('PROMPT_TS_UTC', '')}")
print(f"BYTES: {bytes_n}")
print(f"CHARS: {chars_n}")
print(f"LINES: {lines_n}")
print(f"APPROX_TOKENS: {approx_tokens}")
print("TOKEN_ESTIMATE_BASIS: utf8_bytes_div_4")
print(f"BILLING_PROVIDER: {os.environ.get('BILLING_PROVIDER', 'unknown')}")
print(f"BILLING_MODEL: {os.environ.get('BILLING_MODEL', 'unknown')}")
if input_price_raw:
    input_price = float(input_price_raw)
    print(f"INPUT_USD_PER_1M: {input_price_raw}")
    print(f"INPUT_ONLY_USD_EST: {(approx_tokens * input_price) / 1_000_000:.6f}")
    print("INPUT_COST_ESTIMATE_BASIS: approx_tokens_times_input_price_output_excluded_cache_excluded")
else:
    print("INPUT_USD_PER_1M: unknown")
    print("INPUT_ONLY_USD_EST: unknown")
    print("INPUT_COST_ESTIMATE_BASIS: price_unavailable_for_model")
PY
        rm -f "${tmp_file}"
        return 1
    fi
    mv "${tmp_file}" "${snapshot_file}"
}

render_context_bundle_report() {
    if ! command -v python3 >/dev/null 2>&1; then
        return 0
    fi
    local billing_model input_price
    billing_model="$(current_billing_model)"
    input_price="$(current_input_price_per_1m 2>/dev/null || true)"
    local -a specs=()
    specs+=("common::${COMMON_INSTRUCT}")
    specs+=("role::${INSTRUCT_TEMPLATE}")
    if [[ -n "${INSTRUCT_TEAM_TEMPLATE}" && -f "${INSTRUCT_TEAM_TEMPLATE}" ]]; then
        specs+=("team::${INSTRUCT_TEAM_TEMPLATE}")
    fi
    if [[ -n "${INSTRUCT_OVERRIDE_TEMPLATE}" && -f "${INSTRUCT_OVERRIDE_TEMPLATE}" ]]; then
        specs+=("override::${INSTRUCT_OVERRIDE_TEMPLATE}")
    fi
    if [[ -f "${USER_INSTRUCT}" ]]; then
        specs+=("user::${USER_INSTRUCT}")
    fi
    BILLING_PROVIDER="${AGENT_PROVIDER}" BILLING_MODEL="${billing_model}" INPUT_USD_PER_1M="${input_price}" python3 - "${specs[@]}" <<'PY'
import pathlib, sys
import os

def metrics(text: str):
    bytes_n = len(text.encode("utf-8"))
    chars_n = len(text)
    lines_n = text.count("\n") + (1 if text and not text.endswith("\n") else 0)
    approx_tokens = (bytes_n + 3) // 4
    return bytes_n, chars_n, lines_n, approx_tokens

components = []
totals = [0, 0, 0, 0]
for spec in sys.argv[1:]:
    try:
        label, path = spec.split("::", 1)
    except ValueError:
        continue
    path_obj = pathlib.Path(path)
    try:
        text = path_obj.read_text(errors="replace")
    except OSError:
        continue
    m = metrics(text)
    components.append((label, path, m))
    for i, value in enumerate(m):
        totals[i] += value

input_price_raw = os.environ.get("INPUT_USD_PER_1M", "").strip()
print(
    f"  - total: files={len(components)} bytes={totals[0]} chars={totals[1]} "
    f"lines={totals[2]} approx_tokens={totals[3]}"
)
print(
    f"  - billing: provider={os.environ.get('BILLING_PROVIDER', 'unknown')} "
    f"model={os.environ.get('BILLING_MODEL', 'unknown')}"
)
if input_price_raw:
    input_price = float(input_price_raw)
    print(f"  - input_usd_per_1m: {input_price_raw}")
    print(f"  - input_only_usd_est: {(totals[3] * input_price) / 1_000_000:.6f}")
    print("  - input_cost_estimate_basis: approx_tokens_times_input_price_output_excluded_cache_excluded")
else:
    print("  - input_usd_per_1m: unknown")
    print("  - input_only_usd_est: unknown")
    print("  - input_cost_estimate_basis: price_unavailable_for_model")
for label, path, (bytes_n, chars_n, lines_n, approx_tokens) in components:
    print(
        f"  - {label}: {path} bytes={bytes_n} chars={chars_n} "
        f"lines={lines_n} approx_tokens={approx_tokens}"
    )
print("  - token_estimate_basis: utf8_bytes_div_4")
PY
}

# Extract header value from a message file
get_header() {
    local key="$1" file="$2"
    awk -v key="${key}" '
        $0 == "---" { exit }
        match($0, "^" key ":[[:space:]]*") {
            print substr($0, RSTART + RLENGTH)
            exit
        }
    ' "${file}" | xargs
}

# Extract body (everything after first --- line)
get_body() {
    awk '/^---$/{found=1; next} found{print}' "$1"
}

extract_result_field() {
    local key="$1" text="$2"
    printf '%s\n' "${text}" | awk -v key="${key}" '
        match($0, "^" key ":[[:space:]]*") {
            print substr($0, RSTART + RLENGTH)
            exit
        }
    '
}

result_has_structured_fields() {
    local text="$1"
    [[ -n "$(extract_result_field "CHECK" "${text}")" ]] && return 0
    [[ -n "$(extract_result_field "STATUS" "${text}")" ]] && return 0
    [[ -n "$(extract_result_field "SELFCHECK" "${text}")" ]] && return 0
    [[ -n "$(extract_result_field "ROUND_STATUS" "${text}")" ]] && return 0
    return 1
}

result_starts_with_structured_preamble() {
    local text="$1"
    printf '%s\n' "${text}" | awk '
        /^[[:space:]]*$/ { next }
        /^(CHECK|STATUS|SELFCHECK|ROUND_STATUS|TYPE):[[:space:]]*/ { exit 0 }
        { exit 1 }
    '
}

strip_command_wrapper_fields() {
    local text="$1"
    printf '%s\n' "${text}" | awk '
        /^CONDUCTOR_NOTIFY:[[:space:]]*/ { next }
        /^STUDENT_RW_ALLOW_SENSITIVE:[[:space:]]*/ { next }
        /^COMMIT_RW_ALLOW_HOOKS:[[:space:]]*/ { next }
        { print }
    '
}

extract_command_block() {
    local key="$1" text="$2"
    printf '%s\n' "${text}" | awk -v key="${key}" '
        BEGIN { in_block=0 }
        match($0, "^" key ":[[:space:]]*") {
            remainder = substr($0, RSTART + RLENGTH)
            if (length(remainder) > 0) {
                print remainder
            }
            in_block=1
            next
        }
        in_block && /^[A-Z][A-Z0-9_ ]*:[[:space:]]*$/ { exit }
        in_block { print }
    '
}

paths_overlap() {
    local a="$1" b="$2"
    [[ "${a}" == "${b}" || "${a}" == "${b}/"* || "${b}" == "${a}/"* ]]
}

append_unique_path() {
    local candidate="$1"
    local out_ref="$2"
    local existing
    local -a current_paths=()

    named_array_copy "${out_ref}" current_paths
    for existing in "${current_paths[@]}"; do
        [[ "${existing}" == "${candidate}" ]] && return 0
    done
    named_array_append "${out_ref}" "${candidate}"
}

append_rw_paths_from_spec() {
    local path_spec="$1"
    local out_ref="$2"
    local extra_path extra_real existing seen

    [[ -n "${path_spec}" ]] || return 0
    local IFS=:
    for extra_path in ${path_spec}; do
        [[ -n "${extra_path}" ]] || continue
        extra_real="$(realpath_m_compat "${extra_path}")"
        if [[ ! -e "${extra_real}" ]]; then
            printf '[cortex] worker bwrap RW path does not exist: %s\n' "${extra_path}" >&2
            return 1
        fi
        seen=0
        local -a current_paths=()
        named_array_copy "${out_ref}" current_paths
        for existing in "${current_paths[@]}"; do
            if [[ "${existing}" == "${extra_real}" ]]; then
                seen=1
                break
            fi
        done
        (( seen == 0 )) && named_array_append "${out_ref}" "${extra_real}"
    done
}

register_codex_stage_home() {
    local stage_home="$1"
    [[ -n "${stage_home}" ]] || return 0
    ACTIVE_CODEX_STAGE_HOMES+=("${stage_home}")
}

forget_codex_stage_home() {
    local target="$1"
    local stage_home
    local -a remaining=()

    for stage_home in "${ACTIVE_CODEX_STAGE_HOMES[@]+"${ACTIVE_CODEX_STAGE_HOMES[@]}"}"; do
        [[ "${stage_home}" == "${target}" ]] || remaining+=("${stage_home}")
    done
    ACTIVE_CODEX_STAGE_HOMES=("${remaining[@]}")
}

cleanup_codex_stage_home() {
    local stage_home="$1"
    [[ -n "${stage_home}" ]] || return 0
    rm -rf "${stage_home}"
    forget_codex_stage_home "${stage_home}"
}

mark_agent_offline() {
    [[ -n "${AGENT_DIR:-}" ]] || return 0
    [[ -d "${AGENT_DIR}" ]] || return 0
    write_text_file_atomic "${AGENT_DIR}/status" "offline" || true
    rm -f "${AGENT_DIR}/heartbeat" "${AGENT_DIR}/working"
}

cleanup_runtime() {
    local stage_home
    (( RUNTIME_CLEANED_UP == 0 )) || return 0
    RUNTIME_CLEANED_UP=1
    mark_agent_offline
    for stage_home in "${ACTIVE_CODEX_STAGE_HOMES[@]+"${ACTIVE_CODEX_STAGE_HOMES[@]}"}"; do
        [[ -n "${stage_home}" ]] || continue
        rm -rf "${stage_home}"
    done
    ACTIVE_CODEX_STAGE_HOMES=()
}

research_runtime_env_file() {
    if [[ -n "${CORTEX_RESEARCH_PROJECT:-}" ]]; then
        local env_file="${CORTEX_DIR}/projects/${CORTEX_RESEARCH_PROJECT}/research_runtime.env"
        if [[ -f "${env_file}" ]]; then
            printf '%s\n' "${env_file}"
            return 0
        fi
    fi
    printf '%s\n' "none"
}

write_agent_info_file() {
    write_msg "${AGENT_DIR}/info" << EOF
AGENT_ID:     ${AGENT_ID}
ROLE:         ${AGENT_ROLE}
RUN_MODE:     ${AGENT_RUN_MODE}
IP:           $(hostname -I 2>/dev/null | awk '{print $1}' || echo unknown)
USER:         $(whoami)
REGISTERED:   $(date -u '+%Y-%m-%d %H:%M:%S UTC')
EPOCH:        $(date -u +%s)
PROVIDER:     ${AGENT_PROVIDER}
STATE_DIR:    ${AGENT_STATE_DIR}
LOG_FILE:     ${LOG_FILE}
FALLBACK_PROVIDER: $([[ -n "${FALLBACK_PROVIDER}" ]] && printf '%s' "${FALLBACK_PROVIDER}" || printf 'none')
SANDBOX_BACKEND: $([[ "${AGENT_ROLE}" == "worker" ]] && printf '%s' "${WORKER_SANDBOX_BACKEND}" || printf 'n/a')
PROVIDER_PREFLIGHT: ${PRIMARY_PROVIDER_PREFLIGHT}
FALLBACK_PREFLIGHT: ${FALLBACK_PROVIDER_PREFLIGHT}
WORKER_LOGBOOK: $([[ "${AGENT_ROLE}" == "worker" && "${AGENT_RUN_MODE}" == "persistent" ]] && printf '%s' "${WORKER_LOGBOOK}" || printf 'n/a')
WORKER_CHECK_INTERVAL: $([[ "${AGENT_ROLE}" == "worker" ]] && printf '%s' "${WORKER_REVIEW_INTERVAL}" || printf 'n/a')
RESEARCH_PROJECT: $([[ -n "${CORTEX_RESEARCH_PROJECT:-}" ]] && printf '%s' "${CORTEX_RESEARCH_PROJECT}" || printf 'none')
RESEARCH_RUNTIME_ENV: $(research_runtime_env_file)
RESEARCH_PROJECT_RW_PATHS: $([[ -n "${CORTEX_RESEARCH_PROJECT_RW_PATHS:-}" ]] && printf '%s' "${CORTEX_RESEARCH_PROJECT_RW_PATHS}" || printf 'none')
RESEARCH_PROJECT_RO_PATHS: $([[ -n "${CORTEX_RESEARCH_PROJECT_RO_PATHS:-}" ]] && printf '%s' "${CORTEX_RESEARCH_PROJECT_RO_PATHS}" || printf 'none')
INSTRUCT_OVERRIDE: $([[ -n "${INSTRUCT_OVERRIDE_TEMPLATE}" && -f "${INSTRUCT_OVERRIDE_TEMPLATE}" ]] && printf '%s' "${INSTRUCT_OVERRIDE_TEMPLATE}" || printf 'none')
CLAUDE_EFFORT: $([[ "${AGENT_PROVIDER}" == "claude" ]] && printf '%s' "${CLAUDE_EFFORT}" || printf 'n/a')
CLAUDE_MODEL: $([[ -n "${CLAUDE_MODEL}" ]] && printf '%s' "${CLAUDE_MODEL}" || printf 'provider-default')
CODEX_MODEL:  $([[ "${AGENT_PROVIDER}" == "codex" ]] && printf '%s' "${CODEX_MODEL}" || printf 'n/a')
CODEX_REASONING_EFFORT: $([[ "${AGENT_PROVIDER}" == "codex" ]] && printf '%s' "${CODEX_REASONING_EFFORT}" || printf 'n/a')
CLI_VERSION:  $("${AGENT_CLI}" --version 2>/dev/null | head -1 || echo unknown)
EOF
}

should_forward_command_response() {
    local notify_policy="$1" wrapper_status="$2" result="$3"
    local inner_status=""
    inner_status="$(extract_result_field "STATUS" "${result}")"

    case "${notify_policy}" in
        ""|always)
            return 0
            ;;
        quiet)
            [[ "${wrapper_status}" != "done" ]] && return 0
            [[ "${inner_status}" == "warning" || "${inner_status}" == "error" ]] && return 0
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

send_to_conductor() {
    local type="$1" ref="$2" status="$3" body="$4"
    local safe_body="${body}"
    local msg_id; msg_id="$(new_msg_id)"
    local dest="${CONDUCTOR_INBOX}/$(date -u +%s)_${AGENT_ID}_${msg_id}.msg"
    if ! result_starts_with_structured_preamble "${body}"; then
        safe_body="$(neutralize_envelope_header_lines "${body}")"
    fi
    write_msg "${dest}" << EOF
MSG_ID: ${msg_id}
FROM:   ${AGENT_ID}
TO:     conductor
TYPE:   ${type}
TIME:   $(date -u +%s)
REF:    ${ref}
STATUS: ${status}
---
${safe_body}
EOF
    log "→ conductor [${type}/${status}] ref=${ref}"
}

auto_forward_research_specialist_report() {
    local wrapper_status="$1" result="$2"
    local report_from cycle_id role_result lead_id msg_id epoch dest

    [[ "${wrapper_status}" == "done" ]] || return 0
    [[ "${CURRENT_COMMAND_FROM:-}" == "research-lead" ]] || return 0
    worker_id_has_team_role "${AGENT_ID}" research specialist || return 0

    report_from="$(extract_result_field "RESEARCH_FROM" "${result}")"
    cycle_id="$(extract_result_field "CYCLE_ID" "${result}")"
    role_result="$(extract_result_field "ROLE_RESULT" "${result}")"
    [[ -n "${report_from}" && -n "${cycle_id}" && -n "${role_result}" ]] || return 0

    if [[ "${report_from}" != "${AGENT_ID}" ]]; then
        log "research auto-forward skipped: RESEARCH_FROM=${report_from:-missing} does not match AGENT_ID=${AGENT_ID}"
        return 0
    fi

    lead_id="$(worker_research_lead_id 2>/dev/null || true)"
    [[ -n "${lead_id}" ]] || return 0
    [[ -d "${CORTEX_DIR}/agents/${lead_id}/inbox" ]] || return 0

    msg_id="$(new_msg_id)"
    epoch="${msg_id%%_*}"
    dest="${CORTEX_DIR}/agents/${lead_id}/inbox/1_${msg_id}.msg"
    write_msg "${dest}" << EOF
MSG_ID: ${msg_id}
FROM:   ${AGENT_ID}
TO:     ${lead_id}
TYPE:   COMMAND
TIME:   ${epoch}
REF:    none
STATUS: pending
---
${result}
EOF
    log "→ research-lead auto-forwarded [${role_result}] cycle=${cycle_id} envelope=agents/${lead_id}/inbox/1_${msg_id}.msg"
}

set_status() {
    write_text_file_atomic "${AGENT_DIR}/status" "$1"
}

valid_agent_status() {
    case "$1" in
        idle|busy|working|selfcheck|error|offline) return 0 ;;
        *) return 1 ;;
    esac
}

status_repair_default() {
    if [[ -e "${AGENT_DIR}/working" ]]; then
        printf '%s' "working"
    else
        printf '%s' "idle"
    fi
}

read_agent_status_raw() {
    local status_file="${AGENT_DIR}/status"
    [[ -f "${status_file}" ]] || return 1
    tr -d '\r\n' < "${status_file}" 2>/dev/null || return 1
}

read_agent_status() {
    local raw repaired
    raw="$(read_agent_status_raw || true)"
    if valid_agent_status "${raw}"; then
        printf '%s' "${raw}"
        return 0
    fi
    repaired="$(status_repair_default)"
    if write_text_file_atomic "${AGENT_DIR}/status" "${repaired}"; then
        log "status repair: ${raw:-empty} -> ${repaired}"
    fi
    printf '%s' "${repaired}"
}

read_epoch_file_or_default() {
    local file="$1" fallback="${2:-0}" raw
    [[ -f "${file}" ]] || {
        printf '%s' "${fallback}"
        return 0
    }
    raw="$(tr -dc '0-9' < "${file}" 2>/dev/null || true)"
    if [[ -n "${raw}" ]]; then
        printf '%s' "${raw}"
    else
        printf '%s' "${fallback}"
    fi
}

preflight_head_line() {
    local text="$1"
    printf '%s' "${text}" \
        | tr '\r' '\n' \
        | awk 'NF { print; exit }' \
        | sed -E 's/[[:space:]]+/ /g'
}

provider_preflight_status() {
    local provider="$1"
    local out rc auth_file
    case "${provider}" in
        codex)
            if ! command -v codex >/dev/null 2>&1; then
                printf '%s' "missing-cli"
                return 1
            fi
            auth_file="${HOME}/.codex/auth.json"
            if [[ ! -f "${auth_file}" ]]; then
                printf '%s' "auth-file-missing"
                return 1
            fi
            out="$(codex -c 'service_tier="fast"' login status 2>&1)"
            rc=$?
            if (( rc == 0 )) && printf '%s' "${out}" | grep -qi '^Logged in'; then
                printf '%s' "ready"
                return 0
            fi
            printf 'status-error: %s' "$(preflight_head_line "${out}")"
            return 1
            ;;
        claude)
            if ! command -v claude >/dev/null 2>&1; then
                printf '%s' "missing-cli"
                return 1
            fi
            out="$(claude auth status 2>&1)"
            rc=$?
            if printf '%s' "${out}" | grep -q '"loggedIn":[[:space:]]*true'; then
                printf '%s' "ready"
                return 0
            fi
            if printf '%s' "${out}" | grep -q '"loggedIn":[[:space:]]*false'; then
                printf '%s' "not-logged-in"
                return 1
            fi
            printf 'status-error: %s' "$(preflight_head_line "${out}")"
            return 1
            ;;
    esac
    printf '%s' "unsupported-provider"
    return 1
}

worker_runtime_preflight() {
    local primary_rc=1 fallback_rc=1 backend_rc=1

    [[ "${AGENT_ROLE}" == "worker" ]] || return 0

    WORKER_SANDBOX_BACKEND="$(resolve_worker_sandbox_backend "${CORTEX_WORKER_SANDBOX_BACKEND}")"
    backend_rc=$?
    if (( backend_rc != 0 )); then
        printf "[cortex] worker '%s' has no usable sandbox backend for %s (requested=%s, resolved=%s).\n" \
            "${AGENT_ID}" "$(uname -s 2>/dev/null || echo unknown)" \
            "${CORTEX_WORKER_SANDBOX_BACKEND}" "${WORKER_SANDBOX_BACKEND}" >&2
        return 1
    fi

    PRIMARY_PROVIDER_PREFLIGHT="$(provider_preflight_status "${AGENT_PROVIDER}")"
    primary_rc=$?

    if [[ -n "${FALLBACK_PROVIDER}" && "${FALLBACK_PROVIDER}" != "${AGENT_PROVIDER}" ]]; then
        FALLBACK_PROVIDER_PREFLIGHT="$(provider_preflight_status "${FALLBACK_PROVIDER}")"
        fallback_rc=$?
    else
        FALLBACK_PROVIDER_PREFLIGHT="none"
    fi

    if (( primary_rc == 0 )); then
        return 0
    fi
    if [[ "${FALLBACK_PROVIDER_PREFLIGHT}" == "ready" ]]; then
        return 0
    fi

    printf "[cortex] worker '%s' provider preflight failed: %s=%s" \
        "${AGENT_ID}" "${AGENT_PROVIDER}" "${PRIMARY_PROVIDER_PREFLIGHT}" >&2
    if [[ -n "${FALLBACK_PROVIDER}" && "${FALLBACK_PROVIDER}" != "${AGENT_PROVIDER}" ]]; then
        printf "; %s=%s" "${FALLBACK_PROVIDER}" "${FALLBACK_PROVIDER_PREFLIGHT}" >&2
    fi
    printf '\n' >&2
    return 1
}

hash_text() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    else
        cksum | awk '{print $1 "-" $2}'
    fi
}

provider_failure_state_field() {
    local key="$1"
    [[ -f "${PROVIDER_FAILURE_STATE}" ]] || return 0
    awk -F= -v key="${key}" '$1 == key { print substr($0, length(key) + 2); exit }' \
        "${PROVIDER_FAILURE_STATE}" 2>/dev/null
}

provider_failure_matches_quota_auth() {
    local text="$1"
    printf '%s' "${text}" | grep -qiE \
        "you've hit your limit|usage limit exceeded|rate limit exceeded|insufficient quota|quota exceeded|invalid api key|authentication failed"
}

provider_failure_retry_hint() {
    local text="$1"
    printf '%s' "${text}" \
        | tr '\n' ' ' \
        | grep -Eio 'try again at [^.]+' \
        | head -1 \
        | sed -E 's/[[:space:]]+/ /g'
}

clear_provider_failure_state_if_matches() {
    local provider="$1"
    [[ -f "${PROVIDER_FAILURE_STATE}" ]] || return 0
    [[ "$(provider_failure_state_field provider)" == "${provider}" ]] || return 0
    rm -f "${PROVIDER_FAILURE_STATE}"
}

record_provider_failure_cooldown() {
    local provider="$1" reason="$2" output="$3"
    local now until retry_hint head tmp
    now="$(date -u +%s)"
    until=$(( now + PROVIDER_FAILURE_COOLDOWN_SECONDS ))
    retry_hint="$(provider_failure_retry_hint "${output}")"
    head="$(printf '%s' "${output}" | head -n 1 | tr '\n' ' ')"
    tmp="${PROVIDER_FAILURE_STATE}.tmp"
    {
        printf 'provider=%s\n' "${provider}"
        printf 'reason=%s\n' "${reason}"
        printf 'until_epoch=%s\n' "${until}"
        printf 'until_iso=%s\n' "$(epoch_to_iso8601_utc "${until}")"
        printf 'retry_hint=%s\n' "${retry_hint}"
        printf 'head=%s\n' "${head}"
        printf 'recorded_epoch=%s\n' "${now}"
    } > "${tmp}"
    mv "${tmp}" "${PROVIDER_FAILURE_STATE}"
}

provider_failure_cooldown_active() {
    local provider="$1"
    local state_provider until_epoch now
    [[ -f "${PROVIDER_FAILURE_STATE}" ]] || return 1
    state_provider="$(provider_failure_state_field provider)"
    [[ "${state_provider}" == "${provider}" ]] || return 1
    until_epoch="$(provider_failure_state_field until_epoch)"
    until_epoch="${until_epoch:-0}"
    now="$(date -u +%s)"
    if (( until_epoch > now )); then
        return 0
    fi
    rm -f "${PROVIDER_FAILURE_STATE}"
    return 1
}

provider_failure_cooldown_message() {
    local provider="$1"
    local until_iso retry_hint reason head
    until_iso="$(provider_failure_state_field until_iso)"
    retry_hint="$(provider_failure_state_field retry_hint)"
    reason="$(provider_failure_state_field reason)"
    head="$(provider_failure_state_field head)"
    printf "[cortex] provider '%s' is cooling down until %s after %s failure." \
        "${provider}" "${until_iso:-unknown}" "${reason:-recent}"
    if [[ -n "${retry_hint}" ]]; then
        printf " %s." "${retry_hint}"
    elif [[ -n "${head}" ]]; then
        printf " Last head: %s" "${head}"
    fi
}

# Background heartbeat ticker used while a long-running provider CLI
# invocation is in flight. Without this the poll loop stalls inside
# run_agent_cli and the conductor sees the agent go stale/offline even though
# it is actively working. The ticker writes the heartbeat every
# WORK_HEARTBEAT_INTERVAL seconds and self-terminates if the conductor script
# dies (belt-and-braces against explicit stop being missed on crash).
WORK_HEARTBEAT_INTERVAL=10

start_work_heartbeat() {
    local parent_pid=$$
    # Detach stdio on the backgrounded ticker so it does not inherit the
    # capture pipe of the enclosing `$(start_work_heartbeat)`. Without this,
    # bash's command substitution deadlocks waiting for EOF on a pipe the
    # ticker keeps open for its entire lifetime.
    (
        while kill -0 "${parent_pid}" 2>/dev/null; do
            write_epoch_file_atomic "${AGENT_DIR}/heartbeat" "$(date -u +%s)" || true
            sleep "${WORK_HEARTBEAT_INTERVAL}"
        done
    ) </dev/null >/dev/null 2>&1 &
    echo $!
}

stop_work_heartbeat() {
    local pid="$1"
    [[ -n "${pid}" ]] || return 0
    kill "${pid}" 2>/dev/null
    wait "${pid}" 2>/dev/null || true
}
prepare_codex_stage_home() {
    local stage_root="${TMPDIR:-/tmp}/cortex_codex_home"
    local stage_home=""
    local source_auth="${HOME}/.codex/auth.json"

    if [[ ! -f "${source_auth}" ]]; then
        printf '[cortex] codex auth file missing: %s\n' "${source_auth}" >&2
        return 1
    fi

    mkdir -p -m 700 "${stage_root}"
    stage_home="$(mktemp -d "${stage_root}/${AGENT_ID}.XXXXXX")" || {
        printf '[cortex] failed to create staged Codex home under %s\n' "${stage_root}" >&2
        return 1
    }

    cp "${source_auth}" "${stage_home}/auth.json"
    chmod 600 "${stage_home}/auth.json" || {
        rm -rf "${stage_home}"
        return 1
    }
    register_codex_stage_home "${stage_home}"
    printf '%s\n' "${stage_home}"
}

prepare_codex_direct_home() {
    local stage_root="${TMPDIR:-/tmp}/cortex_codex_home"
    local stage_home=""
    local source_auth="${HOME}/.codex/auth.json"

    if [[ ! -f "${source_auth}" ]]; then
        printf '[cortex] codex auth file missing: %s\n' "${source_auth}" >&2
        return 1
    fi

    mkdir -p -m 700 "${stage_root}"
    stage_home="$(mktemp -d "${stage_root}/${AGENT_ID}.home.XXXXXX")" || {
        printf '[cortex] failed to create staged direct Codex home under %s\n' "${stage_root}" >&2
        return 1
    }

    mkdir -p "${stage_home}/.codex"
    cp "${source_auth}" "${stage_home}/.codex/auth.json"
    chmod 600 "${stage_home}/.codex/auth.json" || {
        rm -rf "${stage_home}"
        return 1
    }
    register_codex_stage_home "${stage_home}"
    printf '%s\n' "${stage_home}"
}

start_codex_stage_scrubber() {
    local stage_home="$1"
    # Codex can open websocket connections after startup and during retries.
    # Removing auth.json while the process is alive produces "Missing bearer"
    # failures; callers remove the whole staged home after codex exits.
    [[ -n "${stage_home}" ]]
}

trap cleanup_runtime EXIT
trap 'exit 130' INT TERM

# Build the prompt: static instructions template + dynamic context + body.
# Pure bash concatenation — handles multi-line bodies and arbitrary characters
# correctly (sed-based substitution breaks on newlines, |, &, etc.).
build_prompt() {
    local body="$1" tag="${2:-}"
    local label="COMMAND TO EXECUTE"
    [[ -n "${tag}" ]] && label="COMMAND TO EXECUTE (${tag})"
    local team_body=""
    local override_body=""
    local user_body=""
    local machine_time_utc machine_time_local machine_epoch
    machine_time_utc="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    machine_time_local="$(date '+%Y-%m-%dT%H:%M:%S%:z')"
    machine_epoch="$(date -u +%s)"
    if [[ -n "${INSTRUCT_TEAM_TEMPLATE}" && -f "${INSTRUCT_TEAM_TEMPLATE}" ]]; then
        team_body="$(cat "${INSTRUCT_TEAM_TEMPLATE}")"
    fi
    if [[ -n "${INSTRUCT_OVERRIDE_TEMPLATE}" && -f "${INSTRUCT_OVERRIDE_TEMPLATE}" ]]; then
        override_body="$(cat "${INSTRUCT_OVERRIDE_TEMPLATE}")"
    fi
    if [[ -f "${USER_INSTRUCT}" ]]; then
        user_body="$(cat "${USER_INSTRUCT}")"
    fi
    printf '%s\n\n%s' "$(cat "${COMMON_INSTRUCT}")" "$(cat "${INSTRUCT_TEMPLATE}")"
    if [[ -n "${team_body}" ]]; then
        printf '\n\n%s' "${team_body}"
    fi
    if [[ -n "${override_body}" ]]; then
        printf '\n\n%s' "${override_body}"
    fi
    if [[ -n "${user_body}" ]]; then
        printf '\n\n%s' "${user_body}"
    fi
    printf '\n\n---\nAGENT_ID: %s\nAGENT_ROLE: %s\nAGENT_RUN_MODE: %s\nAGENT_PROVIDER: %s\nAGENT_STATE_DIR: %s\nAGENT_LOG_FILE: %s\nAGENT_WORKER_LOGBOOK: %s\nAGENT_INSTRUCT_TEAM: %s\nAGENT_INSTRUCT_OVERRIDE: %s\nMACHINE_TIME_UTC: %s\nMACHINE_TIME_LOCAL: %s\nMACHINE_EPOCH_UTC: %s\n\n%s:\n%s\n' \
        "${AGENT_ID}" "${AGENT_ROLE}" "${AGENT_RUN_MODE}" "${AGENT_PROVIDER}" \
        "${AGENT_STATE_DIR}" "${LOG_FILE}" "${WORKER_LOGBOOK}" \
        "$([[ -n "${team_body}" ]] && printf '%s' "${INSTRUCT_TEAM_TEMPLATE}" || printf 'none')" \
        "$([[ -n "${override_body}" ]] && printf '%s' "${INSTRUCT_OVERRIDE_TEMPLATE}" || printf 'none')" \
        "${machine_time_utc}" "${machine_time_local}" "${machine_epoch}" \
        "${label}" "${body}"
}

run_agent_cli_single_provider() {
    local prompt="$1"
    local timeout_secs="${2:-${COMMAND_TIMEOUT}}"
    local working_file="${AGENT_DIR}/working"
    local tmp_out; tmp_out="$(mktemp)"
    local tmp_last; tmp_last="$(mktemp)"
    # Sandboxed codex worker: bwrap mounts /tmp as a tmpfs that does not
    # survive container exit, so --output-last-message must land inside the
    # worker's own agent dir (the only cortex path writable under the sandbox).
    if [[ "${AGENT_ROLE}" == "worker" && "${AGENT_PROVIDER}" == "codex" ]]; then
        rm -f "${tmp_last}"
        tmp_last="${AGENT_DIR}/.codex_last.tmp"
    fi
    local exit_code=0
    local hb_pid; hb_pid="$(start_work_heartbeat)"
    local started_epoch ended_epoch
    local usage_codex_home=""
    local role_output=""
    # Wrap the CLI in `timeout` so a hung provider can't silently park the
    # agent. exit code 124 = timed out (GNU coreutils convention).
    local -a timeout_cmd=()
    if (( timeout_secs > 0 )); then
        if command -v timeout >/dev/null 2>&1; then
            timeout_cmd=(timeout --preserve-status --kill-after=30s "${timeout_secs}")
        elif command -v gtimeout >/dev/null 2>&1; then
            timeout_cmd=(gtimeout --preserve-status --kill-after=30s "${timeout_secs}")
        fi
    fi
    # Stream output to working file and terminal (stderr → screen/log) in real-time
    started_epoch="$(date -u +%s)"
    role_output="$(role_run_provider_cli "${prompt}" "${working_file}" "${tmp_out}" "${tmp_last}" timeout_cmd)"
    exit_code=$?
    usage_codex_home="${ROLE_CLI_USAGE_CODEX_HOME:-}"
    ended_epoch="$(date -u +%s)"
    stop_work_heartbeat "${hb_pid}"
    local out; out="$(cat "${tmp_out}")"
    if [[ -z "$(printf '%s' "${out}" | tr -d '[:space:]')" && -n "${role_output}" ]]; then
        out="${role_output}"
    fi
    local usage_model="${CODEX_MODEL}"
    if [[ "${AGENT_PROVIDER}" == "claude" ]]; then
        usage_model="${CLAUDE_MODEL:-provider-default}"
    fi
    if [[ -n "${usage_codex_home}" ]]; then
        CORTEX_USAGE_CODEX_HOME="${usage_codex_home}" \
            cortex_usage_record_from_file \
                "${tmp_out}" "${AGENT_ID}" "${AGENT_ROLE}" "${AGENT_RUN_MODE}" \
                "${AGENT_PROVIDER}" "${usage_model}" "start_agent:${AGENT_ID}" \
                "${started_epoch}" "${ended_epoch}" "${CORTEX_DIR}" || true
        cleanup_codex_stage_home "${usage_codex_home}"
    else
        cortex_usage_record_from_file \
            "${tmp_out}" "${AGENT_ID}" "${AGENT_ROLE}" "${AGENT_RUN_MODE}" \
            "${AGENT_PROVIDER}" "${usage_model}" "start_agent:${AGENT_ID}" \
            "${started_epoch}" "${ended_epoch}" "${CORTEX_DIR}" || true
    fi
    if [[ "${AGENT_PROVIDER}" == "codex" && -s "${tmp_last}" ]]; then
        out="$(cat "${tmp_last}")"
    fi
    rm -f "${tmp_out}" "${tmp_last}" "${working_file}"
    if (( exit_code == 124 )); then
        log "provider CLI timed out after ${timeout_secs}s"
        # Append a clear marker so the conductor-side RESPONSE body shows the reason
        out="${out}
[cortex] provider CLI '${AGENT_PROVIDER}' exceeded ${timeout_secs}s and was killed."
    fi
    printf '%s' "${out}"
    return "${exit_code}"
}

RUN_AGENT_LAST_OUTPUT=""
RUN_AGENT_LAST_FAILURE_KIND=""

run_agent_cli_provider_attempt() {
    local provider="$1"
    local prompt="$2"
    local timeout_secs="${3:-${COMMAND_TIMEOUT}}"
    local saved_provider="${AGENT_PROVIDER}"
    local provider_prompt output rc=0

    RUN_AGENT_LAST_OUTPUT=""
    RUN_AGENT_LAST_FAILURE_KIND=""

    if provider_failure_cooldown_active "${provider}"; then
        RUN_AGENT_LAST_FAILURE_KIND="cooldown"
        RUN_AGENT_LAST_OUTPUT="$(provider_failure_cooldown_message "${provider}")"
        log "${RUN_AGENT_LAST_OUTPUT}"
        return 1
    fi

    provider_prompt="$(printf '%s\n' "${prompt}" | awk -v provider="${provider}" '
        !done && /^AGENT_PROVIDER: / { $0 = "AGENT_PROVIDER: " provider; done = 1 }
        { print }
    ')"

    AGENT_PROVIDER="${provider}"
    output="$(run_agent_cli_single_provider "${provider_prompt}" "${timeout_secs}")" || rc=$?
    AGENT_PROVIDER="${saved_provider}"

    if (( rc == 0 )); then
        if provider_failure_matches_quota_auth "${output}"; then
            RUN_AGENT_LAST_FAILURE_KIND="quota_auth"
            RUN_AGENT_LAST_OUTPUT="${output}"
            log "provider CLI ${provider}: quota/auth failure detected (head: $(printf '%s' "${output}" | head -n 1))"
            return 1
        fi
        if [[ -z "$(printf '%s' "${output}" | tr -d '[:space:]')" ]]; then
            RUN_AGENT_LAST_FAILURE_KIND="empty"
            RUN_AGENT_LAST_OUTPUT="${output}"
            log "provider CLI ${provider}: empty output"
            return 1
        fi
        clear_provider_failure_state_if_matches "${provider}"
        printf '%s' "${output}"
        return 0
    fi

    if [[ -n "$(printf '%s' "${output}" | tr -d '[:space:]')" ]] \
       && result_has_structured_fields "${output}"; then
        log "provider CLI ${provider}: nonzero exit ${rc}, but structured output was preserved"
        clear_provider_failure_state_if_matches "${provider}"
        printf '%s' "${output}"
        return 0
    fi

    if (( rc == 124 )); then
        RUN_AGENT_LAST_FAILURE_KIND="timeout"
    else
        RUN_AGENT_LAST_FAILURE_KIND="exit"
    fi
    RUN_AGENT_LAST_OUTPUT="${output}"
    return 1
}

run_agent_cli() {
    local prompt="$1"
    local timeout_secs="${2:-${COMMAND_TIMEOUT}}"
    local primary_provider="${AGENT_PROVIDER}"
    local fallback_provider="${FALLBACK_PROVIDER:-}"
    local primary_output fallback_output
    local primary_failure_kind fallback_failure_kind

    if primary_output="$(run_agent_cli_provider_attempt "${primary_provider}" "${prompt}" "${timeout_secs}")"; then
        printf '%s' "${primary_output}"
        return 0
    fi
    primary_failure_kind="${RUN_AGENT_LAST_FAILURE_KIND}"
    primary_output="${RUN_AGENT_LAST_OUTPUT}"
    if [[ "${primary_failure_kind}" == "quota_auth" ]]; then
        record_provider_failure_cooldown "${primary_provider}" "${primary_failure_kind}" "${primary_output}"
    fi

    if [[ -n "${fallback_provider}" && "${fallback_provider}" != "${primary_provider}" ]]; then
        log "primary provider ${primary_provider} unavailable (${primary_failure_kind:-unknown}); trying fallback ${fallback_provider}"
        if fallback_output="$(run_agent_cli_provider_attempt "${fallback_provider}" "${prompt}" "${timeout_secs}")"; then
            printf '%s' "${fallback_output}"
            return 0
        fi
        fallback_failure_kind="${RUN_AGENT_LAST_FAILURE_KIND}"
        fallback_output="${RUN_AGENT_LAST_OUTPUT}"
        if [[ "${fallback_failure_kind}" == "quota_auth" ]]; then
            record_provider_failure_cooldown "${fallback_provider}" "${fallback_failure_kind}" "${fallback_output}"
        fi
        printf '%s\n\n[cortex] fallback provider %s also failed.\n%s' \
            "${primary_output}" "${fallback_provider}" "${fallback_output}"
        return 1
    fi

    printf '%s' "${primary_output}"
    return 1
}

process_command() {
    local cmd_file="$1"
    local ref_msg; ref_msg="$(get_header MSG_ID "${cmd_file}")"
    local from_name body_raw notify_policy body
    from_name="$(get_header FROM "${cmd_file}")"
    body_raw="$(get_body "${cmd_file}")"
    notify_policy="$(extract_result_field "CONDUCTOR_NOTIFY" "${body_raw}")"
    notify_policy="${notify_policy:-always}"
    body="$(strip_command_wrapper_fields "${body_raw}")"

    set_status "busy"
    log "Processing [${ref_msg}]: ${body:0:200}..."

    CURRENT_COMMAND_FROM="${from_name}"
    CURRENT_COMMAND_BODY_RAW="${body_raw}"

    local prompt result status="done"
    if ! result="$(role_prepare_command_scope "${body_raw}" "${from_name}")"; then
        status="warning"
    fi

    if [[ "${status}" == "done" ]]; then
        prompt="$(build_prompt "${body}")"
        record_prompt_context_snapshot "command" "${prompt}" || true
        result="$(run_agent_cli "${prompt}")" || status="error"
    fi

    worker_record_command_next_wake "${result}"

    auto_forward_research_specialist_report "${status}" "${result}"

    if should_forward_command_response "${notify_policy}" "${status}" "${result}"; then
        send_to_conductor "RESPONSE" "${ref_msg}" "${status}" "${result}"
    else
        log "→ conductor suppressed [RESPONSE/${status}] ref=${ref_msg} policy=${notify_policy}"
    fi

    mkdir -p "${ARCHIVE}"
    mv "${cmd_file}" "${ARCHIVE}/"
    role_reset_command_scope
    CURRENT_COMMAND_FROM=""
    CURRENT_COMMAND_BODY_RAW=""

    set_status "idle"
    log "Completed [${ref_msg}] → ${status}"
}

next_personal_inbox_command() {
    ls -1 "${INBOX}"/*.msg 2>/dev/null | sort | head -1
}

process_pending_personal_inbox() {
    local drain_all=0 cmd
    role_should_drain_inbox_before_periodic && drain_all=1

    while true; do
        cmd="$(next_personal_inbox_command)"
        [[ -n "${cmd}" && -f "${cmd}" ]] || return 0

        process_command "${cmd}"

        if (( RUN_ONCE == 1 )); then
            log "Exiting after one personal inbox command (--once)."
            return 10
        fi

        if (( drain_all == 0 )); then
            return 0
        fi
    done
}

# ── Periodic self-check ───────────────────────────────────────────────────────
# Build a bounded snapshot of server + experiment state, then invoke the
# provider CLI with the self-check instructions. If the CLI returns
# "SELFCHECK: alert ...", post a STATUS message to the conductor for triage. If it
# returns "SELFCHECK: ok" (or anything unparseable), stay silent.
collect_selfcheck_snapshot() {
    # Lean snapshot: drop empty sections, cap log tails, emit log tails only
    # for files that have an error-pattern hit. The snapshot is also the only
    # input the fast-path gate uses, so every line here matters.
    local ts_iso ts_epoch user
    ts_iso="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    ts_epoch="$(date -u +%s)"
    user="$(whoami)"

    local err_pattern='traceback|cuda error|runtimeerror|oom|out of memory|\bnan\b|xid'

    {
        echo "### snapshot @ ${ts_iso} (epoch ${ts_epoch}) on ${AGENT_ID} (user=${user})"
        echo

        if command -v nvidia-smi >/dev/null 2>&1; then
            echo "## nvidia-smi"
            nvidia-smi --query-gpu=index,utilization.gpu,memory.used,memory.total,temperature.gpu \
                       --format=csv,noheader 2>&1 | head -16
            local apps
            apps="$(nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_memory \
                       --format=csv,noheader 2>/dev/null | head -32)"
            if [[ -n "${apps}" ]]; then
                echo
                echo "## nvidia-smi processes"
                echo "${apps}"
            fi
            echo
        fi

        local train_procs
        train_procs="$(ps -u "${user}" -o pid,pcpu,pmem,etime,stat,cmd --no-headers 2>/dev/null \
            | grep -Ei 'python|train|sweep|wandb|accelerate|torchrun|deepspeed' \
            | grep -v 'grep' \
            | head -20)"
        if [[ -n "${train_procs}" ]]; then
            echo "## user processes — training-ish"
            echo "${train_procs}"
            echo
        fi

        # Disk: only lines >80% used
        local disk_hot
        disk_hot="$(df -hT -x tmpfs -x devtmpfs -x overlay -x squashfs 2>/dev/null \
            | awk 'NR==1 || ($6+0 >= 80)' | head -12)"
        if [[ "$(echo "${disk_hot}" | wc -l)" -gt 1 ]]; then
            echo "## disk usage (>=80%)"
            echo "${disk_hot}"
            echo
        fi

        local session_backend sessions
        session_backend="$(cortex_session_backend_resolve "${CORTEX_SESSION_BACKEND:-${CORTEX_DEFAULT_SESSION_BACKEND}}")"
        if cortex_session_backend_available "${session_backend}"; then
            sessions="$(cortex_session_list "${session_backend}" | head -20)"
        else
            sessions=""
        fi
        if [[ -n "${sessions}" ]]; then
            echo "## ${session_backend} sessions"
            echo "${sessions}"
            echo
        fi

        # Log tails: only emit for files whose recent content has error hits
        local candidate_dirs=(
            "${HOME}/logs"
            "${HOME}/workspace"
            "/tmp"
        )
        local err_emitted=0
        for base in "${candidate_dirs[@]}"; do
            [[ -d "${base}" ]] || continue
            while IFS= read -r f; do
                [[ -f "${f}" ]] || continue
                local hits
                hits="$(grep -Ein "${err_pattern}" "${f}" 2>/dev/null | tail -3)"
                [[ -z "${hits}" ]] && continue
                if (( err_emitted == 0 )); then
                    echo "## error-pattern hits in recent logs"
                fi
                echo "--- ${f}"
                echo "${hits}"
                err_emitted=$((err_emitted + 1))
                (( err_emitted >= 3 )) && break
            done < <(find "${base}" -maxdepth 4 -type f -name '*.log' -mmin -60 -size +0c 2>/dev/null | head -20)
            (( err_emitted >= 3 )) && break
        done
        (( err_emitted > 0 )) && echo

        echo "## load"
        uptime 2>/dev/null
    } > "${SELFCHECK_SNAPSHOT}.tmp" 2>&1
    mv "${SELFCHECK_SNAPSHOT}.tmp" "${SELFCHECK_SNAPSHOT}"
}

# Fast-path gate: decide whether a snapshot is boring enough that we can
# skip the provider CLI and record `ok` directly. We look for:
#   - any error-pattern section in the snapshot
#   - disappearance of a training-ish process that was present in the
#     previous snapshot
#   - new disk hotspots vs previous snapshot
# Everything else is treated as boring (timestamps/util/uptime churn).
# Return 0 = boring (skip LLM), 1 = needs LLM.
selfcheck_fast_path_boring() {
    local cur="$1" prev="$2"
    [[ -f "${cur}" ]] || return 1

    # Any error-pattern section means non-boring.
    grep -q '^## error-pattern hits' "${cur}" 2>/dev/null && return 1

    # Previous-snapshot comparisons only make sense when we have one.
    if [[ -f "${prev}" ]]; then
        # A training-ish process section that disappeared → non-boring.
        if grep -q '^## user processes' "${prev}" 2>/dev/null \
           && ! grep -q '^## user processes' "${cur}" 2>/dev/null; then
            return 1
        fi

        # Disk hotspot section that grew → non-boring.
        local prev_disk cur_disk
        prev_disk="$(awk '/^## disk usage/,/^$/' "${prev}" 2>/dev/null | grep -cE '[0-9]+%')"
        cur_disk="$(awk '/^## disk usage/,/^$/' "${cur}" 2>/dev/null | grep -cE '[0-9]+%')"
        (( cur_disk > prev_disk )) && return 1
    else
        # No previous snapshot → always run the LLM once for a baseline.
        return 1
    fi

    return 0
}

run_self_check() {
    # Rotate snapshots: current → previous before writing new one
    [[ -f "${SELFCHECK_SNAPSHOT}" ]] && cp "${SELFCHECK_SNAPSHOT}" "${SELFCHECK_PREVIOUS}"

    collect_selfcheck_snapshot

    # Fast-path gate: if the snapshot has no error markers and nothing
    # obviously regressed vs the previous snapshot, skip the provider CLI
    # and record `ok` directly. This saves a large fraction of routine
    # self-check invocations while preserving alerting on real changes.
    if selfcheck_fast_path_boring "${SELFCHECK_SNAPSHOT}" "${SELFCHECK_PREVIOUS}"; then
        log "self-check: ok (fast-path, no LLM call)"
        return 0
    fi

    local instruct_body snapshot_body prev_body prompt result
    instruct_body="$(cat "${SELFCHECK_TEMPLATE}" 2>/dev/null)"
    if [[ -z "${instruct_body}" ]]; then
        log "self-check: template missing at ${SELFCHECK_TEMPLATE}, skipping"
        return 0
    fi
    snapshot_body="$(cat "${SELFCHECK_SNAPSHOT}")"
    prev_body=""
    [[ -f "${SELFCHECK_PREVIOUS}" ]] && prev_body="$(cat "${SELFCHECK_PREVIOUS}")"

    prompt="$(printf '%s\n\n---\nAGENT_ID: %s\nAGENT_PROVIDER: %s\n\nCURRENT SNAPSHOT:\n%s\n\nPREVIOUS SNAPSHOT (for diff; may be empty on first run):\n%s\n' \
        "${instruct_body}" "${AGENT_ID}" "${AGENT_PROVIDER}" "${snapshot_body}" "${prev_body}")"

    log "self-check: invoking provider (snapshot=$(wc -c < "${SELFCHECK_SNAPSHOT}") bytes, timeout=${SELFCHECK_TIMEOUT}s)"
    record_prompt_context_snapshot "selfcheck" "${prompt}" || true
    result="$(run_agent_cli "${prompt}" "${SELFCHECK_TIMEOUT}")" || true

    # Parse result tolerantly: LLMs sometimes add leading whitespace, quote
    # the block in Markdown fences, or prepend a short preamble. Anchor on
    # the SELFCHECK: line anywhere in the output. Case-insensitive for robustness.
    # Strip class covers whitespace + Markdown quote/fence glyphs only; do
    # NOT include '-', '*', '_' here because those legitimately prefix DETAILS
    # bullets or emphasis that we want to preserve inside the alert body.
    local strip_class='[[:space:]>`]'
    local alert_line
    alert_line="$(printf '%s' "${result}" | grep -niE "(^|${strip_class})selfcheck:[[:space:]]+alert" | head -1)"
    local ok_line
    ok_line="$(printf '%s' "${result}" | grep -niE "(^|${strip_class})selfcheck:[[:space:]]+ok" | head -1)"

    if [[ -n "${alert_line}" ]]; then
        # Extract from the first SELFCHECK: alert line onward, stripping any
        # leading fence/quote markers so the conductor sees a clean block.
        local alert_body
        # Use character-class regex instead of IGNORECASE so this works under
        # both gawk and mawk (default awk on Debian/Ubuntu). Only strip
        # whitespace + Markdown quote/fence glyphs from the line start; keep
        # bullet dashes and emphasis characters.
        alert_body="$(printf '%s' "${result}" \
            | awk '/[Ss][Ee][Ll][Ff][Cc][Hh][Ee][Cc][Kk]:[[:space:]]+[Aa][Ll][Ee][Rr][Tt]/{found=1} found{sub(/^[[:space:]>`]+/,""); print}')"

        # Suppress unchanged re-alerts. Fingerprint the alert body with
        # rolling/transient lines stripped (timestamps, byte counts,
        # rotation eligibility hints) so that "same problem, slightly
        # different numbers" still matches. A fresh fingerprint or one
        # older than CORTEX_DEFAULT_SELFCHECK_REALERT_SECONDS resends.
        local alert_fp now_epoch state_file last_fp last_epoch realert_secs n_suppressed=0
        alert_fp="$(printf '%s' "${alert_body}" \
            | sed -E \
                -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.+Z-]+//g' \
                -e 's/\b[0-9]+(\.[0-9]+)?\s*(B|KB|MB|GB|s|min|h|hours?)\b//g' \
                -e 's/[[:space:]]+/ /g' \
            | sha256sum | awk '{ print $1 }')"
        now_epoch="$(date -u +%s)"
        state_file="${AGENT_DIR}/selfcheck_alert_state"
        last_fp=""
        last_epoch=0
        if [[ -f "${state_file}" ]]; then
            last_fp="$(awk -F'\t' 'NR==1 { print $1 }' "${state_file}" 2>/dev/null || true)"
            last_epoch="$(awk -F'\t' 'NR==1 { print $2 }' "${state_file}" 2>/dev/null || true)"
            n_suppressed="$(awk -F'\t' 'NR==1 { print $3 }' "${state_file}" 2>/dev/null || true)"
            [[ "${last_epoch}" =~ ^[0-9]+$ ]] || last_epoch=0
            [[ "${n_suppressed}" =~ ^[0-9]+$ ]] || n_suppressed=0
        fi
        realert_secs="${CORTEX_DEFAULT_SELFCHECK_REALERT_SECONDS:-86400}"
        [[ "${realert_secs}" =~ ^[0-9]+$ ]] || realert_secs=86400

        if [[ "${alert_fp}" == "${last_fp}" && "${realert_secs}" -gt 0 \
              && $(( now_epoch - last_epoch )) -lt ${realert_secs} ]]; then
            n_suppressed=$(( n_suppressed + 1 ))
            printf '%s\t%s\t%s\n' "${alert_fp}" "${last_epoch}" "${n_suppressed}" \
                > "${state_file}.tmp" && mv "${state_file}.tmp" "${state_file}"
            log "self-check: ALERT suppressed (fingerprint unchanged; last sent $(( (now_epoch - last_epoch) / 60 ))min ago; ${n_suppressed} suppressed since)"
        else
            send_to_conductor "STATUS" "none" "done" "$(printf 'TYPE: selfcheck_alert\n%s' "${alert_body}")"
            printf '%s\t%s\t%s\n' "${alert_fp}" "${now_epoch}" "0" \
                > "${state_file}.tmp" && mv "${state_file}.tmp" "${state_file}"
            if [[ -n "${last_fp}" && "${alert_fp}" != "${last_fp}" ]]; then
                log "self-check: ALERT sent to conductor (fingerprint changed)"
            else
                log "self-check: ALERT sent to conductor"
            fi
        fi
    elif [[ -n "${ok_line}" ]]; then
        log "self-check: ok (no alert)"
    else
        # Unparseable — don't silently swallow it. Stash the raw response so
        # the conductor (or a human) can inspect it without losing the signal.
        local stash="${AGENT_DIR}/selfcheck_unparseable_$(date -u +%s).txt"
        printf '%s\n' "${result}" > "${stash}"
        log "self-check: unparseable provider response (${#result} chars); raw saved to ${stash}"
    fi
}

# ── Periodic status report ────────────────────────────────────────────────────
# Local status snapshot only — no LLM call. Overwrites a current-state
# snapshot file with GPU/screen state plus compact per-run progress lines so
# the conductor/watch can answer many status questions without SSH-ing.
collect_status_report_run_lines() {
    python3 - <<'PY'
import os
import pathlib
import re
import subprocess


def fmt_duration(seconds: float | int) -> str:
    seconds = max(0, int(round(float(seconds))))
    hours, rem = divmod(seconds, 3600)
    minutes, secs = divmod(rem, 60)
    if hours:
        return f"{hours}h{minutes:02d}m"
    if minutes:
        return f"{minutes}m{secs:02d}s"
    return f"{secs}s"


def parse_hms(text: str) -> int:
    parts = [int(part) for part in text.split(":")]
    if len(parts) == 2:
        return parts[0] * 60 + parts[1]
    if len(parts) == 3:
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    return 0


def tail_text(path: pathlib.Path, max_bytes: int = 250_000) -> str:
    try:
        with path.open("rb") as handle:
            handle.seek(0, 2)
            size = handle.tell()
            handle.seek(max(0, size - max_bytes))
            data = handle.read()
    except OSError:
        return ""
    return data.decode("utf-8", errors="ignore").replace("\r", "\n")


def parse_log_progress(path: pathlib.Path) -> dict[str, float | int] | None:
    text = tail_text(path)
    if not text:
        return None
    lines = text.splitlines()
    if len(lines) > 4000:
        lines = lines[-4000:]
    text = "\n".join(lines)

    progress_re = re.compile(
        r"Epoch\s+(\d+)/(\d+)[^\n]*?(\d{1,3})%\|[^\n]*?\[(\d+:\d\d(?::\d\d)?)<(\d+:\d\d(?::\d\d)?)",
        re.IGNORECASE,
    )
    completed_re = re.compile(r"Epoch\s+(\d+),\s*Train Loss:")
    epochs_arg_re = re.compile(r"--epochs(?:=| )(\d+)\b")

    result: dict[str, float | int] = {}

    completed_matches = list(completed_re.finditer(text))
    if completed_matches:
        result["completed_epochs"] = int(completed_matches[-1].group(1)) + 1

    progress_matches = list(progress_re.finditer(text))
    if progress_matches:
        last = progress_matches[-1]
        result["current_epoch"] = int(last.group(1))
        result["requested_epochs"] = int(last.group(2))
        result["epoch_pct"] = int(last.group(3))
        result["epoch_elapsed_s"] = parse_hms(last.group(4))
        result["epoch_remaining_s"] = parse_hms(last.group(5))

    if "requested_epochs" not in result:
        arg_matches = list(epochs_arg_re.finditer(text))
        if arg_matches:
            result["requested_epochs"] = int(arg_matches[-1].group(1))

    return result or None


ps_output = subprocess.check_output(
    ["ps", "-eo", "pid=,etimes=,args="],
    text=True,
    errors="ignore",
)
ps_lines = ps_output.splitlines()

repo_roots: list[pathlib.Path] = []
seen_roots: set[str] = set()
train_root_re = re.compile(os.environ.get("CORTEX_STATUS_TRAIN_ROOT_RE", r"(/[^ ]+)/train\.py\b"))
for line in ps_lines:
    match = train_root_re.search(line)
    if not match:
        continue
    root = match.group(1)
    if root not in seen_roots:
        seen_roots.add(root)
        repo_roots.append(pathlib.Path(root))

for root_text in os.environ.get("CORTEX_STATUS_REPO_ROOTS", "").split(":"):
    if not root_text:
        continue
    root = pathlib.Path(root_text).expanduser()
    root_str = str(root)
    if root.exists() and root_str not in seen_roots:
        seen_roots.add(root_str)
        repo_roots.append(root)

screen_re = re.compile(
    r"^\s*(\d+)\s+(\d+)\s+SCREEN\b.*?-Logfile\s+(\S+)\s+-dmS\s+(\S+)"
)

entries: list[tuple[str, int, pathlib.Path | None]] = []
for line in ps_lines:
    match = screen_re.match(line)
    if not match:
        continue
    elapsed_s = int(match.group(2))
    log_spec = match.group(3)
    screen_name = match.group(4)
    if "wandb_agents" not in log_spec and not re.search(
        r"(?:^|_)(ema_teacher|contrastive|sigreg|ds30fix|downstream)", screen_name
    ):
        continue

    candidates: list[pathlib.Path] = []
    log_path = pathlib.Path(log_spec)
    if log_path.is_absolute():
        candidates.append(log_path)
    else:
        for root in repo_roots:
            candidates.append(root / log_path)
        candidates.append(pathlib.Path.home() / log_path)

    resolved = next((cand for cand in candidates if cand.exists()), None)
    entries.append((screen_name, elapsed_s, resolved))

for screen_name, elapsed_s, log_path in sorted(entries, key=lambda item: item[0]):
    parts = [screen_name]
    progress = parse_log_progress(log_path) if log_path is not None else None
    requested = None
    total_fraction = None

    if progress:
        requested = progress.get("requested_epochs")
        completed = int(progress.get("completed_epochs", 0))
        current_epoch = progress.get("current_epoch")
        epoch_pct = progress.get("epoch_pct")

        if isinstance(current_epoch, int) and isinstance(requested, int):
            parts.append(f"ep {current_epoch}/{requested}")
            if isinstance(epoch_pct, int):
                parts.append(f"epoch {epoch_pct}%")
                total_fraction = ((current_epoch - 1) + (epoch_pct / 100.0)) / max(1, requested)
            else:
                total_fraction = (current_epoch - 1) / max(1, requested)
        elif isinstance(requested, int) and completed:
            parts.append(f"ep {completed}/{requested}")
            total_fraction = completed / max(1, requested)
        elif completed:
            parts.append(f"completed {completed} ep")

        if isinstance(total_fraction, float):
            total_fraction = max(0.0, min(total_fraction, 1.0))
            parts.append(f"total {total_fraction * 100:.1f}%")

    parts.append(f"elapsed {fmt_duration(elapsed_s)}")

    if isinstance(total_fraction, float) and 0.0 < total_fraction < 1.0:
        eta_total_s = elapsed_s * ((1.0 - total_fraction) / total_fraction)
        parts.append(f"eta {fmt_duration(eta_total_s)}")

    print("  - run: " + " | ".join(parts))
PY
}

collect_gpu_status_line() {
    python3 - <<'PY'
import re
import subprocess
import time


def query():
    try:
        output = subprocess.check_output(
            [
                "nvidia-smi",
                "--query-gpu=index,utilization.gpu,memory.used,memory.total",
                "--format=csv,noheader",
            ],
            text=True,
            errors="ignore",
        )
    except Exception:
        return {}

    rows = {}
    for raw_line in output.splitlines():
        parts = [part.strip() for part in raw_line.split(",")]
        if len(parts) < 4:
            continue
        index = parts[0]
        util_match = re.search(r"(\d+)", parts[1])
        util = int(util_match.group(1)) if util_match else 0
        rows[index] = {
            "util": util,
            "mem_used": parts[2],
            "mem_total": parts[3],
        }
    return rows


first = query()
if not first:
    raise SystemExit(0)

rows = first
if any(item["util"] == 0 for item in first.values()):
    time.sleep(30)
    second = query()
    if second:
        merged = {}
        for index in sorted(set(first) | set(second), key=lambda v: int(v)):
            a = first.get(index)
            b = second.get(index)
            if a and b:
                merged[index] = b if b["util"] > a["util"] else a
            else:
                merged[index] = a or b
        rows = merged

parts = []
for index in sorted(rows, key=lambda v: int(v)):
    row = rows[index]
    parts.append(f"GPU{index}:{row['util']} % {row['mem_used']}/{row['mem_total']}")
print("  ".join(parts))
PY
}

run_status_report() {
    local ts; ts="$(date '+%Y-%m-%dT%H:%M:%S%:z')"
    local gpu_line="" screen_line="" run_lines="" context_bundle_lines="" last_prompt_lines=""
    local snapshot_file="${STATUSREPORT_SNAPSHOT}"
    local tmp_file="${snapshot_file}.tmp"

    if command -v nvidia-smi >/dev/null 2>&1; then
        gpu_line="$(collect_gpu_status_line 2>/dev/null || true)"
    fi

    local session_backend
    session_backend="$(cortex_session_backend_resolve "${CORTEX_SESSION_BACKEND:-${CORTEX_DEFAULT_SESSION_BACKEND}}")"
    if cortex_session_backend_available "${session_backend}"; then
        screen_line="$(cortex_session_list "${session_backend}" \
            | tr '\n' ' ' \
            | sed 's/ $//')"
    fi

    run_lines="$(collect_status_report_run_lines 2>/dev/null || true)"
    context_bundle_lines="$(render_context_bundle_report 2>/dev/null || true)"
    if [[ -f "${PROMPT_CONTEXT_SNAPSHOT}" ]]; then
        last_prompt_lines="$(sed 's/^/  /' "${PROMPT_CONTEXT_SNAPSHOT}" 2>/dev/null || true)"
    fi

    (
        flock -x 9
        {
            printf 'STATUS: periodic status report\n'
            printf 'TIME: %s\n' "${ts}"
            printf 'AGENT: %s\n' "${AGENT_ID}"
            [[ -n "${gpu_line}" ]]    && printf '  - gpus: %s\n' "${gpu_line}"
            [[ -n "${screen_line}" ]] && printf '  - screens: %s\n' "${screen_line}"
            if [[ -n "${context_bundle_lines}" ]]; then
                printf 'CONTEXT_BUNDLE:\n%s\n' "${context_bundle_lines}"
            fi
            if [[ -n "${last_prompt_lines}" ]]; then
                printf 'LAST_PROMPT:\n%s\n' "${last_prompt_lines}"
            else
                printf 'LAST_PROMPT:\n  - none yet\n'
            fi
            [[ -n "${run_lines}" ]]   && printf '%s\n' "${run_lines}"
        } > "${tmp_file}"
        mv "${tmp_file}" "${snapshot_file}"
    ) 9>"${snapshot_file}.lock"
}

process_broadcast() {
    local bcast_file="$1"
    local ref_msg; ref_msg="$(get_header MSG_ID "${bcast_file}")"
    local body; body="$(get_body "${bcast_file}")"

    log "Broadcast [${ref_msg}]"

    local prompt result status="done"
    prompt="$(build_prompt "${body}" BROADCAST)"
    record_prompt_context_snapshot "broadcast" "${prompt}" || true
    result="$(run_agent_cli "${prompt}")" || status="error"

    send_to_conductor "RESPONSE" "${ref_msg}" "${status}" "${result}"

    # Mark as seen locally — do NOT move the file. Other agents still need it.
    # Master is responsible for cleaning broadcast/ once all responses are in.
    mkdir -p "${ARCHIVE}"
    touch "${ARCHIVE}/$(basename "${bcast_file}").seen"
}

# ── Registration ──────────────────────────────────────────────────────────────
mkdir -p "${AGENT_DIR}" "${AGENT_STATE_DIR}"

if ! worker_runtime_preflight; then
    exit 2
fi

mkdir -p "${INBOX}" "${AGENT_DIR}" "${AGENT_STATE_DIR}" "${CONDUCTOR_INBOX}" "${ARCHIVE}" \
         "${BROADCAST_DIR}"
role_prepare_registration

write_agent_info_file

set_status "idle"
if [[ "${AGENT_PROVIDER}" == "claude" ]]; then
    log "Agent registered (role=${AGENT_ROLE}, run_mode=${AGENT_RUN_MODE}, provider=${AGENT_PROVIDER}, model=${CLAUDE_MODEL:-provider-default}, effort=${CLAUDE_EFFORT}, once=${RUN_ONCE}, worker_check_interval=${WORKER_REVIEW_INTERVAL}, sandbox_backend=${WORKER_SANDBOX_BACKEND}, provider_preflight=${PRIMARY_PROVIDER_PREFLIGHT}, fallback_preflight=${FALLBACK_PROVIDER_PREFLIGHT}). Entering poll loop (interval=${POLL_INTERVAL}s)."
elif [[ "${AGENT_PROVIDER}" == "codex" ]]; then
    log "Agent registered (role=${AGENT_ROLE}, run_mode=${AGENT_RUN_MODE}, provider=${AGENT_PROVIDER}, model=${CODEX_MODEL}, reasoning_effort=${CODEX_REASONING_EFFORT}, once=${RUN_ONCE}, worker_check_interval=${WORKER_REVIEW_INTERVAL}, sandbox_backend=${WORKER_SANDBOX_BACKEND}, provider_preflight=${PRIMARY_PROVIDER_PREFLIGHT}, fallback_preflight=${FALLBACK_PROVIDER_PREFLIGHT}). Entering poll loop (interval=${POLL_INTERVAL}s)."
else
    log "Agent registered (role=${AGENT_ROLE}, run_mode=${AGENT_RUN_MODE}, provider=${AGENT_PROVIDER}, once=${RUN_ONCE}, worker_check_interval=${WORKER_REVIEW_INTERVAL}, sandbox_backend=${WORKER_SANDBOX_BACKEND}, provider_preflight=${PRIMARY_PROVIDER_PREFLIGHT}, fallback_preflight=${FALLBACK_PROVIDER_PREFLIGHT}). Entering poll loop (interval=${POLL_INTERVAL}s)."
fi

# ── Announce online ───────────────────────────────────────────────────────────
case "${AGENT_REGISTER_NOTIFY}" in
    1|yes|true|always)
        send_to_conductor "STATUS" "none" "done" \
            "Agent ${AGENT_ID} (role=${AGENT_ROLE}, run_mode=${AGENT_RUN_MODE}) is online and ready. Poll interval: ${POLL_INTERVAL}s. Worker check interval: ${WORKER_REVIEW_INTERVAL}s."
        ;;
    *)
        log "registration notification: local-only (set AGENT_REGISTER_NOTIFY=1 to forward)"
        ;;
esac

# ── Poll loop ─────────────────────────────────────────────────────────────────
while true; do
    # 1. Heartbeat
    write_epoch_file_atomic "${AGENT_DIR}/heartbeat" "$(date -u +%s)" || true

    # 2. Broadcast messages (process all pending, sorted = FIFO)
    #    Each agent processes every broadcast once, tracked via .seen markers.
    for bcast in $(ls -1 "${BROADCAST_DIR}"/*.msg 2>/dev/null | sort); do
        [[ -f "${bcast}" ]] || continue
        [[ -f "${ARCHIVE}/$(basename "${bcast}").seen" ]] && continue
        process_broadcast "${bcast}"
    done

    # 3. Personal inbox — stable FIFO. Some workers, such as research-lead,
    #    drain all pending inbox work before periodic review to avoid a local
    #    backlog outranking fresh cycle coordination.
    process_pending_personal_inbox
    personal_inbox_rc=$?
    if (( personal_inbox_rc == 10 )); then
        break
    fi

    # 4. Role-specific periodic work
    role_maybe_run_periodic_work

    # 5. Periodic self-check (every SELFCHECK_INTERVAL seconds, when idle)
    if (( SELFCHECK_INTERVAL > 0 )); then
        now_ts=$(date -u +%s)
        last_selfcheck="$(read_epoch_file_or_default "${SELFCHECK_LAST_FILE}" 0)"
        current_status="$(read_agent_status)"
        if [[ "${current_status}" == "idle" ]] \
           && (( now_ts - last_selfcheck >= SELFCHECK_INTERVAL )); then
            set_status "selfcheck"
            run_self_check
            write_epoch_file_atomic "${SELFCHECK_LAST_FILE}" "${now_ts}" || true
            set_status "idle"
        fi
    fi

    # 6. Periodic status report (bash-only, no LLM, every STATUSREPORT_INTERVAL seconds)
    if (( STATUSREPORT_INTERVAL > 0 )); then
        _sr_now=$(date -u +%s)
        _sr_last="$(read_epoch_file_or_default "${STATUSREPORT_LAST_FILE}" 0)"
        _sr_status="$(read_agent_status)"
        if [[ "${_sr_status}" == "idle" ]] \
           && (( _sr_now - _sr_last >= STATUSREPORT_INTERVAL )); then
            run_status_report
            write_epoch_file_atomic "${STATUSREPORT_LAST_FILE}" "${_sr_now}" || true
        fi
        unset _sr_now _sr_last _sr_status
    fi

    sleep "${POLL_INTERVAL}"
done
