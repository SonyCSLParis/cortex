#!/usr/bin/env bash
# rotate_logbook.sh — deterministic compactor for any Cortex logbook family.
#
# Policy (conductor.instruct §Logbook):
#   - The last MIN_AGE_HOURS of entries always stay in the live file,
#     regardless of its size.
#   - The size threshold (LIVE_MAX_LINES / LIVE_MAX_BYTES) only *triggers*
#     a rotation — rotation itself moves only entries older than
#     MIN_AGE_HOURS into sibling history/logbook_YYYY-MM-DD_HH-MM.md.
#   - If the live file is over threshold but every entry is <MIN_AGE_HOURS
#     old, this script is a no-op and logs a notice.
#
# Sections are partitioned by timestamp parsed from the header line
# "## [ISO_TIMESTAMP] — topic {#tag}". Sections with an unparseable
# timestamp (e.g. "## [2026-04-17 morning]") stay in the live file — we
# prefer false-negative rotation over accidentally archiving something
# recent.
#
# Idempotent. Atomic (.tmp + mv). flock-guarded on .logbook.lock so
# concurrent append_logbook calls (conductor_standby.sh) cannot race the
# rewrite. Existing append paths do not themselves take the lock —
# the rotation window is <1 s and writers use `>>` which is atomic at
# the OS level for short lines, so the remaining race is tiny but not
# zero.
#
# Usage:
#   bash roles/operational/compressor/rotate_logbook.sh [path/to/logbook.md]
#
# Env overrides:
#   CORTEX_DIR     default: repo root resolved from this script
#   LIVE_MAX_LINES  default: CORTEX_DEFAULT_LOGBOOK_LIVE_MAX_LINES
#   LIVE_MAX_BYTES  default: CORTEX_DEFAULT_LOGBOOK_LIVE_MAX_BYTES
#   MIN_AGE_HOURS   default: CORTEX_DEFAULT_LOGBOOK_MIN_AGE_HOURS
#                   (entries younger than this never move)

set -euo pipefail
shopt -s nullglob

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CORTEX_DIR="${CORTEX_DIR:-$(cd "${SCRIPT_DIR}/../../.." && pwd -P)}"
source "${CORTEX_DIR}/config/cortex_defaults.sh"
source "${CORTEX_DIR}/scripts/bash_compat.sh"
LOGBOOK_INPUT="${1:-agents/conductor/logbook.md}"
LIVE_MAX_LINES="${LIVE_MAX_LINES:-${CORTEX_DEFAULT_LOGBOOK_LIVE_MAX_LINES}}"
LIVE_MAX_BYTES="${LIVE_MAX_BYTES:-${CORTEX_DEFAULT_LOGBOOK_LIVE_MAX_BYTES}}"
MIN_AGE_HOURS="${MIN_AGE_HOURS:-${CORTEX_DEFAULT_LOGBOOK_MIN_AGE_HOURS}}"

