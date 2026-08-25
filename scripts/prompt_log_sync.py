#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import json
import os
import sys
import tempfile
import time
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Sync interactive conductor prompts and final answers from provider session artifacts into a session-local transcript."
    )
    parser.add_argument("--cwd", required=True, help="Target Cortex repo cwd to match.")
    parser.add_argument(
        "--session-dir",
        default=None,
        help="Conductor session directory, e.g. agents/conductor/sessions/<session>.",
    )
    parser.add_argument(
        "--user-home",
        default=None,
        help="Legacy transcript home fallback, e.g. users/<user>.",
    )
    parser.add_argument(
        "--log-path",
        default=None,
        help="Transcript output path. Default: <session-dir>/prompt_log.txt or <user-home>/prompt_log.txt.",
    )
    parser.add_argument(
        "--state-path",
        default=None,
        help="State cursor path. Default: <session-dir>/.prompt_log_state.json or <user-home>/.prompt_log_state.json.",
    )
    parser.add_argument(
        "--exclude-text",
        action="append",
        default=[],
        help="Exact prompt text to suppress from logging. May be passed multiple times.",
    )
    parser.add_argument(
        "--backfill",
        action="store_true",
        help="Backfill existing matching prompts from artifact files that predate the state file.",
    )
    return parser.parse_args()


def claude_project_dir(cwd: str) -> Path:
    encoded = cwd.replace("/", "-")
    return Path.home() / ".claude" / "projects" / encoded


def codex_sessions_root() -> Path:
    codex_home = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))
    return codex_home / "sessions"


def load_state(path: Path) -> dict:
    if not path.exists():
        return {
            "initialized_at": int(time.time()),
            "codex_prompts": {},
            "codex_answers": {},
            "claude_prompts": {},
            "claude_answers": {},
        }
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {
            "initialized_at": int(time.time()),
            "codex_prompts": {},
            "codex_answers": {},
            "claude_prompts": {},
            "claude_answers": {},
        }
    if not isinstance(data, dict):
        data = {}
    data.setdefault("initialized_at", int(time.time()))
    if isinstance(data.get("codex"), dict):
        data.setdefault("codex_prompts", dict(data["codex"]))
    else:
        data.setdefault("codex_prompts", {})
    if isinstance(data.get("claude"), dict):
        data.setdefault("claude_prompts", dict(data["claude"]))
    else:
        data.setdefault("claude_prompts", {})
    data.setdefault("codex_answers", {})
    data.setdefault("claude_answers", {})
    if not isinstance(data["codex_prompts"], dict):
        data["codex_prompts"] = {}
    if not isinstance(data["codex_answers"], dict):
        data["codex_answers"] = {}
    if not isinstance(data["claude_prompts"], dict):
        data["claude_prompts"] = {}
    if not isinstance(data["claude_answers"], dict):
        data["claude_answers"] = {}
    return data


def atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=str(path.parent), delete=False
    ) as tmp:
        tmp.write(content)
        tmp_path = Path(tmp.name)
    os.replace(tmp_path, path)


def ensure_log_header(path: Path) -> None:
    if path.exists() and path.stat().st_size > 0:
        return
    header = (
        "# Cortex Session Transcript\n\n"
        "Full append-only log of interactive conductor prompts and final chat answers for one conductor session.\n"
        "This file may contain sensitive text.\n\n"
    )
    atomic_write(path, header)


def normalize_prompt(text: str) -> str:
    return text.replace("\r\n", "\n").replace("\r", "\n")


def is_environment_context(text: str) -> bool:
    stripped = text.strip()
    return stripped.startswith("<environment_context>") and stripped.endswith("</environment_context>")


def is_synthetic_wrapper(text: str) -> bool:
    stripped = text.strip()
    synthetic_prefixes = (
        "<turn_aborted>",
        "<local-command-caveat>",
        "<local-command-stdout>",
        "<command-name>",
    )
    return stripped.startswith(synthetic_prefixes)


def is_launcher_prompt(text: str) -> bool:
    return text.strip().startswith("Read CONDUCTOR.md and follow it.")


def should_skip_prompt(text: str, exclude_texts: set[str]) -> bool:
    normalized = normalize_prompt(text)
    if not normalized.strip():
        return True
    if is_environment_context(normalized):
        return True
    if is_synthetic_wrapper(normalized):
        return True
    if is_launcher_prompt(normalized):
        return True
    stripped = normalized.strip()
    return normalized in exclude_texts or stripped in exclude_texts


def should_skip_answer(text: str) -> bool:
    return not normalize_prompt(text).strip()


