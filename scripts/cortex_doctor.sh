#!/usr/bin/env bash
# Deterministic validators for Cortex framework invariants and drift.

set -uo pipefail
shopt -s nullglob

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CORTEX_DIR="${CORTEX_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd -P)}"
cd "${CORTEX_DIR}" 2>/dev/null || { echo "cortex dir not found: ${CORTEX_DIR}" >&2; exit 2; }
source "${CORTEX_DIR}/scripts/bash_compat.sh"
source "${CORTEX_DIR}/scripts/public_sync_lib.sh"

ALL_CHECKS=(tasks public-manifest public-sync sandbox git-lane repo-hygiene claude-local-settings git-sync-health worker-meta)
SELECTED_CHECKS=()
FAIL_COUNT=0
WARN_COUNT=0
OK_COUNT=0

usage() {
    cat <<'EOF'
Usage:
  bash scripts/cortex_doctor.sh [--check NAME ...] [--list-checks]

Checks:
  tasks        Validate task-board section/status layout.
  public-manifest  Warn on tracked public-looking framework files that are
               outside the public export manifest.
  public-sync  Detect private/deployment literals embedded in public sync.
  sandbox      Detect broad provider sandbox read exposure.
  git-lane     Validate commit-worker git metadata/hook guardrails.
  repo-hygiene Validate local private files are ignored.
  claude-local-settings  Warn on repo-local Claude settings that disable
               sandboxing or grant credential-path reads.
  git-sync-health  Warn when master is ahead of origin or public branch
               is behind master (catches commit-push and sync-publish lag).
  worker-meta  Validate metadata-driven worker docs and owned-script
               co-location.

Exit:
  0 all checks ok
  1 warnings only
  2 one or more failures
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)
            [[ $# -ge 2 ]] || { echo "Missing value for --check" >&2; exit 2; }
            SELECTED_CHECKS+=("$2")
            shift 2
            ;;
        --list-checks)
            printf '%s\n' "${ALL_CHECKS[@]}"
            exit 0
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

if (( $(bash_array_len SELECTED_CHECKS) == 0 )); then
    SELECTED_CHECKS=("${ALL_CHECKS[@]}")
fi

check_known() {
    local want="$1" known
    for known in "${ALL_CHECKS[@]}"; do
        [[ "${want}" == "${known}" ]] && return 0
    done
    echo "Unknown check: ${want}" >&2
    return 1
}

emit_result() {
    local check="$1" state="$2" summary="$3" evidence="${4:-}"
    printf 'CHECK: %s\n' "${check}"
    printf 'STATE: %s\n' "${state}"
    printf 'SUMMARY: %s\n' "${summary}"
    [[ -n "${evidence}" ]] && printf 'EVIDENCE: %s\n' "${evidence}"
    printf '\n'
    case "${state}" in
        ok) OK_COUNT=$((OK_COUNT + 1)) ;;
        warn) WARN_COUNT=$((WARN_COUNT + 1)) ;;
        fail) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
        *)
            FAIL_COUNT=$((FAIL_COUNT + 1))
            ;;
    esac
}

join_evidence() {
    sed '/^$/d' | paste -sd ';' - | sed 's/;/; /g'
}

discover_tasks_files() {
    find agents projects users -mindepth 2 -maxdepth 2 -type f -name tasks.md 2>/dev/null | LC_ALL=C sort
}

