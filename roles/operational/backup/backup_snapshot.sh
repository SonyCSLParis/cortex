#!/usr/bin/env bash
# Create source-oriented backup snapshots for the Cortex repo and other
# explicitly listed working trees. Intended for use by the persistent
# `backup` worker, but safe to run manually as well.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CORTEX_DIR="${CORTEX_DIR:-$(cd "${SCRIPT_DIR}/../../.." && pwd -P)}"
source "${CORTEX_DIR}/config/cortex_defaults.sh"
source "${CORTEX_DIR}/scripts/bash_compat.sh"
BACKUP_TARGETS_FILE="${BACKUP_TARGETS_FILE:-${CORTEX_DEFAULT_BACKUP_TARGETS_FILE}}"
BACKUP_ROOT="${BACKUP_ROOT:-${CORTEX_DEFAULT_BACKUP_ROOT}}"
BACKUP_KEEP="${BACKUP_KEEP:-7}"
DRY_RUN=0
BACKUP_EXCLUDES_DIR="${BACKUP_EXCLUDES_DIR:-}"

usage() {
    cat <<'EOF'
Usage: bash roles/operational/backup/backup_snapshot.sh [--dry-run]

Env:
  BACKUP_TARGETS_FILE   Manifest file. Default: CORTEX_DEFAULT_BACKUP_TARGETS_FILE
                        (normally environments/<env>/backup_targets.txt)
  BACKUP_EXCLUDES_DIR   Directory containing mode-specific exclude files.
                        Default: <manifest dir>/backup_excludes
                        Expected files: repo_worktree.txt source_tree.txt path.txt
  BACKUP_ROOT           Snapshot root. Default: CORTEX_DEFAULT_BACKUP_ROOT
  BACKUP_KEEP           Number of snapshots to retain. Default: 7
EOF
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "${s}"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

[[ -f "${BACKUP_TARGETS_FILE}" ]] || die "backup manifest missing: ${BACKUP_TARGETS_FILE}"
[[ "${BACKUP_KEEP}" =~ ^[0-9]+$ ]] || die "BACKUP_KEEP must be a non-negative integer"
(( BACKUP_KEEP >= 1 )) || die "BACKUP_KEEP must be at least 1"
if [[ -z "${BACKUP_EXCLUDES_DIR}" ]]; then
    BACKUP_TARGETS_DIR="$(cd "$(dirname "${BACKUP_TARGETS_FILE}")" && pwd -P)"
    BACKUP_EXCLUDES_DIR="${BACKUP_TARGETS_DIR}/backup_excludes"
fi
[[ -d "${BACKUP_EXCLUDES_DIR}" ]] || die "backup excludes dir missing: ${BACKUP_EXCLUDES_DIR}"

mkdir -p "${BACKUP_ROOT}/snapshots"

# Reap any leftover `.tmp.*` snapshot dirs from prior runs that were killed
# before their cleanup trap could fire (rsync getting SIGTERM'd by the
# worker periodic-check timeout has produced multi-GB orphan snapshot dirs
# in the past — see T20260519-03). Only touch dirs at our snapshot base
# whose name starts with the literal `.` prefix the script uses for
# in-flight runs.
if [[ -d "${BACKUP_ROOT}/snapshots" ]]; then
    find "${BACKUP_ROOT}/snapshots" -mindepth 1 -maxdepth 1 -type d -name '.*.tmp.*' \
        -print0 2>/dev/null \
        | xargs -0 -r rm -rf -- 2>/dev/null || true
fi

snapshot_id="$(date '+%Y-%m-%dT%H-%M-%S%z')"
snapshot_base="${BACKUP_ROOT}/snapshots"
snapshot_tmp="$(mktemp -d "${snapshot_base}/.${snapshot_id}.tmp.XXXXXX")"
snapshot_final="${snapshot_base}/${snapshot_id}"

cleanup() {
    if [[ -n "${snapshot_tmp:-}" && -d "${snapshot_tmp}" ]]; then
        rm -rf -- "${snapshot_tmp}"
    fi
}
trap cleanup EXIT

previous_snapshot="$(find "${snapshot_base}" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | sort | tail -n 1 || true)"

append_mode_excludes() {
    local mode="$1"
    local args_ref="$2"
    local exclude_file="${BACKUP_EXCLUDES_DIR}/${mode}.txt"
    local raw_pattern
    local pattern

    case "${mode}" in
        repo_worktree)
            named_array_append "${args_ref}" --copy-unsafe-links
            ;;
        source_tree)
            named_array_append "${args_ref}" --copy-unsafe-links
            ;;
        path)
            ;;
        *)
            die "unsupported backup mode: ${mode}"
            ;;
    esac

    [[ -f "${exclude_file}" ]] || die "exclude file missing for mode ${mode}: ${exclude_file}"
    while IFS= read -r raw_pattern || [[ -n "${raw_pattern}" ]]; do
        pattern="$(trim "${raw_pattern}")"
        [[ -n "${pattern}" ]] || continue
        [[ "${pattern}" == \#* ]] && continue
        named_array_append "${args_ref}" "--exclude=${pattern}"
    done < "${exclude_file}"
}

write_git_metadata() {
    local source_path="$1"
    local metadata_dir="$2"
    local git_root

    if ! git_root="$(git -C "${source_path}" rev-parse --show-toplevel 2>/dev/null)"; then
        return 0
    fi

    mkdir -p "${metadata_dir}"
    git -C "${source_path}" rev-parse HEAD > "${metadata_dir}/head.txt"
    git -C "${source_path}" status --short --branch > "${metadata_dir}/status.txt"
    git -C "${source_path}" diff > "${metadata_dir}/diff.patch"
    git -C "${source_path}" diff --cached > "${metadata_dir}/diff_staged.patch"
    git -C "${source_path}" ls-files --others --exclude-standard > "${metadata_dir}/untracked.txt"
    printf '%s\n' "${git_root}" > "${metadata_dir}/git_root.txt"
}

run_rsync() {
    local -a cmd=("$@")
    if (( DRY_RUN )); then
        printf 'DRY_RUN:'
        printf ' %q' "${cmd[@]}"
        printf '\n'
        return 0
    fi
    "${cmd[@]}"
}

printf 'SNAPSHOT_ROOT: %s\n' "${BACKUP_ROOT}"
printf 'SNAPSHOT_ID: %s\n' "${snapshot_id}"
printf 'MANIFEST: %s\n' "${BACKUP_TARGETS_FILE}"
printf 'EXCLUDES_DIR: %s\n' "${BACKUP_EXCLUDES_DIR}"
printf 'KEEP: %s\n' "${BACKUP_KEEP}"

while IFS='|' read -r raw_label raw_mode raw_path raw_extra; do
    raw_label="$(trim "${raw_label:-}")"
    raw_mode="$(trim "${raw_mode:-}")"
    raw_path="$(trim "${raw_path:-}")"
    raw_extra="$(trim "${raw_extra:-}")"

    [[ -n "${raw_extra}" ]] && die "manifest line has too many fields for label ${raw_label}"
    [[ -z "${raw_label}" ]] && continue
    [[ "${raw_label}" == \#* ]] && continue
    [[ -n "${raw_mode}" ]] || die "missing mode for label ${raw_label}"
    [[ -n "${raw_path}" ]] || die "missing path for label ${raw_label}"
    [[ "${raw_label}" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid label: ${raw_label}"

    source_path="${raw_path}"
    [[ "${source_path}" != /* ]] && source_path="${CORTEX_DIR}/${source_path}"
    [[ -e "${source_path}" ]] || die "target missing: ${raw_label} -> ${source_path}"

    resolved_path="$(readlink_f_compat "${source_path}")"
    [[ -n "${resolved_path}" && -e "${resolved_path}" ]] || die "target resolution failed: ${raw_label} -> ${source_path}"

    target_dir="${snapshot_tmp}/${raw_label}"
    mkdir -p "${target_dir}"

    rsync_args=(-a --no-owner --no-group --delete)
    append_mode_excludes "${raw_mode}" rsync_args

    if [[ -n "${previous_snapshot}" && -d "${previous_snapshot}/${raw_label}" ]]; then
        rsync_args+=(--link-dest "${previous_snapshot}/${raw_label}")
    fi

    rsync_cmd=(rsync "${rsync_args[@]}" "${resolved_path}/" "${target_dir}/")
    run_rsync "${rsync_cmd[@]}"

    if [[ "${raw_mode}" == "repo_worktree" || "${raw_mode}" == "source_tree" ]]; then
        if (( DRY_RUN )); then
            printf 'DRY_RUN: git metadata for %s (%s)\n' "${raw_label}" "${resolved_path}"
        else
            write_git_metadata "${resolved_path}" "${snapshot_tmp}/_${raw_label}_git"
        fi
    fi

    printf 'TARGET: %s | mode=%s | source=%s\n' "${raw_label}" "${raw_mode}" "${resolved_path}"
done < "${BACKUP_TARGETS_FILE}"

if (( DRY_RUN )); then
    echo "PRUNED: dry-run"
    exit 0
fi

mv "${snapshot_tmp}" "${snapshot_final}"
snapshot_tmp=""
ln -sfn "${snapshot_final}" "${BACKUP_ROOT}/latest"

snapshots=()
while IFS= read -r snapshot_path; do
    [[ -n "${snapshot_path}" ]] || continue
    snapshots+=("${snapshot_path}")
done < <(find "${snapshot_base}" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | sort)
pruned=()
if (( $(bash_array_len snapshots) > BACKUP_KEEP )); then
    prune_count=$(( $(bash_array_len snapshots) - BACKUP_KEEP ))
    for old_snapshot in "${snapshots[@]:0:${prune_count}}"; do
        pruned+=("$(basename "${old_snapshot}")")
        rm -rf -- "${old_snapshot}"
    done
fi

if (( $(bash_array_len pruned) == 0 )); then
    echo "PRUNED: none"
else
    printf 'PRUNED: %s\n' "$(IFS=,; echo "${pruned[*]}")"
fi

printf 'LATEST: %s\n' "${BACKUP_ROOT}/latest"
