#!/usr/bin/env bash

append_ro_bind_if_exists() {
    local path="$1"
    local out_ref="$2"
    local source

    [[ -e "${path}" ]] || return 0
    source="$(readlink_f_compat "${path}" 2>/dev/null || printf '%s' "${path}")"
    named_array_append "${out_ref}" --ro-bind "${source}" "${path}"
}

security_bwrap_ro_binds() {
    local cortex_real="$1" provider="$2"
    local ro_binds_ref="$3"
    named_array_clear "${ro_binds_ref}"

    local provider_bin="" provider_real="" provider_dir="" provider_real_dir=""
    provider_bin="$(command -v "${provider}" 2>/dev/null || true)"
    if [[ -n "${provider_bin}" ]]; then
        provider_real="$(readlink_f_compat "${provider_bin}" 2>/dev/null || printf '%s' "${provider_bin}")"
        provider_dir="$(dirname "${provider_bin}")"
        provider_real_dir="$(dirname "${provider_real}")"
    fi

    append_ro_bind_if_exists "${cortex_real}" "${ro_binds_ref}"
    append_ro_bind_if_exists /usr "${ro_binds_ref}"
    append_ro_bind_if_exists /usr/local "${ro_binds_ref}"
    append_ro_bind_if_exists /bin "${ro_binds_ref}"
    append_ro_bind_if_exists /sbin "${ro_binds_ref}"
    append_ro_bind_if_exists /lib "${ro_binds_ref}"
    append_ro_bind_if_exists /lib64 "${ro_binds_ref}"
    append_ro_bind_if_exists /etc "${ro_binds_ref}"
    append_ro_bind_if_exists /opt "${ro_binds_ref}"
    append_ro_bind_if_exists "${HOME}/anaconda3" "${ro_binds_ref}"
    append_ro_bind_if_exists "${HOME}/.conda" "${ro_binds_ref}"
    append_ro_bind_if_exists "${HOME}/.condarc" "${ro_binds_ref}"
    append_ro_bind_if_exists /run/systemd/resolve "${ro_binds_ref}"
    append_ro_bind_if_exists "${provider_bin}" "${ro_binds_ref}"
    append_ro_bind_if_exists "${provider_real}" "${ro_binds_ref}"
    append_ro_bind_if_exists "${provider_dir}" "${ro_binds_ref}"
    append_ro_bind_if_exists "${provider_real_dir}" "${ro_binds_ref}"

    if [[ "${provider}" == "claude" ]]; then
        append_ro_bind_if_exists "${HOME}/.local/bin" "${ro_binds_ref}"
        append_ro_bind_if_exists "${HOME}/.local/share/claude" "${ro_binds_ref}"
        append_ro_bind_if_exists "${HOME}/.claude.json" "${ro_binds_ref}"
        append_ro_bind_if_exists "${HOME}/.claude" "${ro_binds_ref}"
    fi
}

# Claude usage stage: bind a fresh writable directory over the CLI's
# per-project transcript dir (~/.claude/projects/<slug of cwd>) inside an
# otherwise read-only ~/.claude, so `claude --print` can persist its session
# JSONL and usage_lib can attribute this run's tokens. Appends the bind to the
# named array and exports the stage path in ROLE_CLI_USAGE_CLAUDE_PROJECT_DIR;
# the launcher (scripts/start_agent.sh) removes the stage after recording usage.
security_claude_usage_stage_bind() {
    local cwd_real="$1" bind_args_ref="$2"
    local slug host_dir stage_dir
    [[ -n "${HOME:-}" && -n "${cwd_real}" ]] || return 0
    slug="$(printf '%s' "${cwd_real}" | sed 's,/,-,g')"
    host_dir="${HOME}/.claude/projects/${slug}"
    mkdir -p "${host_dir}" 2>/dev/null || return 0
    stage_dir="$(mktemp -d 2>/dev/null)" || return 0
    named_array_append "${bind_args_ref}" --bind "${stage_dir}" "${host_dir}"
    ROLE_CLI_USAGE_CLAUDE_PROJECT_DIR="${stage_dir}"
    return 0
}

security_bwrap_dir_args() {
    local dir_args_ref="$1"
    named_array_clear "${dir_args_ref}"
    named_array_append "${dir_args_ref}" \
        --dir /home \
        --dir "${HOME}" \
        --dir "${HOME}/anaconda3" \
        --dir "${HOME}/.conda" \
        --dir "${HOME}/.local" \
        --dir "${HOME}/.local/bin" \
        --dir "${HOME}/.local/share" \
        --dir "${HOME}/.local/share/claude" \
        --dir "${HOME}/.claude"
}

# Start from bwrap's minimal devtmpfs. Selected accelerator character devices
# may be appended by a role hook; never bind the host's complete /dev tree.
security_bwrap_device_args() {
    local device_args_ref="$1"
    named_array_clear "${device_args_ref}"
    named_array_append "${device_args_ref}" --dev /dev
}

security_bwrap_append_nvidia_device_binds() {
    local device_args_ref="$1"
    local device index

    for device in /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools /dev/nvidia-modeset; do
        [[ -c "${device}" ]] || continue
        named_array_append "${device_args_ref}" --dev-bind "${device}" "${device}"
    done
    for index in {0..31}; do
        device="/dev/nvidia${index}"
        [[ -c "${device}" ]] || continue
        named_array_append "${device_args_ref}" --dev-bind "${device}" "${device}"
    done
}

claude_ipc_binds() {
    local ipc_binds_ref="$1"
    named_array_clear "${ipc_binds_ref}"

    local sock
    shopt -s nullglob
    for sock in /tmp/claude-*.sock; do
        [[ -S "${sock}" ]] || continue
        named_array_append "${ipc_binds_ref}" --bind "${sock}" "${sock}"
    done
    shopt -u nullglob
}

resolve_worker_sandbox_backend() {
    local requested="${1:-auto}"
    local platform
    platform="$(uname -s 2>/dev/null || echo unknown)"

    case "${requested}" in
        auto)
            if command -v bwrap >/dev/null 2>&1; then
                printf '%s\n' "bwrap"
                return 0
            fi
            if [[ "${platform}" == "Darwin" ]]; then
                printf '%s\n' "macos-direct"
                return 0
            fi
            printf '%s\n' "unavailable"
            return 1
            ;;
        bwrap)
            if command -v bwrap >/dev/null 2>&1; then
                printf '%s\n' "bwrap"
                return 0
            fi
            printf '%s\n' "unavailable"
            return 1
            ;;
        macos-direct)
            if [[ "${platform}" == "Darwin" ]]; then
                printf '%s\n' "macos-direct"
                return 0
            fi
            printf '%s\n' "unsupported"
            return 1
            ;;
        *)
            printf '%s\n' "invalid"
            return 1
            ;;
    esac
}
