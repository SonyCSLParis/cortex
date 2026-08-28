#!/usr/bin/env bash
# Build a sanitized public export from the current master, run a hard leak
# scan on the export, then commit it on top of the configured public
# remote/branch and push normally. Run from master only.
#
# Usage:
#   bash scripts/sync_public.sh --dry-run
#   bash scripts/sync_public.sh --subject "cortex: describe the exported change"
#   bash scripts/sync_public.sh --no-push
#   bash scripts/sync_public.sh --list-files
#   bash scripts/sync_public.sh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
source config/cortex_defaults.sh
source scripts/bash_compat.sh
source scripts/public_sync_lib.sh

DRY_RUN=0
NO_PUSH=0
KEEP_EXPORT=0
LIST_FILES=0
EXPORT_PARENT=""
PUBLIC_COMMIT_SUBJECT=""

usage() {
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
}

source_branch=""
source_sha=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --no-push)
            NO_PUSH=1
            shift
            ;;
        --list-files)
            LIST_FILES=1
            shift
            ;;
        --keep-export)
            KEEP_EXPORT=1
            shift
            ;;
        --export-parent)
            [[ $# -ge 2 ]] || { echo "Missing value for --export-parent" >&2; exit 2; }
            EXPORT_PARENT="$2"
            shift 2
            ;;
        --subject)
            [[ $# -ge 2 ]] || { echo "Missing value for --subject" >&2; exit 2; }
            PUBLIC_COMMIT_SUBJECT="$2"
            shift 2
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

FRAMEWORK_FILES=()
while IFS= read -r framework_file || [[ -n "${framework_file}" ]]; do
    [[ -n "${framework_file}" ]] || continue
    FRAMEWORK_FILES+=("${framework_file}")
done < <(public_framework_files)

if [[ -z "${CORTEX_DEFAULT_PUBLIC_REMOTE_URL:-}" ]]; then
    echo "Public remote not configured; set CORTEX_DEFAULT_PUBLIC_REMOTE_URL in environments/{env}/settings.env." >&2
    exit 2
fi

if (( LIST_FILES )); then
    printf '%s\n' "${FRAMEWORK_FILES[@]}"
    exit 0
fi

public_scan_export() {
    local export_dir="$1"
    local regex
    regex="$(public_forbidden_regex)"
    local scan_backend="grep"

    # The forbidden-pattern list uses PCRE syntax (negative lookbehind in at
    # least one rule), so the scan must run under a Perl-compatible engine.
    # ripgrep needs PCRE2 compiled in for `-P`; many distros ship without it
    # and `rg -P` then exits 2 silently. Prefer GNU grep where available, but
    # fall back to Perl on macOS-style hosts that do not ship `grep -P`.
    if ! printf 'probe' | grep -Pq 'probe' >/dev/null 2>&1; then
        if command -v perl >/dev/null 2>&1; then
            scan_backend="perl"
        else
            echo "Public export leak check requires GNU grep with -P or Perl." >&2
            echo "Install/upgrade GNU grep or Perl and re-run sync_public.sh." >&2
            return 2
        fi
    fi

    local path_matches content_matches path_rc content_rc
    set +e
    if [[ "${scan_backend}" == "grep" ]]; then
        path_matches="$(
            cd "${export_dir}"
            find . -print | sed 's#^\./##' | grep -Pin "${regex}"
        )"
        path_rc=$?
        content_matches="$(
            cd "${export_dir}"
            grep -rPin --binary-files=without-match "${regex}" .
        )"
        content_rc=$?
    else
        path_matches="$(
            cd "${export_dir}"
            find . -print | sed 's#^\./##' | perl -ne '
                BEGIN { $re = shift @ARGV; }
                chomp;
                print "$.:$_\n" if /$re/;
            ' "${regex}"
        )"
        path_rc=$?
        content_matches="$(
            cd "${export_dir}"
            perl -MFile::Find -e '
                use strict;
                use warnings;
                my $re = shift @ARGV;
                find(
                    sub {
                        return if -d $_;
                        return if -B _;
                        my $path = $File::Find::name;
                        open my $fh, "<", $_ or return;
                        my $line_no = 0;
                        while (my $line = <$fh>) {
                            $line_no++;
                            if ($line =~ /$re/) {
                                print "$path:$line_no:$line";
                            }
                        }
                    },
                    "."
                );
            ' "${regex}"
        )"
        content_rc=$?
    fi
    set -e

    content_matches="$(printf '%s\n' "${content_matches}" | public_filter_allowed_content_matches)"

    # grep exit codes: 0 = match, 1 = no match, >=2 = error. Treat tool
    # errors as hard aborts so a broken scan never silently authorises a push.
    if (( path_rc > 1 )) || (( content_rc > 1 )); then
        echo "Public export leak scan failed to execute (grep exit ${path_rc}/${content_rc})." >&2
        return 2
    fi

    if [[ -n "${path_matches}" || -n "${content_matches}" ]]; then
        echo "Public export leak check failed." >&2
        if [[ -n "${path_matches}" ]]; then
            echo >&2
            echo "Path matches:" >&2
            printf '%s\n' "${path_matches}" >&2
        fi
        if [[ -n "${content_matches}" ]]; then
            echo >&2
            echo "Content matches:" >&2
            printf '%s\n' "${content_matches}" >&2
        fi
        return 1
    fi
}

