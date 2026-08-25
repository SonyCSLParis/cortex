#!/usr/bin/env bash
# =============================================================================
# run_mac_tests.sh — one entry point to check that this Cortex checkout runs
# correctly on this host (developed for macOS Bash 3.2 + BSD userland).
#
# Runs, in order:
#   - tests/test_mac_portability.sh        syntax + Bash-4 scan + userland (tri-state)
#   - tests/test_bash_compat.sh            unit tests for the bash_compat helpers
#   - roles/operational/backup/test_backup_freshness_predicate.sh
#                                         existing snapshot predicate smoke
#   - test_selfcheck_alert_dedup.sh        existing dedup smoke
#   - test_usage_capture_bounds.sh         existing usage-bounds smoke
#   - cortex_doctor.sh                     framework-invariant validators (tri-state)
#   With --full also:
#   - control_plane_smoke.sh     live worker COMMAND->RESPONSE round-trip
#                                (needs a logged-in provider; slow)
#
# Exit: 0 all ok, 1 warnings only, 2 one or more failures.
# Usage: bash scripts/tests/run_mac_tests.sh [--full] [--provider codex|claude]
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CORTEX_DIR="${CORTEX_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd -P)}"
cd "${CORTEX_DIR}" || { echo "cortex dir not found: ${CORTEX_DIR}" >&2; exit 2; }

FULL=0
PROVIDER=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --full) FULL=1; shift ;;
        --provider) PROVIDER="${2:-}"; shift 2 ;;
        -h|--help)
            sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

# Result accounting. Tri-state tests treat exit 1 as a warning, not a failure.
RESULTS=""
ANY_FAIL=0
ANY_WARN=0

run_test() {
    # run_test <label> <tristate:0|1> <cmd...>
    local label="$1" tristate="$2"; shift 2
    echo
    echo "============================================================"
    echo ">>> ${label}"
    echo "============================================================"
    local rc=0
    "$@" || rc=$?
    local status
    if (( rc == 0 )); then
        status="ok"
    elif (( tristate == 1 && rc == 1 )); then
        status="warn"; ANY_WARN=1
    else
        status="FAIL(rc=${rc})"; ANY_FAIL=1
    fi
    RESULTS="${RESULTS}  ${status}	${label}"$'\n'
}

run_test "portability (syntax/bash4/userland)" 1 bash scripts/tests/test_mac_portability.sh
run_test "bash_compat unit tests"              0 bash scripts/tests/test_bash_compat.sh
run_test "snapshot-freshness predicate smoke"  0 bash roles/operational/backup/test_backup_freshness_predicate.sh
run_test "selfcheck alert dedup smoke"         0 bash scripts/test_selfcheck_alert_dedup.sh
run_test "usage capture bounds smoke"          0 bash scripts/test_usage_capture_bounds.sh
run_test "cortex_doctor invariants"            1 bash scripts/cortex_doctor.sh

if (( FULL )); then
    smoke_args=()
    [[ -n "${PROVIDER}" ]] && smoke_args=(--provider "${PROVIDER}")
    run_test "control-plane smoke (live worker)" 0 bash scripts/control_plane_smoke.sh "${smoke_args[@]}"
else
    RESULTS="${RESULTS}  skip	control-plane smoke (live worker) — pass --full to run"$'\n'
fi

echo
echo "============================================================"
echo "SUMMARY"
echo "============================================================"
printf '%s' "${RESULTS}" | sed 's/^/ /'

echo
if (( ANY_FAIL )); then
    echo "RESULT: FAIL — one or more tests failed on this host"
    exit 2
fi
if (( ANY_WARN )); then
    echo "RESULT: ok with warnings — review flagged items above"
    exit 1
fi
echo "RESULT: ok — Cortex runs cleanly on this host ($(uname -s) bash ${BASH_VERSION%%(*})"
exit 0
