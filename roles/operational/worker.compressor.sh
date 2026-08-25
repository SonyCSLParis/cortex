#!/usr/bin/env bash

worker_compressor_apply_defaults() {
    worker_set_codex_defaults medium "${DEFAULT_WORKER_REVIEW_INTERVAL_HOURLY}" ""
}

worker_compressor_use_shared_rw_spec() {
    return 1
}

worker_compressor_append_rw_paths() {
    local cortex_real="$1"
    local rw_paths_ref="$2"

    append_unique_path "${cortex_real}" "${rw_paths_ref}"
}

worker_compressor_launch_claude() {
    local prompt="$1" working_file="$2" tmp_out="$3" timeout_ref="$4"
    local exit_code=0

    if ! command -v bwrap >/dev/null 2>&1; then
        printf '%s' "[cortex] compressor worker requires bubblewrap (bwrap), but bwrap is not installed."
        return 1
    fi

    local cortex_real; cortex_real="$(realpath "${CORTEX_DIR}" 2>/dev/null || printf '%s' "${CORTEX_DIR}")"
    local claude_sandbox_dir; claude_sandbox_dir="$(mktemp -d)"
    mkdir -p "${claude_sandbox_dir}/session-env"
    local -a claude_cmd=(claude --print --verbose --effort "${CLAUDE_EFFORT}")
    local -a compressor_dir_args=()
    local -a compressor_ro_binds=()
    local -a compressor_rw_binds=()
    [[ -n "${CLAUDE_MODEL}" ]] && claude_cmd+=(--model "${CLAUDE_MODEL}")
    if ! security_bwrap_ro_binds "${cortex_real}" claude compressor_ro_binds; then
        rm -rf "${claude_sandbox_dir}"
        return 1
    fi
    security_bwrap_dir_args compressor_dir_args
    if ! worker_bwrap_rw_binds "${cortex_real}" compressor_rw_binds; then
        rm -rf "${claude_sandbox_dir}"
        return 1
    fi
    run_with_array_prefix "${timeout_ref}" bwrap \
        --unshare-pid \
        --unshare-ipc \
        --unshare-uts \
        "${compressor_dir_args[@]}" \
        "${compressor_ro_binds[@]}" \
        --dev-bind /dev /dev \
        --proc /proc \
        --tmpfs /tmp \
        "${compressor_rw_binds[@]}" \
        --bind "${claude_sandbox_dir}/session-env" "${HOME}/.claude/session-env" \
        --chdir "${cortex_real}" \
        "${claude_cmd[@]}" --dangerously-skip-permissions "${prompt}" 2>&1 \
        | tee "${working_file}" \
        | tee /dev/fd/2 > "${tmp_out}" \
        || exit_code=${PIPESTATUS[0]}
    rm -rf "${claude_sandbox_dir}"
    return "${exit_code}"
}

worker_compressor_launch_codex() {
    local prompt="$1" working_file="$2" tmp_out="$3" tmp_last="$4" timeout_ref="$5"
    local exit_code=0

    if ! command -v bwrap >/dev/null 2>&1; then
        printf '%s' "[cortex] compressor worker requires bubblewrap (bwrap), but bwrap is not installed."
        return 1
    fi

    local cortex_real; cortex_real="$(realpath "${CORTEX_DIR}" 2>/dev/null || printf '%s' "${CORTEX_DIR}")"
    local compressor_codex_home=""
    local compressor_codex_bin=""
    local -a compressor_rw_binds=()
    local -a compressor_dir_args=()
    local -a compressor_ro_binds=()
    local compressor_scrubber_pid=""
    compressor_codex_bin="$(command -v codex 2>/dev/null || true)"
    if [[ -z "${compressor_codex_bin}" ]]; then
        printf '%s' "[cortex] compressor worker could not resolve codex on PATH."
        return 1
    fi
    if ! security_bwrap_ro_binds "${cortex_real}" codex compressor_ro_binds; then
        return 1
    fi
    security_bwrap_dir_args compressor_dir_args
    if ! compressor_codex_home="$(prepare_codex_stage_home)"; then
        return 1
    fi
    ROLE_CLI_USAGE_CODEX_HOME="${compressor_codex_home}"
    if ! worker_bwrap_rw_binds "${cortex_real}" compressor_rw_binds; then
        cleanup_codex_stage_home "${compressor_codex_home}"
        ROLE_CLI_USAGE_CODEX_HOME=""
        return 1
    fi
    compressor_scrubber_pid="$(start_codex_stage_scrubber "${compressor_codex_home}")"
    run_with_array_prefix "${timeout_ref}" bwrap \
        --unshare-pid \
        --unshare-ipc \
        --unshare-uts \
        "${compressor_dir_args[@]}" \
        "${compressor_ro_binds[@]}" \
        --dev-bind /dev /dev \
        --proc /proc \
        --tmpfs /tmp \
        "${compressor_rw_binds[@]}" \
        --bind "${compressor_codex_home}" "${HOME}/.codex" \
        --chdir "${cortex_real}" \
        "${compressor_codex_bin}" exec --model "${CODEX_MODEL}" \
            -c "model_reasoning_effort=\"${CODEX_REASONING_EFFORT}\"" \
            --ephemeral \
            --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox \
            --output-last-message "${tmp_last}" - <<<"${prompt}" 2>&1 \
        | tee "${working_file}" \
        | tee /dev/fd/2 > "${tmp_out}" \
        || exit_code=${PIPESTATUS[0]}
    if [[ -n "${compressor_scrubber_pid}" ]]; then
        wait "${compressor_scrubber_pid}" 2>/dev/null || true
    fi
    return "${exit_code}"
}