build_export_tree() {
    local export_dir="$1" master_sha="$2"
    mkdir -p "${export_dir}"
    git archive --format=tar "${master_sha}" -- "${FRAMEWORK_FILES[@]}" | tar -x -C "${export_dir}"
}

commit_source_sha_in_repo() {
    local repo="$1" commit="$2"
    git -C "${repo}" log -1 --format=%B "${commit}" 2>/dev/null \
        | sed -En \
            -e 's/^cortex: sync framework from [A-Za-z0-9._-]+ ([0-9a-f]+)$/\1/p' \
            -e 's/^cortex: public framework export from [A-Za-z0-9._-]+ ([0-9a-f]+)$/\1/p' \
            -e 's/^Source-Commit: ([0-9a-f]+)$/\1/p' \
        | head -n 1
}

latest_export_commit_in_repo() {
    local repo="$1" ref="$2" commit source_sha
    while IFS= read -r commit; do
        source_sha="$(commit_source_sha_in_repo "${repo}" "${commit}" || true)"
        if [[ -n "${source_sha}" ]]; then
            printf '%s\n' "${commit}"
            return 0
        fi
    done < <(git -C "${repo}" rev-list "${ref}" 2>/dev/null || true)
    return 1
}

prepare_export_repo() {
    local export_dir="$1"
    local branch_ref="refs/heads/${CORTEX_DEFAULT_PUBLIC_BRANCH}"
    git -C "${export_dir}" init -q
    git -C "${export_dir}" remote add origin "${CORTEX_DEFAULT_PUBLIC_REMOTE_URL}"
    git -C "${export_dir}" config user.name "$(git config user.name || echo 'Cortex Public Sync')"
    git -C "${export_dir}" config user.email "$(git config user.email || echo 'cortex-public-sync@example.invalid')"

    local ls_remote_status=0
    git -C "${export_dir}" ls-remote --quiet --exit-code --heads origin \
        "${CORTEX_DEFAULT_PUBLIC_BRANCH}" >/dev/null || ls_remote_status=$?
    if [[ "${ls_remote_status}" -eq 0 ]]; then
        # Fetch the branch history so the divergence guard can find the most
        # recent export marker even when several direct public commits follow
        # it. A depth-1 fetch makes that safe recovery path impossible.
        git -C "${export_dir}" fetch --quiet origin \
            "${branch_ref}:refs/remotes/origin/${CORTEX_DEFAULT_PUBLIC_BRANCH}"
        git -C "${export_dir}" checkout -q -b "${CORTEX_DEFAULT_PUBLIC_BRANCH}" \
            "refs/remotes/origin/${CORTEX_DEFAULT_PUBLIC_BRANCH}"
    elif [[ "${ls_remote_status}" -eq 2 ]]; then
        echo "No existing public branch found; creating initial public root commit." >&2
        git -C "${export_dir}" checkout -q --orphan "${CORTEX_DEFAULT_PUBLIC_BRANCH}"
    else
        echo "Could not inspect public remote branch ${CORTEX_DEFAULT_PUBLIC_BRANCH}; aborting." >&2
        return "${ls_remote_status}"
    fi
}

