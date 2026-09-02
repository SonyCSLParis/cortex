#!/usr/bin/env bash
# rotate_tasks_done.sh — deterministic compactor for retired Cortex task rows.
#
# Policy:
#   - Keep active sections unchanged.
#   - Keep only the newest KEEP_RECENT_DONE Done rows live in tasks.md.
#   - Keep only the newest KEEP_RECENT_CANCELLED Cancelled rows live in tasks.md.
#   - Move older live retired rows verbatim into sibling history/tasks_*.md shards.
#   - Rebuild each live pointer block from the existing sibling history shards on each run.
#
# Usage:
#   bash roles/operational/compressor/rotate_tasks_done.sh [--all]
#   bash roles/operational/compressor/rotate_tasks_done.sh path/to/tasks.md [path/to/other/tasks.md ...]
#
# With no arguments, the script scans known durable homes for task boards:
#   agents/*/tasks.md
#   projects/*/tasks.md
#   users/*/tasks.md
#
# Env overrides:
#   CORTEX_DIR         default: repo root resolved from this script
#   KEEP_RECENT_DONE        default: CORTEX_DEFAULT_TASKS_KEEP_RECENT_DONE
#   DONE_ROTATE_MIN         default: CORTEX_DEFAULT_TASKS_DONE_ROTATE_MIN
#                           (do nothing unless live Done rows exceed this)
#   KEEP_RECENT_CANCELLED   default: CORTEX_DEFAULT_TASKS_KEEP_RECENT_CANCELLED
#   CANCELLED_ROTATE_MIN    default: CORTEX_DEFAULT_TASKS_CANCELLED_ROTATE_MIN
#                           (do nothing unless live Cancelled rows exceed this)

set -euo pipefail
shopt -s nullglob

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CORTEX_DIR="${CORTEX_DIR:-$(cd "${SCRIPT_DIR}/../../.." && pwd -P)}"
source "${CORTEX_DIR}/config/cortex_defaults.sh"
source "${CORTEX_DIR}/scripts/bash_compat.sh"
KEEP_RECENT_DONE="${KEEP_RECENT_DONE:-${CORTEX_DEFAULT_TASKS_KEEP_RECENT_DONE}}"
DONE_ROTATE_MIN="${DONE_ROTATE_MIN:-${CORTEX_DEFAULT_TASKS_DONE_ROTATE_MIN}}"
KEEP_RECENT_CANCELLED="${KEEP_RECENT_CANCELLED:-${CORTEX_DEFAULT_TASKS_KEEP_RECENT_CANCELLED}}"
CANCELLED_ROTATE_MIN="${CANCELLED_ROTATE_MIN:-${CORTEX_DEFAULT_TASKS_CANCELLED_ROTATE_MIN}}"
BEST_EFFORT_SCAN=0

usage() {
    sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
}

discover_tasks_files() {
    find \
        "${CORTEX_DIR}/agents" \
        "${CORTEX_DIR}/projects" \
        "${CORTEX_DIR}/users" \
        -mindepth 2 -maxdepth 2 -type f -name tasks.md 2>/dev/null \
        | LC_ALL=C sort
}

