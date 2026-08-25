#!/usr/bin/env bash

worker_student_apply_defaults() {
    worker_set_codex_defaults medium "${DEFAULT_WORKER_REVIEW_INTERVAL_DISABLED}" "${DEFAULT_WORKER_REVIEW_TIMEOUT_LONG_SECONDS}"
    append_cortex_worker_bwrap_rw "${CORTEX_DIR}/agents/supervisor/inbox"
}

worker_student_reset_round_scope() {
    STUDENT_RW_ALLOW_SENSITIVE="0"
    STUDENT_ROUND_RW_PATHS=()
}

worker_student_sensitive_scope_reason() {
    local candidate="$1" cortex_real="$2"
    local denied

    for denied in \
        "${cortex_real}/.git" \
        "${cortex_real}/roles" \
        "${cortex_real}/agents/conductor/secrets"
    do
        if paths_overlap "${candidate}" "${denied}"; then
            printf '%s' "${denied}"
            return 0
        fi
    done

    local inbox_path
    shopt -s nullglob
    for inbox_path in "${cortex_real}"/agents/*/inbox; do
        [[ "${inbox_path}" == "${cortex_real}/agents/supervisor/inbox" ]] && continue
        if paths_overlap "${candidate}" "${inbox_path}"; then
            printf '%s' "${inbox_path}"
            shopt -u nullglob
            return 0
        fi
    done
    shopt -u nullglob

    return 1
}

worker_student_collect_round_scope() {
    local body_raw="$1" from_name="$2"
    worker_student_reset_round_scope

    local allow_sensitive
    allow_sensitive="$(trim_whitespace "$(extract_result_field "STUDENT_RW_ALLOW_SENSITIVE" "${body_raw}")")"
    case "${allow_sensitive}" in
        1|true|TRUE|yes|YES)
            [[ "${from_name}" == "conductor" ]] && STUDENT_RW_ALLOW_SENSITIVE="1"
            ;;
    esac

    local scope_block
    scope_block="$(extract_command_block "WRITABLE_PATHS" "${body_raw}")"
    if [[ -z "${scope_block}" ]]; then
        scope_block="$(extract_command_block "TARGETS" "${body_raw}")"
    fi
    [[ -n "${scope_block}" ]] || return 0

    local cortex_real raw_line candidate sensitive_reason
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

        if [[ "${STUDENT_RW_ALLOW_SENSITIVE}" != "1" ]]; then
            if sensitive_reason="$(worker_student_sensitive_scope_reason "${candidate}" "${cortex_real}")"; then
                printf 'student writable scope denied for `%s` (overlaps `%s`); only a direct conductor COMMAND may set `STUDENT_RW_ALLOW_SENSITIVE: yes`.\n' \
                    "${candidate}" "${sensitive_reason}"
                return 1
            fi
        fi

        if [[ ! -e "${candidate}" ]]; then
            printf 'student writable path does not exist: `%s`; enumerate existing files or directories in `WRITABLE_PATHS:`.\n' "${candidate}"
            return 1
        fi

        local seen=0 existing
        for existing in "${STUDENT_ROUND_RW_PATHS[@]}"; do
            if [[ "${existing}" == "${candidate}" ]]; then
                seen=1
                break
            fi
        done
        (( seen == 0 )) && STUDENT_ROUND_RW_PATHS+=("${candidate}")
    done <<< "${scope_block}"

    return 0
}

worker_student_prepare_command_scope() {
    worker_student_collect_round_scope "$@"
}

worker_student_reset_scope() {
    worker_student_reset_round_scope
}

worker_student_append_rw_paths() {
    local rw_paths_ref="${2:-$1}"
    if (( $(bash_array_len STUDENT_ROUND_RW_PATHS) == 0 )); then
        return 0
    fi

    local student_path
    for student_path in "${STUDENT_ROUND_RW_PATHS[@]}"; do
        append_unique_path "${student_path}" "${rw_paths_ref}"
    done
}

worker_student_prepare_registration() {
    mkdir -p "${CORTEX_DIR}/agents/supervisor/inbox"
}
