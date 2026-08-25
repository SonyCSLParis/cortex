#!/usr/bin/env python3
"""Select autonomous periodic commit candidates for the `commit` worker.

This helper keeps the worker's periodic runtime-dirt lane deterministic:
only allow-listed runtime files are eligible, and high-churn text files
must exceed a minimum changed-line threshold before they qualify.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import re
import shlex
import subprocess
import sys


AGENT_LOG_RE = re.compile(r"^agents/([^/]+)/log\.md$")
AGENT_LOGBOOK_RE = re.compile(r"^agents/([^/]+)/logbook\.md$")
AGENT_LOGBOOK_SUMMARY_RE = re.compile(r"^agents/([^/]+)/logbook\.summary\.md$")
PROJECT_LOGBOOK_SUMMARY_RE = re.compile(r"^projects/([^/]+)/logbook\.summary\.md$")
AGENT_ARCHIVE_MSG_RE = re.compile(r"^agents/([^/]+)/archive/(.+\.msg)$")
# Rotated history shards are written once and never edited afterward, so they
# are settled archive (always eligible) regardless of which live logbook they
# came from. The live conductor/project logbooks they were rotated out of stay
# excluded below; a frozen shard is not the same as the actively-edited source.
AGENT_HISTORY_RE = re.compile(r"^agents/([^/]+)/history/.+\.md$")
PROJECT_HISTORY_RE = re.compile(r"^projects/([^/]+)/history/.+\.md$")
# Persistent-worker durable notes; incrementally appended like a logbook, so
# threshold-gated rather than always eligible.
AGENT_NOTES_RE = re.compile(r"^agents/([^/]+)/notes\.txt$")

EXCLUDED_PATHS = {
    "agents/conductor/log.md",
    "agents/conductor/logbook.md",
}


def repo_default(repo: pathlib.Path, name: str, fallback: str) -> str:
    if name in os.environ:
        return os.environ[name]
    defaults_file = repo / "config" / "cortex_defaults.sh"
    if not defaults_file.is_file():
        return fallback
    command = f"source {shlex.quote(str(defaults_file))}; printf '%s' \"${{{name}:-}}\""
    try:
        value = subprocess.check_output(["bash", "-lc", command], text=True).strip()
    except subprocess.SubprocessError:
        return fallback
    return value or fallback


def int_default(repo: pathlib.Path, name: str, fallback: int) -> int:
    raw = repo_default(repo, name, str(fallback))
    try:
        return int(raw)
    except ValueError:
        return fallback


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=".", help="Git repo root. Default: current directory.")
    parser.add_argument(
        "--paths-only",
        action="store_true",
        help="Print only qualifying paths, one per line.",
    )
    parser.add_argument(
        "--min-log-lines",
        type=int,
        default=None,
        help="Minimum changed lines for agents/*/log.md files. Default: CORTEX_COMMIT_PERIODIC_TEXT_MIN_CHANGED_LINES.",
    )
    parser.add_argument(
        "--min-logbook-lines",
        type=int,
        default=None,
        help="Minimum changed lines for agents/*/logbook.md files. Default: CORTEX_COMMIT_PERIODIC_TEXT_MIN_CHANGED_LINES.",
    )
    parser.add_argument(
        "--min-summary-lines",
        type=int,
        default=None,
        help="Minimum changed lines for *logbook.summary.md files. Default: CORTEX_COMMIT_PERIODIC_TEXT_MIN_CHANGED_LINES.",
    )
    return parser.parse_args(argv)


def run_git(repo: pathlib.Path, *args: str) -> str:
    return subprocess.check_output(
        ["git", "-C", str(repo), *args],
        text=True,
        errors="replace",
    )


def dirty_paths(repo: pathlib.Path) -> list[str]:
    modified = run_git(repo, "diff", "--name-only").splitlines()
    untracked = run_git(repo, "ls-files", "--others", "--exclude-standard").splitlines()
    paths = sorted({path.strip() for path in modified + untracked if path.strip()})
    return paths


def classify(path: str) -> tuple[str | None, int | None]:
    if path in EXCLUDED_PATHS:
        return "excluded", None
    if AGENT_LOG_RE.match(path):
        return "agent_log", None
    if AGENT_LOGBOOK_RE.match(path):
        return "agent_logbook", None
    if AGENT_LOGBOOK_SUMMARY_RE.match(path):
        return "agent_logbook_summary", None
    if PROJECT_LOGBOOK_SUMMARY_RE.match(path):
        return "project_logbook_summary", None
    if AGENT_ARCHIVE_MSG_RE.match(path):
        return "agent_archive_msg", None
    if AGENT_HISTORY_RE.match(path):
        return "agent_history", None
    if PROJECT_HISTORY_RE.match(path):
        return "project_history", None
    if AGENT_NOTES_RE.match(path):
        return "agent_notes", None
    return None, None


def changed_lines_for_tracked_path(repo: pathlib.Path, path: str) -> int:
    output = run_git(repo, "diff", "--numstat", "--", path)
    total = 0
    for line in output.splitlines():
        fields = line.split("\t")
        if len(fields) < 3:
            continue
        added, deleted = fields[0], fields[1]
        if added == "-" or deleted == "-":
            return 10**9
        total += int(added) + int(deleted)
    return total


def changed_lines_for_untracked_path(repo: pathlib.Path, path: str) -> int:
    full_path = repo / path
    try:
        text = full_path.read_text(errors="replace")
    except OSError:
        return 0
    if not text:
        return 0
    return text.count("\n") + (0 if text.endswith("\n") else 1)


def changed_lines(repo: pathlib.Path, path: str) -> int:
    tracked = changed_lines_for_tracked_path(repo, path)
    if tracked > 0:
        return tracked
    return changed_lines_for_untracked_path(repo, path)


def threshold_for_kind(kind: str, args: argparse.Namespace) -> int:
    if kind == "agent_log":
        return args.min_log_lines
    if kind == "agent_logbook":
        return args.min_logbook_lines
    if kind in {"agent_logbook_summary", "project_logbook_summary"}:
        return args.min_summary_lines
    if kind == "agent_notes":
        return args.min_logbook_lines
    return 0


def evaluate(repo: pathlib.Path, path: str, args: argparse.Namespace) -> tuple[bool, str, int, str]:
    kind, _ = classify(path)
    if kind is None:
        return False, "out_of_scope", 0, "not in periodic allow-list"
    if kind == "excluded":
        return False, kind, 0, "explicitly excluded from autonomous periodic commits"

    line_count = changed_lines(repo, path)
    if kind == "agent_archive_msg":
        return True, kind, line_count, "archive msg always eligible"
    if kind in {"agent_history", "project_history"}:
        return True, kind, line_count, "rotated history shard always eligible"

    threshold = threshold_for_kind(kind, args)
    if line_count >= threshold:
        return True, kind, line_count, f"meets threshold >= {threshold}"
    return False, kind, line_count, f"below threshold < {threshold}"


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    repo = pathlib.Path(args.repo).resolve()
    text_threshold = int_default(repo, "CORTEX_COMMIT_PERIODIC_TEXT_MIN_CHANGED_LINES", 40)
    if args.min_log_lines is None:
        args.min_log_lines = text_threshold
    if args.min_logbook_lines is None:
        args.min_logbook_lines = text_threshold
    if args.min_summary_lines is None:
        args.min_summary_lines = text_threshold
    any_qualifying = False

    for path in dirty_paths(repo):
        qualify, kind, line_count, reason = evaluate(repo, path, args)
        if args.paths_only:
            if qualify:
                print(path)
                any_qualifying = True
            continue

        verdict = "QUALIFY" if qualify else "SKIP"
        print(f"{verdict}\t{path}\tkind={kind}\tchanged_lines={line_count}\treason={reason}")
        any_qualifying = any_qualifying or qualify

    return 0 if any_qualifying or args.paths_only else 0


if __name__ == "__main__":
    sys.exit(main())
