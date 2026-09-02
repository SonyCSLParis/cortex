#!/usr/bin/env bash

node_apply_defaults() {
    :
}

node_select_instruction_templates() {
    INSTRUCT_TEMPLATE="${CORTEX_DIR}/roles/node.instruct"
    SELFCHECK_INTERVAL="${SELFCHECK_INTERVAL:-${CORTEX_DEFAULT_SELFCHECK_INTERVAL_SECONDS}}"
    STATUSREPORT_INTERVAL="${STATUSREPORT_INTERVAL:-${CORTEX_DEFAULT_STATUSREPORT_INTERVAL_SECONDS}}"
}

node_run_provider_cli() {
    local prompt="$1" working_file="$2" tmp_out="$3" tmp_last="$4" timeout_ref="$5"
    local exit_code=0

    case "${AGENT_PROVIDER}" in
        claude)
            local -a claude_cmd=(claude --print --verbose --effort "${CLAUDE_EFFORT}")
            [[ -n "${CLAUDE_MODEL}" ]] && claude_cmd+=(--model "${CLAUDE_MODEL}")
            local node_claude_sid; node_claude_sid="$(cortex_usage_new_claude_session_id 2>/dev/null || true)"
            if [[ -n "${node_claude_sid}" ]]; then
                claude_cmd+=(--session-id "${node_claude_sid}")
                ROLE_CLI_USAGE_CLAUDE_SESSION_ID="${node_claude_sid}"
            fi
            if ! command -v bwrap >/dev/null 2>&1; then
                printf '%s' "[cortex] claude node launch requires bubblewrap (bwrap) for read-only enforcement, but bwrap is not installed."
                return 1
            fi
            local cortex_real; cortex_real="$(realpath "${CORTEX_DIR}" 2>/dev/null || printf '%s' "${CORTEX_DIR}")"
            local claude_sandbox_dir; claude_sandbox_dir="$(mktemp -d)"
            mkdir -p "${claude_sandbox_dir}/session-env"
            local -a node_dir_args=()
            local -a node_ro_binds=()
            local -a node_device_args=()
            if ! security_bwrap_ro_binds "${cortex_real}" claude node_ro_binds; then
                rm -rf "${claude_sandbox_dir}"
                return 1
            fi
            security_bwrap_dir_args node_dir_args
            security_bwrap_device_args node_device_args
            local -a node_usage_binds=()
            security_claude_usage_stage_bind "${cortex_real}" node_usage_binds
            run_with_array_prefix "${timeout_ref}" bwrap \
                --unshare-pid \
                --unshare-ipc \
                --unshare-uts \
                "${node_dir_args[@]}" \
                "${node_ro_binds[@]}" \
                "${node_device_args[@]}" \
                --proc /proc \
                --tmpfs /tmp \
                --bind "${claude_sandbox_dir}/session-env" "${HOME}/.claude/session-env" \
                "${node_usage_binds[@]}" \
                --chdir "${cortex_real}" \
                "${claude_cmd[@]}" --permission-mode dontAsk "${prompt}" 2>&1 \
                | tee "${working_file}" \
                | tee /dev/fd/2 > "${tmp_out}" \
                || exit_code=${PIPESTATUS[0]}
            rm -rf "${claude_sandbox_dir}"
            return "${exit_code}"
            ;;
        codex)
            run_with_array_prefix "${timeout_ref}" codex exec --model "${CODEX_MODEL}" \
                -c "model_reasoning_effort=\"${CODEX_REASONING_EFFORT}\"" \
                --skip-git-repo-check --sandbox read-only \
                --output-last-message "${tmp_last}" - <<<"${prompt}" 2>&1 \
                | tee "${working_file}" \
                | tee /dev/fd/2 > "${tmp_out}" \
                || exit_code=${PIPESTATUS[0]}
            return "${exit_code}"
            ;;
    esac

    printf '[cortex] unsupported provider for node role: %s' "${AGENT_PROVIDER}"
    return 1
}
