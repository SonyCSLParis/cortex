#!/usr/bin/env bash
# =============================================================================
# test_mac_portability.sh — static + environment checks that the Cortex shell
# scripts run on macOS (Bash 3.2 + BSD userland), not just on Linux/Bash 4+.
#
# Three sections:
#   1. SYNTAX  — `bash -n` parse check on every framework shell script. FAIL.
#   2. BASH4   — scan for Bash-4-only constructs (mapfile/readarray/assoc
#                arrays/case-modification expansions) that silently break on
#                the system Bash 3.2. FAIL if any appear.
#   3. ENV     — probe this host's userland (timeout/stat/date/etc.) and WARN
#                when a tool the scripts call directly is missing here.
#
# Tri-state exit, matching cortex_doctor.sh:
#   0 = all ok, 1 = warnings only, 2 = one or more hard failures.
#
# Run from anywhere: bash scripts/tests/test_mac_portability.sh
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CORTEX_DIR="${CORTEX_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd -P)}"
cd "${CORTEX_DIR}" || { echo "cortex dir not found: ${CORTEX_DIR}" >&2; exit 2; }

SELF_BASENAME="$(basename "${BASH_SOURCE[0]}")"
FAIL_COUNT=0
WARN_COUNT=0

note_fail() { printf '  FAIL %s\n' "$1" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
note_warn() { printf '  warn %s\n' "$1"; WARN_COUNT=$((WARN_COUNT + 1)); }
note_ok()   { printf '  ok   %s\n' "$1"; }

# Collect framework shell scripts (scripts/, roles/ incl. subdirs, config/).
shell_scripts() {
    find scripts roles config -type f -name '*.sh' 2>/dev/null | sort
}

# -----------------------------------------------------------------------------
echo "[1] syntax (bash -n) — system bash ${BASH_VERSION%%(*}"
syntax_bad=0
while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    if ! err="$(bash -n "${f}" 2>&1)"; then
        note_fail "parse error in ${f}: ${err}"
        syntax_bad=$((syntax_bad + 1))
    fi
done <<EOF
$(shell_scripts)
EOF
(( syntax_bad == 0 )) && note_ok "all framework shell scripts parse under bash ${BASH_VERSION%%(*}"

# -----------------------------------------------------------------------------
echo "[2] bash-4-only constructs (must be absent for Bash 3.2)"
# Each pattern is a feature that does not exist in Bash 3.2. We scan all
# framework shell scripts except this file (which necessarily names them).
bash4_hits=0
scan_targets() { shell_scripts | grep -v "/${SELF_BASENAME}\$"; }

check_pattern() {
    # check_pattern <label> <rg-regex>
    local label="$1" regex="$2" hits
    hits="$(scan_targets | tr '\n' '\0' | xargs -0 rg -n --no-heading "${regex}" 2>/dev/null)"
    if [[ -n "${hits}" ]]; then
        note_fail "${label} found:"
        printf '%s\n' "${hits}" | sed 's/^/         /' >&2
        bash4_hits=$((bash4_hits + 1))
    fi
}

check_pattern "mapfile/readarray (no equivalent in Bash 3.2)" '\b(mapfile|readarray)\b'
check_pattern "associative arrays (declare/local -A)" '\b(declare|local)\b[^#]*[[:space:]]-A\b'
check_pattern "case-modification expansion \${v^^}/\${v,,}" '\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?[\^,]{1,2}'
(( bash4_hits == 0 )) && note_ok "no Bash-4-only constructs present"

# -----------------------------------------------------------------------------
echo "[3] environment / userland on this host ($(uname -s))"
have() { command -v "$1" >/dev/null 2>&1; }

# Tools the framework relies on; missing 'screen'/'python3'/'git'/'ssh' is a
# hard problem for normal operation, so FAIL. Others are informational.
for t in git ssh ssh-agent python3 screen; do
    if have "${t}"; then note_ok "found ${t}"; else note_fail "missing required tool: ${t}"; fi
done

# GNU vs BSD userland: the scripts must already handle BSD here.
if stat -c %Y / >/dev/null 2>&1; then
    note_ok "stat: GNU (-c) available"
else
    note_ok "stat: BSD userland (no -c) — bash_compat file_mtime_epoch must use -f %m"
fi
if date -d @0 >/dev/null 2>&1; then
    note_ok "date: GNU (-d) available"
else
    note_ok "date: BSD userland (no -d) — bash_compat date helpers must use -r/-j"
fi

# timeout availability (informational): bash_compat.run_with_timeout and the
# guarded callers degrade gracefully when it is absent.
if have timeout || have gtimeout; then
    note_ok "timeout/gtimeout available"
else
    note_ok "no timeout/gtimeout on this host (guarded callers fall back to no-timeout)"
fi

# Unguarded direct `timeout`/`gtimeout` invocations are a real portability gap:
# on any host without coreutils they fail. We flag a file only when it invokes
# timeout at statement position AND lacks a `command -v (g)timeout` guard — this
# excludes the guarded wrappers and doc/string mentions, leaving true gaps.
# A statement-position invocation: line start, optional leading whitespace,
# optional inline `VAR=val` assignments, then `timeout`/`gtimeout` + a space.
invoke_regex='^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*g?timeout[[:space:]]'
unguarded=""
while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    invs="$(rg -n --no-heading "${invoke_regex}" "${f}" 2>/dev/null || true)"
    [[ -n "${invs}" ]] || continue
    rg -q 'command -v g?timeout' "${f}" 2>/dev/null && continue
    while IFS= read -r line; do
        [[ -n "${line}" ]] && unguarded="${unguarded}${f}:${line}"$'\n'
    done <<EOF2
${invs}
EOF2
done <<EOF
$(scan_targets)
EOF
if [[ -n "${unguarded}" ]]; then
    note_warn "unguarded direct timeout/gtimeout calls (fail on hosts without coreutils):"
    printf '%s' "${unguarded}" | sed 's/^/         /'
else
    note_ok "no unguarded direct timeout/gtimeout invocations"
fi

# flock / bwrap: absence is expected on macOS and the framework has fallbacks
# (mkdir locks, macos-direct worker backend). Informational only.
have flock || note_ok "flock absent (expected on macOS — locks use mkdir, not flock)"
have bwrap || note_ok "bwrap absent (expected on macOS — workers use macos-direct backend)"

# -----------------------------------------------------------------------------
echo
if (( FAIL_COUNT > 0 )); then
    echo "FAIL: ${FAIL_COUNT} failure(s), ${WARN_COUNT} warning(s)" >&2
    exit 2
fi
if (( WARN_COUNT > 0 )); then
    echo "ok with warnings: ${WARN_COUNT} warning(s) — review above"
    exit 1
fi
echo "ok: macOS portability checks passed"
exit 0
