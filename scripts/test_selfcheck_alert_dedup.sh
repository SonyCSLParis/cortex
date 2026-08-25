#!/usr/bin/env bash
# =============================================================================
# test_selfcheck_alert_dedup.sh — smoke test for the per-agent selfcheck
# alert dedup logic added to scripts/start_agent.sh. Builds a minimal harness
# that exercises the fingerprint compute + state-file branch logic without
# running the full agent loop or invoking a provider CLI.
# =============================================================================

set -uo pipefail

CORTEX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
fail=0

# Inline replica of the fingerprint computation used by the launcher; if
# this drifts from `scripts/start_agent.sh` the test should fail.
compute_fp() {
    printf '%s' "$1" \
        | sed -E \
            -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.+Z-]+//g' \
            -e 's/\b[0-9]+(\.[0-9]+)?\s*(B|KB|MB|GB|s|min|h|hours?)\b//g' \
            -e 's/[[:space:]]+/ /g' \
        | sha256sum | awk '{ print $1 }'
}

body_a=$'SELFCHECK: alert\nSUMMARY: /home at 95% full — unchanged from previous snapshot\nDETAILS:\n- 3 Traceback entries unchanged\nTIMESTAMP: 2026-05-18T09:56:00Z'
body_b=$'SELFCHECK: alert\nSUMMARY: /home at 95% full — unchanged from previous snapshot\nDETAILS:\n- 3 Traceback entries unchanged\nTIMESTAMP: 2026-05-18T13:38:00Z'
body_c=$'SELFCHECK: alert\nSUMMARY: NEW issue: rsync hang on cortex_worktree\nDETAILS:\n- snapshot stalled\nTIMESTAMP: 2026-05-18T13:38:00Z'

fp_a="$(compute_fp "${body_a}")"
fp_b="$(compute_fp "${body_b}")"
fp_c="$(compute_fp "${body_c}")"

if [[ "${fp_a}" != "${fp_b}" ]]; then
    echo "FAIL: body_a and body_b differ only in timestamp; fingerprints should match" >&2
    echo "  fp_a=${fp_a}" >&2
    echo "  fp_b=${fp_b}" >&2
    fail=1
fi
if [[ "${fp_a}" == "${fp_c}" ]]; then
    echo "FAIL: body_a and body_c are substantively different; fingerprints must differ" >&2
    fail=1
fi

# State-file lifecycle: first run writes; same-fp second run within window
# suppresses; different-fp third run writes.
state_dir="$(mktemp -d)"
trap 'rm -rf "${state_dir}"' EXIT
state_file="${state_dir}/selfcheck_alert_state"
realert_secs=86400
now_epoch="$(date -u +%s)"

# Step 1: no state yet → must send.
last_fp=""; last_epoch=0
if [[ -f "${state_file}" ]]; then
    last_fp="$(awk -F'\t' 'NR==1 { print $1 }' "${state_file}")"
    last_epoch="$(awk -F'\t' 'NR==1 { print $2 }' "${state_file}")"
fi
if [[ "${fp_a}" == "${last_fp}" && $(( now_epoch - last_epoch )) -lt ${realert_secs} ]]; then
    echo "FAIL: step1 should have sent (no prior state)" >&2; fail=1
fi
printf '%s\t%s\t%s\n' "${fp_a}" "${now_epoch}" "0" > "${state_file}"

# Step 2: same body, should suppress.
last_fp="$(awk -F'\t' 'NR==1 { print $1 }' "${state_file}")"
last_epoch="$(awk -F'\t' 'NR==1 { print $2 }' "${state_file}")"
suppress=0
if [[ "${fp_b}" == "${last_fp}" && $(( now_epoch - last_epoch )) -lt ${realert_secs} ]]; then
    suppress=1
fi
if (( suppress != 1 )); then
    echo "FAIL: step2 should have suppressed (same fingerprint, fresh state)" >&2; fail=1
fi

# Step 3: different body → must send and rewrite state.
last_fp="$(awk -F'\t' 'NR==1 { print $1 }' "${state_file}")"
last_epoch="$(awk -F'\t' 'NR==1 { print $2 }' "${state_file}")"
suppress=0
if [[ "${fp_c}" == "${last_fp}" && $(( now_epoch - last_epoch )) -lt ${realert_secs} ]]; then
    suppress=1
fi
if (( suppress == 1 )); then
    echo "FAIL: step3 should have sent (different fingerprint)" >&2; fail=1
fi

# Step 4: stale state (>=realert_secs old) should send even with same fp.
stale_epoch=$(( now_epoch - realert_secs - 60 ))
printf '%s\t%s\t%s\n' "${fp_a}" "${stale_epoch}" "10" > "${state_file}"
last_fp="$(awk -F'\t' 'NR==1 { print $1 }' "${state_file}")"
last_epoch="$(awk -F'\t' 'NR==1 { print $2 }' "${state_file}")"
suppress=0
if [[ "${fp_a}" == "${last_fp}" && $(( now_epoch - last_epoch )) -lt ${realert_secs} ]]; then
    suppress=1
fi
if (( suppress == 1 )); then
    echo "FAIL: step4 should have sent (state older than realert window)" >&2; fail=1
fi

# Verify the launcher source still uses the same regex shape so this test
# stays meaningful. If `scripts/start_agent.sh`'s fingerprint compute
# drifts, this regex stops matching and the test fails loudly.
if ! grep -q "s/\\[0-9\\]{4}-\\[0-9\\]{2}-\\[0-9\\]{2}T\\[0-9:.+Z-\\]+//g" "${CORTEX_DIR}/scripts/start_agent.sh"; then
    echo "FAIL: scripts/start_agent.sh no longer uses the documented timestamp-stripping regex" >&2
    fail=1
fi

if (( fail )); then
    echo "selfcheck-dedup smoke FAILED" >&2
    exit 1
fi
echo "ok: selfcheck-dedup smoke passed"