refuse_if_public_branch_diverged() {
    local export_dir="$1" source_sha="$2"
    local public_head latest_export_commit

    git -C "${export_dir}" rev-parse --verify --quiet HEAD >/dev/null || return 0
    public_head="$(git -C "${export_dir}" rev-parse HEAD)"
    latest_export_commit="$(latest_export_commit_in_repo "${export_dir}" HEAD || true)"

    if [[ -z "${latest_export_commit}" ]]; then
        echo "Refusing public export: public branch has history but no recognized prior export commit." >&2
        echo "Integrate that public history into private master first." >&2
        git -C "${export_dir}" log --oneline -n 10 HEAD >&2
        return 1
    fi

    if [[ "${public_head}" != "${latest_export_commit}" ]]; then
        # Direct public edits are safe to supersede only after their exact head
        # has been integrated into private history. This preserves the audit
        # trail and prevents an unrelated private tree from clobbering them.
        if git merge-base --is-ancestor "${public_head}" "${source_sha}" 2>/dev/null; then
            echo "Public branch changes after ${latest_export_commit:0:12} are integrated into private source ${source_sha:0:12}; continuing." >&2
            return 0
        fi
        echo "Refusing public export: public branch contains commit(s) after its last export commit ${latest_export_commit:0:12}." >&2
        echo "Merge or cherry-pick those public-branch changes into private master before exporting again." >&2
        git -C "${export_dir}" log --oneline "${latest_export_commit}..HEAD" >&2
        return 1
    fi
}

sync_export_tree() {
    local export_tree="$1" export_dir="$2"
    find "${export_dir}" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
    cp -a "${export_tree}/." "${export_dir}/"
}

public_commit_subject() {
    local export_dir="$1" path category categories="" count=0 first rest second

    while IFS= read -r path; do
        case "${path}" in
            README.md|CONDUCTOR.md|PROTOCOL.md|SHORTCUTS.md|BASH_RECIPES.md|*.md|*.instruct)
                category="documentation"
                ;;
            config/*)
                category="configuration"
                ;;
            roles/*)
                category="agent runtime"
                ;;
            scripts/*)
                category="tooling"
                ;;
            templates/*)
                category="templates"
                ;;
            *)
                category="${path##*/}"
                ;;
        esac
        case ",${categories}," in
            *,"${category}",*) ;;
            *)
                if [[ -n "${categories}" ]]; then
                    categories="${categories}, ${category}"
                else
                    categories="${category}"
                fi
                count=$((count + 1))
                ;;
        esac
    done < <(git -C "${export_dir}" diff --cached --name-only)

    if [[ "${count}" -gt 3 ]]; then
        first="${categories%%, *}"
        rest="${categories#*, }"
        second="${rest%%, *}"
        categories="${first}, ${second}, and other framework surfaces"
    fi
    printf 'cortex: update public %s\n' "${categories:-framework}"
}