resolve_tasks_file() {
    local tasks_input="$1"
    local tasks_file
    if [[ "${tasks_input}" != /* ]]; then
        tasks_file="${CORTEX_DIR}/${tasks_input}"
    else
        tasks_file="${tasks_input}"
    fi
    [[ -f "${tasks_file}" ]] || { echo "rotate_tasks_done: no tasks file at ${tasks_file}" >&2; return 0; }
    [[ "$(basename "${tasks_file}")" == "tasks.md" ]] || {
        echo "rotate_tasks_done: expected a tasks.md path, got ${tasks_file}" >&2
        return 2
    }
    local tasks_dir
    tasks_dir="$(cd "$(dirname "${tasks_file}")" && pwd -P)"
    printf '%s/%s\n' "${tasks_dir}" "$(basename "${tasks_file}")"
}

handle_rotation_issue() {
    local rel_tasks="$1" detail="$2"
    echo "rotate_tasks_done: ${rel_tasks} ${detail}" >&2
    if (( BEST_EFFORT_SCAN )); then
        return 0
    fi
    return 1
}

validate_tasks_layout() {
    local tasks_file="$1" rel_tasks="$2"
    awk -v rel_tasks="${rel_tasks}" '
        function section_name(status) {
            if (status == "open") return "Open"
            if (status == "doing") return "Doing"
            if (status == "blocked") return "Blocked"
            if (status == "done") return "Done"
            if (status == "cancelled" || status == "expired") return "Cancelled"
            return status
        }
        /^## Open$/ { current = "open"; next }
        /^## Doing$/ { current = "doing"; next }
        /^## Blocked$/ { current = "blocked"; next }
        /^## Done$/ { current = "done"; next }
        /^## Cancelled$/ { current = "cancelled"; next }
        /^- \[(open|doing|blocked|done|cancelled|expired)\]/ {
            status = $0
            sub(/^- \[/, "", status)
            sub(/\].*$/, "", status)
            if (status == "expired") status = "cancelled"
            if (current == "") {
                printf "rotate_tasks_done: %s has [%s] task row outside a recognized task section; advisory only, leaving board unchanged\n", rel_tasks, status > "/dev/stderr"
                invalid = 1
                next
            }
            if (status != current) {
                printf "rotate_tasks_done: %s has [%s] row under ## %s; advisory only, leaving board unchanged\n", rel_tasks, status, section_name(current) > "/dev/stderr"
                invalid = 1
            }
        }
        END { exit invalid ? 1 : 0 }
    ' "${tasks_file}"
}

rotate_one_tasks_file() {
    local tasks_file="$1"
    local tasks_dir history_dir lock_file rel_tasks
    tasks_dir="$(cd "$(dirname "${tasks_file}")" && pwd -P)"
    tasks_file="${tasks_dir}/$(basename "${tasks_file}")"
    history_dir="${tasks_dir}/history"
    lock_file="${tasks_dir}/.tasks.lock"
    rel_tasks="${tasks_file#${CORTEX_DIR}/}"

    if ! validate_tasks_layout "${tasks_file}" "${rel_tasks}"; then
        handle_rotation_issue "${rel_tasks}" "failed section/status validation" || return 1
        return 0
    fi

    if [[ ! -w "${tasks_file}" ]]; then
        handle_rotation_issue "${rel_tasks}" "tasks file is not writable; skipping" || return 1
        return 0
    fi
    if [[ ! -w "${tasks_dir}" ]]; then
        handle_rotation_issue "${rel_tasks}" "task-board directory is not writable; skipping" || return 1
        return 0
    fi
    if [[ -e "${lock_file}" && ! -w "${lock_file}" ]]; then
        handle_rotation_issue "${rel_tasks}" "lock file is not writable; skipping" || return 1
        return 0
    fi
    if [[ -d "${history_dir}" && ! -w "${history_dir}" ]]; then
        handle_rotation_issue "${rel_tasks}" "history directory is not writable; skipping" || return 1
        return 0
    fi

    mkdir -p "${history_dir}"
    (
        flock -n 9 || { echo "rotate_tasks_done: ${rel_tasks} busy, skipping" >&2; exit 0; }
        rotate_section_rows() {
            local section_name="$1" status="$2" keep_recent="$3" rotate_min="$4" shard_prefix="$5"
            local header_line next_header_line section_end_line
            header_line="$(grep -n "^## ${section_name}\$" "${tasks_file}" | head -1 | cut -d: -f1 || true)"
            [[ -n "${header_line}" ]] || return 0

            next_header_line="$(awk -v start="${header_line}" 'NR > start && /^## / { print NR; exit }' "${tasks_file}")"
            if [[ -n "${next_header_line}" ]]; then
                section_end_line=$(( next_header_line - 1 ))
            else
                section_end_line="$(wc -l < "${tasks_file}")"
            fi

            local -a row_lines archive_lines keep_lines history_shards
            local row_line
            while IFS= read -r row_line; do
                [[ -n "${row_line}" ]] || continue
                row_lines+=("${row_line}")
            done < <(sed -n "$((header_line + 1)),${section_end_line}p" "${tasks_file}" | grep -E "^- \\[(${status})\\]" || true)
            local row_count archive_count
            row_count="$(bash_array_len row_lines)"
            if (( row_count <= rotate_min || row_count <= keep_recent )); then
                return 0
            fi

            archive_count=$(( row_count - keep_recent ))
            archive_lines=("${row_lines[@]:0:${archive_count}}")
            keep_lines=("${row_lines[@]:${archive_count}}")

            local stamp history_file tmp_history tmp_tasks local_line shard new_live_count
            stamp="$(date '+%Y-%m-%d_%H-%M')"
            history_file="${history_dir}/${shard_prefix}_${stamp}.md"
            if [[ -e "${history_file}" ]]; then
                history_file="${history_dir}/${shard_prefix}_${stamp}_$$.md"
            fi

            tmp_history="${history_file}.tmp"
            tmp_tasks="${tasks_file}.tmp"
            trap 'rm -f "${tmp_history}" "${tmp_tasks}"' RETURN

            {
                printf '# Archived %s Tasks: %s\n\n' "${section_name}" "${rel_tasks}"
                printf '<!-- source: %s | archived: %s -->\n\n' "${rel_tasks}" "$(date -Iseconds)"
                printf 'Older `## %s` rows archived verbatim from `%s`.\n\n' "${section_name}" "${rel_tasks}"
                printf '## %s\n' "${section_name}"
                for local_line in "${archive_lines[@]}"; do
                    printf '%s\n' "${local_line}"
                done
            } > "${tmp_history}"

            local history_shard
            while IFS= read -r history_shard; do
                [[ -n "${history_shard}" ]] || continue
                history_shards+=("${history_shard}")
            done < <(
                {
                    find "${history_dir}" -maxdepth 1 -type f -name "${shard_prefix}_*.md" -exec basename {} \; 2>/dev/null
                    printf '%s\n' "$(basename "${history_file}")"
                } | LC_ALL=C sort -u
            )

            sed -n "1,${header_line}p" "${tasks_file}" > "${tmp_tasks}"
            for shard in "${history_shards[@]}"; do
                [[ -n "${shard}" ]] || continue
                printf '<!-- older %s items archived in history/%s -->\n' "${status}" "${shard}" >> "${tmp_tasks}"
            done
            if (( $(bash_array_len history_shards) > 0 && $(bash_array_len keep_lines) > 0 )); then
                printf '\n' >> "${tmp_tasks}"
            fi
            for local_line in "${keep_lines[@]}"; do
                printf '%s\n' "${local_line}" >> "${tmp_tasks}"
            done
            if [[ -n "${next_header_line}" ]]; then
                printf '\n' >> "${tmp_tasks}"
                sed -n "${next_header_line},\$p" "${tasks_file}" >> "${tmp_tasks}"
            fi

            new_live_count="$(grep -Ec "^- \\[(${status})\\]" "${tmp_tasks}" || true)"
            if (( new_live_count != keep_recent )); then
                echo "rotate_tasks_done: ${rel_tasks} expected ${keep_recent} live ${section_name} row(s) after rotation, got ${new_live_count}" >&2
                exit 1
            fi

            mv "${tmp_history}" "${history_file}"
            mv "${tmp_tasks}" "${tasks_file}"
            trap - RETURN
            rm -f "${tmp_history}" "${tmp_tasks}"

            echo "rotate_tasks_done: ${rel_tasks} archived ${archive_count} older ${section_name} row(s) to $(basename "${history_file}"); kept ${keep_recent} live"
        }

        rotate_section_rows "Cancelled" "cancelled|expired" "${KEEP_RECENT_CANCELLED}" "${CANCELLED_ROTATE_MIN}" "tasks_cancelled"
        rotate_section_rows "Done" "done" "${KEEP_RECENT_DONE}" "${DONE_ROTATE_MIN}" "tasks_done"
    ) 9>"${lock_file}"
}

declare -a tasks_files=()

if (( $# == 0 )); then
    BEST_EFFORT_SCAN=1
    while IFS= read -r discovered_tasks_file; do
        [[ -n "${discovered_tasks_file}" ]] || continue
        tasks_files+=("${discovered_tasks_file}")
    done < <(discover_tasks_files)
elif [[ "${1:-}" == "--all" ]]; then
    shift
    (( $# == 0 )) || { echo "rotate_tasks_done: --all does not take file arguments" >&2; exit 2; }
    BEST_EFFORT_SCAN=1
    while IFS= read -r discovered_tasks_file; do
        [[ -n "${discovered_tasks_file}" ]] || continue
        tasks_files+=("${discovered_tasks_file}")
    done < <(discover_tasks_files)
elif [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
else
    for tasks_input in "$@"; do
        tasks_file="$(resolve_tasks_file "${tasks_input}")" || exit $?
        [[ -n "${tasks_file}" ]] && tasks_files+=("${tasks_file}")
    done
fi

if (( $(bash_array_len tasks_files) == 0 )); then
    echo "rotate_tasks_done: no tasks.md files found"
    exit 0
fi

for tasks_file in "${tasks_files[@]}"; do
    rotate_one_tasks_file "${tasks_file}"
done
