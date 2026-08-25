#!/usr/bin/env bash
# =============================================================================
# control_plane_smoke.sh — deterministic control-plane smoke harness
# Verifies one real worker COMMAND→RESPONSE round-trip and one watch fast-path
# probe that confirms unread conductor inbox messages stay unread without
# forcing a watch LLM wake on their own.
# =============================================================================

set -euo pipefail

CORTEX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONDUCTOR_INBOX="${CORTEX_DIR}/agents/conductor/inbox"
AGENT="${SMOKE_AGENT:-}"
TIMEOUT_SECS=120
POLL_SECS=2
TEMP_WORKER_PROVIDER="${SMOKE_PROVIDER:-codex}"

CMD_DEST=""
CMD_ARCHIVE=""
RESPONSE_FILE=""
PROBE_FILE=""
TEMP_WORKER_PID=""
TEMP_WORKER_STDOUT=""
LAUNCHED_TEMP_AGENT=0

usage() {
    cat <<'EOF'
Usage:
  bash scripts/control_plane_smoke.sh [--agent AGENT] [--provider codex|claude] [--timeout SECONDS]

Options:
  --agent AGENT       Existing worker agent to use for the round-trip.
                     If omitted, the harness launches a temporary one-shot worker.
  --provider VALUE    Provider for the temporary one-shot worker. Default: codex.
  --timeout SECONDS   Wait timeout for the worker response. Default: 120.
  -h, --help          Show this help text.
EOF
}

cleanup() {
    if [[ -n "${TEMP_WORKER_PID}" ]] && kill -0 "${TEMP_WORKER_PID}" 2>/dev/null; then
        kill "${TEMP_WORKER_PID}" 2>/dev/null || true
        wait "${TEMP_WORKER_PID}" 2>/dev/null || true
    fi
    [[ -n "${PROBE_FILE}" ]] && rm -f "${PROBE_FILE}" 2>/dev/null || true
    [[ -n "${RESPONSE_FILE}" ]] && rm -f "${RESPONSE_FILE}" 2>/dev/null || true
    [[ -n "${CMD_ARCHIVE}" ]] && rm -f "${CMD_ARCHIVE}" 2>/dev/null || true
    [[ -n "${CMD_DEST}" ]] && rm -f "${CMD_DEST}" 2>/dev/null || true
    if (( LAUNCHED_TEMP_AGENT == 1 )) && [[ -n "${AGENT}" ]]; then
        find "${CONDUCTOR_INBOX}" -maxdepth 1 -type f -name '*.msg' -print0 2>/dev/null \
            | while IFS= read -r -d '' candidate; do
                if grep -Eq "^FROM:[[:space:]]*${AGENT}$" "${candidate}"; then
                    rm -f "${candidate}" 2>/dev/null || true
                fi
            done
        rm -rf "${CORTEX_DIR}/agents/${AGENT}" 2>/dev/null || true
        [[ -n "${TEMP_WORKER_STDOUT}" ]] && rm -f "${TEMP_WORKER_STDOUT}" 2>/dev/null || true
    fi
}

trap cleanup EXIT

fail() {
    printf 'SMOKE: fail\n'
    printf 'DETAIL: %s\n' "$1"
    exit 1
}

rand_hex() {
    head -c 2 /dev/urandom | xxd -p
}

launch_temp_worker() {
    local deadline

    AGENT="smoke-worker-$(date +%s)-$(rand_hex)"
    TEMP_WORKER_STDOUT="/tmp/${AGENT}.log"
    LAUNCHED_TEMP_AGENT=1

    bash "${CORTEX_DIR}/scripts/start_agent.sh" --role worker --name "${AGENT}" --provider "${TEMP_WORKER_PROVIDER}" --once \
        > "${TEMP_WORKER_STDOUT}" 2>&1 &
    TEMP_WORKER_PID=$!

    deadline=$(( $(date +%s) + TIMEOUT_SECS ))
    while (( $(date +%s) < deadline )); do
        [[ -d "${CORTEX_DIR}/agents/${AGENT}/inbox" ]] && return 0
        if ! kill -0 "${TEMP_WORKER_PID}" 2>/dev/null; then
            fail "temporary worker ${AGENT} exited before registering; see ${TEMP_WORKER_STDOUT}"
        fi
        sleep "${POLL_SECS}"
    done

    fail "temporary worker ${AGENT} did not register in time"
}

queue_smoke_command() {
    local ts hex msg_id filename

    [[ -d "${CORTEX_DIR}/agents/${AGENT}/inbox" ]] || fail "agent inbox missing: ${AGENT}"

    ts="$(date +%s)"
    hex="$(rand_hex)"
    msg_id="${ts}_${hex}"
    filename="1_${ts}_${hex}.msg"
    CMD_DEST="${CORTEX_DIR}/agents/${AGENT}/inbox/${filename}"
    CMD_ARCHIVE="${CORTEX_DIR}/agents/${AGENT}/archive/${filename}"

    cat > "${CMD_DEST}.tmp" <<EOF
MSG_ID: ${msg_id}
FROM:   conductor
TO:     ${AGENT}
TYPE:   COMMAND
TIME:   ${ts}
REF:    none
STATUS: pending
---
This is a deterministic control-plane smoke test.
TOKEN_OVERRIDE: approved

Reply exactly in the following shape. No preamble, no transcript, no markdown fences, no tool output, no prompt echo.

STATUS: done
SUMMARY: smoke harness: colon survives

DETAILS:
- first detail line
- second detail line: colon survives too
EOF
    mv "${CMD_DEST}.tmp" "${CMD_DEST}"
    printf '%s' "${msg_id}"
}