commit_export() {
    local export_dir="$1" export_sha="$2" export_branch="$3" subject="${4:-}"
    git -C "${export_dir}" add -A
    if git -C "${export_dir}" diff --cached --quiet; then
        echo "Public export is already up to date with ${export_branch} ${export_sha}."
        return 1
    fi
    [[ -n "${subject}" ]] || subject="$(public_commit_subject "${export_dir}")"
    printf 'Public export subject: %s\n' "${subject}"
    git -C "${export_dir}" commit -q \
        -m "${subject}" \
        -m "Source-Commit: ${export_sha}"
}

current_branch="$(git symbolic-ref --short HEAD)"
if [[ -z "${current_branch}" ]]; then
    echo "Must be on a local branch to sync. Currently on: detached HEAD" >&2
    exit 1
fi
source_branch="${current_branch}"
manifest_status="$(git status --porcelain --untracked-files=all -- "${FRAMEWORK_FILES[@]}")"
if [[ -n "${manifest_status}" ]]; then
    echo "Refusing public export: public-manifest files have uncommitted changes." >&2
    echo "Commit the framework export package first, then re-run sync_public.sh." >&2
    echo >&2
    printf '%s\n' "${manifest_status}" >&2
    exit 1
fi
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Refusing to export with uncommitted tracked changes." >&2
    echo "Run from a clean worktree, or use a clean temporary worktree at the committed source ref." >&2
    exit 1
fi

for path in "${FRAMEWORK_FILES[@]}"; do
    git ls-tree -r --name-only HEAD -- "${path}" >/dev/null
done

source_sha="$(git rev-parse --short=12 "${source_branch}")"
export_parent="${EXPORT_PARENT:-$(mktemp -d)}"
export_tree="${export_parent%/}/cortex-public-tree-${source_sha}"
export_dir="${export_parent%/}/cortex-public-repo-${source_sha}"
cleanup_export=1
if [[ -n "${EXPORT_PARENT}" || "${KEEP_EXPORT}" -eq 1 || "${NO_PUSH}" -eq 1 ]]; then
    cleanup_export=0
fi
trap 'if [[ "${cleanup_export}" -eq 1 ]]; then rm -rf "${export_parent}"; fi' EXIT

rm -rf "${export_tree}" "${export_dir}"
build_export_tree "${export_tree}" "${source_sha}"
public_scan_export "${export_tree}"

if (( DRY_RUN )); then
    echo "Dry run — built and scanned public export tree from ${source_branch} (${source_sha})."
    if (( cleanup_export )); then
        echo "Export tree: ${export_tree} (removed after dry run; pass --keep-export to inspect)"
    else
        echo "Export tree: ${export_tree}"
    fi
    echo "Files:"
    (cd "${export_tree}" && find . -type f | sed 's#^\./#  #' | sort)
    exit 0
fi

mkdir -p "${export_dir}"
prepare_export_repo "${export_dir}"
refuse_if_public_branch_diverged "${export_dir}" "${source_sha}"
sync_export_tree "${export_tree}" "${export_dir}"
if ! commit_export "${export_dir}" "${source_sha}" "${source_branch}" "${PUBLIC_COMMIT_SUBJECT}"; then
    if (( NO_PUSH )); then
        echo "Export repo: ${export_dir}"
    fi
    exit 0
fi
public_commit="$(git -C "${export_dir}" rev-parse --short=12 HEAD)"

if (( NO_PUSH )); then
    echo "Built public commit ${public_commit} from ${source_branch} ${source_sha}; not pushed."
    echo "Export repo: ${export_dir}"
    exit 0
fi

git -C "${export_dir}" push origin \
    "HEAD:refs/heads/${CORTEX_DEFAULT_PUBLIC_BRANCH}"
if remote_name="$(public_remote_name)"; then
    git fetch --quiet "${remote_name}" "${CORTEX_DEFAULT_PUBLIC_BRANCH}" || true
fi
echo "Pushed public commit ${public_commit} to ${CORTEX_DEFAULT_PUBLIC_REMOTE_URL} ${CORTEX_DEFAULT_PUBLIC_BRANCH}."
