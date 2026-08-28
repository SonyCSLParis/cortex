#!/usr/bin/env bash
# =============================================================================
# public_commit_notice.sh — report public commits not yet represented locally
#
# Intended for the conductor startup operator view. Refreshes the configured
# public branch, then reports only commits that are not already accounted for
# by the local private source branch. Generated public-export commits whose
# Source-Commit is already in that branch are deliberately quiet.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CORTEX_DIR="${CORTEX_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd -P)}"
source "${CORTEX_DIR}/config/cortex_defaults.sh"
source "${CORTEX_DIR}/scripts/public_sync_lib.sh"

REPO_DIR="${CORTEX_PUBLIC_COMMIT_NOTICE_REPO:-${CORTEX_DIR}}"
BASE_BRANCH="${CORTEX_PUBLIC_COMMIT_NOTICE_BASE_BRANCH:-}"
TIMEOUT_SECONDS="${CORTEX_DEFAULT_PUBLIC_COMMIT_NOTICE_TIMEOUT_SECONDS}"
MAX_COMMITS="${CORTEX_DEFAULT_PUBLIC_COMMIT_NOTICE_MAX_COMMITS}"

cd "${REPO_DIR}" 2>/dev/null || {
    printf 'PUBLIC UPDATE CHECK UNAVAILABLE: Cortex directory not found.\n'
    exit 1
}

[[ "${TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]] || TIMEOUT_SECONDS=8
[[ "${MAX_COMMITS}" =~ ^[1-9][0-9]*$ ]] || MAX_COMMITS=3

current_branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
remote="$(public_remote_name 2>/dev/null || true)"
public_checkout=0

if [[ -z "${remote}" ]]; then
    if [[ "${current_branch}" == "${CORTEX_DEFAULT_PUBLIC_BRANCH}" ]] \
        && git remote get-url origin >/dev/null 2>&1; then
        remote="origin"
        public_checkout=1
    else
        exit 0
    fi
elif [[ "${current_branch}" == "${CORTEX_DEFAULT_PUBLIC_BRANCH}" ]]; then
    tracking_remote="$(git config --get "branch.${current_branch}.remote" 2>/dev/null || true)"
    [[ "${tracking_remote}" == "${remote}" ]] && public_checkout=1
fi

if [[ -z "${BASE_BRANCH}" ]]; then
    if (( public_checkout )); then
        BASE_BRANCH="${current_branch}"
    else
        BASE_BRANCH="master"
    fi
fi

if ! git rev-parse --verify --quiet "refs/heads/${BASE_BRANCH}" >/dev/null; then
    printf 'PUBLIC UPDATE CHECK UNAVAILABLE: local %s branch is missing.\n' "${BASE_BRANCH}"
    exit 1
fi

fetch_output=""
if fetch_output="$(run_with_timeout "${TIMEOUT_SECONDS}" git fetch --quiet "${remote}" "${CORTEX_DEFAULT_PUBLIC_BRANCH}" 2>&1)"; then
    :
else
    fetch_status=$?
    if [[ "${fetch_status}" == 124 || "${fetch_status}" == 137 ]]; then
        printf 'PUBLIC UPDATE CHECK UNAVAILABLE: refresh of %s/%s timed out after %ss.\n' \
            "${remote}" "${CORTEX_DEFAULT_PUBLIC_BRANCH}" "${TIMEOUT_SECONDS}"
    else
        printf 'PUBLIC UPDATE CHECK UNAVAILABLE: could not refresh %s/%s%s.\n' \
            "${remote}" "${CORTEX_DEFAULT_PUBLIC_BRANCH}" \
            "${fetch_output:+ (${fetch_output//$'\n'/ })}"
    fi
    exit 1
fi

public_ref="${remote}/${CORTEX_DEFAULT_PUBLIC_BRANCH}"
if ! git rev-parse --verify --quiet "${public_ref}" >/dev/null; then
    printf 'PUBLIC UPDATE CHECK UNAVAILABLE: %s is unavailable after refresh.\n' "${public_ref}"
    exit 1
fi

unaccounted=()
while IFS= read -r commit || [[ -n "${commit}" ]]; do
    [[ -n "${commit}" ]] || continue
    source_sha="$(git log -1 --format=%B "${commit}" | sed -En \
        -e 's/^cortex: sync framework from [A-Za-z0-9._-]+ ([0-9a-f]+)$/\1/p' \
        -e 's/^cortex: public framework export from [A-Za-z0-9._-]+ ([0-9a-f]+)$/\1/p' \
        -e 's/^Source-Commit: ([0-9a-f]+)$/\1/p' | head -n 1)"
    if [[ -n "${source_sha}" ]] && git merge-base --is-ancestor "${source_sha}" "${BASE_BRANCH}" 2>/dev/null; then
        continue
    fi
    unaccounted+=("${commit}")
done < <(git rev-list "${BASE_BRANCH}..${public_ref}")

count="${#unaccounted[@]}"
(( count > 0 )) || exit 0

if (( count == 1 )); then
    noun='commit'
else
    noun='commits'
fi
printf '\n\033[1;33m'
printf 'UPDATE AVAILABLE: %s new public %s on %s not represented in %s. Ask Conductor to pull from public!\n' \
    "${count}" "${noun}" "${public_ref}" "${BASE_BRANCH}"

shown=0
for commit in "${unaccounted[@]}"; do
    (( shown < MAX_COMMITS )) || break
    git log -1 --format='  %h %s' "${commit}"
    shown=$((shown + 1))
done
if (( count > shown )); then
    printf '  … and %s more.\n' "$((count - shown))"
fi
printf '\033[0m'
