#!/usr/bin/env bash

# Shared helpers for Cortex's sanitized public export flow. Keep this file
# side-effect free so it can be sourced by sync/export, doctor, and periodic
# checks alike.

source "${CORTEX_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)}/scripts/bash_compat.sh"

public_framework_files() {
    local root="${CORTEX_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)}"
    local -a root_public_files=(
        .gitignore
        BASH_RECIPES.md
        CLAUDE.md
        CONDUCTOR.md
        LICENSE
        PROTOCOL.md
        README.md
        SHORTCUTS.md
        setup.instruct
        environment.instruct.example
        user.instruct.example
        cortex.sh
        archive/README
        broadcast/README
        logs/README
        agents/conductor/inbox/README
        assets/cortex_logo.png
        assets/presentation_cortex.pdf
    )
    printf '%s\n' "${root_public_files[@]}"
    (cd "${root}" && if [[ -d roles ]]; then find roles -type f \( -name '*.instruct' -o -name '*.sh' -o -name '*.meta' -o -name '*.py' -o -name '*.md' \) | sort; fi)
    (cd "${root}" && if [[ -d scripts ]]; then find scripts -maxdepth 1 -type f \( -name '*.sh' -o -name '*.py' \) | sort; fi)
    (cd "${root}" && if [[ -d scripts/tests ]]; then find scripts/tests -type f \( -name '*.sh' -o -name '*.py' \) | sort; fi)
    (cd "${root}" && if [[ -d config ]]; then find config -maxdepth 1 -type f -name '*.sh' | sort; fi)
    (cd "${root}" && if [[ -d templates ]]; then find templates -type f | sort; fi)
}

public_forbidden_patterns() {
    local -a patterns=(
        "\\braid-[a-z]+\\b"
        "todo\\.md"
        "projects/[A-Za-z0-9._-]+/tasks\\.md"
        "conductor""_watch"
        "conductor""_mode\\b"
        "CONDUCTOR_""LOCK"
        "conductor_""lock"
        "(^|[^[:alnum:]_.-])conductor[.]sh\\b"
        "(?<!scripts/)\\bstart_""agent[.]sh\\b"
        "scripts/""scripts/"
    )
    printf '%s\n' "${patterns[@]}"

    local root="${CORTEX_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)}"
    # CORTEX_DEFAULT_ENV_DIR is already an absolute path in normal Cortex
    # invocations (set in config/cortex_defaults.sh). Use it directly when
    # absolute; fall back to "environments/<name>" relative to root otherwise.
    local env_overlay
    if [[ "${CORTEX_DEFAULT_ENV_DIR:-}" == /* ]]; then
        env_overlay="${CORTEX_DEFAULT_ENV_DIR}/public_forbidden_patterns.txt"
    else
        env_overlay="${root}/environments/${CORTEX_DEFAULT_ENV_NAME:-unknown}/public_forbidden_patterns.txt"
    fi
    local pattern_file pattern_line
    for pattern_file in \
        "${root}/config/public_forbidden_patterns.local" \
        "${env_overlay}" \
        "${root}/agents/conductor/secrets/public_forbidden_patterns.txt"; do
        [[ -f "${pattern_file}" ]] || continue
        while IFS= read -r pattern_line || [[ -n "${pattern_line}" ]]; do
            pattern_line="${pattern_line#"${pattern_line%%[![:space:]]*}"}"
            pattern_line="${pattern_line%"${pattern_line##*[![:space:]]}"}"
            [[ -z "${pattern_line}" || "${pattern_line}" == \#* ]] && continue
            printf '%s\n' "${pattern_line}"
        done < "${pattern_file}"
    done
}

public_forbidden_regex() {
    local regex="" pattern
    while IFS= read -r pattern || [[ -n "${pattern}" ]]; do
        [[ -n "${pattern}" ]] || continue
        if [[ -z "${regex}" ]]; then
            regex="${pattern}"
        else
            regex="${regex}|${pattern}"
        fi
    done < <(public_forbidden_patterns)
    printf '%s' "${regex}"
}

# A public license must name its copyright holder. Keep that intentional notice
# out of deployment-leak findings while continuing to scan every other LICENSE
# line and every other exported file.
public_filter_allowed_content_matches() {
    local match
    while IFS= read -r match || [[ -n "${match}" ]]; do
        case "${match}" in
            LICENSE:[0-9]*:Copyright\ \(c\)\ [0-9][0-9][0-9][0-9]\ *|./LICENSE:[0-9]*:Copyright\ \(c\)\ [0-9][0-9][0-9][0-9]\ *)
                continue
                ;;
        esac
        printf '%s\n' "${match}"
    done
}

public_sync_ref() {
    local remote url
    while IFS=$'\t' read -r remote url; do
        if [[ "${url}" == "${CORTEX_DEFAULT_PUBLIC_REMOTE_URL}" ]]; then
            printf '%s/%s\n' "${remote}" "${CORTEX_DEFAULT_PUBLIC_BRANCH}"
            return 0
        fi
    done < <(git remote -v | awk '$3 == "(fetch)" { print $1 "\t" $2 }')
    return 1
}

public_sync_local_ref() {
    if git rev-parse --verify --quiet refs/heads/public >/dev/null; then
        printf 'public\n'
        return 0
    fi
    if git rev-parse --verify --quiet "refs/heads/${CORTEX_DEFAULT_PUBLIC_BRANCH}" >/dev/null; then
        printf '%s\n' "${CORTEX_DEFAULT_PUBLIC_BRANCH}"
        return 0
    fi
    return 1
}

public_sync_available_ref() {
    local public_ref=""
    if public_ref="$(public_sync_ref 2>/dev/null)" \
        && git rev-parse --verify --quiet "${public_ref}" >/dev/null; then
        printf '%s\n' "${public_ref}"
        return 0
    fi
    public_sync_local_ref
}

public_remote_name() {
    local ref
    ref="$(public_sync_ref)" || return 1
    printf '%s\n' "${ref%%/*}"
}

public_sync_last_source_sha() {
    local public_ref="${1:-}"
    if [[ -z "${public_ref}" ]]; then
        public_ref="$(public_sync_available_ref)" || return 1
    fi
    git log -1 --format=%B "${public_ref}" 2>/dev/null \
        | sed -En \
            -e 's/^cortex: sync framework from [A-Za-z0-9._-]+ ([0-9a-f]+)$/\1/p' \
            -e 's/^cortex: public framework export from [A-Za-z0-9._-]+ ([0-9a-f]+)$/\1/p' \
            -e 's/^Source-Commit: ([0-9a-f]+)$/\1/p' \
        | head -n 1
}

public_framework_drift_log() {
    local since_sha="$1"
    local branch="${2:-master}"
    local -a files=()
    local file
    while IFS= read -r file || [[ -n "${file}" ]]; do
        [[ -n "${file}" ]] || continue
        files+=("${file}")
    done < <(public_framework_files)
    (( $(bash_array_len files) > 0 )) || return 1
    git log --oneline "${since_sha}..${branch}" -- "${files[@]}" 2>/dev/null
}
