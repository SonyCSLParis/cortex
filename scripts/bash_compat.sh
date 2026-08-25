#!/usr/bin/env bash

# Bash 3 / BSD-userland compatibility helpers shared by Cortex shell scripts.

bash_array_len() {
    local name="$1" len restore_u=0
    [[ $- == *u* ]] && restore_u=1
    set +u
    eval "len=\${#${name}[@]}"
    (( restore_u )) && set -u
    printf '%s' "${len:-0}"
}

named_array_clear() {
    eval "$1=()"
}

named_array_copy() {
    local __bca_src="$1" __bca_dest="$2" restore_u=0
    [[ $- == *u* ]] && restore_u=1
    set +u
    eval "$__bca_dest=(\"\${${__bca_src}[@]}\")"
    (( restore_u )) && set -u
}

named_array_append() {
    local name="$1" item
    shift
    for item in "$@"; do
        eval "$name+=(\"\$item\")"
    done
}

named_array_append_unique() {
    local name="$1" candidate="$2" existing
    local -a items=()
    named_array_copy "${name}" items
    for existing in "${items[@]}"; do
        [[ "${existing}" == "${candidate}" ]] && return 0
    done
    named_array_append "${name}" "${candidate}"
}

run_with_array_prefix() {
    local prefix_ref="$1"
    shift
    local -a prefix=()
    named_array_copy "${prefix_ref}" prefix
    if (( $(bash_array_len prefix) > 0 )); then
        "${prefix[@]}" "$@"
    else
        "$@"
    fi
}

run_with_timeout() {
    local seconds="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "${seconds}" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout "${seconds}" "$@"
    else
        "$@"
    fi
}

file_mtime_epoch() {
    local path="$1"
    if stat -c %Y "${path}" >/dev/null 2>&1; then
        stat -c %Y "${path}"
    elif stat -f %m "${path}" >/dev/null 2>&1; then
        stat -f %m "${path}"
    else
        printf '0\n'
    fi
}

normalize_abs_path_components() {
    local path="$1" part
    local -a stack=()
    local stack_len=0
    local old_ifs="${IFS}"

    if [[ "${path}" != /* ]]; then
        path="${PWD}/${path}"
    fi

    IFS='/'
    # shellcheck disable=SC2206
    local parts=( ${path} )
    IFS="${old_ifs}"

    for part in "${parts[@]}"; do
        [[ -n "${part}" && "${part}" != "." ]] || continue
        if [[ "${part}" == ".." ]]; then
            if (( stack_len > 0 )); then
                stack_len=$(( stack_len - 1 ))
                unset "stack[${stack_len}]"
            fi
            continue
        fi
        stack[${stack_len}]="${part}"
        stack_len=$(( stack_len + 1 ))
    done

    if (( stack_len == 0 )); then
        printf '/\n'
        return 0
    fi

    printf '/%s' "${stack[0]}"
    local i
    for (( i=1; i<stack_len; i++ )); do
        printf '/%s' "${stack[i]}"
    done
    printf '\n'
}

readlink_f_compat() {
    local path="$1" dir base
    if readlink -f -- "${path}" >/dev/null 2>&1; then
        readlink -f -- "${path}"
        return 0
    fi
    if command -v realpath >/dev/null 2>&1 && realpath "${path}" >/dev/null 2>&1; then
        realpath "${path}"
        return 0
    fi
    [[ -e "${path}" ]] || return 1
    dir="$(cd "$(dirname "${path}")" 2>/dev/null && pwd -P)" || return 1
    base="$(basename "${path}")"
    printf '%s/%s\n' "${dir}" "${base}"
}

realpath_m_compat() {
    local path="$1"
    if realpath -m -- "${path}" >/dev/null 2>&1; then
        realpath -m -- "${path}"
        return 0
    fi
    normalize_abs_path_components "${path}"
}

trim_whitespace() {
    local text="$1"
    text="${text#"${text%%[![:space:]]*}"}"
    text="${text%"${text##*[![:space:]]}"}"
    printf '%s' "${text}"
}

epoch_to_iso8601_utc() {
    local epoch="$1"
    if date -u -d "@${epoch}" '+%Y-%m-%dT%H:%M:%SZ' >/dev/null 2>&1; then
        date -u -d "@${epoch}" '+%Y-%m-%dT%H:%M:%SZ'
    else
        date -u -r "${epoch}" '+%Y-%m-%dT%H:%M:%SZ'
    fi
}

iso8601_to_epoch_utc() {
    local iso="$1" normalized
    if date -u -d "${iso}" +%s >/dev/null 2>&1; then
        date -u -d "${iso}" +%s
        return 0
    fi

    normalized="$(printf '%s' "${iso}" | sed -E 's/Z$/+0000/; s/([+-][0-9]{2}):([0-9]{2})$/\1\2/')"
    if date -j -u -f '%Y-%m-%dT%H:%M:%S%z' "${normalized}" +%s >/dev/null 2>&1; then
        date -j -u -f '%Y-%m-%dT%H:%M:%S%z' "${normalized}" +%s
        return 0
    fi

    printf '0\n'
}
