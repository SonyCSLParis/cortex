#!/usr/bin/env bash
# Update a public Cortex checkout from the configured public upstream.
#
# This helper is intentionally conservative. It updates clean public
# checkouts, reports tracked framework drift, and only discards local tracked
# edits when the user asks for that explicitly. Untracked / ignored overlay
# state is left alone.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CORTEX_DIR="${CORTEX_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd -P)}"
cd "${CORTEX_DIR}"
source "${CORTEX_DIR}/config/cortex_defaults.sh"
source "${CORTEX_DIR}/scripts/bash_compat.sh"
source "${CORTEX_DIR}/scripts/public_sync_lib.sh"

MODE="update"
REMOTE_NAME=""
BRANCH_NAME="${CORTEX_DEFAULT_PUBLIC_BRANCH}"
FETCH=1

usage() {
    cat <<'EOF'
Usage:
  bash scripts/update_public_checkout.sh [--check]
  bash scripts/update_public_checkout.sh [--discard-framework-changes]
  bash scripts/update_public_checkout.sh [--remote NAME] [--branch NAME] [--no-fetch]

Modes:
  default                     Fast-forward a clean public checkout.
  --check                     Report tracked drift; do not update.
  --discard-framework-changes Reset tracked files to upstream, leaving
                              untracked/ignored overlay state alone.

This is not a merge helper. If the public branch has local commits, move them
to a branch/fork and re-run from a clean public branch.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check|--dry-run)
            MODE="check"
            shift
            ;;
        --discard-framework-changes)
            MODE="discard"
            shift
            ;;
        --remote)
            [[ $# -ge 2 ]] || { echo "Missing value for --remote" >&2; exit 2; }
            REMOTE_NAME="$2"
            shift 2
            ;;
        --branch)
            [[ $# -ge 2 ]] || { echo "Missing value for --branch" >&2; exit 2; }
            BRANCH_NAME="$2"
            shift 2
            ;;
        --no-fetch)
            FETCH=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ -z "${REMOTE_NAME}" ]]; then
    if REMOTE_NAME="$(public_remote_name 2>/dev/null)"; then
        :
    elif git remote get-url origin >/dev/null 2>&1; then
        REMOTE_NAME="origin"
    else
        echo "Could not determine public remote; pass --remote NAME." >&2
        exit 2
    fi
fi

current_branch="$(git symbolic-ref --quiet --short HEAD || true)"
target_ref="refs/remotes/${REMOTE_NAME}/${BRANCH_NAME}"

if (( FETCH )); then
    git fetch --quiet --prune "${REMOTE_NAME}" \
        "+refs/heads/${BRANCH_NAME}:${target_ref}"
fi

if ! git rev-parse --verify --quiet "${target_ref}" >/dev/null; then
    echo "Upstream branch not found: ${REMOTE_NAME}/${BRANCH_NAME}" >&2
    exit 2
fi

framework_files=()
while IFS= read -r framework_file; do
    [[ -n "${framework_file}" ]] || continue
    framework_files+=("${framework_file}")
done < <(public_framework_files)
dirty_framework="$(
    git status --porcelain --untracked-files=no -- "${framework_files[@]}" 2>/dev/null || true
)"
dirty_count="$(printf '%s\n' "${dirty_framework}" | sed '/^$/d' | wc -l | tr -d ' ')"
ahead_count="$(git rev-list --count "${target_ref}..HEAD" 2>/dev/null | tr -d ' ' || echo 0)"
behind_count="$(git rev-list --count "HEAD..${target_ref}" 2>/dev/null | tr -d ' ' || echo 0)"

print_summary() {
    printf 'Remote: %s\n' "${REMOTE_NAME}"
    printf 'Branch: %s\n' "${BRANCH_NAME}"
    printf 'Current branch: %s\n' "${current_branch:-detached}"
    printf 'Tracked framework changes: %s\n' "${dirty_count}"
    printf 'Local commits not in upstream: %s\n' "${ahead_count}"
    printf 'Upstream commits not in local HEAD: %s\n' "${behind_count}"
}

if [[ "${MODE}" == "check" ]]; then
    print_summary
    if [[ -n "${dirty_framework}" ]]; then
        printf '\nChanged tracked framework files:\n'
        printf '%s\n' "${dirty_framework}"
    fi
    if (( dirty_count > 0 || ahead_count > 0 )); then
        exit 1
    fi
    exit 0
fi

if [[ -z "${current_branch}" ]]; then
    echo "Refusing to update a detached HEAD checkout." >&2
    exit 1
fi

if [[ "${current_branch}" != "${BRANCH_NAME}" ]]; then
    echo "Refusing to update branch '${current_branch}' as public branch '${BRANCH_NAME}'." >&2
    echo "Switch to ${BRANCH_NAME}, or pass the matching --branch value." >&2
    exit 1
fi

if (( ahead_count > 0 )); then
    echo "Refusing: this public branch has ${ahead_count} local commit(s)." >&2
    echo "Move them to a branch/fork before updating from ${REMOTE_NAME}/${BRANCH_NAME}." >&2
    exit 1
fi

if (( dirty_count > 0 )) && [[ "${MODE}" != "discard" ]]; then
    echo "Refusing: tracked framework files have local changes." >&2
    echo "Run with --check to inspect them, or --discard-framework-changes to reset tracked files to upstream." >&2
    exit 1
fi

if [[ "${MODE}" == "discard" ]]; then
    git reset --hard "${target_ref}"
    echo "Reset tracked files to ${REMOTE_NAME}/${BRANCH_NAME}. Untracked and ignored overlay state was left alone."
    exit 0
fi

if (( behind_count == 0 )); then
    echo "Public checkout is already up to date with ${REMOTE_NAME}/${BRANCH_NAME}."
    exit 0
fi

git merge --ff-only "${target_ref}"
echo "Updated public checkout to ${REMOTE_NAME}/${BRANCH_NAME}."