if [[ "${LOGBOOK_INPUT}" != /* ]]; then
    LOGBOOK="${CORTEX_DIR}/${LOGBOOK_INPUT}"
else
    LOGBOOK="${LOGBOOK_INPUT}"
fi
LOGBOOK_DIR="$(cd "$(dirname "${LOGBOOK}")" && pwd)"
LOGBOOK="${LOGBOOK_DIR}/$(basename "${LOGBOOK}")"
HISTORY_DIR="${LOGBOOK_DIR}/history"
LOCK_FILE="${LOGBOOK_DIR}/.logbook.lock"
REL_LOGBOOK="${LOGBOOK#${CORTEX_DIR}/}"

[[ -f "${LOGBOOK}" ]] || { echo "rotate_logbook: no logbook at ${LOGBOOK}" >&2; exit 0; }
[[ "$(basename "${LOGBOOK}")" == "logbook.md" ]] || {
    echo "rotate_logbook: expected a logbook.md path, got ${LOGBOOK}" >&2
    exit 2
}

mkdir -p "${HISTORY_DIR}"
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
    echo "rotate_logbook: logbook busy, skipping" >&2
    exit 0
fi

lines=$(wc -l < "${LOGBOOK}")
bytes=$(wc -c < "${LOGBOOK}")

if (( lines <= LIVE_MAX_LINES )) && (( bytes <= LIVE_MAX_BYTES )); then
    exit 0
fi

first_section=$(grep -n '^## \[' "${LOGBOOK}" | head -1 | cut -d: -f1 || true)
if [[ -z "${first_section}" ]]; then
    echo "rotate_logbook: no '## [' sections; nothing to rotate" >&2
    exit 0
fi
header_end=$(( first_section - 1 ))

section_lines=()
while IFS= read -r section_line; do
    [[ -n "${section_line}" ]] || continue
    section_lines+=("${section_line}")
done < <(grep -n '^## \[' "${LOGBOOK}" | cut -d: -f1)
section_count="$(bash_array_len section_lines)"
(( section_count < 2 )) && exit 0

cutoff_epoch=$(( $(date +%s) - MIN_AGE_HOURS * 3600 ))
old_starts=()
old_ends=()
recent_starts=()
recent_ends=()

for (( i=0; i<section_count; i++ )); do
    start=${section_lines[i]}
    if (( i == section_count - 1 )); then
        end=$lines
    else
        end=$(( section_lines[i+1] - 1 ))
    fi
    header_line=$(sed -n "${start}p" "${LOGBOOK}")
    ts_str=$(printf '%s' "${header_line}" | sed -nE 's/^## \[([^]]+)\].*/\1/p')
    section_epoch=0
    if [[ -n "${ts_str}" ]]; then
        ts_clean=$(printf '%s' "${ts_str}" | sed -E 's/~//g; s/^([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2})\+/\1T\2:00+/')
        section_epoch="$(iso8601_to_epoch_utc "${ts_clean}")"
    fi
    if (( section_epoch > 0 && section_epoch < cutoff_epoch )); then
        old_starts+=("${start}")
        old_ends+=("${end}")
    else
        recent_starts+=("${start}")
        recent_ends+=("${end}")
    fi
done

if (( $(bash_array_len old_starts) == 0 )); then
    echo "rotate_logbook: ${REL_LOGBOOK} over threshold (${lines} lines / ${bytes} bytes) but no entries >=${MIN_AGE_HOURS}h old; keeping live intact" >&2
    exit 0
fi

clean_header() {
    (( header_end > 0 )) || return 0
    sed -n "1,${header_end}p" "${LOGBOOK}" | sed -E '/^<!-- continued from history\/.*-->[[:space:]]*$/d'
}

stamp=$(date '+%Y-%m-%d_%H-%M')
history_file="${HISTORY_DIR}/logbook_${stamp}.md"
if [[ -e "${history_file}" ]]; then
    history_file="${HISTORY_DIR}/logbook_${stamp}_$$.md"
fi

before_headers="$(mktemp)"
after_headers="$(mktemp)"
clean_header_tmp="$(mktemp)"
existing_history_headers="$(mktemp)"
candidate_old_headers="$(mktemp)"
duplicate_old_headers="$(mktemp)"
history_tmp="${history_file}.tmp"
live_tmp="${LOGBOOK}.tmp"
trap 'rm -f "${before_headers}" "${after_headers}" "${clean_header_tmp}" "${existing_history_headers}" "${candidate_old_headers}" "${duplicate_old_headers}" "${history_tmp}" "${live_tmp}"' EXIT

{
    while IFS= read -r shard; do
        [[ -n "${shard}" ]] || continue
        grep '^## \[' "${shard}" || true
    done < <(find "${HISTORY_DIR}" -maxdepth 1 -type f -name 'logbook_*.md' | LC_ALL=C sort)
} > "${existing_history_headers}"

: > "${candidate_old_headers}"
for (( i=0; i<$(bash_array_len old_starts); i++ )); do
    sed -n "${old_starts[i]}p" "${LOGBOOK}" >> "${candidate_old_headers}"
done

if [[ -s "${existing_history_headers}" ]]; then
    grep -Fxf "${existing_history_headers}" "${candidate_old_headers}" | LC_ALL=C sort -u > "${duplicate_old_headers}" || true
    if [[ -s "${duplicate_old_headers}" ]]; then
        dup_count="$(wc -l < "${duplicate_old_headers}" | tr -d ' ')"
        dup_example="$(head -n 1 "${duplicate_old_headers}")"
        echo "rotate_logbook: ${REL_LOGBOOK} refusing rotation; ${dup_count} section header(s) slated for archival already exist in history (example: ${dup_example})" >&2
        exit 1
    fi
fi

rg -H '^## \[' "${LOGBOOK}" "${HISTORY_DIR}"/*.md 2>/dev/null \
    | sed -E 's#^[^:]+:##' \
    | LC_ALL=C sort > "${before_headers}"

clean_header > "${clean_header_tmp}"

{
    cat "${clean_header_tmp}"
    for (( i=0; i<$(bash_array_len old_starts); i++ )); do
        sed -n "${old_starts[i]},${old_ends[i]}p" "${LOGBOOK}"
    done
} > "${history_tmp}"

{
    cat "${clean_header_tmp}"
} > "${live_tmp}"

{
    find "${HISTORY_DIR}" -maxdepth 1 -type f -name 'logbook_*.md' -exec basename {} \; 2>/dev/null
    printf '%s\n' "$(basename "${history_file}")"
} | LC_ALL=C sort -u | while read -r shard; do
    [[ -n "${shard}" ]] && printf '<!-- continued from history/%s -->\n' "${shard}"
done >> "${live_tmp}"

printf '\n' >> "${live_tmp}"
for (( i=0; i<$(bash_array_len recent_starts); i++ )); do
    sed -n "${recent_starts[i]},${recent_ends[i]}p" "${LOGBOOK}" >> "${live_tmp}"
done

rg -H '^## \[' "${live_tmp}" "${HISTORY_DIR}"/*.md "${history_tmp}" 2>/dev/null \
    | sed -E 's#^[^:]+:##' \
    | LC_ALL=C sort > "${after_headers}"

if ! cmp -s "${before_headers}" "${after_headers}"; then
    echo "rotate_logbook: ${REL_LOGBOOK} header coverage mismatch; refusing rewrite" >&2
    exit 1
fi

mv "${history_tmp}" "${history_file}"
mv "${live_tmp}" "${LOGBOOK}"

pointer_count=$(find "${HISTORY_DIR}" -maxdepth 1 -type f -name 'logbook_*.md' | wc -l)
moved="$(bash_array_len old_starts)"
kept="$(bash_array_len recent_starts)"
new_lines=$(wc -l < "${LOGBOOK}")
echo "rotate_logbook: ${REL_LOGBOOK} moved ${moved} section(s) >=${MIN_AGE_HOURS}h old to $(basename "${history_file}"); kept ${kept} section(s) in live (${new_lines} lines, ${pointer_count} history shard pointers)"
