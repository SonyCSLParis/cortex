#!/usr/bin/env bash

worker_efficiency_apply_defaults() {
    worker_set_codex_defaults medium "${DEFAULT_WORKER_REVIEW_INTERVAL_6H}" ""
}

worker_efficiency_launch_codex() {
    local prompt="$1" working_file="$2" tmp_out="$3" tmp_last="$4" timeout_ref="$5"
    local exit_code=0

    if ! command -v bwrap >/dev/null 2>&1; then
        printf '%s' "[cortex] efficiency worker requires bubblewrap (bwrap) for framework-only sandbox, but bwrap is not installed."
        return 1
    fi

    local cortex_real; cortex_real="$(realpath "${CORTEX_DIR}" 2>/dev/null || printf '%s' "${CORTEX_DIR}")"
    local efficiency_agent_dir="${cortex_real}/agents/${AGENT_ID}"
    local efficiency_codex_home=""
    local efficiency_codex_bin=""
    local -a efficiency_dir_args=()
    local -a efficiency_ro_binds=()
    local efficiency_scrubber_pid=""
    efficiency_codex_bin="$(command -v codex 2>/dev/null || true)"
    if [[ -z "${efficiency_codex_bin}" ]]; then
        printf '%s' "[cortex] efficiency worker could not resolve codex on PATH."
        return 1
    fi
    if ! security_bwrap_ro_binds "${cortex_real}" codex efficiency_ro_binds; then
        return 1
    fi
    security_bwrap_dir_args efficiency_dir_args
    if ! efficiency_codex_home="$(prepare_codex_stage_home)"; then
        return 1
    fi
    ROLE_CLI_USAGE_CODEX_HOME="${efficiency_codex_home}"
    efficiency_scrubber_pid="$(start_codex_stage_scrubber "${efficiency_codex_home}")"
    tmp_last="${efficiency_agent_dir}/.codex_last.tmp"
    run_with_array_prefix "${timeout_ref}" bwrap \
        --unshare-pid \
        --unshare-ipc \
        --unshare-uts \
        "${efficiency_dir_args[@]}" \
        "${efficiency_ro_binds[@]}" \
        --dev-bind /dev /dev \
        --proc /proc \
        --tmpfs /tmp \
        --bind "${efficiency_agent_dir}" "${efficiency_agent_dir}" \
        --bind "${efficiency_codex_home}" "${HOME}/.codex" \
        --chdir "${cortex_real}" \
        "${efficiency_codex_bin}" exec --model "${CODEX_MODEL}" \
            -c "model_reasoning_effort=\"${CODEX_REASONING_EFFORT}\"" \
            --ephemeral \
            --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox \
            --output-last-message "${tmp_last}" - <<<"${prompt}" 2>&1 \
        | tee "${working_file}" \
        | tee /dev/fd/2 > "${tmp_out}" \
        || exit_code=${PIPESTATUS[0]}
    if [[ -n "${efficiency_scrubber_pid}" ]]; then
        wait "${efficiency_scrubber_pid}" 2>/dev/null || true
    fi
    return "${exit_code}"
}
