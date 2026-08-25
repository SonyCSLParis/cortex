#!/usr/bin/env bash
# zip_archive_dirs.sh — bundle older loose files in pure archive dirs into dated zip files.
#
# Usage:
#   bash roles/operational/compressor/zip_archive_dirs.sh [--all]
#   bash roles/operational/compressor/zip_archive_dirs.sh path/to/archive [path/to/other/archive ...]
#
# With no arguments, the script scans standard agent archive dirs:
#   agents/*/archive
#
# Env overrides:
#   CORTEX_DIR            default: repo root resolved from this script
#   ARCHIVE_KEEP_RECENT_FILES  default: CORTEX_DEFAULT_ARCHIVE_KEEP_RECENT_FILES
#   ARCHIVE_ZIP_MIN_FILES      default: CORTEX_DEFAULT_ARCHIVE_ZIP_MIN_FILES

set -euo pipefail
shopt -s nullglob

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CORTEX_DIR="${CORTEX_DIR:-$(cd "${SCRIPT_DIR}/../../.." && pwd -P)}"
source "${CORTEX_DIR}/config/cortex_defaults.sh"
source "${CORTEX_DIR}/scripts/bash_compat.sh"
ARCHIVE_KEEP_RECENT_FILES="${ARCHIVE_KEEP_RECENT_FILES:-${CORTEX_DEFAULT_ARCHIVE_KEEP_RECENT_FILES}}"
ARCHIVE_ZIP_MIN_FILES="${ARCHIVE_ZIP_MIN_FILES:-${CORTEX_DEFAULT_ARCHIVE_ZIP_MIN_FILES}}"
BEST_EFFORT_SCAN=0

usage() {
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
}

discover_archive_dirs() {
    find "${CORTEX_DIR}/agents" -mindepth 2 -maxdepth 2 -type d -name archive 2>/dev/null | LC_ALL=C sort
}

resolve_archive_dir() {
    local archive_input="$1"
    local archive_dir
    if [[ "${archive_input}" != /* ]]; then
        archive_dir="${CORTEX_DIR}/${archive_input}"
    else
        archive_dir="${archive_input}"
    fi
    [[ -d "${archive_dir}" ]] || { echo "zip_archive_dirs: no archive dir at ${archive_dir}" >&2; return 0; }
    [[ "$(basename "${archive_dir}")" == "archive" ]] || {
        echo "zip_archive_dirs: expected an archive directory, got ${archive_dir}" >&2
        return 2
    }
    archive_dir="$(cd "${archive_dir}" && pwd -P)"
    printf '%s\n' "${archive_dir}"
}

handle_zip_issue() {
    local rel_archive="$1" detail="$2"
    echo "zip_archive_dirs: ${rel_archive} ${detail}" >&2
    if (( BEST_EFFORT_SCAN )); then
        return 0
    fi
    return 1
}

collect_loose_files_oldest_first() {
    local archive_dir="$1"
    local path mtime
    while IFS= read -r path; do
        [[ -n "${path}" ]] || continue
        mtime="$(file_mtime_epoch "${path}")"
        printf '%s\t%s\n' "${mtime}" "$(basename "${path}")"
    done < <(
        find "${archive_dir}" -maxdepth 1 -type f ! -name '*.zip' ! -name '.*' | LC_ALL=C sort
    ) | LC_ALL=C sort -n -k1,1 -k2,2
}

zip_one_archive_dir() {
    local archive_dir="$1"
    local rel_archive lock_file
    archive_dir="$(cd "${archive_dir}" && pwd -P)"
    rel_archive="${archive_dir#${CORTEX_DIR}/}"
    lock_file="${archive_dir}/.archive_zip.lock"

    command -v zip >/dev/null 2>&1 || {
        echo "zip_archive_dirs: zip command not found" >&2
        return 127
    }

    if [[ ! -w "${archive_dir}" ]]; then
        handle_zip_issue "${rel_archive}" "archive dir is not writable; skipping" || return 1
        return 0
    fi
    if [[ -e "${lock_file}" && ! -w "${lock_file}" ]]; then
        handle_zip_issue "${rel_archive}" "lock file is not writable; skipping" || return 1
        return 0
    fi

    (
        flock -n 9 || { echo "zip_archive_dirs: ${rel_archive} busy, skipping" >&2; exit 0; }

        local -a loose_files=() to_zip=()
        local record mtime base
        while IFS=$'\t' read -r mtime base; do
            [[ -n "${base}" ]] || continue
            loose_files+=("${base}")
        done < <(collect_loose_files_oldest_first "${archive_dir}")

        local loose_count archive_count
        loose_count="$(bash_array_len loose_files)"
        if (( loose_count <= ARCHIVE_ZIP_MIN_FILES || loose_count <= ARCHIVE_KEEP_RECENT_FILES )); then
            exit 0
        fi

        archive_count=$(( loose_count - ARCHIVE_KEEP_RECENT_FILES ))
        to_zip=("${loose_files[@]:0:${archive_count}}")

        local stamp zip_file tmp_zip list_file base_zip
        stamp="$(date '+%Y-%m-%d_%H-%M')"
        zip_file="${archive_dir}/archive_${stamp}.zip"
        if [[ -e "${zip_file}" ]]; then
            zip_file="${archive_dir}/archive_${stamp}_$$.zip"
        fi
        tmp_zip="${archive_dir}/.archive_${stamp}_$$.tmp.zip"
        list_file="${archive_dir}/.archive_${stamp}_$$.list"
        base_zip="$(basename "${tmp_zip}")"
        trap 'rm -f "${tmp_zip}" "${list_file}"' RETURN

        : > "${list_file}"
        for base in "${to_zip[@]}"; do
            printf '%s\n' "${base}" >> "${list_file}"
        done

        (
            cd "${archive_dir}"
            zip -q -m "${base_zip}" -@ < "$(basename "${list_file}")"
        )

        [[ -s "${tmp_zip}" ]] || {
            echo "zip_archive_dirs: ${rel_archive} created empty zip bundle unexpectedly" >&2
            exit 1
        }

        mv "${tmp_zip}" "${zip_file}"
        rm -f "${list_file}"
        trap - RETURN

        echo "zip_archive_dirs: ${rel_archive} zipped ${archive_count} archived file(s) into $(basename "${zip_file}"); kept ${ARCHIVE_KEEP_RECENT_FILES} loose"
    ) 9>"${lock_file}"
}

declare -a archive_dirs=()

if (( $# == 0 )); then
    BEST_EFFORT_SCAN=1
    while IFS= read -r discovered_archive_dir; do
        [[ -n "${discovered_archive_dir}" ]] || continue
        archive_dirs+=("${discovered_archive_dir}")
    done < <(discover_archive_dirs)
elif [[ "${1:-}" == "--all" ]]; then
    shift
    (( $# == 0 )) || { echo "zip_archive_dirs: --all does not take directory arguments" >&2; exit 2; }
    BEST_EFFORT_SCAN=1
    while IFS= read -r discovered_archive_dir; do
        [[ -n "${discovered_archive_dir}" ]] || continue
        archive_dirs+=("${discovered_archive_dir}")
    done < <(discover_archive_dirs)
else
    for archive_input in "$@"; do
        resolved_archive_dir="$(resolve_archive_dir "${archive_input}")" || exit $?
        [[ -n "${resolved_archive_dir}" ]] || continue
        archive_dirs+=("${resolved_archive_dir}")
    done
fi

for archive_dir in "${archive_dirs[@]}"; do
    zip_one_archive_dir "${archive_dir}"
done
