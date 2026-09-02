#!/usr/bin/env bash

worker_set_codex_defaults() {
    local tier="$1" interval="$2" timeout="$3"
    if [[ "${AGENT_PROVIDER_EXPLICIT}" -eq 0 ]]; then
        AGENT_PROVIDER="codex"
    fi
    apply_model_tier "${tier}"
    [[ -n "${WORKER_REVIEW_INTERVAL}" ]] || WORKER_REVIEW_INTERVAL="${interval}"
    if [[ -n "${timeout}" && "${WORKER_REVIEW_TIMEOUT}" == "${DEFAULT_WORKER_REVIEW_TIMEOUT_SECONDS}" ]]; then
        WORKER_REVIEW_TIMEOUT="${timeout}"
    fi
}

worker_prepare_command_scope_default() {
    return 0
}

worker_reset_command_scope_default() {
    return 0
}

worker_append_rw_paths_default() {
    return 0
}

worker_append_ro_binds_default() {
    return 0
}

worker_prepare_registration_default() {
    return 0
}

worker_resolve_state_dir_default() {
    return 0
}

worker_append_ssh_binds_default() {
    return 0
}

worker_append_safe_ssh_binds() {
    local ssh_binds_ref="$1"
    local ssh_file ssh_real

    for ssh_file in "${HOME}/.ssh/config" "${HOME}/.ssh/known_hosts" "${HOME}/.ssh/known_hosts.old"; do
        [[ -f "${ssh_file}" ]] || continue
        ssh_real="$(readlink_f_compat "${ssh_file}" 2>/dev/null || printf '%s' "${ssh_file}")"
        named_array_append "${ssh_binds_ref}" --ro-bind "${ssh_real}" "${ssh_file}"
    done

    if [[ -d "${HOME}/.ssh/known_hosts.d" ]]; then
        local khd_real
        khd_real="$(readlink_f_compat "${HOME}/.ssh/known_hosts.d" 2>/dev/null || printf '%s' "${HOME}/.ssh/known_hosts.d")"
        named_array_append "${ssh_binds_ref}" --ro-bind "${khd_real}" "${HOME}/.ssh/known_hosts.d"
    fi

    if [[ -n "${SSH_AUTH_SOCK:-}" && -S "${SSH_AUTH_SOCK}" ]]; then
        local ssh_sock_dir
        ssh_sock_dir="$(dirname "${SSH_AUTH_SOCK}")"
        if [[ -d "${ssh_sock_dir}" ]]; then
            named_array_append "${ssh_binds_ref}" --bind "${ssh_sock_dir}" "${ssh_sock_dir}"
        else
            named_array_append "${ssh_binds_ref}" --bind "${SSH_AUTH_SOCK}" "${SSH_AUTH_SOCK}"
        fi
    fi
}

worker_claude_pin_session() {
    # Appends --session-id to the named command array and records the id for
    # usage attribution (see cortex_usage_claude_session_match).
    local cmd_ref="$1" sid
    sid="$(cortex_usage_new_claude_session_id 2>/dev/null || true)"
    [[ -n "${sid}" ]] || return 0
    named_array_append "${cmd_ref}" --session-id "${sid}"
    ROLE_CLI_USAGE_CLAUDE_SESSION_ID="${sid}"
}

worker_launch_claude_direct() {
    local prompt="$1" working_file="$2" tmp_out="$3"
    local timeout_ref="$4"
    local exit_code=0

    local -a claude_cmd=(claude --print --verbose --effort "${CLAUDE_EFFORT}")
    [[ -n "${CLAUDE_MODEL}" ]] && claude_cmd+=(--model "${CLAUDE_MODEL}")
    worker_claude_pin_session claude_cmd

    run_with_array_prefix "${timeout_ref}" \
        "${claude_cmd[@]}" --dangerously-skip-permissions "${prompt}" 2>&1 \
        | tee "${working_file}" \
        | tee /dev/fd/2 > "${tmp_out}" \
        || exit_code=${PIPESTATUS[0]}
    return "${exit_code}"
}

