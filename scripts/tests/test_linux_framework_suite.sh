#!/usr/bin/env bash
# =============================================================================
# test_linux_framework_suite.sh — Linux regression suite for the Cortex shell
# control plane after the BSD/macOS compatibility work.
#
# Default run is deterministic and Linux-only. It checks:
#   1) Linux worker sandbox backend resolution still prefers bwrap and rejects
#      `macos-direct`.
#   2) Linux worker dispatch still uses the generic/bwrap launchers rather than
#      the direct macOS provider paths.
#   3) `scripts/start_agent.sh` still prepends the highest available nvm Node
#      bin once, without duplicating the chosen PATH entry.
#   4) `cortex.sh` still retains both the util-linux `script -c` branch and the
#      BSD fallback branch in source.
#   5) Existing deterministic framework smokes and selected doctor checks pass.
#
# Optional `--with-live-smoke` adds a real control-plane round trip through
# `scripts/control_plane_smoke.sh`.
# =============================================================================

set -euo pipefail

CORTEX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
WITH_LIVE_SMOKE=0
LIVE_PROVIDER="codex"
LIVE_TIMEOUT=180

cleanup() {
    if [[ -n "${TMP_ROOT:-}" && -d "${TMP_ROOT}" ]]; then
        rm -rf "${TMP_ROOT}"
    fi
}

trap cleanup EXIT

usage() {
    cat <<'EOF'
Usage:
  bash scripts/tests/test_linux_framework_suite.sh
  bash scripts/tests/test_linux_framework_suite.sh --with-live-smoke [--provider codex|claude] [--timeout SECONDS]

Options:
  --with-live-smoke   Also run scripts/control_plane_smoke.sh after the
                      deterministic Linux regression checks.
  --provider VALUE    Provider for --with-live-smoke. Default: codex.
  --timeout SECONDS   Timeout for --with-live-smoke. Default: 180.
  -h, --help          Show this help text.
EOF
}

note() {
    printf 'SUITE: %s\n' "$1"
}

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

run_step() {
    local label="$1"
    shift
    note "${label}"
    "$@"
}

require_linux() {
    local platform
    platform="$(uname -s 2>/dev/null || echo unknown)"
    [[ "${platform}" == "Linux" ]] || fail "this suite is Linux-only; saw ${platform}"
}

test_linux_worker_sandbox_resolution() {
    local fakebin auto_out explicit_out rc

    fakebin="${TMP_ROOT}/fakebin"
    mkdir -p "${fakebin}"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "${fakebin}/bwrap"
    chmod +x "${fakebin}/bwrap"

    auto_out="$(
        PATH="${fakebin}:${PATH}" CORTEX_DIR="${CORTEX_DIR}" bash <<'EOF'
set -euo pipefail
source "${CORTEX_DIR}/scripts/bash_compat.sh"
source "${CORTEX_DIR}/roles/sandbox.sh"
resolve_worker_sandbox_backend auto
EOF
    )"
    [[ "${auto_out}" == "bwrap" ]] || fail "expected auto sandbox backend to resolve to bwrap on Linux, got '${auto_out}'"

    set +e
    explicit_out="$(
        PATH="${fakebin}:${PATH}" CORTEX_DIR="${CORTEX_DIR}" bash <<'EOF'
set -euo pipefail
source "${CORTEX_DIR}/scripts/bash_compat.sh"
source "${CORTEX_DIR}/roles/sandbox.sh"
resolve_worker_sandbox_backend macos-direct
EOF
    )"
    rc=$?
    set -e

    [[ ${rc} -ne 0 ]] || fail "macos-direct should fail on Linux"
    [[ "${explicit_out}" == "unsupported" ]] || fail "expected macos-direct on Linux to report unsupported, got '${explicit_out}'"
}

test_start_agent_nvm_path_bootstrap() {
    local home path_block resulting_path first_path first_count

    home="${TMP_ROOT}/home"
    mkdir -p \
        "${home}/.nvm/versions/node/v18.20.2/bin" \
        "${home}/.nvm/versions/node/v20.10.0/bin" \
        "${home}/.nvm/versions/node/v20.11.1/bin"

    path_block="$(sed -n '/^_cortex_nvm_bin=""/,/^unset _cortex_nvm_candidate _cortex_nvm_version _cortex_nvm_major _cortex_nvm_rest _cortex_nvm_minor _cortex_nvm_patch/p' "${CORTEX_DIR}/scripts/start_agent.sh")"
    [[ -n "${path_block}" ]] || fail "could not extract PATH bootstrap block from scripts/start_agent.sh"

    resulting_path="$(
        HOME="${home}" \
        PATH="${home}/.nvm/versions/node/v18.20.2/bin:/usr/bin:/bin" \
        bash <<EOF
set -euo pipefail
${path_block}
printf '%s\n' "\${PATH}"
EOF
    )"

    first_path="${resulting_path%%:*}"
    [[ "${first_path}" == "${home}/.nvm/versions/node/v20.11.1/bin" ]] \
        || fail "expected highest nvm node bin to lead PATH, got '${first_path}'"

    first_count="$(printf '%s' "${resulting_path}" | tr ':' '\n' | grep -Fxc "${home}/.nvm/versions/node/v20.11.1/bin")"
    [[ "${first_count}" == "1" ]] || fail "expected chosen nvm node bin exactly once in PATH, saw ${first_count}"
}

test_linux_worker_dispatch() {
    local output line1 line2

    output="$(
        CORTEX_DIR="${CORTEX_DIR}" bash <<'EOF'
set -euo pipefail
source "${CORTEX_DIR}/scripts/bash_compat.sh"
source "${CORTEX_DIR}/roles/sandbox.sh"
source "${CORTEX_DIR}/roles/worker.sh"

worker_launch_claude_direct() { printf 'claude_direct\n'; }
worker_launch_claude_generic() { printf 'claude_generic\n'; }
worker_launch_codex_direct() { printf 'codex_direct\n'; }
worker_launch_codex_generic() { printf 'codex_generic\n'; }

timeout_cmd=()
AGENT_ID="linux-dispatch-smoke"
WORKER_SANDBOX_BACKEND="bwrap"

AGENT_PROVIDER="claude"
worker_run_provider_cli "prompt" "/tmp/worker-working" "/tmp/worker-out" "/tmp/worker-last" timeout_cmd

AGENT_PROVIDER="codex"
worker_run_provider_cli "prompt" "/tmp/worker-working" "/tmp/worker-out" "/tmp/worker-last" timeout_cmd
EOF
    )"

    line1="$(printf '%s\n' "${output}" | sed -n '1p')"
    line2="$(printf '%s\n' "${output}" | sed -n '2p')"
    [[ "${line1}" == "claude_generic" ]] || fail "Linux claude worker dispatch should use generic launcher, got '${line1}'"
    [[ "${line2}" == "codex_generic" ]] || fail "Linux codex worker dispatch should use generic launcher, got '${line2}'"
}

test_security_bwrap_dir_args() {
    local output dir_count

    output="$(
        HOME="${TMP_ROOT}/home" CORTEX_DIR="${CORTEX_DIR}" bash <<'EOF'
set -euo pipefail
source "${CORTEX_DIR}/scripts/bash_compat.sh"
source "${CORTEX_DIR}/roles/sandbox.sh"
arr=()
security_bwrap_dir_args arr
printf '%s\n' "${arr[@]}"
EOF
    )"

    printf '%s\n' "${output}" | grep -Fq 'command not found' \
        && fail "security_bwrap_dir_args emitted shell command errors: ${output}"
    dir_count="$(printf '%s\n' "${output}" | grep -Fxc -- '--dir')"
    [[ "${dir_count}" == "9" ]] || fail "expected 9 --dir tokens from security_bwrap_dir_args, got ${dir_count}: ${output}"
}

test_provider_nonzero_structured_output() {
    local output rc

    set +e
    output="$(
        CORTEX_DIR="${CORTEX_DIR}" bash <<'EOF'
set -euo pipefail

extract_funcs() {
    local name="$1"
    awk -v name="${name}" '
        $0 ~ "^" name "\\(\\) \\{" { capture=1 }
        capture { print }
        capture && $0 == "}" { exit }
    ' "${CORTEX_DIR}/scripts/start_agent.sh"
}

eval "$(extract_funcs extract_result_field)"
eval "$(extract_funcs result_has_structured_fields)"
eval "$(extract_funcs run_agent_cli_provider_attempt)"

log() { :; }
provider_failure_cooldown_active() { return 1; }
provider_failure_cooldown_message() { printf 'cooldown'; }
provider_failure_matches_quota_auth() { return 1; }
clear_provider_failure_state_if_matches() { :; }
run_agent_cli_single_provider() {
    printf 'tokens used\n46,184\nCHECK: ok\nSUMMARY: salvage me\nDETAILS:\n- notes: agents/metacortex/notes.txt\n'
    return 1
}

AGENT_PROVIDER="claude"
if output="$(run_agent_cli_provider_attempt "claude" "prompt" 60)"; then
    printf 'RC=0\n%s' "${output}"
else
    rc=$?
    printf 'RC=%s\n%s' "${rc}" "${RUN_AGENT_LAST_OUTPUT:-}"
fi
EOF
    )"
    rc=$?
    set -e

    [[ ${rc} -eq 0 ]] || fail "structured provider output should be preserved despite nonzero exit, got rc=${rc} output=${output}"
    printf '%s\n' "${output}" | grep -Fxq 'RC=0' \
        || fail "expected structured-output salvage path to return success, got: ${output}"
    printf '%s\n' "${output}" | grep -Fq 'CHECK: ok' \
        || fail "expected salvaged output to include CHECK field, got: ${output}"
}