wait_for_response() {
    local ref_msg="$1"
    local deadline now candidate

    deadline=$(( $(date +%s) + TIMEOUT_SECS ))
    while (( $(date +%s) < deadline )); do
        while IFS= read -r candidate; do
            [[ -n "${candidate}" ]] || continue
            if grep -Eq "^REF:[[:space:]]*${ref_msg}$" "${candidate}"; then
                RESPONSE_FILE="${candidate}"
                return 0
            fi
        done < <(find "${CONDUCTOR_INBOX}" -maxdepth 1 -type f -name '*.msg' | sort)
        sleep "${POLL_SECS}"
    done

    fail "timed out waiting for RESPONSE to ${ref_msg}"
}

validate_response() {
    local body

    grep -Eq "^FROM:[[:space:]]*${AGENT}$" "${RESPONSE_FILE}" || fail "response sender mismatch"
    grep -Eq '^TYPE:[[:space:]]*RESPONSE$' "${RESPONSE_FILE}" || fail "response TYPE mismatch"
    grep -Eq '^STATUS:[[:space:]]*done$' "${RESPONSE_FILE}" || fail "response STATUS mismatch"

    body="$(awk 'found { print } /^---$/ { found=1; next }' "${RESPONSE_FILE}")"
    printf '%s\n' "${body}" | grep -Fx 'STATUS: done' >/dev/null || fail "missing STATUS line in response body"
    printf '%s\n' "${body}" | grep -Fx 'SUMMARY: smoke harness: colon survives' >/dev/null || fail "missing colon-bearing SUMMARY"
    printf '%s\n' "${body}" | grep -Fx 'DETAILS:' >/dev/null || fail "missing DETAILS header"
    printf '%s\n' "${body}" | grep -Fx -- '- first detail line' >/dev/null || fail "missing first DETAILS line"
    printf '%s\n' "${body}" | grep -Fx -- '- second detail line: colon survives too' >/dev/null || fail "missing second DETAILS line"
}

create_probe_message() {
    local ts hex msg_id

    ts="$(date +%s)"
    hex="$(rand_hex)"
    msg_id="${ts}_${hex}"
    PROBE_FILE="${CONDUCTOR_INBOX}/${ts}_smoke_${hex}.msg"

    cat > "${PROBE_FILE}.tmp" <<EOF
MSG_ID: ${msg_id}
FROM:   smoke
TO:     conductor
TYPE:   STATUS
TIME:   ${ts}
REF:    none
STATUS: done
---
SUMMARY: smoke probe unread conductor inbox message
EOF
    mv "${PROBE_FILE}.tmp" "${PROBE_FILE}"
}

probe_watch_fast_path() {
    local output rc

    set +e
    output="$(bash "${CORTEX_DIR}/scripts/watch.sh" --fast-path-reason 2>&1)"
    rc=$?
    set -e

    case "${rc}" in
        0)
            printf '%s\n' "${output}" | grep -Fx 'FAST_PATH: ok' >/dev/null || fail "watch probe missing FAST_PATH ok marker"
            ;;
        1)
            printf '%s\n' "${output}" | grep -Fx 'FAST_PATH: block' >/dev/null || fail "watch probe missing FAST_PATH block marker"
            ;;
        *)
            fail "watch fast-path probe exited ${rc}"
            ;;
    esac
    if printf '%s\n' "${output}" | grep -Eq '^REASON: inbox has [0-9]+ unread$'; then
        fail "watch probe still treated unread conductor inbox as a fast-path blocker"
    fi
    [[ -f "${PROBE_FILE}" ]] || fail "watch probe consumed the unread conductor inbox message"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent)
            [[ $# -ge 2 ]] || fail "missing value for --agent"
            AGENT="$2"
            shift 2
            ;;
        --provider)
            [[ $# -ge 2 ]] || fail "missing value for --provider"
            TEMP_WORKER_PROVIDER="$2"
            shift 2
            ;;
        --timeout)
            [[ $# -ge 2 ]] || fail "missing value for --timeout"
            TIMEOUT_SECS="$2"
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

[[ "${TIMEOUT_SECS}" =~ ^[0-9]+$ ]] || fail "timeout must be an integer"
case "${TEMP_WORKER_PROVIDER}" in
    codex|claude) ;;
    *) fail "unsupported temporary worker provider: ${TEMP_WORKER_PROVIDER}" ;;
esac

if [[ -z "${AGENT}" ]]; then
    launch_temp_worker
fi

ref_msg="$(queue_smoke_command)"
wait_for_response "${ref_msg}"
validate_response
create_probe_message
probe_watch_fast_path

printf 'SMOKE: ok\n'
printf 'AGENT: %s\n' "${AGENT}"
printf 'ROUND_TRIP: worker command delivered and response validated\n'
printf 'WATCH_GATE: unread conductor inbox remains unread without forcing a watch-only wake\n'