worker_launch_codex_direct() {
    local prompt="$1" working_file="$2" tmp_out="$3" tmp_last="$4"
    local timeout_ref="$5"
    local exit_code=0

    local worker_codex_home_root=""
    local worker_codex_bin=""
    worker_codex_bin="$(command -v codex 2>/dev/null || true)"
    if [[ -z "${worker_codex_bin}" ]]; then
        printf "[cortex] worker '%s' could not resolve codex on PATH." "${AGENT_ID}"
        return 1
    fi
    if ! worker_codex_home_root="$(prepare_codex_direct_home)"; then
        return 1
    fi
    ROLE_CLI_USAGE_CODEX_HOME="${worker_codex_home_root}/.codex"
    run_with_array_prefix "${timeout_ref}" env HOME="${worker_codex_home_root}" \
        "${worker_codex_bin}" exec --model "${CODEX_MODEL}" \
            -c "model_reasoning_effort=\"${CODEX_REASONING_EFFORT}\"" \
            --ephemeral \
            --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox \
            --output-last-message "${tmp_last}" - <<<"${prompt}" 2>&1 \
        | tee "${working_file}" \
        | tee /dev/fd/2 > "${tmp_out}" \
        || exit_code=${PIPESTATUS[0]}
    return "${exit_code}"
}

worker_launch_claude_generic() {
    local prompt="$1" working_file="$2" tmp_out="$3"
    local timeout_ref="$4"
    local exit_code=0

    local -a claude_cmd=(claude --print --verbose --effort "${CLAUDE_EFFORT}")
    [[ -n "${CLAUDE_MODEL}" ]] && claude_cmd+=(--model "${CLAUDE_MODEL}")
    worker_claude_pin_session claude_cmd

    if ! command -v bwrap >/dev/null 2>&1; then
        printf "[cortex] worker '%s' requires bubblewrap (bwrap) for sandboxed elevated mode, but bwrap is not installed." "${AGENT_ID}"
        return 1
    fi

    local cortex_real; cortex_real="$(realpath "${CORTEX_DIR}" 2>/dev/null || printf '%s' "${CORTEX_DIR}")"
    local claude_sandbox_dir; claude_sandbox_dir="$(mktemp -d)"
    mkdir -p "${claude_sandbox_dir}/session-env"
    local -a worker_usage_binds=()
    security_claude_usage_stage_bind "${cortex_real}" worker_usage_binds
    local -a worker_dir_args=()
    local -a worker_ro_binds=()
    local -a worker_rw_binds=()
    local -a worker_ro_overlays=()
    local -a worker_ro_masks=()
    local -a worker_ssh_binds=()
    local -a worker_pid_args=()
    local -a worker_device_args=()
    if ! security_bwrap_ro_binds "${cortex_real}" claude worker_ro_binds; then
        rm -rf "${claude_sandbox_dir}"
        return 1
    fi
    if ! worker_pre_rw_ro_base worker_ro_binds; then
        rm -rf "${claude_sandbox_dir}"
        return 1
    fi
    security_bwrap_dir_args worker_dir_args
    if ! worker_bwrap_rw_binds "${cortex_real}" worker_rw_binds; then
        rm -rf "${claude_sandbox_dir}"
        return 1
    fi
    if ! worker_post_rw_ro_binds worker_ro_overlays; then
        rm -rf "${claude_sandbox_dir}"
        return 1
    fi
    if ! worker_ro_masks worker_ro_masks; then
        rm -rf "${claude_sandbox_dir}"
        return 1
    fi
    worker_append_ssh_binds worker_ssh_binds
    worker_bwrap_pid_args worker_pid_args
    worker_bwrap_device_args worker_device_args
    run_with_array_prefix "${timeout_ref}" bwrap \
        "${worker_pid_args[@]}" \
        --unshare-ipc \
        --unshare-uts \
        "${worker_dir_args[@]}" \
        "${worker_ro_binds[@]}" \
        "${worker_device_args[@]}" \
        --proc /proc \
        --tmpfs /tmp \
        "${worker_rw_binds[@]}" \
        "${worker_ro_overlays[@]}" \
        "${worker_ro_masks[@]}" \
        "${worker_ssh_binds[@]}" \
        --bind "${claude_sandbox_dir}/session-env" "${HOME}/.claude/session-env" \
        "${worker_usage_binds[@]}" \
        --chdir "${cortex_real}" \
        "${claude_cmd[@]}" --dangerously-skip-permissions "${prompt}" 2>&1 \
        | tee "${working_file}" \
        | tee /dev/fd/2 > "${tmp_out}" \
        || exit_code=${PIPESTATUS[0]}
    rm -rf "${claude_sandbox_dir}"
    return "${exit_code}"
}