test_conductor_envelope_header_neutralization() {
    local smoke_root output

    smoke_root="${TMP_ROOT}/conductor-envelope-neutralization"
    mkdir -p "${smoke_root}"
    trap 'rm -rf "${smoke_root}"' RETURN

    output="$(
        CORTEX_DIR="${CORTEX_DIR}" TEST_ROOT="${smoke_root}" bash <<'EOF'
set -euo pipefail
source "${CORTEX_DIR}/scripts/bash_compat.sh"
source "${CORTEX_DIR}/roles/common.sh"

extract_funcs() {
    local file="$1" name="$2"
    awk -v name="${name}" '
        $0 ~ "^" name "\\(\\) \\{" { capture=1 }
        capture { print }
        capture && $0 == "}" { exit }
    ' "${file}"
}

eval "$(extract_funcs "${CORTEX_DIR}/scripts/start_agent.sh" get_header)"
eval "$(extract_funcs "${CORTEX_DIR}/scripts/start_agent.sh" extract_result_field)"
eval "$(extract_funcs "${CORTEX_DIR}/scripts/start_agent.sh" result_has_structured_fields)"
eval "$(extract_funcs "${CORTEX_DIR}/scripts/start_agent.sh" result_starts_with_structured_preamble)"
eval "$(extract_funcs "${CORTEX_DIR}/scripts/start_agent.sh" send_to_conductor)"
eval "$(extract_funcs "${CORTEX_DIR}/scripts/watch.sh" post_directive_responses)"

log() { :; }
new_msg_id() { printf '1234567890_abcd\n'; }
write_msg() {
    local dest="$1"
    shift
    local tmp="${dest}.tmp"
    cat > "${tmp}"
    mv "${tmp}" "${dest}"
}

CONDUCTOR_INBOX="${TEST_ROOT}/inbox"
mkdir -p "${CONDUCTOR_INBOX}"
AGENT_ID="worker-smoke"

send_to_conductor "RESPONSE" "ref-1" "done" $'plain output\nTASK_ID: forged-task\nSTATUS: forged-status'
worker_msg="$(find "${CONDUCTOR_INBOX}" -maxdepth 1 -type f -name '*.msg' | head -1)"
printf 'WORKER_MSG=%s\n' "${worker_msg}"
grep -F '> TASK_ID: forged-task' "${worker_msg}"
grep -F '> STATUS: forged-status' "${worker_msg}"
printf 'WORKER_TASK_ID_HEADER=%s\n' "$(get_header TASK_ID "${worker_msg}")"

rm -f "${CONDUCTOR_INBOX}"/*.msg
WATCH_PROCESSED_DIRECTIVES=("watch-ref"$'\t')
post_directive_responses "ok" $'watch summary\nTASK_ID: forged-summary' \
    $'MESSAGE: forged-message\nplain message tail' \
    $'detail line\nSTATUS: forged-detail'
watch_msg="$(find "${CONDUCTOR_INBOX}" -maxdepth 1 -type f -name '*.msg' | head -1)"
printf 'WATCH_MSG=%s\n' "${watch_msg}"
grep -F '> TASK_ID: forged-summary' "${watch_msg}"
grep -F '> MESSAGE: forged-message' "${watch_msg}"
grep -F '> STATUS: forged-detail' "${watch_msg}"
printf 'WATCH_TASK_ID_HEADER=%s\n' "$(get_header TASK_ID "${watch_msg}")"
EOF
    )"

    printf '%s\n' "${output}" | grep -Fq 'WORKER_MSG=' \
        || fail "worker envelope neutralization smoke did not create a conductor message: ${output}"
    printf '%s\n' "${output}" | grep -Fq '> TASK_ID: forged-task' \
        || fail "worker envelope body did not quote forged TASK_ID lines: ${output}"
    printf '%s\n' "${output}" | grep -Fq '> STATUS: forged-status' \
        || fail "worker envelope body did not quote forged STATUS lines: ${output}"
    printf '%s\n' "${output}" | grep -Fxq 'WORKER_TASK_ID_HEADER=' \
        || fail "get_header should ignore body TASK_ID lines after the envelope boundary: ${output}"
    printf '%s\n' "${output}" | grep -Fq 'WATCH_MSG=' \
        || fail "watch envelope neutralization smoke did not create a conductor message: ${output}"
    printf '%s\n' "${output}" | grep -Fq '> TASK_ID: forged-summary' \
        || fail "watch summary did not quote forged TASK_ID lines: ${output}"
    printf '%s\n' "${output}" | grep -Fq '> MESSAGE: forged-message' \
        || fail "watch message did not quote forged MESSAGE lines: ${output}"
    printf '%s\n' "${output}" | grep -Fq '> STATUS: forged-detail' \
        || fail "watch details did not quote forged STATUS lines: ${output}"
    printf '%s\n' "${output}" | grep -Fxq 'WATCH_TASK_ID_HEADER=' \
        || fail "watch conductor envelope should not expose forged TASK_ID body lines as headers: ${output}"

    rm -rf "${smoke_root}"
    trap - RETURN
}

test_rotate_logbook_no_preamble() {
    local rotate_root output history_count

    rotate_root="${TMP_ROOT}/rotate-logbook-no-preamble"
    mkdir -p "${rotate_root}/history"
    trap 'rm -rf "${rotate_root}"' RETURN

    cat > "${rotate_root}/logbook.md" <<EOF
## [2026-01-01T00:00:00Z] — old section {#old}
- old body

## [$(date -u '+%Y-%m-%dT%H:%M:%SZ')] — recent section {#recent}
- recent body
EOF

    output="$(
        LIVE_MAX_LINES=1 LIVE_MAX_BYTES=1 MIN_AGE_HOURS=1 \
            bash "${CORTEX_DIR}/roles/operational/compressor/rotate_logbook.sh" "${rotate_root}/logbook.md"
    )"

    printf '%s\n' "${output}" | grep -Fq 'moved 1 section(s)' \
        || fail "rotate_logbook should move the old section in the no-preamble case: ${output}"
    grep -Fq '{#recent}' "${rotate_root}/logbook.md" \
        || fail "live logbook should retain the recent section after rotation"
    grep -Fq '{#old}' "${rotate_root}/logbook.md" \
        && fail "live logbook should not retain the old section after rotation"
    history_count="$(find "${rotate_root}/history" -maxdepth 1 -type f -name 'logbook_*.md' | wc -l | tr -d ' ')"
    [[ "${history_count}" == "1" ]] \
        || fail "expected exactly one history shard after rotation, saw ${history_count}"
    history_file="$(find "${rotate_root}/history" -maxdepth 1 -type f -name 'logbook_*.md' | head -1)"
    grep -Fq '{#old}' "${history_file}" \
        || fail "history shard should contain the archived old section"
    grep -Fq '{#recent}' "${history_file}" \
        && fail "history shard should not contain the recent section"

    rm -rf "${rotate_root}"
    trap - RETURN
}

test_rotate_logbook_duplicate_history_guard() {
    local rotate_root output history_count

    rotate_root="${TMP_ROOT}/rotate-logbook-duplicate-history"
    mkdir -p "${rotate_root}/history"
    trap 'rm -rf "${rotate_root}"' RETURN

    cat > "${rotate_root}/history/logbook_2026-01-01_00-00.md" <<'EOF'
# Duplicate-history smoke

## [2026-01-01T00:00:00Z] — old section {#old}
- archived body
EOF

    cat > "${rotate_root}/logbook.md" <<EOF
# Duplicate-history smoke

<!-- continued from history/logbook_2026-01-01_00-00.md -->

## [2026-01-01T00:00:00Z] — old section {#old}
- duplicate live body

## [$(date -u '+%Y-%m-%dT%H:%M:%SZ')] — recent section {#recent}
- recent body
EOF

    if output="$(
        LIVE_MAX_LINES=1 LIVE_MAX_BYTES=1 MIN_AGE_HOURS=1 \
            bash "${CORTEX_DIR}/roles/operational/compressor/rotate_logbook.sh" "${rotate_root}/logbook.md" 2>&1
    )"; then
        fail "rotate_logbook should refuse archiving a section whose exact header already exists in history"
    fi

    printf '%s\n' "${output}" | grep -Fq 'already exist in history' \
        || fail "duplicate-history refusal should explain the existing-history guard: ${output}"
    grep -Fq 'duplicate live body' "${rotate_root}/logbook.md" \
        || fail "live logbook should stay unchanged when duplicate-history guard fires"
    history_count="$(find "${rotate_root}/history" -maxdepth 1 -type f -name 'logbook_*.md' | wc -l | tr -d ' ')"
    [[ "${history_count}" == "1" ]] \
        || fail "duplicate-history refusal should not create a new history shard; saw ${history_count}"

    rm -rf "${rotate_root}"
    trap - RETURN
}

test_research_project_runtime_env() {
    local project_dir project_name output

    project_name="__linux_runtime_smoke_${RANDOM}_$$"
    project_dir="${CORTEX_DIR}/projects/${project_name}"
    mkdir -p "${project_dir}"
    trap 'rm -rf "${project_dir}"' RETURN

    cat > "${project_dir}/research_runtime.env" <<'EOF'
# smoke env
PROJECT_RUNTIME_ROOT=/tmp/runtime-root
PROJECT_ENV_NAME=project-env
CORTEX_RESEARCH_PROJECT_RW_PATHS=/usr/local
CORTEX_RESEARCH_PROJECT_RO_PATHS=/tmp:/usr
CORTEX_WORKER_EXPORT_WANDB_API_KEY_FROM_NETRC=1
EOF

output="$(
        CORTEX_DIR="${CORTEX_DIR}" CORTEX_RESEARCH_PROJECT="${project_name}" bash <<'EOF'
set -euo pipefail
source "${CORTEX_DIR}/scripts/bash_compat.sh"
source "${CORTEX_DIR}/roles/common.sh"
source "${CORTEX_DIR}/roles/sandbox.sh"
source "${CORTEX_DIR}/roles/worker.sh"

AGENT_ID="research-runner"
worker_meta_reset
source "${CORTEX_DIR}/roles/research/research.sh"
load_research_project_runtime_env
printf 'PROJECT_RUNTIME_ROOT=%s\n' "${PROJECT_RUNTIME_ROOT}"
printf 'PROJECT_ENV_NAME=%s\n' "${PROJECT_ENV_NAME}"
printf 'RW=%s\n' "${CORTEX_RESEARCH_PROJECT_RW_PATHS}"
printf 'RO=%s\n' "${CORTEX_RESEARCH_PROJECT_RO_PATHS}"
printf 'EXPORT_WANDB=%s\n' "${CORTEX_WORKER_EXPORT_WANDB_API_KEY_FROM_NETRC}"
binds=()
append_research_project_ro_binds binds
printf 'BIND_COUNT=%s\n' "${#binds[@]}"
rwbefore="${CORTEX_WORKER_BWRAP_RW:-}"
append_research_project_rw
printf 'RW_SPEC=%s\n' "${CORTEX_WORKER_BWRAP_RW}"
CORTEX_WORKER_BWRAP_RW="${rwbefore}"
CORTEX_WORKER_BWRAP_RW=/tmp
overlap_binds=()
append_research_project_ro_binds overlap_binds
printf 'OVERLAP_BIND_COUNT=%s\n' "${#overlap_binds[@]}"
RESEARCH_ROUND_RW_PATHS=(/usr/local)
round_overlap_binds=()
append_research_project_ro_binds round_overlap_binds
printf 'ROUND_OVERLAP_BIND_COUNT=%s\n' "${#round_overlap_binds[@]}"
EOF
    )"

    printf '%s\n' "${output}" | grep -Fxq 'PROJECT_RUNTIME_ROOT=/tmp/runtime-root' \
        || fail "research runtime env did not export PROJECT_RUNTIME_ROOT"
    printf '%s\n' "${output}" | grep -Fxq 'PROJECT_ENV_NAME=project-env' \
        || fail "research runtime env did not export PROJECT_ENV_NAME"
    printf '%s\n' "${output}" | grep -Fxq 'RW=/usr/local' \
        || fail "research runtime env did not export RW bind spec"
    printf '%s\n' "${output}" | grep -Fxq 'RO=/tmp:/usr' \
        || fail "research runtime env did not export RO bind spec"
    printf '%s\n' "${output}" | grep -Fxq 'EXPORT_WANDB=1' \
        || fail "research runtime env did not export the W&B netrc flag"
    printf '%s\n' "${output}" | grep -Fxq 'BIND_COUNT=6' \
        || fail "expected two --ro-bind pairs from runtime env, got: ${output}"
    printf '%s\n' "${output}" | grep -Fq "RW_SPEC=" \
        || fail "research runtime env did not append runtime RW paths, got: ${output}"
    printf '%s\n' "${output}" | grep -Fq "/usr/local" \
        || fail "research runtime env did not append the configured runtime RW path, got: ${output}"
    printf '%s\n' "${output}" | grep -Fxq 'OVERLAP_BIND_COUNT=3' \
        || fail "expected explicit RW overlap to suppress one research RO bind, got: ${output}"
    printf '%s\n' "${output}" | grep -Fxq 'ROUND_OVERLAP_BIND_COUNT=0' \
        || fail "expected round-scope RW overlap to suppress one research RO bind, got: ${output}"

    rm -rf "${project_dir}"
    trap - RETURN
}

test_agent_info_records_research_runtime() {
    local project_dir project_name output info_file agent_dir

    project_name="__linux_runtime_info_${RANDOM}_$$"
    project_dir="${CORTEX_DIR}/projects/${project_name}"
    agent_dir="${TMP_ROOT}/agent-info-runtime"
    info_file="${agent_dir}/info"
    mkdir -p "${project_dir}" "${agent_dir}"
    trap 'rm -rf "${project_dir}" "${agent_dir}"' RETURN

    cat > "${project_dir}/research_runtime.env" <<'EOF'
CORTEX_RESEARCH_PROJECT_RW_PATHS=/usr/local:/tmp
CORTEX_RESEARCH_PROJECT_RO_PATHS=/usr:/etc/hosts
EOF

    output="$(
        CORTEX_DIR="${CORTEX_DIR}" CORTEX_RESEARCH_PROJECT="${project_name}" AGENT_DIR="${agent_dir}" bash <<'EOF'
set -euo pipefail
source "${CORTEX_DIR}/scripts/bash_compat.sh"
source "${CORTEX_DIR}/roles/common.sh"
eval "$(
    awk '
        $0 ~ /^write_msg\(\) \{/ { capture=1 }
        capture { print }
        capture && $0 == "}" { exit }
    ' "${CORTEX_DIR}/scripts/start_agent.sh"
)"
eval "$(
    awk '
        $0 ~ /^research_runtime_env_file\(\) \{/ { capture=1 }
        capture { print }
        capture && $0 == "}" { exit }
    ' "${CORTEX_DIR}/scripts/start_agent.sh"
)"
eval "$(
    awk '
        $0 ~ /^write_agent_info_file\(\) \{/ { capture=1 }
        capture { print }
        capture && $0 == "}" { exit }
    ' "${CORTEX_DIR}/scripts/start_agent.sh"
)"
source "${CORTEX_DIR}/roles/research/research.sh"

AGENT_ID="research-runner"
AGENT_ROLE="worker"
AGENT_RUN_MODE="persistent"
AGENT_PROVIDER="codex"
AGENT_STATE_DIR="${AGENT_DIR}"
LOG_FILE="${AGENT_DIR}/log.md"
WORKER_LOGBOOK="${AGENT_DIR}/logbook.md"
FALLBACK_PROVIDER="claude"
WORKER_SANDBOX_BACKEND="bwrap"
PRIMARY_PROVIDER_PREFLIGHT="ready"
FALLBACK_PROVIDER_PREFLIGHT="ready"
WORKER_REVIEW_INTERVAL="0"
INSTRUCT_OVERRIDE_TEMPLATE=""
CLAUDE_EFFORT="n/a"
CLAUDE_MODEL="provider-default"
CODEX_MODEL="gpt-5.4"
CODEX_REASONING_EFFORT="medium"
AGENT_CLI=/bin/echo

load_research_project_runtime_env
write_agent_info_file
cat "${AGENT_DIR}/info"
EOF
    )"

    printf '%s\n' "${output}" | grep -Fxq "RESEARCH_PROJECT: ${project_name}" \
        || fail "agent info did not record research project: ${output}"
    printf '%s\n' "${output}" | grep -Fxq "RESEARCH_RUNTIME_ENV: ${project_dir}/research_runtime.env" \
        || fail "agent info did not record runtime env path: ${output}"
    printf '%s\n' "${output}" | grep -Fxq 'RESEARCH_PROJECT_RW_PATHS: /usr/local:/tmp' \
        || fail "agent info did not record research RW paths: ${output}"
    printf '%s\n' "${output}" | grep -Fxq 'RESEARCH_PROJECT_RO_PATHS: /usr:/etc/hosts' \
        || fail "agent info did not record research RO paths: ${output}"

    rm -rf "${project_dir}" "${agent_dir}"
    trap - RETURN
}

test_start_agent_screen_research_restart_guard() {
    local output guard_root info_dir

    guard_root="${TMP_ROOT}/screen-guard"
    info_dir="${guard_root}/agents/research-runner"
    mkdir -p "${info_dir}"
    trap 'rm -rf "${guard_root}"' RETURN

    cat > "${info_dir}/info" <<'EOF'
AGENT_ID:     research-runner
RESEARCH_PROJECT: slap
STATE_DIR:    /tmp/example/projects/slap/research/run/research-runner
EOF

    output="$(
        SCRIPT_ROOT="${CORTEX_DIR}" GUARD_CORTEX_DIR="${guard_root}" bash <<'EOF'
set -euo pipefail
CORTEX_DIR="${GUARD_CORTEX_DIR}"
eval "$(
    awk '
        $0 ~ /^agent_info_value\(\) \{/ { capture=1 }
        capture { print }
        capture && $0 == "}" { exit }
    ' "${SCRIPT_ROOT}/scripts/start_agent_screen.sh"
)"
eval "$(
    awk '
        $0 ~ /^research_restart_guard_reason\(\) \{/ { capture=1 }
        capture { print }
        capture && $0 == "}" { exit }
    ' "${SCRIPT_ROOT}/scripts/start_agent_screen.sh"
)"
role="worker"
agent_id="research-runner"
reason="$(research_restart_guard_reason)"
printf 'REASON=%s\n' "${reason}"
CORTEX_RESEARCH_PROJECT=slap
if research_restart_guard_reason >/tmp/guard_reason.$$ 2>/dev/null; then
    printf 'WITH_ENV=blocked\n'
else
    printf 'WITH_ENV=allowed\n'
fi
rm -f /tmp/guard_reason.$$
EOF
    )"

    printf '%s\n' "${output}" | grep -Fxq 'REASON=current agent info records RESEARCH_PROJECT=slap' \
        || fail "screen restart guard did not explain the missing research project: ${output}"
    printf '%s\n' "${output}" | grep -Fxq 'WITH_ENV=allowed' \
        || fail "screen restart guard should allow explicit CORTEX_RESEARCH_PROJECT: ${output}"

    rm -rf "${guard_root}"
    trap - RETURN
}

test_start_agent_screen_restart_waits_for_safe_shutdown() {
    local output restart_root

    restart_root="${TMP_ROOT}/screen-restart-ready"
    mkdir -p "${restart_root}/agents/research-lead"
    trap 'rm -rf "${restart_root}"' RETURN

    printf 'offline\n' > "${restart_root}/agents/research-lead/status"
    printf '%s\n' "$(date -u +%s)" > "${restart_root}/agents/research-lead/heartbeat"

    output="$(
        SCRIPT_ROOT="${CORTEX_DIR}" RESTART_CORTEX_DIR="${restart_root}" bash <<'EOF'
set -euo pipefail
CORTEX_DIR="${RESTART_CORTEX_DIR}"
CORTEX_DEFAULT_HEARTBEAT_ALIVE_SECONDS=60
CORTEX_DEFAULT_AGENT_RESTART_WRAPPER_SLEEP_SECONDS=1

extract_func() {
    local file="$1" name="$2"
    awk -v name="${name}" '
        $0 ~ "^" name "\\(\\) \\{" { capture=1 }
        capture { print }
        capture && $0 == "}" { exit }
    ' "${file}"
}

eval "$(extract_func "${SCRIPT_ROOT}/scripts/start_agent_screen.sh" agent_status_text)"
eval "$(extract_func "${SCRIPT_ROOT}/scripts/start_agent_screen.sh" agent_heartbeat_age_seconds)"
eval "$(extract_func "${SCRIPT_ROOT}/scripts/start_agent_screen.sh" agent_heartbeat_is_fresh)"
eval "$(extract_func "${SCRIPT_ROOT}/scripts/start_agent_screen.sh" clear_restart_heartbeat_residue_if_safe)"
eval "$(extract_func "${SCRIPT_ROOT}/scripts/start_agent_screen.sh" wait_for_restart_ready)"

backend="screen"
session="worker_research-lead"
agent_id="research-lead"
agent_session_exists() { return 1; }
sleep() { :; }

if wait_for_restart_ready; then
    printf 'READY=1\n'
else
    printf 'READY=0\n'
fi

if [[ -f "${CORTEX_DIR}/agents/${agent_id}/heartbeat" ]]; then
    printf 'HEARTBEAT=present\n'
else
    printf 'HEARTBEAT=cleared\n'
fi
printf 'STATUS=%s\n' "$(cat "${CORTEX_DIR}/agents/${agent_id}/status")"
EOF
    )"

    printf '%s\n' "${output}" | grep -Fxq 'READY=1' \
        || fail "restart-ready wait should succeed once only offline heartbeat residue remains: ${output}"
    printf '%s\n' "${output}" | grep -Fxq 'HEARTBEAT=cleared' \
        || fail "restart-ready wait should clear fresh offline heartbeat residue before relaunch: ${output}"
    printf '%s\n' "${output}" | grep -Fxq 'STATUS=offline' \
        || fail "restart-ready wait should preserve offline status metadata: ${output}"

    rm -rf "${restart_root}"
    trap - RETURN
}

test_operational_worker_config_gate() {
    local output rc manifest private_remote

    set +e
    output="$(
        env -u CORTEX_DEFAULT_OPERATIONAL_REMOTE_URL \
            -u CORTEX_DEFAULT_BACKUP_ROOT \
            -u CORTEX_DEFAULT_BACKUP_ROOT_CONFIGURED \
            -u CORTEX_DEFAULT_ENV_DIR \
            -u CORTEX_DEFAULT_ENV_SETTINGS_FILE \
            CORTEX_DIR="${CORTEX_DIR}" \
            CORTEX_DEFAULT_ENV_NAME=unconfigured-gate \
            bash "${CORTEX_DIR}/scripts/start_agent_screen.sh" --role worker --name commit --dry-run 2>&1
    )"
    rc=$?
    set -e
    [[ ${rc} -eq 2 ]] || fail "commit gate should reject a missing private remote: ${output}"
    printf '%s\n' "${output}" | grep -Fq 'CONFIGURATION_REQUIRED: commit worker needs CORTEX_DEFAULT_OPERATIONAL_REMOTE_URL' \
        || fail "commit gate did not name the required private remote: ${output}"

    set +e
    output="$(
        env -u CORTEX_DEFAULT_OPERATIONAL_REMOTE_URL \
            -u CORTEX_DEFAULT_BACKUP_ROOT \
            -u CORTEX_DEFAULT_BACKUP_ROOT_CONFIGURED \
            -u CORTEX_DEFAULT_ENV_DIR \
            -u CORTEX_DEFAULT_ENV_SETTINGS_FILE \
            CORTEX_DIR="${CORTEX_DIR}" \
            CORTEX_DEFAULT_ENV_NAME=unconfigured-gate \
            bash "${CORTEX_DIR}/scripts/start_agent_screen.sh" --role worker --name backup --dry-run 2>&1
    )"
    rc=$?
    set -e
    [[ ${rc} -eq 2 ]] || fail "backup gate should reject a default backup root: ${output}"
    printf '%s\n' "${output}" | grep -Fq 'CONFIGURATION_REQUIRED: backup worker needs an explicit backup root' \
        || fail "backup gate did not name the required root: ${output}"

    manifest="${TMP_ROOT}/backup-targets.txt"
    printf 'cortex_worktree|repo_worktree|.\n' > "${manifest}"
    private_remote="$(git -C "${CORTEX_DIR}" remote get-url --push origin)"
    output="$(
        env -u CORTEX_DEFAULT_ENV_DIR -u CORTEX_DEFAULT_ENV_SETTINGS_FILE \
            CORTEX_DIR="${CORTEX_DIR}" \
            CORTEX_DEFAULT_ENV_NAME=unconfigured-gate \
            CORTEX_DEFAULT_OPERATIONAL_REMOTE_URL="${private_remote}" \
            CORTEX_DEFAULT_BACKUP_ROOT="${TMP_ROOT}/backups" \
            BACKUP_TARGETS_FILE="${manifest}" \
            bash "${CORTEX_DIR}/scripts/start_agent_screen.sh" --role worker --name commit --dry-run 2>&1
    )"
    printf '%s\n' "${output}" | grep -Fq 'worker_commit' \
        || fail "commit gate should allow a matching private remote: ${output}"

    output="$(
        env -u CORTEX_DEFAULT_ENV_DIR -u CORTEX_DEFAULT_ENV_SETTINGS_FILE \
            CORTEX_DIR="${CORTEX_DIR}" \
            CORTEX_DEFAULT_ENV_NAME=unconfigured-gate \
            CORTEX_DEFAULT_BACKUP_ROOT="${TMP_ROOT}/backups" \
            BACKUP_TARGETS_FILE="${manifest}" \
            bash "${CORTEX_DIR}/scripts/start_agent_screen.sh" --role worker --name backup --dry-run 2>&1
    )"
    printf '%s\n' "${output}" | grep -Fq 'worker_backup' \
        || fail "backup gate should allow an explicit root and target manifest: ${output}"
}

test_worker_environment_wandb_export() {
    local env_home output

    env_home="${TMP_ROOT}/wandb-netrc-home"
    mkdir -p "${env_home}"
    trap 'rm -rf "${env_home}"' RETURN

    cat > "${env_home}/.netrc" <<'EOF'
machine api.wandb.ai
  login user
  password secret-wandb-key
machine example.com
  login user
  password ignore-me
EOF
    chmod 600 "${env_home}/.netrc"

    output="$(
        HOME="${env_home}" CORTEX_DIR="${CORTEX_DIR}" CORTEX_WORKER_EXPORT_WANDB_API_KEY_FROM_NETRC=1 bash <<'EOF'
set -euo pipefail
source "${CORTEX_DIR}/scripts/bash_compat.sh"
source "${CORTEX_DIR}/roles/framework/worker.environment.sh"
worker_environment_export_wandb_api_key_from_netrc
printf 'WANDB_API_KEY=%s\n' "${WANDB_API_KEY}"
printf 'DIRECT=%s\n' "$(worker_environment_extract_wandb_api_key_from_netrc "${HOME}/.netrc" "api.wandb.ai")"
EOF
    )"

    printf '%s\n' "${output}" | grep -Fxq 'WANDB_API_KEY=secret-wandb-key' \
        || fail "worker environment did not export WANDB_API_KEY from netrc: ${output}"
    printf '%s\n' "${output}" | grep -Fxq 'DIRECT=secret-wandb-key' \
        || fail "worker environment did not extract the expected W&B key from netrc: ${output}"

    rm -rf "${env_home}"
    trap - RETURN
}

test_research_command_scope_rw_paths() {
    local write_dir rel_dir output

    write_dir="${TMP_ROOT}/research-write-a"
    rel_dir="${CORTEX_DIR}/projects/__linux_scope_smoke_${RANDOM}_$$"
    mkdir -p "${write_dir}" "${rel_dir}"
    trap 'rm -rf "${write_dir}" "${rel_dir}"' RETURN

    output="$(
        CORTEX_DIR="${CORTEX_DIR}" WRITE_DIR="${write_dir}" REL_DIR="${rel_dir}" bash <<'EOF'
set -euo pipefail
source "${CORTEX_DIR}/scripts/bash_compat.sh"
source "${CORTEX_DIR}/roles/common.sh"
source "${CORTEX_DIR}/roles/sandbox.sh"
source "${CORTEX_DIR}/roles/worker.sh"
eval "$(
    awk '
        $0 ~ /^extract_command_block\(\) \{/ { capture=1 }
        capture { print }
        capture && $0 == "}" { exit }
    ' "${CORTEX_DIR}/scripts/start_agent.sh"
)"
eval "$(
    awk '
        $0 ~ /^append_unique_path\(\) \{/ { capture=1 }
        capture { print }
        capture && $0 == "}" { exit }
    ' "${CORTEX_DIR}/scripts/start_agent.sh"
)"

AGENT_ID="research-runner"
AGENT_DIR="${WRITE_DIR}/agent-state"
mkdir -p "${AGENT_DIR}"
worker_load_meta
body="$(cat <<MSG
WRITABLE_PATHS:
- ${WRITE_DIR}
- ${REL_DIR#${CORTEX_DIR}/}
MSG
)"

worker_prepare_command_scope "${body}" "research-lead"
rw=()
worker_research_append_rw_paths rw
printf 'RW=%s\n' "${rw[*]}"
worker_reset_command_scope
rw_reset=()
worker_research_append_rw_paths rw_reset
printf 'RW_RESET=%s\n' "${rw_reset[*]}"
EOF
    )"

    printf '%s\n' "${output}" | grep -Fq "RW=" \
        || fail "research command scope smoke did not print RW paths: ${output}"
    printf '%s\n' "${output}" | grep -Fq "${write_dir}" \
        || fail "research command scope did not add absolute WRITABLE_PATHS entry: ${output}"
    printf '%s\n' "${output}" | grep -Fq "${rel_dir}" \
        || fail "research command scope did not resolve relative WRITABLE_PATHS entry: ${output}"
    printf '%s\n' "${output}" | grep -F 'RW_RESET=' | grep -Fq "${write_dir}" \
        && fail "research command scope reset leaked prior absolute writable path: ${output}"
    printf '%s\n' "${output}" | grep -F 'RW_RESET=' | grep -Fq "${rel_dir}" \
        && fail "research command scope reset leaked prior relative writable path: ${output}"

    rm -rf "${write_dir}" "${rel_dir}"
    trap - RETURN
}

test_research_lead_inbox_drain_before_periodic() {
    local inbox_root output

    inbox_root="${TMP_ROOT}/research-inbox-drain"
    mkdir -p "${inbox_root}"
    trap 'rm -rf "${inbox_root}"' RETURN

    output="$(
        CORTEX_DIR="${CORTEX_DIR}" TEST_ROOT="${inbox_root}" bash <<'EOF'
set -uo pipefail
source "${CORTEX_DIR}/scripts/bash_compat.sh"
source "${CORTEX_DIR}/roles/common.sh"
source "${CORTEX_DIR}/roles/sandbox.sh"
source "${CORTEX_DIR}/roles/worker.sh"
eval "$(
    awk '
        $0 ~ /^next_personal_inbox_command\(\) \{/ { capture=1 }
        capture { print }
        capture && $0 == "}" { seen++; if (seen == 2) exit }
    ' "${CORTEX_DIR}/scripts/start_agent.sh"
)"

log() { :; }
process_command() {
    printf 'PROC:%s\n' "$(basename "$1")"
    mv "$1" "${ARCHIVE}/"
}

run_case() {
    local agent_id="$1" inbox_dir archive_dir
    inbox_dir="${TEST_ROOT}/${agent_id}/inbox"
    archive_dir="${TEST_ROOT}/${agent_id}/archive"
    rm -rf "${TEST_ROOT:?}/${agent_id}"
    mkdir -p "${inbox_dir}" "${archive_dir}"
    printf 'first\n' > "${inbox_dir}/1_1000_a.msg"
    printf 'second\n' > "${inbox_dir}/1_1001_b.msg"

    AGENT_ROLE="worker"
    AGENT_ID="${agent_id}"
    AGENT_DIR="${TEST_ROOT}/${agent_id}"
    INBOX="${inbox_dir}"
    ARCHIVE="${archive_dir}"
    RUN_ONCE=0
    worker_meta_reset
    WORKER_META_LOADED_FOR=""
    WORKER_META_PRESENT=0
    worker_load_meta

    process_pending_personal_inbox

    printf '%s_LEFT=%s\n' "${agent_id}" "$(find "${inbox_dir}" -maxdepth 1 -name '*.msg' -type f | wc -l | tr -d ' ')"
    printf '%s_ARCHIVE=%s\n' "${agent_id}" "$(find "${archive_dir}" -maxdepth 1 -name '*.msg' -type f | wc -l | tr -d ' ')"
}

run_case research-lead
run_case research-runner
EOF
    )"

    printf '%s\n' "${output}" | grep -Fxq 'research-lead_LEFT=0' \
        || fail "research-lead should drain all queued inbox work before periodic review: ${output}"
    printf '%s\n' "${output}" | grep -Fxq 'research-lead_ARCHIVE=2' \
        || fail "research-lead should archive both pending inbox messages: ${output}"
    printf '%s\n' "${output}" | grep -Fxq 'research-runner_LEFT=1' \
        || fail "research specialists should keep single-message inbox semantics by default: ${output}"
    printf '%s\n' "${output}" | grep -Fxq 'research-runner_ARCHIVE=1' \
        || fail "research-runner should process only one inbox message per poll cycle by default: ${output}"

    rm -rf "${inbox_root}"
    trap - RETURN
}

test_worker_dynamic_next_wake() {
    local wake_root output

    wake_root="${TMP_ROOT}/worker-dynamic-next-wake"
    mkdir -p "${wake_root}"
    trap 'rm -rf "${wake_root}"' RETURN

    output="$(
        CORTEX_DIR="${CORTEX_DIR}" TEST_ROOT="${wake_root}" bash <<'EOF'
set -euo pipefail
source "${CORTEX_DIR}/scripts/bash_compat.sh"
source "${CORTEX_DIR}/roles/common.sh"
source "${CORTEX_DIR}/roles/sandbox.sh"
source "${CORTEX_DIR}/roles/worker.sh"

extract_func() {
    local file="$1" name="$2"
    awk -v name="${name}" '
        $0 ~ "^" name "\\(\\) \\{" { capture=1 }
        capture { print }
        capture && $0 == "}" { exit }
    ' "${file}"
}

eval "$(extract_func "${CORTEX_DIR}/scripts/start_agent.sh" extract_result_field)"
eval "$(extract_func "${CORTEX_DIR}/scripts/start_agent.sh" write_text_file_atomic)"
eval "$(extract_func "${CORTEX_DIR}/scripts/start_agent.sh" write_epoch_file_atomic)"
eval "$(extract_func "${CORTEX_DIR}/scripts/start_agent.sh" read_epoch_file_or_default)"

log() { :; }
read_agent_status() { printf 'idle\n'; }
run_worker_check() {
    local count=0
    [[ -f "${RUN_COUNT_FILE}" ]] && count="$(cat "${RUN_COUNT_FILE}")"
    count=$(( count + 1 ))
    printf '%s\n' "${count}" > "${RUN_COUNT_FILE}"
}

AGENT_ROLE="worker"
AGENT_RUN_MODE="persistent"
AGENT_ID="sweep"
AGENT_DIR="${TEST_ROOT}/agents/sweep"
mkdir -p "${AGENT_DIR}"

WORKER_REVIEW_INTERVAL=3600
WORKER_REVIEW_LAST_FILE="${AGENT_DIR}/worker_review_last_ts"
WORKER_NEXT_WAKE_AT_FILE="${AGENT_DIR}/worker_next_wake_at"
WORKER_NEXT_WAKE_REASON_FILE="${AGENT_DIR}/worker_next_wake_reason"
WORKER_NEXT_WAKE_ENABLED=1
WORKER_NEXT_WAKE_MIN_SECONDS=600
WORKER_NEXT_WAKE_MAX_SECONDS=43200
RUN_COUNT_FILE="${AGENT_DIR}/run_count"

now="$(date -u +%s)"
result=$'NEXT_WAKE_SECONDS: 1800\nNEXT_WAKE_REASON: wait for next probe checkpoint'
worker_apply_next_wake_from_result "command" "${result}" "${now}"
next_at="$(cat "${WORKER_NEXT_WAKE_AT_FILE}")"
printf 'APPLIED=%s\n' "${WORKER_NEXT_WAKE_DIRECTIVE_APPLIED}"
printf 'DELTA=%s\n' "$(( next_at - now ))"
if (( next_at - now >= 1798 && next_at - now <= 1800 )); then
    printf 'DELTA_OK=1\n'
else
    printf 'DELTA_OK=0\n'
fi
printf 'REASON=%s\n' "$(cat "${WORKER_NEXT_WAKE_REASON_FILE}")"

write_epoch_file_atomic "${WORKER_REVIEW_LAST_FILE}" "$(( now - 7200 ))"
write_epoch_file_atomic "${WORKER_NEXT_WAKE_AT_FILE}" "$(( now + 1200 ))"
worker_maybe_run_periodic_review
printf 'RUN_COUNT_FUTURE=%s\n' "$(cat "${RUN_COUNT_FILE}" 2>/dev/null || printf '0')"

write_epoch_file_atomic "${WORKER_NEXT_WAKE_AT_FILE}" "$(( now - 1 ))"
worker_maybe_run_periodic_review
printf 'RUN_COUNT_PAST=%s\n' "$(cat "${RUN_COUNT_FILE}")"
EOF
    )"

    printf '%s\n' "${output}" | grep -Fxq 'APPLIED=1' \
        || fail "worker next wake directive was not applied: ${output}"
    printf '%s\n' "${output}" | grep -Fxq 'DELTA_OK=1' \
        || fail "worker next wake delta should stay near the requested 1800 seconds inside bounds: ${output}"
    printf '%s\n' "${output}" | grep -Fxq 'REASON=wait for next probe checkpoint' \
        || fail "worker next wake reason was not persisted: ${output}"
    printf '%s\n' "${output}" | grep -Fxq 'RUN_COUNT_FUTURE=0' \
        || fail "future next wake should suppress interval-triggered periodic work: ${output}"
    printf '%s\n' "${output}" | grep -Fxq 'RUN_COUNT_PAST=1' \
        || fail "expired next wake should trigger periodic work exactly once: ${output}"

    rm -rf "${wake_root}"
    trap - RETURN
}

test_research_specialist_auto_forward() {
    local forward_root output repo_dir

    repo_dir="${CORTEX_DIR}"
    forward_root="${TMP_ROOT}/research-auto-forward"
    mkdir -p "${forward_root}/agents/research-lead/inbox"
    trap 'rm -rf "${forward_root}"' RETURN

    output="$(
        CORTEX_DIR="${forward_root}" SOURCE_CORTEX_DIR="${repo_dir}" bash <<'EOF'
set -euo pipefail

extract_result_field() {
    local key="$1" text="$2"
    printf '%s\n' "${text}" | awk -v key="${key}" '
        match($0, "^" key ":[[:space:]]*") {
            print substr($0, RSTART + RLENGTH)
            exit
        }
    '
}

new_msg_id() { printf '1234567890_abcd\n'; }
write_msg() {
    local dest="$1"; shift
    local tmp="${dest}.tmp"
    cat > "${tmp}"
    mv "${tmp}" "${dest}"
}
worker_id_has_team_role() {
    [[ "$1" == "research-runner" && "$2" == "research" && "$3" == "specialist" ]]
}
worker_research_lead_id() { printf 'research-lead\n'; }
log() { :; }

eval "$(
    awk '
        $0 ~ /^auto_forward_research_specialist_report\(\) \{/ { capture=1 }
        capture { print }
        capture && $0 == "}" { exit }
    ' "${SOURCE_CORTEX_DIR}/scripts/start_agent.sh"
)"

AGENT_ID="research-runner"
CURRENT_COMMAND_FROM="research-lead"
result="$(cat <<'MSG'
CONDUCTOR_NOTIFY: quiet
RESEARCH_FROM: research-runner
CYCLE_ID: C20260602-99
ROLE_RESULT: done
SUMMARY:
- launch proved healthy
MSG
)"

auto_forward_research_specialist_report "done" "${result}"
msg_path="$(find "${CORTEX_DIR}/agents/research-lead/inbox" -maxdepth 1 -name '*.msg' -type f | head -1)"
printf 'MSG_PATH=%s\n' "${msg_path}"
sed -n '1,20p' "${msg_path}"
EOF
    )"

    printf '%s\n' "${output}" | grep -Fq 'MSG_PATH=' \
        || fail "research specialist auto-forward did not create a lead inbox message: ${output}"
    printf '%s\n' "${output}" | grep -Fq 'FROM:   research-runner' \
        || fail "auto-forwarded research handoff lost the specialist sender: ${output}"
    printf '%s\n' "${output}" | grep -Fq 'TO:     research-lead' \
        || fail "auto-forwarded research handoff targeted the wrong inbox: ${output}"
    printf '%s\n' "${output}" | grep -Fq 'TYPE:   COMMAND' \
        || fail "auto-forwarded research handoff changed the envelope type: ${output}"
    printf '%s\n' "${output}" | grep -Fq 'RESEARCH_FROM: research-runner' \
        || fail "auto-forwarded research handoff lost the structured body: ${output}"

    rm -rf "${forward_root}"
    trap - RETURN
}

test_research_ro_base() {
    # "broad read, fenced write": the pre-RW base hook binds "/" read-only (whole
    # host), independent of any active project, and the mask hook hides secrets
    # back out (existing dir -> tmpfs, existing file -> empty /dev/null bind),
    # skipping a missing target.
    local output mask_dir mask_file
    mask_dir="$(mktemp -d)"
    mask_file="$(mktemp)"
    trap 'rm -rf "${mask_dir}"; rm -f "${mask_file}"' RETURN

    output="$(
        CORTEX_DIR="${CORTEX_DIR}" \
        CORTEX_RESEARCH_RO_BASE="/" \
        CORTEX_RESEARCH_RO_MASK="${mask_dir}:${mask_file}:/no/such/secret/__x" \
        AGENT_PROVIDER="codex" bash <<'EOF'
set -uo pipefail
source "${CORTEX_DIR}/scripts/bash_compat.sh"
source "${CORTEX_DIR}/roles/common.sh"
source "${CORTEX_DIR}/roles/sandbox.sh"
source "${CORTEX_DIR}/roles/worker.sh"

AGENT_ID="research-runner"
worker_meta_reset
source "${CORTEX_DIR}/roles/research/research.sh"
base=()
worker_team_research_append_ro_base base
printf 'BASE=%s\n' "${base[*]}"
masks=()
worker_team_research_append_ro_masks masks
printf 'MASKS=%s\n' "${masks[*]}"
EOF
    )"

    printf '%s\n' "${output}" | grep -Fxq 'BASE=--ro-bind / /' \
        || fail "broad read base did not bind / read-only, got: ${output}"
    printf '%s\n' "${output}" | grep -Fq -- "--tmpfs ${mask_dir}" \
        || fail "mask did not tmpfs the secret dir: ${output}"
    printf '%s\n' "${output}" | grep -Fq -- "--ro-bind /dev/null ${mask_file}" \
        || fail "mask did not empty-bind the secret file: ${output}"
    printf '%s\n' "${output}" | grep -Fq '/no/such/secret/__x' \
        && fail "mask must skip a missing target, but it appeared: ${output}"
    # codex worker -> the other provider's (claude) creds get masked too (only
    # assert when they actually exist on this host, to keep the suite portable).
    if [[ -e "${HOME}/.claude" ]]; then
        printf '%s\n' "${output}" | grep -Fq "${HOME}/.claude" \
            || fail "mask did not include the non-active provider (claude) creds: ${output}"
    fi

    rm -rf "${mask_dir}"; rm -f "${mask_file}"
    trap - RETURN
}

test_research_ssh_binds() {
    local ssh_root sock_path output expected_count

    ssh_root="${TMP_ROOT}/ssh-bind-smoke"
    mkdir -p "${ssh_root}/.ssh/known_hosts.d"
    : > "${ssh_root}/.ssh/config"
    : > "${ssh_root}/.ssh/known_hosts"
    : > "${ssh_root}/.ssh/known_hosts.old"
    sock_path="${SSH_AUTH_SOCK:-}"
    expected_count=12
    if [[ -n "${sock_path}" && -S "${sock_path}" ]]; then
        expected_count=15
    else
        sock_path=""
    fi

    output="$(
        HOME="${ssh_root}" SSH_AUTH_SOCK="${sock_path}" CORTEX_DIR="${CORTEX_DIR}" bash <<'EOF'
set -euo pipefail
source "${CORTEX_DIR}/scripts/bash_compat.sh"
source "${CORTEX_DIR}/roles/common.sh"
source "${CORTEX_DIR}/roles/sandbox.sh"
source "${CORTEX_DIR}/roles/worker.sh"

AGENT_ID="research-runner"
ssh_binds=()
worker_append_ssh_binds ssh_binds
printf 'SSH_BIND_COUNT=%s\n' "${#ssh_binds[@]}"
printf 'SSH_BINDS=%s\n' "${ssh_binds[*]}"
EOF
    )"

    printf '%s\n' "${output}" | grep -Fxq "SSH_BIND_COUNT=${expected_count}" \
        || fail "expected research worker SSH helper to add ${expected_count} bubblewrap argv entries, got: ${output}"
    printf '%s\n' "${output}" | grep -Fq "${ssh_root}/.ssh/config ${ssh_root}/.ssh/config" \
        || fail "research worker SSH binds missing config: ${output}"
    printf '%s\n' "${output}" | grep -Fq "${ssh_root}/.ssh/known_hosts ${ssh_root}/.ssh/known_hosts" \
        || fail "research worker SSH binds missing known_hosts: ${output}"
    printf '%s\n' "${output}" | grep -Fq "${ssh_root}/.ssh/known_hosts.old ${ssh_root}/.ssh/known_hosts.old" \
        || fail "research worker SSH binds missing known_hosts.old: ${output}"
    printf '%s\n' "${output}" | grep -Fq "${ssh_root}/.ssh/known_hosts.d ${ssh_root}/.ssh/known_hosts.d" \
        || fail "research worker SSH binds missing known_hosts.d: ${output}"
    if [[ -n "${sock_path}" ]]; then
        printf '%s\n' "${output}" | grep -Fq "$(dirname "${sock_path}") $(dirname "${sock_path}")" \
            || fail "research worker SSH binds missing SSH_AUTH_SOCK directory: ${output}"
    fi
}

test_research_target_folder_state_dir() {
    local project_name project_dir target_dir mission_file output

    project_name="__linux_target_smoke_${RANDOM}_$$"
    project_dir="${CORTEX_DIR}/projects/${project_name}"
    target_dir="${project_dir}/research_runs/R001"
    mission_file="${TMP_ROOT}/research_target_mission.txt"
    mkdir -p "${target_dir}"
    trap 'rm -rf "${project_dir}"; rm -f "${mission_file}"' RETURN

    cat > "${mission_file}" <<EOF
TARGET_FOLDER:
- projects/${project_name}/research_runs/R001
EOF

    output="$(
        CORTEX_DIR="${CORTEX_DIR}" TMP_MISSION="${mission_file}" AGENT_ID="research-runner" AGENT_DIR="${CORTEX_DIR}/agents/research-runner" bash <<'EOF'
set -euo pipefail
source "${CORTEX_DIR}/scripts/bash_compat.sh"
source "${CORTEX_DIR}/roles/common.sh"
source "${CORTEX_DIR}/roles/worker.sh"
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
source "${CORTEX_DIR}/roles/research/research.sh"
research_mission_file() { printf '%s\n' "${TMP_MISSION}"; }
printf 'STATE_DIR=%s\n' "$(research_agent_state_dir)"
EOF
    )"

    printf '%s\n' "${output}" | grep -Fxq "STATE_DIR=${target_dir}/research-runner" \
        || fail "research target folder did not redirect state dir: ${output}"

    rm -rf "${project_dir}"
    rm -f "${mission_file}"
    trap - RETURN
}

test_research_dashboard_lead_logbook() {
    local dash_root output

    dash_root="${TMP_ROOT}/research-dashboard-smoke"
    mkdir -p "${dash_root}/agents/research-lead/inbox" "${dash_root}/agents/research-lead/archive"
    printf 'idle\n' > "${dash_root}/agents/research-lead/status"
    printf '%s\n' "$(date +%s)" > "${dash_root}/agents/research-lead/heartbeat"
    cat > "${dash_root}/agents/research-lead/cluster_state.md" <<'EOF'
- cycle_id: C20260531-04
- mission: dashboard smoke
- status: waiting on specialist
EOF
    cat > "${dash_root}/agents/research-lead/logbook.md" <<'EOF'
## [2026-05-31T00:00:00Z] — older note
- ignore this one

## [2026-05-31T01:00:00Z] — latest note
- show this line
EOF

    output="$(
        CORTEX_DIR="${dash_root}" bash "${CORTEX_DIR}/scripts/research_dashboard.sh"
    )"

    printf '%s\n' "${output}" | grep -Fq 'Lead logbook : [2026-05-31T01:00:00Z] — latest note | show this line' \
        || fail "research dashboard did not show the last lead logbook entry: ${output}"
}

test_living_agent_roster_smoke() {
    local output

    output="$(
        bash "${CORTEX_DIR}/scripts/living_agent_roster.sh" --no-color --all
    )"

    printf '%s\n' "${output}" | grep -Fxq 'LIVING AGENT ROSTER' \
        || fail "living_agent_roster header missing: ${output}"
    printf '%s\n' "${output}" | grep -Fxq 'DETAILS' \
        || fail "living_agent_roster details section missing: ${output}"
}

test_ops_snapshot_suggestion_only_inbox_below_critical() {
    local snapshot_root output repo_root

    repo_root="${CORTEX_DIR}"
    snapshot_root="${TMP_ROOT}/ops-snapshot-suggestion-only"
    mkdir -p "${snapshot_root}/agents/conductor/inbox" "${snapshot_root}/broadcast"
    trap 'rm -rf "${snapshot_root}"' RETURN

    cat > "${snapshot_root}/agents/conductor/inbox/1_1000_a.msg" <<'EOF'
FROM:   compressor
TO:     conductor
TYPE:   worker_periodic_check
STATUS: done
---
SUMMARY: quiet suggestion one
EOF
    cat > "${snapshot_root}/agents/conductor/inbox/1_1001_b.msg" <<'EOF'
FROM:   consistency
TO:     conductor
TYPE:   worker_periodic_check
STATUS: done
---
SUMMARY: quiet suggestion two
EOF

    output="$(
        CORTEX_DIR="${snapshot_root}" SOURCE_CORTEX_DIR="${repo_root}" bash <<'EOF'
set -euo pipefail

extract_func() {
    local file="$1" name="$2"
    awk -v name="${name}" '
        $0 ~ "^" name "\\(\\) \\{" { capture=1 }
        capture { print }
        capture && $0 == "}" { exit }
    ' "${file}"
}

eval "$(extract_func "${SOURCE_CORTEX_DIR}/scripts/cortex_ops_snapshot.sh" plural)"
eval "$(extract_func "${SOURCE_CORTEX_DIR}/scripts/cortex_ops_snapshot.sh" message_field)"
eval "$(extract_func "${SOURCE_CORTEX_DIR}/scripts/cortex_ops_snapshot.sh" message_preview)"
eval "$(extract_func "${SOURCE_CORTEX_DIR}/scripts/cortex_ops_snapshot.sh" inbox_message_class)"
eval "$(extract_func "${SOURCE_CORTEX_DIR}/scripts/cortex_ops_snapshot.sh" collect_queues)"

CRITICAL=()
WARNINGS=()
ACTIVE=()
QUIET=()
add_critical() { CRITICAL+=("$1"); }
add_warning() { WARNINGS+=("$1"); }
add_active() { ACTIVE+=("$1"); }
add_quiet() { QUIET+=("$1"); }
CONDUCTOR_INBOX="${CORTEX_DIR}/agents/conductor/inbox"

collect_queues
printf 'CRITICAL_COUNT=%s\n' "${#CRITICAL[@]}"
printf 'WARNING=%s\n' "${WARNINGS[0]}"
printf 'ACTIVE_COUNT=%s\n' "${#ACTIVE[@]}"
EOF
    )"

    printf '%s\n' "${output}" | grep -Fxq 'CRITICAL_COUNT=0' \
        || fail "suggestion-only inbox backlog should not page Critical: ${output}"
    printf '%s\n' "${output}" | grep -Fxq 'WARNING=Conductor inbox has 2 unread suggestion-only worker check messages.' \
        || fail "suggestion-only inbox backlog should downgrade to a warning: ${output}"
    printf '%s\n' "${output}" | grep -Fxq 'ACTIVE_COUNT=2' \
        || fail "suggestion-only inbox backlog should still surface preview lines: ${output}"

    rm -rf "${snapshot_root}"
    trap - RETURN
}

test_ops_snapshot_attention_inbox_remains_critical() {
    local snapshot_root output repo_root

    repo_root="${CORTEX_DIR}"
    snapshot_root="${TMP_ROOT}/ops-snapshot-attention-inbox"
    mkdir -p "${snapshot_root}/agents/conductor/inbox" "${snapshot_root}/broadcast"
    trap 'rm -rf "${snapshot_root}"' RETURN

    cat > "${snapshot_root}/agents/conductor/inbox/1_1000_a.msg" <<'EOF'
FROM:   compressor
TO:     conductor
TYPE:   worker_periodic_check
STATUS: done
---
SUMMARY: quiet suggestion
EOF
    cat > "${snapshot_root}/agents/conductor/inbox/1_1001_b.msg" <<'EOF'
FROM:   watch
TO:     conductor
TYPE:   RESPONSE
STATUS: warning
---
SUMMARY: actionable response
EOF

    output="$(
        CORTEX_DIR="${snapshot_root}" SOURCE_CORTEX_DIR="${repo_root}" bash <<'EOF'
set -euo pipefail

extract_func() {
    local file="$1" name="$2"
    awk -v name="${name}" '
        $0 ~ "^" name "\\(\\) \\{" { capture=1 }
        capture { print }
        capture && $0 == "}" { exit }
    ' "${file}"
}

eval "$(extract_func "${SOURCE_CORTEX_DIR}/scripts/cortex_ops_snapshot.sh" plural)"
eval "$(extract_func "${SOURCE_CORTEX_DIR}/scripts/cortex_ops_snapshot.sh" message_field)"
eval "$(extract_func "${SOURCE_CORTEX_DIR}/scripts/cortex_ops_snapshot.sh" message_preview)"
eval "$(extract_func "${SOURCE_CORTEX_DIR}/scripts/cortex_ops_snapshot.sh" inbox_message_class)"
eval "$(extract_func "${SOURCE_CORTEX_DIR}/scripts/cortex_ops_snapshot.sh" collect_queues)"

CRITICAL=()
WARNINGS=()
ACTIVE=()
QUIET=()
add_critical() { CRITICAL+=("$1"); }
add_warning() { WARNINGS+=("$1"); }
add_active() { ACTIVE+=("$1"); }
add_quiet() { QUIET+=("$1"); }
CONDUCTOR_INBOX="${CORTEX_DIR}/agents/conductor/inbox"

collect_queues
printf 'CRITICAL=%s\n' "${CRITICAL[0]}"
printf 'WARNING_COUNT=%s\n' "${#WARNINGS[@]}"
EOF
    )"

    printf '%s\n' "${output}" | grep -Fxq 'CRITICAL=Conductor inbox has 2 unread messages (1 attention-worthy, 1 suggestion-only).' \
        || fail "mixed inbox backlog should remain Critical: ${output}"
    printf '%s\n' "${output}" | grep -Fxq 'WARNING_COUNT=0' \
        || fail "mixed inbox backlog should not degrade to warning-only: ${output}"

    rm -rf "${snapshot_root}"
    trap - RETURN
}

test_ops_snapshot_messenger_selfcheck_fallback() {
    local snapshot_root output repo_root

    repo_root="${CORTEX_DIR}"
    snapshot_root="${TMP_ROOT}/ops-snapshot-messenger-selfcheck"
    mkdir -p "${snapshot_root}/agents/example-host"
    trap 'rm -rf "${snapshot_root}"' RETURN

    cat > "${snapshot_root}/agents/example-host/selfcheck_latest.snapshot" <<'EOF'
### snapshot @ 2026-05-27T14:05:28Z (epoch 1779890728) on example-host (user=example-user)

## user processes — training-ish
 574091  0.0  0.0  3-04:13:18 Ss+  python3 /tmp/cortex-fixture/scripts/signal_inbox_daemon.py

## screen sessions
	574089.cortex_signal_inbox	(05/24/2026 11:52:10 AM)	(Detached)
EOF

    output="$(
        CORTEX_DIR="${snapshot_root}" SOURCE_CORTEX_DIR="${repo_root}" bash <<'EOF'
set -euo pipefail

extract_func() {
    local file="$1" name="$2"
    awk -v name="${name}" '
        $0 ~ "^" name "\\(\\) \\{" { capture=1 }
        capture { print }
        capture && $0 == "}" { exit }
    ' "${file}"
}

eval "$(extract_func "${SOURCE_CORTEX_DIR}/scripts/cortex_ops_snapshot.sh" file_mtime_epoch)"
eval "$(extract_func "${SOURCE_CORTEX_DIR}/scripts/cortex_ops_snapshot.sh" compact_age)"
eval "$(extract_func "${SOURCE_CORTEX_DIR}/scripts/cortex_ops_snapshot.sh" messenger_selfcheck_evidence)"
eval "$(extract_func "${SOURCE_CORTEX_DIR}/scripts/cortex_ops_snapshot.sh" collect_periodics)"

CRITICAL=()
WARNINGS=()
ACTIVE=()
QUIET=()
add_critical() { CRITICAL+=("$1"); }
add_warning() { WARNINGS+=("$1"); }
add_active() { ACTIVE+=("$1"); }
add_quiet() { QUIET+=("$1"); }
now="$(date -u +%s)"
SELFCHECK_FRESH_SECONDS=3600
CORTEX_DEFAULT_SIGNAL_RELAY_HOST="example-host"
CORTEX_DEFAULT_SIGNAL_INBOX_SESSION="cortex_signal_inbox"
periodic_records() {
    printf 'unreachable\tsignal_inbox_daemon\thost=example-host | cadence=always-on\tprobe failed for example-host (ssh/timeout rc=255)\n'
}

collect_periodics
printf 'CRITICAL_COUNT=%s\n' "${#CRITICAL[@]}"
printf 'ACTIVE=%s\n' "${ACTIVE[0]}"
EOF
    )"

    printf '%s\n' "${output}" | grep -Fxq 'CRITICAL_COUNT=0' \
        || fail "fresh selfcheck evidence should suppress messenger probe Criticals: ${output}"
    printf '%s\n' "${output}" | grep -Fq 'ACTIVE=Periodic signal_inbox_daemon is visibility-limited: fresh example-host self-check' \
        || fail "messenger probe fallback should advertise the selfcheck-backed visibility-limited state: ${output}"

    rm -rf "${snapshot_root}"
    trap - RETURN
}

test_linux_source_guards() {
    grep -Fq "script -q -e -c \"\${command_line}\" \"\${usage_file}\"" "${CORTEX_DIR}/cortex.sh" \
        || fail "cortex.sh lost the util-linux script -c branch"
    grep -Fq "script -q -e \"\${usage_file}\" \"\${command[@]}\"" "${CORTEX_DIR}/cortex.sh" \
        || fail "cortex.sh lost the BSD script fallback branch"
    grep -Fq "timeout_cmd=(timeout --preserve-status --kill-after=30s \"\${timeout_secs}\")" "${CORTEX_DIR}/scripts/start_agent.sh" \
        || fail "scripts/start_agent.sh lost the GNU timeout branch"
    grep -Fq "timeout_cmd=(gtimeout --preserve-status --kill-after=30s \"\${timeout_secs}\")" "${CORTEX_DIR}/scripts/start_agent.sh" \
        || fail "scripts/start_agent.sh lost the gtimeout fallback branch"
    ! grep -RInE \
        --exclude='session_backend.sh' \
        --exclude='.nfs*' \
        --exclude-dir='tests' \
        'command -v tmux|tmux (has-session|list-sessions|new-session|kill-session)' \
        "${CORTEX_DIR}/scripts" >/dev/null \
        || fail "tmux runtime calls must stay centralized behind explicit session_backend selection"
}

test_public_license_exception_scope() {
    CORTEX_DIR="${CORTEX_DIR}" bash <<'EOF'
set -euo pipefail
source "${CORTEX_DIR}/scripts/public_sync_lib.sh"

allowed="$(printf 'LICENSE:3:Copyright (c) 2026 Example Holder\n' | public_filter_allowed_content_matches)"
[[ -z "${allowed}" ]]

license_leak="$(printf 'LICENSE:4:host=example-host\n' | public_filter_allowed_content_matches)"
[[ "${license_leak}" == 'LICENSE:4:host=example-host' ]]

other_file="$(printf 'README.md:3:Copyright (c) 2026 Example Holder\n' | public_filter_allowed_content_matches)"
[[ "${other_file}" == 'README.md:3:Copyright (c) 2026 Example Holder' ]]
EOF
}

test_public_sync_integrated_divergence_guard() {
    local helper_block source_repo public_repo source_head public_head

    helper_block="$(
        awk '
            /^commit_source_sha_in_repo\(\)/ { capture=1 }
            /^sync_export_tree\(\)/ { capture=0; exit }
            capture { print }
        ' "${CORTEX_DIR}/scripts/sync_public.sh"
    )"
    [[ -n "${helper_block}" ]] || fail "could not extract public divergence helpers"
    ! grep -Fq -- 'fetch --quiet --depth=1 origin' "${CORTEX_DIR}/scripts/sync_public.sh" \
        || fail "public publisher must fetch enough history to find an earlier export marker"

    source_repo="${TMP_ROOT}/public-guard-source"
    public_repo="${TMP_ROOT}/public-guard-export"
    mkdir -p "${source_repo}" "${public_repo}"
    git -C "${source_repo}" init -q
    git -C "${public_repo}" init -q
    git -C "${source_repo}" config user.name test
    git -C "${source_repo}" config user.email test@example.invalid
    git -C "${public_repo}" config user.name test
    git -C "${public_repo}" config user.email test@example.invalid

    printf 'private\n' > "${source_repo}/state"
    git -C "${source_repo}" add state
    git -C "${source_repo}" commit -q -m 'private source'
    source_head="$(git -C "${source_repo}" rev-parse HEAD)"

    printf 'export\n' > "${public_repo}/README.md"
    git -C "${public_repo}" add README.md
    git -C "${public_repo}" commit -q -m "cortex: public framework export from master ${source_head}"
    printf 'direct edit\n' >> "${public_repo}/README.md"
    git -C "${public_repo}" commit -qam 'direct public edit'
    public_head="$(git -C "${public_repo}" rev-parse HEAD)"

    CORTEX_DIR="${CORTEX_DIR}" SOURCE_REPO="${source_repo}" PUBLIC_REPO="${public_repo}" SOURCE_HEAD="${source_head}" bash <<EOF
set -euo pipefail
${helper_block}
cd "\${SOURCE_REPO}"
if refuse_if_public_branch_diverged "\${PUBLIC_REPO}" "\${SOURCE_HEAD}" >/dev/null 2>&1; then
    exit 1
fi
git fetch -q "\${PUBLIC_REPO}" HEAD:refs/remotes/public/main
git merge -q --no-ff --allow-unrelated-histories -s ours refs/remotes/public/main -m 'integrate public history'
integrated_head="\$(git rev-parse HEAD)"
refuse_if_public_branch_diverged "\${PUBLIC_REPO}" "\${integrated_head}" >/dev/null
git merge-base --is-ancestor "${public_head}" "\${integrated_head}"
EOF
}

test_public_commit_notice() {
    local private_repo public_remote public_work public_checkout output source_head

    private_repo="${TMP_ROOT}/public-notice-private"
    public_remote="${TMP_ROOT}/public-notice.git"
    public_work="${TMP_ROOT}/public-notice-work"
    public_checkout="${TMP_ROOT}/public-notice-checkout"
    git init -q "${private_repo}"
    git -C "${private_repo}" config user.name test
    git -C "${private_repo}" config user.email test@example.invalid
    printf 'source\n' > "${private_repo}/README.md"
    git -C "${private_repo}" add README.md
    git -C "${private_repo}" commit -q -m 'private source'
    git init -q --bare "${public_remote}"
    git -C "${private_repo}" remote add cortex "${public_remote}"
    git -C "${private_repo}" push -q cortex master:main
    git clone -q "${public_remote}" "${public_work}"
    git -C "${public_work}" checkout -q main
    git -C "${public_work}" config user.name test
    git -C "${public_work}" config user.email test@example.invalid
    git clone -q "${public_remote}" "${public_checkout}"
    git -C "${public_checkout}" checkout -q main

    printf 'public update\n' >> "${public_work}/README.md"
    git -C "${public_work}" commit -qam 'public documentation update'
    git -C "${public_work}" push -q origin main

    output="$(CORTEX_DIR="${CORTEX_DIR}" CORTEX_PUBLIC_COMMIT_NOTICE_REPO="${private_repo}" CORTEX_DEFAULT_ENV_SETTINGS_FILE=/nonexistent CORTEX_DEFAULT_PUBLIC_REMOTE_URL="${public_remote}" \
        CORTEX_DEFAULT_PUBLIC_BRANCH=main bash "${CORTEX_DIR}/scripts/public_commit_notice.sh")"
    printf '%s\n' "${output}" | sed $'s/\\033\\[[0-9;]*m//g' | grep -Fq 'UPDATE AVAILABLE: 1 new public commit on cortex/main not represented in master. Ask Conductor to pull from public!' \
        || fail "public commit notice did not report the direct public commit: ${output}"
    printf '%s\n' "${output}" | sed $'s/\\033\\[[0-9;]*m//g' | grep -Fq 'public documentation update' \
        || fail "public commit notice omitted the public commit subject"
    [[ "${output}" == $'\n\033[1;33m'*$'\033[0m' ]] \
        || fail "public commit notice should color the complete update: ${output}"

    output="$(CORTEX_DIR="${CORTEX_DIR}" CORTEX_PUBLIC_COMMIT_NOTICE_REPO="${public_checkout}" CORTEX_DEFAULT_ENV_SETTINGS_FILE=/nonexistent \
        CORTEX_DEFAULT_PUBLIC_BRANCH=main bash "${CORTEX_DIR}/scripts/public_commit_notice.sh")"
    printf '%s\n' "${output}" | sed $'s/\\033\\[[0-9;]*m//g' | grep -Fq 'UPDATE AVAILABLE: 1 new public commit on origin/main not represented in main. Ask Conductor to pull from public!' \
        || fail "public checkout notice did not fall back to origin/main: ${output}"

    git -C "${private_repo}" merge -q --no-edit cortex/main
    output="$(CORTEX_DIR="${CORTEX_DIR}" CORTEX_PUBLIC_COMMIT_NOTICE_REPO="${private_repo}" CORTEX_DEFAULT_ENV_SETTINGS_FILE=/nonexistent CORTEX_DEFAULT_PUBLIC_REMOTE_URL="${public_remote}" \
        CORTEX_DEFAULT_PUBLIC_BRANCH=main bash "${CORTEX_DIR}/scripts/public_commit_notice.sh")"
    [[ -z "${output}" ]] || fail "public commit notice should be quiet after integration"

    printf 'source export\n' >> "${private_repo}/README.md"
    git -C "${private_repo}" commit -qam 'private source update'
    source_head="$(git -C "${private_repo}" rev-parse HEAD)"
    git -C "${public_work}" pull -q --ff-only origin main
    printf 'generated export\n' >> "${public_work}/README.md"
    git -C "${public_work}" commit -qam "cortex: public framework export from master ${source_head}"
    git -C "${public_work}" push -q origin main
    output="$(CORTEX_DIR="${CORTEX_DIR}" CORTEX_PUBLIC_COMMIT_NOTICE_REPO="${private_repo}" CORTEX_DEFAULT_ENV_SETTINGS_FILE=/nonexistent CORTEX_DEFAULT_PUBLIC_REMOTE_URL="${public_remote}" \
        CORTEX_DEFAULT_PUBLIC_BRANCH=main bash "${CORTEX_DIR}/scripts/public_commit_notice.sh")"
    [[ -z "${output}" ]] || fail "public commit notice should suppress an accounted export"
}

test_public_commit_subject_override() {
    local export_repo helper_block output

    helper_block="$(
        awk '
            /^public_commit_subject\(\)/ { capture=1 }
            /^current_branch=/ { exit }
            capture { print }
        ' "${CORTEX_DIR}/scripts/sync_public.sh"
    )"
    [[ -n "${helper_block}" ]] || fail "could not extract public commit helpers"

    export_repo="${TMP_ROOT}/public-subject-export"
    git init -q "${export_repo}"
    git -C "${export_repo}" config user.name test
    git -C "${export_repo}" config user.email test@example.invalid
    printf 'framework\n' > "${export_repo}/README.md"

    output="$(CORTEX_DIR="${CORTEX_DIR}" EXPORT_REPO="${export_repo}" bash <<EOF
set -euo pipefail
${helper_block}
commit_export "\${EXPORT_REPO}" deadbeefcafe master 'cortex: publish an explanatory README update'
git -C "\${EXPORT_REPO}" log -1 --format=%s
EOF
    )"
    [[ "${output}" == *$'cortex: publish an explanatory README update' ]] \
        || fail "public export ignored explicit descriptive subject: ${output}"
}

test_research_timeout_portability() {
    grep -Fq 'run_with_timeout 4 env SSH_AUTH_SOCK="${sock}" ssh-add -l' "${CORTEX_DIR}/roles/research/research.sh" \
        || fail "research ssh-agent liveness check must use run_with_timeout"
    grep -Fq 'run_with_timeout 8 env SSH_AUTH_SOCK="${sock}" ssh-add "${key}"' "${CORTEX_DIR}/roles/research/research.sh" \
        || fail "research ssh-agent key load must use run_with_timeout"
    ! rg -n '(^|[[:space:]])timeout[[:space:]]+[0-9]+[[:space:]]+ssh-add' "${CORTEX_DIR}/roles/research/research.sh" >/dev/null \
        || fail "research ssh-agent operations must not invoke timeout directly"
}

test_conductor_startup_flag_polarity() {
    local help_output

    help_output="$(
        bash "${CORTEX_DIR}/cortex.sh" --help
    )"

    printf '%s\n' "${help_output}" | grep -Fq -- '--startup-checks' \
        || fail "cortex.sh --help missing --startup-checks"
    ! printf '%s\n' "${help_output}" | grep -Fq -- '--minimal-startup' \
        || fail "cortex.sh --help still mentions --minimal-startup"
    grep -Fq 'STARTUP_CHECKS=0' "${CORTEX_DIR}/cortex.sh" \
        || fail "cortex.sh should default STARTUP_CHECKS=0"
    grep -Fq -- '--startup-checks)' "${CORTEX_DIR}/cortex.sh" \
        || fail "cortex.sh should parse --startup-checks"
    grep -Fq 'if (( STARTUP_CHECKS )); then' "${CORTEX_DIR}/cortex.sh" \
        || fail "cortex.sh prompt polarity should branch on STARTUP_CHECKS"
    grep -Fq 'prompt="${prompt} At startup, perform the minimal startup routine."' "${CORTEX_DIR}/cortex.sh" \
        || fail "cortex.sh should default the prompt to minimal startup"
}

test_conductor_no_alt_screen_flag() {
    local help_output

    help_output="$(
        bash "${CORTEX_DIR}/cortex.sh" --help
    )"
    printf '%s\n' "${help_output}" | grep -Fq -- '--no-alt-screen' \
        || fail "cortex.sh --help missing --no-alt-screen"
    grep -Fq 'if [[ "${PROVIDER}" == "codex" ]]; then' "${CORTEX_DIR}/cortex.sh" \
        || fail "cortex.sh should default Codex launches to no-alt-screen"
    grep -Fq 'NO_ALT_SCREEN=1' "${CORTEX_DIR}/cortex.sh" \
        || fail "cortex.sh missing Codex no-alt-screen default"
    grep -Fq -- '--no-alt-screen)' "${CORTEX_DIR}/cortex.sh" \
        || fail "cortex.sh does not parse --no-alt-screen"
    grep -Fq '"--no-alt-screen is supported only with the Codex provider."' "${CORTEX_DIR}/cortex.sh" \
        || fail "cortex.sh should reject --no-alt-screen for Claude"
    grep -Fq 'LAUNCH_ARGS[${#LAUNCH_ARGS[@]}]="--no-alt-screen"' "${CORTEX_DIR}/cortex.sh" \
        || fail "cortex.sh does not forward --no-alt-screen to Codex"
}

test_conductor_model_aliases() {
    local resolver_block help_output

    resolver_block="$(
        awk '
            /^resolve_conductor_model_name\(\)/ { capture=1 }
            /^apply_conductor_model_tier\(\)/ { capture=0; exit }
            capture { print }
        ' "${CORTEX_DIR}/cortex.sh"
    )"
    [[ -n "${resolver_block}" ]] || fail "could not extract conductor model resolver"

    CORTEX_DIR="${CORTEX_DIR}" bash <<EOF
set -euo pipefail
${resolver_block}
[[ "\$(resolve_conductor_model_name claude fable-5)" == "claude-fable-5" ]]
[[ "\$(resolve_conductor_model_name claude sonnet-5)" == "claude-sonnet-5" ]]
[[ "\$(resolve_conductor_model_name claude 4.8)" == "claude-opus-4-8" ]]
[[ "\$(resolve_conductor_model_name codex 5.6)" == "gpt-5.6" ]]
[[ "\$(resolve_conductor_model_name codex 5.6-sol)" == "gpt-5.6-sol" ]]
[[ "\$(resolve_conductor_model_name codex 5.6-terra)" == "gpt-5.6-terra" ]]
[[ "\$(resolve_conductor_model_name codex 5.6-luna)" == "gpt-5.6-luna" ]]
[[ "\$(resolve_conductor_model_name codex 5.5)" == "gpt-5.5" ]]
[[ "\$(resolve_conductor_model_name claude claude-opus-4-8)" == "claude-opus-4-8" ]]
EOF

    help_output="$(bash "${CORTEX_DIR}/cortex.sh" --help)"
    printf '%s\n' "${help_output}" | grep -Fq 'claude: fable-5, sonnet-5, 4.8 (Opus), 4.7, 4.6' \
        || fail "cortex.sh --help missing current Claude aliases"
    printf '%s\n' "${help_output}" | grep -Fq 'codex:  5.6, 5.6-sol, 5.6-terra, 5.6-luna, 5.5, 5.4' \
        || fail "cortex.sh --help missing GPT-5.6 aliases"
}

test_agent_logs_are_local() {
    grep -Fq 'LOG_FILE="${AGENT_STATE_DIR}/log.md"' "${CORTEX_DIR}/scripts/start_agent.sh" \
        || fail "scripts/start_agent.sh should log to the resolved agent state dir"
    grep -Fq 'LOG_FILE="${CORTEX_DIR}/agents/watch/log.md"' "${CORTEX_DIR}/scripts/watch.sh" \
        || fail "scripts/watch.sh should log to agents/watch/log.md"
    ! grep -Fq 'LOG_FILE="${CORTEX_DIR}/logs/${AGENT_ID}.log"' "${CORTEX_DIR}/scripts/start_agent.sh" \
        || fail "scripts/start_agent.sh still uses root logs/ for agent logs"
}

test_start_agent_cleanup_marks_offline() {
    local helper_block agent_dir stage_home

    helper_block="$(
        awk '
            /^write_text_file_atomic\(\)/ { capture=1 }
            /^should_forward_command_response\(\)/ { capture=0; exit }
            capture { print }
        ' "${CORTEX_DIR}/scripts/start_agent.sh"
    )"
    [[ -n "${helper_block}" ]] || fail "could not extract cleanup helpers from scripts/start_agent.sh"

    agent_dir="${TMP_ROOT}/agent-cleanup-smoke"
    stage_home="${TMP_ROOT}/codex-stage-home"
    mkdir -p "${agent_dir}" "${stage_home}"
    printf 'busy\n' > "${agent_dir}/status"
    printf '%s\n' "$(date -u +%s)" > "${agent_dir}/heartbeat"
    : > "${agent_dir}/working"

    AGENT_DIR="${agent_dir}" STAGE_HOME="${stage_home}" bash <<EOF
set -euo pipefail
${helper_block}
RUNTIME_CLEANED_UP=0
ACTIVE_CODEX_STAGE_HOMES=("\${STAGE_HOME}")
cleanup_runtime
[[ "\$(tr -d '\r\n' < "\${AGENT_DIR}/status")" == "offline" ]]
[[ ! -e "\${AGENT_DIR}/heartbeat" ]]
[[ ! -e "\${AGENT_DIR}/working" ]]
[[ ! -d "\${STAGE_HOME}" ]]
EOF
}

run_existing_deterministic_checks() {
    bash "${CORTEX_DIR}/roles/operational/backup/test_backup_freshness_predicate.sh"
    bash "${CORTEX_DIR}/scripts/test_selfcheck_alert_dedup.sh"
    bash "${CORTEX_DIR}/scripts/test_usage_capture_bounds.sh"
    bash "${CORTEX_DIR}/scripts/cortex_doctor.sh" --check public-manifest
    bash "${CORTEX_DIR}/scripts/cortex_doctor.sh" --check sandbox
    bash "${CORTEX_DIR}/scripts/cortex_doctor.sh" --check worker-meta
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --with-live-smoke)
            WITH_LIVE_SMOKE=1
            shift
            ;;
        --provider)
            [[ $# -ge 2 ]] || fail "missing value for --provider"
            LIVE_PROVIDER="$2"
            shift 2
            ;;
        --timeout)
            [[ $# -ge 2 ]] || fail "missing value for --timeout"
            LIVE_TIMEOUT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown argument: $1"
            ;;
    esac
done

[[ "${LIVE_TIMEOUT}" =~ ^[0-9]+$ ]] || fail "timeout must be an integer"
case "${LIVE_PROVIDER}" in
    codex|claude) ;;
    *) fail "unsupported live-smoke provider: ${LIVE_PROVIDER}" ;;
esac

TMP_ROOT="$(mktemp -d)"

run_step "require Linux host" require_linux
run_step "worker sandbox backend resolution" test_linux_worker_sandbox_resolution
run_step "nvm PATH bootstrap" test_start_agent_nvm_path_bootstrap
run_step "Linux worker dispatch" test_linux_worker_dispatch
run_step "security bwrap dir args" test_security_bwrap_dir_args
run_step "provider nonzero structured output" test_provider_nonzero_structured_output
run_step "conductor envelope header neutralization" test_conductor_envelope_header_neutralization
run_step "rotate_logbook no-preamble rotation" test_rotate_logbook_no_preamble
run_step "rotate_logbook duplicate-history guard" test_rotate_logbook_duplicate_history_guard
run_step "research project runtime env" test_research_project_runtime_env
run_step "agent info records research runtime" test_agent_info_records_research_runtime
run_step "screen restart guard" test_start_agent_screen_research_restart_guard
run_step "screen restart waits for safe shutdown" test_start_agent_screen_restart_waits_for_safe_shutdown
run_step "operational worker configuration gate" test_operational_worker_config_gate
run_step "worker environment W&B netrc export" test_worker_environment_wandb_export
run_step "research command scope rw paths" test_research_command_scope_rw_paths
run_step "research lead inbox drain before periodic" test_research_lead_inbox_drain_before_periodic
run_step "worker dynamic next wake" test_worker_dynamic_next_wake
run_step "research specialist auto-forward" test_research_specialist_auto_forward
run_step "research RO base (broad read, fenced write)" test_research_ro_base
run_step "research SSH binds" test_research_ssh_binds
run_step "research target folder state dir" test_research_target_folder_state_dir
run_step "research dashboard lead logbook" test_research_dashboard_lead_logbook
run_step "living agent roster smoke" test_living_agent_roster_smoke
run_step "ops snapshot suggestion-only inbox severity" test_ops_snapshot_suggestion_only_inbox_below_critical
run_step "ops snapshot mixed inbox stays critical" test_ops_snapshot_attention_inbox_remains_critical
run_step "ops snapshot messenger selfcheck fallback" test_ops_snapshot_messenger_selfcheck_fallback
run_step "source guards for Linux branches" test_linux_source_guards
run_step "public license exception scope" test_public_license_exception_scope
run_step "public integrated-divergence guard" test_public_sync_integrated_divergence_guard
run_step "public descriptive commit subject" test_public_commit_subject_override
run_step "public commit notice" test_public_commit_notice
run_step "research timeout portability" test_research_timeout_portability
run_step "conductor startup flag polarity" test_conductor_startup_flag_polarity
run_step "conductor no-alt-screen flag" test_conductor_no_alt_screen_flag
run_step "conductor current-model aliases" test_conductor_model_aliases
run_step "local agent log paths" test_agent_logs_are_local
run_step "launcher cleanup marks offline" test_start_agent_cleanup_marks_offline
run_step "existing deterministic framework smokes" run_existing_deterministic_checks

if (( WITH_LIVE_SMOKE == 1 )); then
    run_step "live control-plane smoke (${LIVE_PROVIDER})" \
        bash "${CORTEX_DIR}/scripts/control_plane_smoke.sh" --provider "${LIVE_PROVIDER}" --timeout "${LIVE_TIMEOUT}"
fi

printf 'ok: Linux framework regression suite passed\n'