check_tasks() {
    local result invalid_count
    result="$(
        discover_tasks_files | while IFS= read -r file; do
            awk -v rel_tasks="${file}" '
                function section_name(status) {
                    if (status == "open") return "Open"
                    if (status == "doing") return "Doing"
                    if (status == "blocked") return "Blocked"
                    if (status == "done") return "Done"
                    if (status == "cancelled" || status == "expired") return "Cancelled"
                    return status
                }
                /^## Open$/ { current = "open"; next }
                /^## Doing$/ { current = "doing"; next }
                /^## Blocked$/ { current = "blocked"; next }
                /^## Done$/ { current = "done"; next }
                /^## Cancelled$/ { current = "cancelled"; next }
                /^- \[(open|doing|blocked|done|cancelled|expired)\]/ {
                    status = $0
                    sub(/^- \[/, "", status)
                    sub(/\].*$/, "", status)
                    if (status == "expired") status = "cancelled"
                    if (current == "") {
                        printf "%s: [%s] row outside recognized section\n", rel_tasks, status
                        next
                    }
                    if (status != current) {
                        printf "%s: [%s] row under ## %s\n", rel_tasks, status, section_name(current)
                    }
                }
            ' "${file}"
        done
    )"
    invalid_count="$(printf '%s\n' "${result}" | sed '/^$/d' | wc -l)"
    if (( invalid_count > 0 )); then
        emit_result tasks fail "${invalid_count} task-board layout issue(s) found" "$(printf '%s\n' "${result}" | join_evidence)"
    else
        emit_result tasks ok "task-board section/status layout is valid"
    fi
}

public_manifest_expected_private_exclusion() {
    local path="$1"
    case "${path}" in
        briefs/*|environment.instruct|shared.instruct|user.instruct)
            return 0
            ;;
    esac
    return 1
}

public_manifest_looks_public_candidate() {
    local path="$1"
    case "${path}" in
        roles/*|scripts/*|config/*|templates/*|assets/*)
            return 0
            ;;
    esac

    case "${path}" in
        */*)
            return 1
            ;;
        *.md|*.instruct|*.example|*.sh|*.py|*.txt|*.pdf|*.png|*.svg)
            return 0
            ;;
    esac
    return 1
}

check_public_manifest() {
    local manifest_file
    manifest_file="$(mktemp "${TMPDIR:-/tmp}/cortex_public_manifest.XXXXXX")" || {
        emit_result public-manifest fail "could not create temp file for public export manifest check"
        return 0
    }

    public_framework_files | LC_ALL=C sort -u > "${manifest_file}"

    local -a suspicious=()
    local file
    while IFS= read -r file; do
        [[ -n "${file}" ]] || continue
        grep -Fqx -- "${file}" "${manifest_file}" && continue
        public_manifest_expected_private_exclusion "${file}" && continue
        public_manifest_looks_public_candidate "${file}" || continue
        suspicious+=("${file}")
    done < <(git ls-files)

    rm -f "${manifest_file}"

    if (( $(bash_array_len suspicious) > 0 )); then
        emit_result public-manifest warn "tracked public-looking files sit outside scripts/sync_public.sh --list-files" \
            "$(printf '%s\n' "${suspicious[@]}" | join_evidence)"
    else
        emit_result public-manifest ok "tracked public-looking framework files are covered by the public export manifest"
    fi
}

check_public_sync() {
    local -a files=()
    local file
    while IFS= read -r file; do
        [[ -n "${file}" ]] || continue
        files+=("${file}")
    done < <(public_framework_files)
    (( $(bash_array_len files) > 0 )) || { emit_result public-sync fail "could not enumerate public export manifest"; return 0; }

    local matches
    matches="$(
        rg -n -i -P "$(public_forbidden_regex)" -- "${files[@]}" 2>/dev/null || true
    )"
    matches="$(printf '%s\n' "${matches}" | public_filter_allowed_content_matches)"
    if [[ -n "${matches}" ]]; then
        emit_result public-sync fail "exported framework files still carry deployment-specific leak patterns" "$(printf '%s\n' "${matches}" | sed -E 's/[[:space:]]+/ /g' | join_evidence)"
    else
        emit_result public-sync ok "exported framework files carry no known deployment-specific leak patterns"
    fi
}

