#!/usr/bin/env bash

worker_sweep_config_file() {
    printf '%s/agents/sweep/config.env\n' "${CORTEX_DIR}"
}

worker_sweep_load_config() {
    local config_file
    config_file="$(worker_sweep_config_file)"
    [[ -f "${config_file}" ]] || return 0

    # shellcheck disable=SC1090
    source "${config_file}"
}

worker_sweep_minutes_to_seconds() {
    local value="$1"
    [[ "${value}" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$(( value * 60 ))"
}

worker_sweep_apply_defaults() {
    worker_sweep_load_config || return 1

    if [[ "${AGENT_PROVIDER_EXPLICIT}" -eq 0 ]]; then
        AGENT_PROVIDER="${SWEEP_PROVIDER:-codex}"
    fi
    apply_model_tier "${SWEEP_MODEL_TIER:-strong}"

    if [[ "${AGENT_PROVIDER}" == "codex" && "${CODEX_REASONING_EFFORT_EXPLICIT}" -eq 0 ]]; then
        CODEX_REASONING_EFFORT="${SWEEP_CODEX_REASONING_EFFORT:-high}"
    fi
    if [[ "${AGENT_PROVIDER}" == "claude" && "${CLAUDE_EFFORT_EXPLICIT}" -eq 0 ]]; then
        CLAUDE_EFFORT="${SWEEP_CLAUDE_EFFORT:-high}"
    fi

    if [[ -n "${SWEEP_WAKE_MINUTES:-}" ]] \
        && { [[ -z "${WORKER_REVIEW_INTERVAL}" ]] || [[ "${WORKER_REVIEW_INTERVAL}" == "${DEFAULT_WORKER_REVIEW_INTERVAL_DISABLED}" ]]; }; then
        WORKER_REVIEW_INTERVAL="$(worker_sweep_minutes_to_seconds "${SWEEP_WAKE_MINUTES}")" || return 1
    fi
    if [[ -n "${SWEEP_WORK_MINUTES:-}" ]]; then
        WORKER_REVIEW_TIMEOUT="$(worker_sweep_minutes_to_seconds "${SWEEP_WORK_MINUTES}")" || return 1
    fi

    case "${SWEEP_SELF_WAKE_ALLOWED:-0}" in
        1|yes|true)
            WORKER_NEXT_WAKE_ENABLED=1
            WORKER_NEXT_WAKE_MIN_SECONDS="${SWEEP_SELF_WAKE_MIN_SECONDS:-600}"
            WORKER_NEXT_WAKE_MAX_SECONDS="${SWEEP_SELF_WAKE_MAX_SECONDS:-43200}"
            ;;
    esac

    if [[ "${SWEEP_EXPORT_WANDB_API_KEY_FROM_NETRC:-0}" == "1" ]]; then
        export CORTEX_WORKER_EXPORT_WANDB_API_KEY_FROM_NETRC=1
        worker_environment_export_wandb_api_key_from_netrc || return 1
    fi
}

worker_sweep_append_rw_paths() {
    local cortex_real="$1"
    local rw_paths_ref="$2"
    local -a extra_rw_paths=()
    local screen_dir=""

    worker_sweep_load_config || return 1
    [[ -n "${SWEEP_RW_PATHS:-}" ]] || return 0

    if ! append_rw_paths_from_spec "${SWEEP_RW_PATHS}" extra_rw_paths; then
        return 1
    fi

    local path
    for path in "${extra_rw_paths[@]}"; do
        append_unique_path "${path}" "${rw_paths_ref}"
    done

    screen_dir="/run/screen/S-$(id -un)"
    if [[ -d "${screen_dir}" ]]; then
        append_unique_path "${screen_dir}" "${rw_paths_ref}"
    fi

    [[ -n "${cortex_real}" ]]
}

worker_sweep_append_ssh_binds() {
    local ssh_binds_ref="$1"
    named_array_clear "${ssh_binds_ref}"
}

worker_sweep_append_bwrap_pid_args() {
    local pid_args_ref="$1"
    named_array_clear "${pid_args_ref}"
    # Keep host PID visibility so sweep can map GPU owners and training jobs.
    return 0
}

worker_sweep_append_bwrap_device_args() {
    local device_args_ref="$1"
    security_bwrap_append_nvidia_device_binds "${device_args_ref}"
}

worker_sweep_append_ro_base() {
    local ro_binds_ref="$1"
    if [[ -d /run/screen ]]; then
        named_array_append "${ro_binds_ref}" --ro-bind /run/screen /run/screen
    fi
}
