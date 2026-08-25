#!/usr/bin/env bash
# =============================================================================
# test_bash_compat.sh — unit tests for ../bash_compat.sh helpers.
#
# Runs every compat helper under `set -uo pipefail` on the *current* host's
# shell and userland, then asserts the result. This is the proof that the
# Bash-3 / BSD-userland compatibility layer actually behaves on this machine
# (macOS Bash 3.2 + BSD stat/date/readlink), not just that it parses.
#
# `set -u` is deliberate: the original macOS breakage was empty-array
# expansion under `set -u`, so the helpers must survive it here.
#
# Run from anywhere: bash scripts/tests/test_bash_compat.sh
# Exit 0 = all assertions passed; nonzero = first failure (with detail).
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CORTEX_DIR="${CORTEX_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd -P)}"
# shellcheck source=/dev/null
source "${CORTEX_DIR}/scripts/bash_compat.sh"

FAILED=0
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; FAILED=$((FAILED + 1)); }

assert_eq() {
    # assert_eq <label> <expected> <actual>
    if [[ "$2" == "$3" ]]; then
        pass "$1"
    else
        fail "$1 — expected [$2], got [$3]"
    fi
}

assert_match() {
    # assert_match <label> <regex> <actual>
    if [[ "$3" =~ $2 ]]; then
        pass "$1"
    else
        fail "$1 — [$3] does not match /$2/"
    fi
}

echo "bash $BASH_VERSION on $(uname -s)"

# ---- bash_array_len: the core set -u empty-array survival case --------------
empty_arr=()
assert_eq "bash_array_len empty array under set -u" "0" "$(bash_array_len empty_arr)"
filled_arr=(a b c)
assert_eq "bash_array_len populated array" "3" "$(bash_array_len filled_arr)"

# ---- named_array_clear / copy / append / append_unique ----------------------
named_array_clear filled_arr
assert_eq "named_array_clear empties the array" "0" "$(bash_array_len filled_arr)"

source_arr=(x y z)
copy_arr=()
named_array_copy source_arr copy_arr
assert_eq "named_array_copy length" "3" "$(bash_array_len copy_arr)"
assert_eq "named_array_copy element 1" "y" "${copy_arr[1]}"
src=(left right)
dest=()
named_array_copy src dest
assert_eq "named_array_copy tolerates src/dest caller names" "2" "$(bash_array_len dest)"
assert_eq "named_array_copy src/dest element 0" "left" "${dest[0]}"

acc=()
named_array_append acc one two
assert_eq "named_array_append two items" "2" "$(bash_array_len acc)"
named_array_append_unique acc two
assert_eq "named_array_append_unique skips duplicate" "2" "$(bash_array_len acc)"
named_array_append_unique acc three
assert_eq "named_array_append_unique adds new" "3" "$(bash_array_len acc)"

# ---- run_with_array_prefix: empty vs non-empty prefix -----------------------
no_prefix=()
assert_eq "run_with_array_prefix empty prefix runs command directly" \
    "hi" "$(run_with_array_prefix no_prefix printf '%s' hi)"
env_prefix=(env CORTEX_TEST_MARK=on)
assert_match "run_with_array_prefix non-empty prefix wraps command" \
    "CORTEX_TEST_MARK=on" "$(run_with_array_prefix env_prefix env | grep CORTEX_TEST_MARK)"

# ---- run_with_timeout: must run the command (timeout present or not) --------
assert_eq "run_with_timeout passes through command output" \
    "done" "$(run_with_timeout 5 printf '%s' done)"

# ---- file_mtime_epoch: real file yields a positive integer (BSD stat -f %m) -
probe_file="${WORKDIR}/mtime_probe"
: > "${probe_file}"
mtime="$(file_mtime_epoch "${probe_file}")"
assert_match "file_mtime_epoch returns positive integer" "^[1-9][0-9]+$" "${mtime}"

# ---- epoch <-> ISO8601 UTC round-trip (BSD date -r / date -j fallbacks) -----
assert_eq "epoch_to_iso8601_utc(0)" "1970-01-01T00:00:00Z" "$(epoch_to_iso8601_utc 0)"
assert_eq "iso8601_to_epoch_utc(epoch 0 string)" "0" "$(iso8601_to_epoch_utc 1970-01-01T00:00:00Z)"
round_in=1700000000
round_iso="$(epoch_to_iso8601_utc "${round_in}")"
round_out="$(iso8601_to_epoch_utc "${round_iso}")"
assert_eq "epoch->iso->epoch round-trip" "${round_in}" "${round_out}"

# ---- normalize_abs_path_components: pure-shell path canonicalization --------
assert_eq "normalize collapses .. segment" "/a/c" "$(normalize_abs_path_components /a/b/../c)"
assert_eq "normalize drops . segment" "/a/b" "$(normalize_abs_path_components /a/./b)"
assert_eq "normalize root stays root" "/" "$(normalize_abs_path_components /)"
assert_eq "normalize underflow clamps to root" "/" "$(normalize_abs_path_components /a/../..)"

# ---- readlink_f_compat: resolves a symlink to its target --------------------
real_target="${WORKDIR}/real_target"
: > "${real_target}"
ln -s "${real_target}" "${WORKDIR}/link"
resolved="$(readlink_f_compat "${WORKDIR}/link")"
# Compare by inode, not string: macOS canonicalizes /var -> /private/var, so a
# literal path match would be wrong even though the helper resolved correctly.
if [[ -n "${resolved}" && "${resolved}" -ef "${real_target}" ]]; then
    pass "readlink_f_compat resolves symlink to target inode"
else
    fail "readlink_f_compat resolves symlink — [${resolved}] is not the same file as [${real_target}]"
fi

# ---- realpath_m_compat: canonicalizes a non-existent path -------------------
assert_eq "realpath_m_compat on non-existent path" \
    "${WORKDIR}/foo" "$(realpath_m_compat "${WORKDIR}/sub/../foo")"

echo
if (( FAILED > 0 )); then
    echo "FAIL: ${FAILED} bash_compat assertion(s) failed on this host" >&2
    exit 1
fi
echo "ok: all bash_compat helpers passed on $(uname -s) bash ${BASH_VERSION%%(*}"
