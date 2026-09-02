#!/usr/bin/env bash
# =============================================================================
# test_usage_capture_bounds.sh — smoke test for the per-call token plausibility
# bound added to scripts/usage_lib.sh and scripts/usage_report.py.
# Confirms that:
#   1) cortex_usage_token_plausible() accepts plausible counts and rejects
#      implausibly-large ones (the 5.8e20 poison shape).
#   2) cortex_usage_record_from_file() marks rows whose transcript-scraped
#      fields exceed the bound as `rejected_implausible` instead of totaling.
#   3) usage_report.py's summarize() drops `rejected_implausible` rows and
#      any row whose recorded total still exceeds the bound (defense against
#      pre-bound ledger rows).
#   4) Codex rollout matching anchors to the invocation start time, so two
#      parallel same-cwd sessions do not both sum both rollout files.
# =============================================================================

set -uo pipefail

CORTEX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${CORTEX_DIR}/scripts/bash_compat.sh"
# shellcheck disable=SC1091
source "${CORTEX_DIR}/scripts/usage_lib.sh"

fail=0

# 1) cortex_usage_token_plausible() bound check.
if ! cortex_usage_token_plausible 1500000; then
    echo "FAIL: 1.5M tokens should be plausible" >&2; fail=1
fi
if cortex_usage_token_plausible 580202605180239000200; then
    echo "FAIL: 5.8e20 tokens should be rejected" >&2; fail=1
fi
if cortex_usage_token_plausible ""; then
    echo "FAIL: empty value should be rejected" >&2; fail=1
fi
if cortex_usage_token_plausible "not-a-number"; then
    echo "FAIL: non-numeric value should be rejected" >&2; fail=1
fi

# Current-model pricing must stay available when conductor aliases resolve to
# their full provider ids.
while read -r price_provider price_model expected_input_price expected_output_price; do
    expected_price="${expected_input_price} ${expected_output_price}"
    actual_price="$(cortex_usage_price_pair "${price_provider}" "${price_model}")"
    if [[ "${actual_price}" != "${expected_price}" ]]; then
        echo "FAIL: ${price_provider} ${price_model} price expected '${expected_price}' but got '${actual_price}'" >&2
        fail=1
    fi
done <<'PRICES'
codex gpt-5.6 4 20
codex gpt-5.6-sol 4 20
codex gpt-5.6-terra 2 12
codex gpt-5.6-luna 0.2 1.2
claude claude-fable-5 10 50
claude claude-fable-5-1 10 50
claude claude-opus-5 5 25
claude claude-sonnet-5 2 10
claude claude-opus-4-8 5 25
claude claude-haiku-4-5-20251001 1 5
PRICES

# 2) Recording path: feed a fake transcript containing only a poisoned total.
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

# 1b) Claude session match honours the per-run project-dir override and reads
# Agent-tool subagent transcripts under <session>/subagents/.
stage="${workdir}/claude_stage"
mkdir -p "${stage}/sess1/subagents"
now_epoch="$(date -u +%s)"
now_iso="$(date -u -d "@${now_epoch}" '+%Y-%m-%dT%H:%M:%S.000Z' 2>/dev/null || date -u -r "${now_epoch}" '+%Y-%m-%dT%H:%M:%S.000Z')"
printf '{"type":"assistant","timestamp":"%s","requestId":"r1","message":{"id":"m1","model":"claude-fable-5-1","usage":{"input_tokens":10,"cache_creation_input_tokens":20,"cache_read_input_tokens":30,"output_tokens":40}}}\n' "${now_iso}" > "${stage}/sess1.jsonl"
printf '{"type":"assistant","timestamp":"%s","requestId":"r2","message":{"id":"m2","model":"claude-fable-5-1","usage":{"input_tokens":1,"cache_creation_input_tokens":2,"cache_read_input_tokens":3,"output_tokens":4}}}\n' "${now_iso}" > "${stage}/sess1/subagents/agent-a.jsonl"
match_row="$(CORTEX_USAGE_CLAUDE_PROJECT_DIR="${stage}" cortex_usage_claude_session_match "$((now_epoch - 60))" "$((now_epoch + 60))" /nonexistent/cwd || true)"
if [[ "${match_row}" != "claude-fable-5-1	11	22	33	44	2" ]]; then
    echo "FAIL: claude session match with override+subagents expected 'claude-fable-5-1 11 22 33 44 2' but got '${match_row}'" >&2
    fail=1