def parse_iso_timestamp(raw: str) -> float:
    if not isinstance(raw, str) or not raw:
        return 0.0
    try:
        value = raw[:-1] + "+00:00" if raw.endswith("Z") else raw
        return dt.datetime.fromisoformat(value).timestamp()
    except ValueError:
        return 0.0


def utc_now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def read_lines(path: Path) -> list[str]:
    try:
        return path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []


def codex_file_matches(lines: list[str], cwd: str) -> bool:
    for raw in lines[:20]:
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if data.get("type") != "session_meta":
            continue
        payload = data.get("payload")
        if not isinstance(payload, dict):
            return False
        return (
            payload.get("cwd") == cwd
            and payload.get("originator") == "codex-tui"
            and payload.get("thread_source") == "user"
        )
    return False


def line_cursor_start(
    path: Path, total_lines: int, provider_state: dict[str, int], initialized_at: int, backfill: bool
) -> int:
    key = str(path)
    last_line = provider_state.get(key)
    if isinstance(last_line, int):
        if last_line > total_lines:
            return 0
        return max(0, last_line)
    if backfill:
        return 0
    try:
        mtime = int(path.stat().st_mtime)
    except OSError:
        mtime = 0
    if mtime >= initialized_at:
        return 0
    return total_lines


def collect_codex_entries(
    cwd: str,
    exclude_texts: set[str],
    prompt_state: dict[str, int],
    answer_state: dict[str, int],
    initialized_at: int,
    backfill: bool,
) -> tuple[list[dict], dict[str, int], dict[str, int]]:
    entries: list[dict] = []
    updated_prompt_state = dict(prompt_state)
    updated_answer_state = dict(answer_state)
    root = codex_sessions_root()
    if not root.exists():
        return entries, updated_prompt_state, updated_answer_state

    for path in sorted(root.rglob("rollout-*.jsonl")):
        lines = read_lines(path)
        if not lines or not codex_file_matches(lines, cwd):
            continue
        prompt_start = line_cursor_start(path, len(lines), prompt_state, initialized_at, backfill)
        answer_start = line_cursor_start(path, len(lines), answer_state, initialized_at, backfill)
        for mode, start in (("prompt", prompt_start), ("answer", answer_start)):
            for line_no, raw in enumerate(lines[start:], start=start + 1):
                try:
                    data = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                if data.get("type") != "response_item":
                    continue
                payload = data.get("payload")
                if not isinstance(payload, dict):
                    continue
                if payload.get("type") != "message":
                    continue
                role = payload.get("role")
                content = payload.get("content")
                if not isinstance(content, list):
                    continue
                if mode == "prompt":
                    if role != "user":
                        continue
                    item_type = "input_text"
                else:
                    if role != "assistant" or payload.get("phase") != "final_answer":
                        continue
                    item_type = "output_text"
                text_parts = []
                for item in content:
                    if (
                        isinstance(item, dict)
                        and item.get("type") == item_type
                        and isinstance(item.get("text"), str)
                    ):
                        text_parts.append(item["text"])
                if not text_parts:
                    continue
                text = normalize_prompt("".join(text_parts))
                if mode == "prompt":
                    if should_skip_prompt(text, exclude_texts):
                        continue
                else:
                    if should_skip_answer(text):
                        continue
                entries.append(
                    {
                        "provider": "codex",
                        "kind": mode,
                        "timestamp": data.get("timestamp", ""),
                        "sort_ts": parse_iso_timestamp(data.get("timestamp", "")),
                        "text": text,
                        "source": f"{path}:{line_no}",
                    }
                )
        updated_prompt_state[str(path)] = len(lines)
        updated_answer_state[str(path)] = len(lines)
    return entries, updated_prompt_state, updated_answer_state


