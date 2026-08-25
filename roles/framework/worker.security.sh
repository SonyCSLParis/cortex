#!/usr/bin/env bash

worker_security_apply_defaults() {
    worker_set_codex_defaults medium "${DEFAULT_WORKER_REVIEW_INTERVAL_DAILY}" ""
}

worker_security_launch_claude() {
    local prompt="$1" working_file="$2" tmp_out="$3" timeout_ref="$4"
    local exit_code=0

    if ! command -v bwrap >/dev/null 2>&1; then
        printf '%s' "[cortex] security worker requires bubblewrap (bwrap) for read-only sandbox, but bwrap is not installed."
        return 1
    fi

    local cortex_real; cortex_real="$(realpath "${CORTEX_DIR}" 2>/dev/null || printf '%s' "${CORTEX_DIR}")"
    local security_agent_dir="${cortex_real}/agents/${AGENT_ID}"
    local claude_sandbox_dir; claude_sandbox_dir="$(mktemp -d)"
    local -a security_dir_args=()
    local -a security_ro_binds=()
    local -a security_claude_cmd=()
    local -a security_claude_ipc_binds=()
    local security_claude_bin=""
    mkdir -p "${claude_sandbox_dir}/session-env"
    security_claude_bin="$(command -v claude 2>/dev/null || true)"
    if [[ -z "${security_claude_bin}" ]]; then
        rm -rf "${claude_sandbox_dir}"
        printf '%s' "[cortex] security worker could not resolve claude on PATH."
        return 1
    fi
    if ! security_bwrap_ro_binds "${cortex_real}" claude security_ro_binds; then
        rm -rf "${claude_sandbox_dir}"
        return 1
    fi
    security_bwrap_dir_args security_dir_args
    claude_ipc_binds security_claude_ipc_binds
    security_claude_cmd=("${security_claude_bin}" --print --verbose --effort "${CLAUDE_EFFORT}")
    [[ -n "${CLAUDE_MODEL}" ]] && security_claude_cmd+=(--model "${CLAUDE_MODEL}")
    run_with_array_prefix "${timeout_ref}" bwrap \
        --unshare-pid \
        --unshare-ipc \
        --unshare-uts \
        "${security_dir_args[@]}" \
        "${security_ro_binds[@]}" \
        --dev-bind /dev /dev \
        --proc /proc \
        --tmpfs /tmp \
        "${security_claude_ipc_binds[@]}" \
        --bind "${security_agent_dir}" "${security_agent_dir}" \
        --bind "${claude_sandbox_dir}/session-env" "${HOME}/.claude/session-env" \
        --chdir "${cortex_real}" \
        /bin/bash -lc 'exec "$@"' bash \
        "${security_claude_cmd[@]}" --dangerously-skip-permissions "${prompt}" 2>&1 \
        | tee "${working_file}" \
        | tee /dev/fd/2 > "${tmp_out}" \
        || exit_code=${PIPESTATUS[0]}
    rm -rf "${claude_sandbox_dir}"
    return "${exit_code}"
}

worker_security_launch_codex() {
    local prompt="$1" working_file="$2" tmp_out="$3" tmp_last="$4" timeout_ref="$5"
    local exit_code=0

    if ! command -v bwrap >/dev/null 2>&1; then
        printf '%s' "[cortex] security worker requires bubblewrap (bwrap) for read-only sandbox, but bwrap is not installed."
        return 1
    fi

    local cortex_real; cortex_real="$(realpath "${CORTEX_DIR}" 2>/dev/null || printf '%s' "${CORTEX_DIR}")"
    local security_agent_dir="${cortex_real}/agents/${AGENT_ID}"
    local security_codex_home=""
    local security_codex_bin=""
    local -a security_dir_args=()
    local -a security_ro_binds=()
    local security_scrubber_pid=""
    security_codex_bin="$(command -v codex 2>/dev/null || true)"
    if [[ -z "${security_codex_bin}" ]]; then
        printf '%s' "[cortex] security worker could not resolve codex on PATH."
        return 1
    fi
    if ! security_bwrap_ro_binds "${cortex_real}" codex security_ro_binds; then
        return 1
    fi
    security_bwrap_dir_args security_dir_args
    if ! security_codex_home="$(prepare_codex_stage_home)"; then
        return 1
    fi
    ROLE_CLI_USAGE_CODEX_HOME="${security_codex_home}"
    security_scrubber_pid="$(start_codex_stage_scrubber "${security_codex_home}")"
    run_with_array_prefix "${timeout_ref}" bwrap \
        --unshare-pid \
        --unshare-ipc \
        --unshare-uts \
        "${security_dir_args[@]}" \
        "${security_ro_binds[@]}" \
        --dev-bind /dev /dev \
        --proc /proc \
        --tmpfs /tmp \
        --bind "${security_agent_dir}" "${security_agent_dir}" \
        --bind "${security_codex_home}" "${HOME}/.codex" \
        --chdir "${cortex_real}" \
        "${security_codex_bin}" exec --model "${CODEX_MODEL}" \
            -c "model_reasoning_effort=\"${CODEX_REASONING_EFFORT}\"" \
            --ephemeral \
            --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox \
            --output-last-message "${tmp_last}" - <<<"${prompt}" 2>&1 \
        | tee "${working_file}" \
        | tee /dev/fd/2 > "${tmp_out}" \
        || exit_code=${PIPESTATUS[0]}
    if [[ -n "${security_scrubber_pid}" ]]; then
        wait "${security_scrubber_pid}" 2>/dev/null || true
    fi
    return "${exit_code}"
}