fi
# 1c) A pinned session id excludes a concurrent decoy session in the same dir.
printf '{"type":"assistant","timestamp":"%s","requestId":"r9","message":{"id":"m9","model":"claude-fable-5-1","usage":{"input_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}\n' "${now_iso}" > "${stage}/decoy.jsonl"
match_row="$(CORTEX_USAGE_CLAUDE_PROJECT_DIR="${stage}" CORTEX_USAGE_CLAUDE_SESSION_ID=sess1 cortex_usage_claude_session_match "$((now_epoch - 60))" "$((now_epoch + 60))" /nonexistent/cwd || true)"
if [[ "${match_row}" != "claude-fable-5-1	11	22	33	44	2" ]]; then
    echo "FAIL: pinned session match expected 'claude-fable-5-1 11 22 33 44 2' (decoy excluded) but got '${match_row}'" >&2
    fail=1
fi
sid_probe="$(cortex_usage_new_claude_session_id || true)"
if [[ ! "${sid_probe}" =~ ^[0-9a-f-]{36}$ ]]; then
    echo "FAIL: cortex_usage_new_claude_session_id produced '${sid_probe}'" >&2
    fail=1
fi
mkdir -p "${workdir}/users/test/usage"
transcript="${workdir}/transcript.txt"
ledger="${workdir}/users/test/usage/usage.tsv"

cat > "${transcript}" <<'OUT'
Total tokens: 580202605180239000200
Output tokens: 5
OUT

# Use a synthetic cwd that has no `~/.claude/projects/<encoded>` entry so
# the claude path falls through to the text-scrape branch instead of
# matching the live conductor session.
fake_cwd="${workdir}/fake_no_claude_session_cwd"
mkdir -p "${fake_cwd}"
CORTEX_USAGE_LEDGER="${ledger}" \
CORTEX_USAGE_DISABLE=0 \
    cortex_usage_record_from_file "${transcript}" \
        test_agent worker periodic claude claude-opus-4-7 unit-test \
        "$(date -u +%s)" "$(date -u +%s)" "${fake_cwd}"

if [[ ! -s "${ledger}" ]]; then
    echo "FAIL: poisoned-transcript run should still write a ledger header + row" >&2; fail=1
else
    # The data row should carry estimate_note=rejected_implausible and empty
    # token fields so usage_report does not sum it in.
    row="$(tail -n 1 "${ledger}")"
    note="$(printf '%s' "${row}" | awk -F'\t' '{ print $14 }')"
    total="$(printf '%s' "${row}" | awk -F'\t' '{ print $12 }')"
    if [[ "${note}" != "rejected_implausible" ]]; then
        echo "FAIL: expected estimate_note=rejected_implausible, got '${note}'" >&2; fail=1
    fi
    if [[ -n "${total}" && "${total}" != "0" ]]; then
        echo "FAIL: expected empty/zero total_tokens for rejected row, got '${total}'" >&2; fail=1
    fi
fi

# 3) usage_report.py drops rejected rows even when the legacy field is set.
# Build a tiny ledger with one plausible row and one pre-bound poison row.
mixed_ledger="${workdir}/mixed_usage.tsv"
{
    printf '%s\n' \
        "timestamp_local	timestamp_utc	epoch	agent	role	run_kind	provider	model	input_tokens	cached_input_tokens	output_tokens	total_tokens	estimated_usd	estimate_note	source"
    epoch="$(date -u +%s)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        "${epoch}" \
        good agent test claude claude-opus-4-7 \
        100 0 50 150 0.001 exact_or_split unit-test
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        "${epoch}" \
        bad agent test codex gpt-5.5 \
        0 0 5 580202605180239000200 0.0001 exact_or_split unit-test
} > "${mixed_ledger}"

report="$(python3 "${CORTEX_DIR}/scripts/usage_report.py" --ledger "${mixed_ledger}" --since 1d --quiet-line 2>&1 || true)"
if ! grep -q '1 calls' <<< "${report}"; then
    echo "FAIL: usage_report should report 1 call after dropping poison; got: ${report}" >&2; fail=1
fi
if ! grep -q '150 tokens' <<< "${report}"; then
    echo "FAIL: usage_report should report 150 tokens (plausible row only); got: ${report}" >&2; fail=1
fi
if ! grep -q 'rejected-implausible' <<< "${report}"; then
    echo "FAIL: usage_report should mention rejected-implausible caveat; got: ${report}" >&2; fail=1
fi

# 4) Codex rollout matching should pick the rollout that started with the
# current invocation, not every overlapping same-cwd rollout.
codex_home="${workdir}/codex_home"
codex_sessions_dir="${codex_home}/sessions/2026/05/20"
mkdir -p "${codex_sessions_dir}"
codex_cwd="${workdir}/same_cwd"
mkdir -p "${codex_cwd}"
dummy_transcript="${workdir}/codex_dummy.txt"
: > "${dummy_transcript}"
codex_ledger="${workdir}/codex_usage.tsv"