check_sandbox() {
    local root_matches device_matches matches
    root_matches="$(rg -n -- '--ro-bind / /' scripts/start_agent.sh || true)"
    device_matches="$(rg -n -- '--dev-bind /dev /dev' roles || true)"
    matches="$(printf '%s\n%s\n' "${root_matches}" "${device_matches}" | sed '/^$/d')"
    if [[ -n "${matches}" ]]; then
        emit_result sandbox fail "provider sandbox still exposes host root or the full host device tree" "$(printf '%s\n' "${matches}" | join_evidence)"
    else
        emit_result sandbox ok "no broad --ro-bind / / provider sandbox binds found"
    fi
}

check_git_lane() {
    local missing=()
    rg -q 'COMMIT_RW_ALLOW_HOOKS="0"' scripts/start_agent.sh || missing+=("default COMMIT_RW_ALLOW_HOOKS=0")
    rg -q 'from_name.*conductor.*COMMIT_RW_ALLOW_HOOKS="1"|COMMIT_RW_ALLOW_HOOKS="1".*from_name.*conductor' roles/operational/worker.commit.sh || missing+=("hooks override gated to conductor")
    rg -q 'worker_post_rw_ro_binds' roles/worker.sh || missing+=("post-RW read-only overlay function")
    rg -q 'hooks_dir=.*commit_git_dir.*/hooks|append_ro_bind_if_exists.*hooks_dir' roles/operational/worker.commit.sh || missing+=(".git/hooks read-only overlay")
    rg -q 'worker_commit_collect_git_dirs' roles/operational/worker.commit.sh || missing+=("git metadata collection for explicit scopes")
    if (( $(bash_array_len missing) > 0 )); then
        emit_result git-lane fail "commit-worker git metadata guardrail is incomplete" "$(printf '%s\n' "${missing[@]}" | join_evidence)"
    else
        emit_result git-lane ok "commit-worker git metadata and hook guardrails are present"
    fi
}

check_repo_hygiene() {
    local path=".claude/settings.local.json"
    if git check-ignore -q "${path}" 2>/dev/null; then
        emit_result repo-hygiene ok "${path} is ignored"
        return 0
    fi
    if [[ -e "${path}" ]]; then
        emit_result repo-hygiene fail "${path} exists and is not ignored"
    else
        emit_result repo-hygiene warn "${path} is not ignored; future local Claude settings can appear as untracked private state"
    fi
}

check_claude_local_settings() {
    local path=".claude/settings.local.json"
    if [[ ! -f "${path}" ]]; then
        emit_result claude-local-settings ok "${path} is absent"
        return 0
    fi

    local findings=()

    # Sandbox disable: any "sandbox" block with "enabled": false.
    # Tolerate whitespace, newlines, and quoting variants.
    if awk 'BEGIN { RS=""; FS=""; found=0 }
            {
                gsub(/[[:space:]]+/, "", $0)
                if (index($0, "\"sandbox\":{") > 0 && match($0, /"sandbox":\{[^}]*"enabled":false/)) {
                    found=1
                }
            }
            END { exit found ? 0 : 1 }' "${path}"; then
        findings+=("disables Claude sandbox (sandbox.enabled=false)")
    fi

    # Credential-bearing allow entries: SSH keys, AWS, GnuPG, env files,
    # browser cookies, generic private-key files. Matches Read(...), Bash(...),
    # or any other tool wrapper that mentions the path.
    local cred_matches
    cred_matches="$(
        rg -n -i -- \
            '/\.ssh(/|"|\)|\*)|/\.aws(/|"|\)|\*)|/\.gnupg(/|"|\)|\*)|/\.config/gh(/|"|\)|\*)|/\.env(\*|[._-]|\)|")|id_rsa|id_ed25519|\.pem(\*|\)|"|/)|\.p12(\*|\)|"|/)|cookies\.sqlite' \
            "${path}" 2>/dev/null || true
    )"
    if [[ -n "${cred_matches}" ]]; then
        findings+=("grants credential-path reads")
    fi

    if (( $(bash_array_len findings) == 0 )); then
        emit_result claude-local-settings ok "${path} carries no sandbox-disable or credential-path grants"
        return 0
    fi

    local evidence_lines=()
    evidence_lines+=("${findings[@]}")
    if [[ -n "${cred_matches}" ]]; then
        # Quote the matched allow-list lines so the evidence shows exactly which
        # entries triggered the warning.
        local trimmed
        trimmed="$(printf '%s\n' "${cred_matches}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+/ /g')"
        evidence_lines+=("${trimmed}")
    fi
    emit_result claude-local-settings warn "${path} weakens repo-local Claude security posture" \
        "$(printf '%s\n' "${evidence_lines[@]}" | join_evidence)"
}

