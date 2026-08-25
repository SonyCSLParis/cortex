#!/usr/bin/env bash

worker_commit_apply_defaults() {
    worker_set_codex_defaults medium "${DEFAULT_WORKER_REVIEW_INTERVAL_HOURLY}" "${DEFAULT_WORKER_REVIEW_TIMEOUT_LONG_SECONDS}"
}

worker_commit_use_shared_rw_spec() {
    return 1
}

worker_commit_reset_command_scope() {
    COMMIT_RW_ALLOW_HOOKS="0"
    COMMIT_COMMAND_RW_PATHS=()
}

worker_commit_collect_command_scope() {
    local body_raw="$1" from_name="$2"
    worker_commit_reset_command_scope

    local allow_hooks
    allow_hooks="$(trim_whitespace "$(extract_result_field "COMMIT_RW_ALLOW_HOOKS" "${body_raw}")")"
    case "${allow_hooks}" in
        1|true|TRUE|yes|YES)
            [[ "${from_name}" == "conductor" ]] && COMMIT_RW_ALLOW_HOOKS="1"
            ;;
    esac

    local scope_block
    scope_block="$(extract_command_block "WRITABLE_PATHS" "${body_raw}")"
    if [[ -z "${scope_block}" ]]; then
        scope_block="$(extract_command_block "TARGETS" "${body_raw}")"
    fi
    [[ -n "${scope_block}" ]] || return 0

    local cortex_real raw_line candidate
    cortex_real="$(realpath "${CORTEX_DIR}" 2>/dev/null || printf '%s' "${CORTEX_DIR}")"
    while IFS= read -r raw_line; do
        candidate="$(trim_whitespace "${raw_line}")"
        [[ -n "${candidate}" ]] || continue
        [[ "${candidate}" == \#* ]] && continue
        while [[ "${candidate}" == -* || "${candidate}" == \** ]]; do
            candidate="${candidate#?}"
            candidate="$(trim_whitespace "${candidate}")"
        done
        candidate="${candidate#\`}"
        candidate="${candidate%\`}"
        candidate="$(trim_whitespace "${candidate}")"
        [[ -n "${candidate}" ]] || continue

        if [[ "${candidate}" != /* ]]; then
            candidate="${cortex_real}/${candidate}"
        fi
        candidate="$(realpath_m_compat "${candidate}")"

        if [[ ! -e "${candidate}" ]]; then
            printf 'commit writable path does not exist: `%s`; enumerate existing files or directories in `WRITABLE_PATHS:`.\n' "${candidate}"
            return 1
        fi

        append_unique_path "${candidate}" COMMIT_COMMAND_RW_PATHS
    done <<< "${scope_block}"

    return 0
}

worker_commit_prepare_command_scope() {
    worker_commit_collect_command_scope "$@"
}

worker_commit_reset_scope() {
    worker_commit_reset_command_scope
}

worker_commit_explicit_rw_paths() {
    local paths_ref="$1"
    named_array_clear "${paths_ref}"

    [[ -n "${CURRENT_COMMAND_BODY_RAW}" ]] || return 0
    if (( $(bash_array_len COMMIT_COMMAND_RW_PATHS) > 0 )); then
        local command_path
        for command_path in "${COMMIT_COMMAND_RW_PATHS[@]}"; do
            append_unique_path "${command_path}" "${paths_ref}"
        done
        return 0
    fi

    local -a fallback_paths=()
    if ! append_rw_paths_from_spec "${CORTEX_WORKER_BWRAP_RW:-}" fallback_paths; then
        return 1
    fi
    local fallback_path
    for fallback_path in "${fallback_paths[@]}"; do
        append_unique_path "${fallback_path}" "${paths_ref}"
    done
}

worker_commit_collect_git_dirs() {
    local scope_paths_ref="$1"
    local git_dirs_ref="$2"
    local -a scope_paths=()
    named_array_clear "${git_dirs_ref}"
    named_array_copy "${scope_paths_ref}" scope_paths

    local scope_path repo_anchor git_dir
    for scope_path in "${scope_paths[@]}"; do
        repo_anchor="${scope_path}"
        [[ -d "${repo_anchor}" ]] || repo_anchor="$(dirname "${repo_anchor}")"
        git_dir="$(git -C "${repo_anchor}" rev-parse --absolute-git-dir 2>/dev/null || true)"
        [[ -n "${git_dir}" && -d "${git_dir}" ]] || continue
        append_unique_path "${git_dir}" "${git_dirs_ref}"
    done
}

worker_commit_append_rw_paths() {
    local cortex_real="$1"
    local rw_paths_ref="$2"
    local -a commit_scope_paths=()
    local -a commit_git_dirs=()
    if ! worker_commit_explicit_rw_paths commit_scope_paths; then
        return 1
    fi
    local commit_scope_path
    for commit_scope_path in "${commit_scope_paths[@]}"; do
        append_unique_path "${commit_scope_path}" "${rw_paths_ref}"
    done
    worker_commit_collect_git_dirs commit_scope_paths commit_git_dirs
    if (( $(bash_array_len commit_git_dirs) == 0 )) && [[ -d "${cortex_real}/.git" ]]; then
        commit_git_dirs+=("${cortex_real}/.git")
    fi
    local commit_git_dir
    for commit_git_dir in "${commit_git_dirs[@]}"; do
        append_unique_path "${commit_git_dir}" "${rw_paths_ref}"
    done
}

worker_commit_append_ro_binds() {
    local ro_binds_ref="$1"
    local -a commit_scope_paths=()
    local -a commit_git_dirs=()
    if ! worker_commit_explicit_rw_paths commit_scope_paths; then
        return 1
    fi
    [[ -n "${CURRENT_COMMAND_BODY_RAW}" ]] || return 0
    [[ "${COMMIT_RW_ALLOW_HOOKS}" != "1" ]] || return 0
    worker_commit_collect_git_dirs commit_scope_paths commit_git_dirs
    local commit_git_dir hooks_dir
    for commit_git_dir in "${commit_git_dirs[@]}"; do
        hooks_dir="${commit_git_dir}/hooks"
        append_ro_bind_if_exists "${hooks_dir}" "${ro_binds_ref}"
    done
}