def collect_claude_entries(
    cwd: str,
    exclude_texts: set[str],
    prompt_state: dict[str, int],
    answer_state: dict[str, int],
    initialized_at: int,
    backfill: bool,
) -> tuple[list[dict], dict[str, int], dict[str, int]]:
    entries: list[dict] = []
    updated_prompt_state = dict(prompt_state)
    updated_answer_state = dict(answer_state)
    project_dir = claude_project_dir(cwd)
    if not project_dir.exists():
        return entries, updated_prompt_state, updated_answer_state

    for path in sorted(project_dir.glob("*.jsonl")):
        lines = read_lines(path)
        if not lines:
            continue
        prompt_start = line_cursor_start(path, len(lines), prompt_state, initialized_at, backfill)
        answer_start = line_cursor_start(path, len(lines), answer_state, initialized_at, backfill)
        for mode, start in (("prompt", prompt_start), ("answer", answer_start)):
            for line_no, raw in enumerate(lines[start:], start=start + 1):
                try:
                    data = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                if data.get("userType") != "external" or data.get("entrypoint") != "cli":
                    continue
                if mode == "prompt":
                    if data.get("type") != "user":
                        continue
                    message = data.get("message")
                    if not isinstance(message, dict) or message.get("role") != "user":
                        continue
                    content = message.get("content")
                    if not isinstance(content, str):
                        continue
                    text = normalize_prompt(content)
                    if should_skip_prompt(text, exclude_texts):
                        continue
                else:
                    if data.get("type") != "assistant":
                        continue
                    message = data.get("message")
                    if not isinstance(message, dict) or message.get("role") != "assistant":
                        continue
                    if message.get("stop_reason") != "end_turn":
                        continue
                    content = message.get("content")
                    if not isinstance(content, list):
                        continue
                    text_parts = []
                    for item in content:
                        if (
                            isinstance(item, dict)
                            and item.get("type") == "text"
                            and isinstance(item.get("text"), str)
                        ):
                            text_parts.append(item["text"])
                    if not text_parts:
                        continue
                    text = normalize_prompt("".join(text_parts))
                    if should_skip_answer(text):
                        continue
                entries.append(
                    {
                        "provider": "claude",
                        "kind": mode,
                        "timestamp": data.get("timestamp", ""),
                        "sort_ts": parse_iso_timestamp(data.get("timestamp", "")),
                        "text": text,
                        "source": f"{path}:{line_no}",
                    }
                )
        updated_prompt_state[str(path)] = len(lines)
        updated_answer_state[str(path)] = len(lines)
    return entries, updated_prompt_state, updated_answer_state


def append_entries(log_path: Path, entries: list[dict]) -> None:
    if not entries:
        return
    ensure_log_header(log_path)
    with log_path.open("a", encoding="utf-8") as handle:
        for entry in entries:
            handle.write(
                f"[{utc_now_iso()}] provider={entry['provider']} kind={entry['kind']}\n"
            )
            handle.write(entry["text"])
            if not entry["text"].endswith("\n"):
                handle.write("\n")
            if entry["kind"] == "prompt":
                handle.write("<<<CORTEX_PROMPT_END>>>\n\n")
            else:
                handle.write("<<<CORTEX_ANSWER_END>>>\n\n")


def main() -> int:
    args = parse_args()
    cwd = str(Path(args.cwd).resolve())
    base_dir = None
    if args.session_dir:
        base_dir = Path(args.session_dir)
    elif args.user_home:
        base_dir = Path(args.user_home)
    elif args.log_path:
        base_dir = Path(args.log_path).parent
    elif args.state_path:
        base_dir = Path(args.state_path).parent
    else:
        print("prompt_log_sync.py: need --session-dir or --user-home unless an explicit output path is given", file=sys.stderr)
        return 2

    log_path = Path(args.log_path) if args.log_path else base_dir / "prompt_log.txt"
    state_path = Path(args.state_path) if args.state_path else base_dir / ".prompt_log_state.json"
    lock_path = state_path.with_suffix(state_path.suffix + ".lock")
    exclude_texts = {normalize_prompt(text) for text in args.exclude_text if text is not None}

    base_dir.mkdir(parents=True, exist_ok=True)
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a+", encoding="utf-8") as lock_handle:
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)
        ensure_log_header(log_path)
        state = load_state(state_path)
        initialized_at = int(state.get("initialized_at", int(time.time())))
        codex_entries, codex_prompt_state, codex_answer_state = collect_codex_entries(
            cwd,
            exclude_texts,
            state.get("codex_prompts", {}),
            state.get("codex_answers", {}),
            initialized_at,
            args.backfill,
        )
        claude_entries, claude_prompt_state, claude_answer_state = collect_claude_entries(
            cwd,
            exclude_texts,
            state.get("claude_prompts", {}),
            state.get("claude_answers", {}),
            initialized_at,
            args.backfill,
        )
        entries = codex_entries + claude_entries
        entries.sort(key=lambda item: (item["sort_ts"], item["timestamp"], item["source"]))
        append_entries(log_path, entries)
        state.pop("codex", None)
        state.pop("claude", None)
        state["codex_prompts"] = codex_prompt_state
        state["codex_answers"] = codex_answer_state
        state["claude_prompts"] = claude_prompt_state
        state["claude_answers"] = claude_answer_state
        atomic_write(state_path, json.dumps(state, indent=2, sort_keys=True) + "\n")

    print(f"appended {len(entries)} transcript entry/entries")
    return 0


if __name__ == "__main__":
    sys.exit(main())
