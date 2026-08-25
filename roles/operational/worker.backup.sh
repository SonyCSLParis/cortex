#!/usr/bin/env bash

worker_backup_apply_defaults() {
    worker_set_codex_defaults weak "${DEFAULT_WORKER_REVIEW_INTERVAL_HOURLY}" "${DEFAULT_WORKER_REVIEW_TIMEOUT_SHORT_SECONDS}"
}

worker_backup_append_rw_paths() {
    local rw_paths_ref="${2:-$1}"
    local backup_real
    backup_real="$(realpath_m_compat "${BACKUP_ROOT}")"
    mkdir -p "${backup_real}"
    named_array_append "${rw_paths_ref}" "${backup_real}"
}

worker_backup_bwrap_ro_paths() {
    local paths_ref="$1"
    named_array_clear "${paths_ref}"

    [[ -f "${BACKUP_TARGETS_FILE}" ]] || return 0

    local agent_real backup_root_real
    agent_real="$(realpath_m_compat "${AGENT_DIR}")"
    backup_root_real="$(realpath_m_compat "${BACKUP_ROOT}")"

    local raw_label raw_mode raw_path raw_extra
    local label mode source_path resolved_path link_path target target_path target_real bind_path
    while IFS='|' read -r raw_label raw_mode raw_path raw_extra; do
        label="$(trim_whitespace "${raw_label:-}")"
        mode="$(trim_whitespace "${raw_mode:-}")"
        source_path="$(trim_whitespace "${raw_path:-}")"
        raw_extra="$(trim_whitespace "${raw_extra:-}")"

        [[ -z "${label}" || "${label}" == \#* ]] && continue
        [[ -n "${raw_extra}" ]] && continue
        [[ -n "${source_path}" ]] || continue
        [[ "${source_path}" != /* ]] && source_path="${CORTEX_DIR}/${source_path}"
        [[ -e "${source_path}" ]] || continue

        resolved_path="$(readlink_f_compat "${source_path}" 2>/dev/null || true)"
        [[ -n "${resolved_path}" && -e "${resolved_path}" ]] || continue
        if ! paths_overlap "${resolved_path}" "${agent_real}" \
            && ! paths_overlap "${resolved_path}" "${backup_root_real}"; then
            append_unique_path "${resolved_path}" "${paths_ref}"
        fi

        case "${mode}" in
            repo_worktree|source_tree)
                while IFS= read -r -d '' link_path; do
                    target="$(readlink -- "${link_path}" 2>/dev/null || true)"
                    [[ -n "${target}" ]] || continue
                    if [[ "${target}" == /* ]]; then
                        target_path="${target}"
                    else
                        target_path="$(dirname "${link_path}")/${target}"
                    fi
                    target_real="$(readlink_f_compat "${target_path}" 2>/dev/null || true)"
                    [[ -n "${target_real}" && -e "${target_real}" ]] || continue
                    paths_overlap "${resolved_path}" "${target_real}" && continue
                    if [[ -d "${target_real}" ]]; then
                        bind_path="${target_real}"
                    else
                        bind_path="$(dirname "${target_real}")"
                    fi
                    paths_overlap "${bind_path}" "${agent_real}" && continue
                    paths_overlap "${bind_path}" "${backup_root_real}" && continue
                    append_unique_path "${bind_path}" "${paths_ref}"
                done < <(find "${resolved_path}" -type l -print0 2>/dev/null)
                ;;
        esac
    done < "${BACKUP_TARGETS_FILE}"
}

worker_backup_append_ro_binds() {
    local ro_binds_ref="$1"
    local -a backup_ro_paths=()
    if ! worker_backup_bwrap_ro_paths backup_ro_paths; then
        return 1
    fi
    local backup_ro_path
    for backup_ro_path in "${backup_ro_paths[@]}"; do
        named_array_append "${ro_binds_ref}" --ro-bind "${backup_ro_path}" "${backup_ro_path}"
    done
}