worker_launch_codex_generic() {
    local prompt="$1" working_file="$2" tmp_out="$3" tmp_last="$4"
    local timeout_ref="$5"
    local exit_code=0

    if ! command -v bwrap >/dev/null 2>&1; then
        printf "[cortex] worker '%s' requires bubblewrap (bwrap) for sandboxed elevated mode, but bwrap is not installed." "${AGENT_ID}"
        return 1
    fi

    local cortex_real; cortex_real="$(realpath "${CORTEX_DIR}" 2>/dev/null || printf '%s' "${CORTEX_DIR}")"
    local worker_codex_home=""
    local worker_codex_bin=""
    local -a worker_rw_binds=()
    local -a worker_dir_args=()
    local -a worker_ro_binds=()
    local -a worker_ro_overlays=()
    local -a worker_ro_masks=()
    local -a worker_ssh_binds=()
    local -a worker_pid_args=()
    local -a worker_device_args=()
    local worker_scrubber_pid=""
    worker_codex_bin="$(command -v codex 2>/dev/null || true)"
    if [[ -z "${worker_codex_bin}" ]]; then
        printf "[cortex] worker '%s' could not resolve codex on PATH." "${AGENT_ID}"
        return 1
    fi
    if ! security_bwrap_ro_binds "${cortex_real}" codex worker_ro_binds; then
        return 1
    fi
    if ! worker_pre_rw_ro_base worker_ro_binds; then
        return 1
    fi
    security_bwrap_dir_args worker_dir_args
    if ! worker_codex_home="$(prepare_codex_stage_home)"; then
        return 1
    fi
    ROLE_CLI_USAGE_CODEX_HOME="${worker_codex_home}"
    if ! worker_bwrap_rw_binds "${cortex_real}" worker_rw_binds; then
        cleanup_codex_stage_home "${worker_codex_home}"
        ROLE_CLI_USAGE_CODEX_HOME=""
        return 1
    fi
    if ! worker_post_rw_ro_binds worker_ro_overlays; then
        cleanup_codex_stage_home "${worker_codex_home}"
        ROLE_CLI_USAGE_CODEX_HOME=""
        return 1
    fi
    if ! worker_ro_masks worker_ro_masks; then
        cleanup_codex_stage_home "${worker_codex_home}"
        ROLE_CLI_USAGE_CODEX_HOME=""
        return 1
    fi
    worker_scrubber_pid="$(start_codex_stage_scrubber "${worker_codex_home}")"
    worker_append_ssh_binds worker_ssh_binds
    worker_bwrap_pid_args worker_pid_args
    worker_bwrap_device_args worker_device_args
    run_with_array_prefix "${timeout_ref}" bwrap \
        "${worker_pid_args[@]}" \
        --unshare-ipc \
        --unshare-uts \
        "${worker_dir_args[@]}" \
        "${worker_ro_binds[@]}" \
        "${worker_device_args[@]}" \
        --proc /proc \
        --tmpfs /tmp \
        "${worker_rw_binds[@]}" \
        "${worker_ro_overlays[@]}" \
        "${worker_ro_masks[@]}" \
        "${worker_ssh_binds[@]}" \
        --bind "${worker_codex_home}" "${HOME}/.codex" \
        --chdir "${cortex_real}" \
        "${worker_codex_bin}" exec --model "${CODEX_MODEL}" \
            -c "model_reasoning_effort=\"${CODEX_REASONING_EFFORT}\"" \
            --ephemeral \
            --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox \
            --output-last-message "${tmp_last}" - <<<"${prompt}" 2>&1 \
        | tee "${working_file}" \
        | tee /dev/fd/2 > "${tmp_out}" \
        || exit_code=${PIPESTATUS[0]}
    if [[ -n "${worker_scrubber_pid}" ]]; then
        wait "${worker_scrubber_pid}" 2>/dev/null || true
    fi
    return "${exit_code}"
}
