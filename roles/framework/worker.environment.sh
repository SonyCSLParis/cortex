#!/usr/bin/env bash

worker_environment_apply_defaults() {
    worker_set_codex_defaults medium "${DEFAULT_WORKER_REVIEW_INTERVAL_DAILY}" "${DEFAULT_WORKER_REVIEW_TIMEOUT_LONG_SECONDS}"
}

worker_environment_append_ssh_binds() {
    local ssh_binds_ref="$1"
    worker_append_safe_ssh_binds "${ssh_binds_ref}"
}

worker_environment_extract_wandb_api_key_from_netrc() {
    local netrc_path="${1:-${HOME}/.netrc}"
    local machine_name="${2:-api.wandb.ai}"

    [[ -f "${netrc_path}" ]] || return 1

    awk -v machine_name="${machine_name}" '
        $1 == "machine" {
            current_machine = $2
            next
        }
        current_machine == machine_name && $1 == "password" {
            print $2
            exit
        }
    ' "${netrc_path}"
}

worker_environment_export_wandb_api_key_from_netrc() {
    [[ "${CORTEX_WORKER_EXPORT_WANDB_API_KEY_FROM_NETRC:-0}" == "1" ]] || return 0
    [[ -n "${WANDB_API_KEY:-}" ]] && return 0

    local netrc_path="${CORTEX_WORKER_WANDB_NETRC_PATH:-${HOME}/.netrc}"
    local machine_name="${CORTEX_WORKER_WANDB_MACHINE:-api.wandb.ai}"
    local api_key=""
    api_key="$(worker_environment_extract_wandb_api_key_from_netrc "${netrc_path}" "${machine_name}" || true)"
    [[ -n "${api_key}" ]] || return 0

    export WANDB_API_KEY="${api_key}"
}