check_git_sync_health() {
    local findings=()
    local branch upstream_ref

    branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || printf 'HEAD')"
    upstream_ref="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"

    local ahead
    ahead=""
    if [[ -n "${upstream_ref}" ]]; then
        ahead="$(git rev-list --count "${upstream_ref}..HEAD" 2>/dev/null | tr -d ' ' || true)"
    fi
    if [[ -n "${ahead}" && "${ahead}" -gt 0 ]]; then
        findings+=("${branch} is ahead of ${upstream_ref} by ${ahead} commit(s)")
    fi

    local public_ref last_sync_sha drift
    if public_ref="$(public_sync_available_ref 2>/dev/null)"; then
        last_sync_sha="$(public_sync_last_source_sha "${public_ref}" || true)"
        if [[ -z "${last_sync_sha}" ]]; then
            findings+=("could not read last public sync source sha from ${public_ref}")
        else
            drift="$(public_framework_drift_log "${last_sync_sha}" "${branch}" || true)"
            if [[ -n "${drift}" ]]; then
                local public_behind
                public_behind="$(printf '%s\n' "${drift}" | wc -l | tr -d ' ')"
                findings+=("public export is behind by ${public_behind} framework commit(s) since ${last_sync_sha:0:8} — run scripts/sync_public.sh")
            fi
        fi
    fi

    if (( $(bash_array_len findings) == 0 )); then
        emit_result git-sync-health ok "${branch} is in sync with its upstream and public export state"
    else
        emit_result git-sync-health warn "git sync lag detected" "$(printf '%s\n' "${findings[@]}" | join_evidence)"
    fi
}

check_worker_meta() {
    if ! command -v python3 >/dev/null 2>&1; then
        emit_result worker-meta fail "python3 is required for worker metadata doc checks"
        return 0
    fi

    local output rc
    set +e
    output="$(python3 "${CORTEX_DIR}/scripts/render_worker_docs.py" --check 2>&1)"
    rc=$?
    set -e

    if [[ ${rc} -eq 0 ]]; then
        emit_result worker-meta ok "worker metadata docs and owned-script paths are in sync"
    else
        emit_result worker-meta fail "worker metadata docs or owned-script paths drifted" "$(printf '%s\n' "${output}" | join_evidence)"
    fi
}

for check in "${SELECTED_CHECKS[@]}"; do
    check_known "${check}" || exit 2
done

printf 'CORTEX DOCTOR\n\n'
for check in "${SELECTED_CHECKS[@]}"; do
    case "${check}" in
        tasks) check_tasks ;;
        public-manifest) check_public_manifest ;;
        public-sync) check_public_sync ;;
        sandbox) check_sandbox ;;
        git-lane) check_git_lane ;;
        repo-hygiene) check_repo_hygiene ;;
        claude-local-settings) check_claude_local_settings ;;
        git-sync-health) check_git_sync_health ;;
        worker-meta) check_worker_meta ;;
    esac
done

printf 'SUMMARY: %s ok, %s warn, %s fail\n' "${OK_COUNT}" "${WARN_COUNT}" "${FAIL_COUNT}"
if (( FAIL_COUNT > 0 )); then
    exit 2
fi
if (( WARN_COUNT > 0 )); then
    exit 1
fi
exit 0
