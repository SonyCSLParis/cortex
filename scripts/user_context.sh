#!/usr/bin/env bash

# Shared Cortex user-resolution helpers.
#
# Contract:
# - `user.instruct` at the repo root is a free-text routing note that points to
#   the default user's profile under `users/<name>/<name>.instruct`.
# - The per-user profile carries the actual durable preferences and private
#   messenger identifiers.

source "${CORTEX_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}/scripts/bash_compat.sh"

cortex_user_pointer_file() {
    local cortex_dir="${1:-${CORTEX_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}}"
    printf '%s\n' "${cortex_dir}/user.instruct"
}

cortex_user_extract_relpath() {
    local pointer_file="$1"
    [[ -r "${pointer_file}" ]] || return 1
    grep -Eo 'users/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\.instruct' "${pointer_file}" | head -n 1
}

cortex_user_load() {
    local cortex_dir="${1:-${CORTEX_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}}"
    local pointer_file relpath instruct_abs user_dir user_name
    pointer_file="$(cortex_user_pointer_file "${cortex_dir}")"
    relpath="${CORTEX_USER_INSTRUCT_REL:-}"

    if [[ -n "${relpath}" ]]; then
        :
    else
        relpath="$(cortex_user_extract_relpath "${pointer_file}" 2>/dev/null || true)"
    fi

    if [[ -z "${relpath}" && -d "${cortex_dir}/users" ]]; then
        local discovered_count=0 discovered_path="" discovered_file
        while IFS= read -r discovered_file; do
            [[ -n "${discovered_file}" ]] || continue
            discovered_count=$(( discovered_count + 1 ))
            if (( discovered_count == 1 )); then
                discovered_path="${discovered_file}"
            fi
        done < <(find "${cortex_dir}/users" -mindepth 2 -maxdepth 2 -type f -name '*.instruct' | sort)
        if (( discovered_count == 1 )); then
            relpath="${discovered_path#${cortex_dir}/}"
        fi
    fi

    [[ -n "${relpath}" ]] || return 1
    instruct_abs="${cortex_dir}/${relpath}"
    [[ -f "${instruct_abs}" ]] || return 1

    user_dir="$(basename "$(dirname "${instruct_abs}")")"
    user_name="${user_dir}"

    export CORTEX_USER_NAME="${user_name}"
    export CORTEX_USER_DIR="${cortex_dir}/users/${user_name}"
    export CORTEX_USER_HOME="${CORTEX_USER_DIR}"
    export CORTEX_USER_INSTRUCT="${instruct_abs}"
    export CORTEX_USER_INSTRUCT_REL="${relpath}"
    export CORTEX_USER_POINTER_FILE="${pointer_file}"
    return 0
}
