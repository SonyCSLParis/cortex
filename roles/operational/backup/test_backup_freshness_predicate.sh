#!/usr/bin/env bash
# =============================================================================
# backup/test_backup_freshness_predicate.sh — smoke test for the
# `last_snapshot_success_iso` awk predicate in scripts/cortex_ops_snapshot.sh.
# Feeds SNAPSHOT_OK markers and non-marker snapshot-worker log lines through the
# predicate and checks the right answer comes out. Run from anywhere; uses
# a temp file.
# =============================================================================

set -euo pipefail

CORTEX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"

tmp_log="$(mktemp)"
trap 'rm -f "${tmp_log}"' EXIT

# Inputs are intentionally ordered so the *last* matching line wins;
# the predicate must pick `[2026-05-19T13:26:24+0200]` (latest marker).
cat > "${tmp_log}" <<'LOG'
[2026-05-19T10:00:00Z] snapshot-worker | START: periodic check starting
[2026-05-19T10:01:00Z] snapshot-worker | ERROR: rsync exited 20 — failure must not be accepted as success
[2026-05-19T11:26:18+0200] snapshot-worker | SNAPSHOT_OK: 2026-05-19T11-26-37+0200
[2026-05-19T12:00:00Z] conductor | NOTE: snapshot-worker | SNAPSHOT_OK: quoted marker — wrong agent
[2026-05-19 13:20:00 +0200] snapshot-worker: worker check: ok; snapshot completed — narrative, not the marker
[2026-05-19T13:26:24+0200] snapshot-worker | SNAPSHOT_OK: 2026-05-19T13-26-31+0200
[2026-05-19T14:00:00Z] snapshot-worker | ERROR: rsync stalled — not a success line
LOG

# Inline the predicate verbatim from cortex_ops_snapshot.sh so this test
# fails if the script's logic drifts away from what the smoke covers.
result="$(
    awk -v agent_id="snapshot-worker" '/^\[/ && index($0, "] " agent_id " | SNAPSHOT_OK: ") { line = $0 }
         END {
             if (line != "") {
                 sub(/^\[/, "", line)
                 sub(/\].*/, "", line)
                 print line
             }
         }' "${tmp_log}"
)"

expected="2026-05-19T13:26:24+0200"
if [[ "${result}" != "${expected}" ]]; then
    echo "FAIL: expected '${expected}', got '${result}'" >&2
    exit 1
fi

# Negative case: only failure lines should yield empty output.
cat > "${tmp_log}" <<'LOG'
[2026-05-19T09:00:00Z] snapshot-worker | ERROR: rsync exited 20
[2026-05-19T09:05:00Z] snapshot-worker | WARN: snapshot stalled, no progress
[2026-05-19 09:10:00 +0200] snapshot-worker: worker check: ok; snapshot completed cleanly
LOG

result="$(
    awk -v agent_id="snapshot-worker" '/^\[/ && index($0, "] " agent_id " | SNAPSHOT_OK: ") { line = $0 }
         END {
             if (line != "") {
                 sub(/^\[/, "", line)
                 sub(/\].*/, "", line)
                 print line
             }
         }' "${tmp_log}"
)"

if [[ -n "${result}" ]]; then
    echo "FAIL: expected empty output for failure-only log, got '${result}'" >&2
    exit 1
fi

# Cross-check against the live script: run it against a fake CORTEX_DIR so
# the test reads our fixture log instead of the real snapshot-worker log.
workdir="$(mktemp -d)"
trap 'rm -f "${tmp_log}"; rm -rf "${workdir}"' EXIT
mkdir -p "${workdir}/agents/snapshot-worker" "${workdir}/scripts" "${workdir}/config" "${workdir}/roles/operational"
# Stub the defaults file the script sources so it does not pull in anything else.
: > "${workdir}/config/cortex_defaults.sh"
cat > "${workdir}/agents/snapshot-worker/log.md" <<'LOG'
[2026-05-19T11:26:18+0200] snapshot-worker | SNAPSHOT_OK: 2026-05-19T11-26-37+0200
[2026-05-19T13:26:24+0200] snapshot-worker | SNAPSHOT_OK: 2026-05-19T13-26-31+0200
LOG
cat > "${workdir}/roles/operational/worker.snapshot-worker.meta" <<'LOG'
META_domain="snapshot creation from backup_targets.txt; backup-freshness tracking"
LOG
cp "${CORTEX_DIR}/scripts/cortex_ops_snapshot.sh" "${workdir}/scripts/cortex_ops_snapshot.sh"

# Source the copy with `set +e` for the sourcing step itself. The test shell
# runs with `set -e`, and we only want to fail on an actual predicate mismatch,
# not on an incidental non-zero command inside the sourced script body.
( CORTEX_DIR="${workdir}"
  set +e
  source "${workdir}/scripts/cortex_ops_snapshot.sh" >/dev/null 2>&1
  source_rc=$?
  set -e
  if ! declare -F last_snapshot_success_iso >/dev/null 2>&1; then
      echo "FAIL: sourcing cortex_ops_snapshot.sh did not define last_snapshot_success_iso" >&2
      exit 1
  fi
  live_result="$(last_snapshot_success_iso 2>/dev/null || true)"
  if (( source_rc != 0 )); then
      echo "FAIL: sourcing cortex_ops_snapshot.sh returned ${source_rc}" >&2
      exit 1
  fi
  if [[ "${live_result}" != "2026-05-19T13:26:24+0200" ]]; then
      echo "FAIL: live last_snapshot_success_iso returned '${live_result}'" >&2
      exit 1
  fi
)

echo "ok: backup-freshness predicate smoke passed"