python3 - "${codex_sessions_dir}" "${codex_cwd}" <<'PY'
import json
import os
import sys

sessions_dir, cwd = sys.argv[1], sys.argv[2]

def write_rollout(name, session_ts, events):
    path = os.path.join(sessions_dir, name)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(json.dumps({
            "timestamp": session_ts,
            "type": "session_meta",
            "payload": {
                "id": name,
                "timestamp": session_ts,
                "cwd": cwd,
                "originator": "codex-tui",
            },
        }) + "\n")
        handle.write(json.dumps({
            "timestamp": session_ts,
            "type": "turn_context",
            "payload": {"model": "gpt-5.4"},
        }) + "\n")
        for index, (ts, input_tokens, cached_tokens, output_tokens) in enumerate(events, start=1):
            handle.write(json.dumps({
                "timestamp": ts,
                "type": "event_msg",
                "payload": {
                    "type": "token_count",
                    "turn_id": f"turn-{index}",
                    "info": {
                        "last_token_usage": {
                            "input_tokens": input_tokens,
                            "cached_input_tokens": cached_tokens,
                            "output_tokens": output_tokens,
                        }
                    },
                },
            }) + "\n")

write_rollout(
    "rollout-a.jsonl",
    "2026-05-20T11:30:08Z",
    [
        ("2026-05-20T11:31:00Z", 1000, 900, 10),
        ("2026-05-20T13:15:16Z", 2000, 1500, 20),
    ],
)
write_rollout(
    "rollout-b.jsonl",
    "2026-05-20T11:41:14Z",
    [
        ("2026-05-20T11:42:00Z", 3000, 2500, 30),
        ("2026-05-20T13:14:42Z", 4000, 3000, 40),
    ],
)
PY

start_a="$(iso8601_to_epoch_utc '2026-05-20T11:30:10Z')"
end_a="$(iso8601_to_epoch_utc '2026-05-20T13:15:41Z')"
start_b="$(iso8601_to_epoch_utc '2026-05-20T11:41:15Z')"
end_b="$(iso8601_to_epoch_utc '2026-05-20T13:16:10Z')"

CORTEX_USAGE_LEDGER="${codex_ledger}" \
CORTEX_USAGE_CODEX_HOME="${codex_home}" \
CORTEX_USAGE_DISABLE=0 \
    cortex_usage_record_from_file "${dummy_transcript}" \
        test_agent conductor interactive codex gpt-5.4 unit-test \
        "${start_a}" "${end_a}" "${codex_cwd}"

CORTEX_USAGE_LEDGER="${codex_ledger}" \
CORTEX_USAGE_CODEX_HOME="${codex_home}" \
CORTEX_USAGE_DISABLE=0 \
    cortex_usage_record_from_file "${dummy_transcript}" \
        test_agent conductor interactive codex gpt-5.4 unit-test \
        "${start_b}" "${end_b}" "${codex_cwd}"

codex_row_1="$(sed -n '2p' "${codex_ledger}")"
codex_row_2="$(sed -n '3p' "${codex_ledger}")"
codex_1_input="$(printf '%s' "${codex_row_1}" | awk -F'\t' '{ print $9 }')"
codex_1_cached="$(printf '%s' "${codex_row_1}" | awk -F'\t' '{ print $10 }')"
codex_1_output="$(printf '%s' "${codex_row_1}" | awk -F'\t' '{ print $11 }')"
codex_1_total="$(printf '%s' "${codex_row_1}" | awk -F'\t' '{ print $12 }')"
codex_2_input="$(printf '%s' "${codex_row_2}" | awk -F'\t' '{ print $9 }')"
codex_2_cached="$(printf '%s' "${codex_row_2}" | awk -F'\t' '{ print $10 }')"
codex_2_output="$(printf '%s' "${codex_row_2}" | awk -F'\t' '{ print $11 }')"
codex_2_total="$(printf '%s' "${codex_row_2}" | awk -F'\t' '{ print $12 }')"

if [[ "${codex_1_input}" != "600" || "${codex_1_cached}" != "2400" || "${codex_1_output}" != "30" || "${codex_1_total}" != "3030" ]]; then
    echo "FAIL: first codex row should match rollout-a only, got: ${codex_row_1}" >&2; fail=1
fi
if [[ "${codex_2_input}" != "1500" || "${codex_2_cached}" != "5500" || "${codex_2_output}" != "70" || "${codex_2_total}" != "7070" ]]; then
    echo "FAIL: second codex row should match rollout-b only, got: ${codex_row_2}" >&2; fail=1
fi

if (( fail )); then
    echo "usage-capture bounds smoke FAILED" >&2
    exit 1
fi
echo "ok: usage-capture bounds smoke passed"
