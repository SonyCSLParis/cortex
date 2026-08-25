#!/usr/bin/env python3
"""Listen for incoming Signal messages and drop them into a Cortex inbox.

The daemon is a thin loop around `signal-cli receive -o json`. Each
matching message becomes one file following the Cortex envelope spec
in `PROTOCOL.md`.

Message kinds and trust model:

    note-to-self  syncMessage where destination == own account number.
                  This is the user messaging the conductor from their phone.
                  In the default setup, this daemon is also the trust gate:
                  only messages whose body starts with `crtx:` are
                  admitted, and the prefix is stripped before delivery.
                  The watch side therefore trusts any daemon-delivered
                  `KIND: note-to-self` envelope as an instruction.

    external      dataMessage from any other sender.
                  Still never trusted as a command. With the current
                  default `--trigger-prefix crtx:` policy, only external
                  messages whose body starts with `crtx:` are written to
                  the inbox at all; others are dropped at ingress.

Filters, top to bottom:

    1. Kind must be one of:
         - `dataMessage.message`  (someone messaged our account)
         - `syncMessage.sentMessage.message`  (this account sent a
           message from another linked device — e.g. the user's phone
           writing in note-to-self)
       A message with downloaded attachments but no text is also kept.
       Receipts, typing, call-setup and empty syncs are dropped.

    2. For `dataMessage` (external): all senders are accepted by
       default. If one or more `--allow-source` numbers are given,
       only those senders are stored; all others are dropped. Use this
       for spam/noise filtering — it does NOT grant any extra trust.

    3. For `syncMessage.sentMessage`, the destination must be the
       account itself (note-to-self) unless `--include-self-sync` is
       passed.

    4. Group scoping: if one or more `--allow-group` ids are given,
       only messages in those groups are delivered; otherwise group
       messages are dropped.

    5. Trigger prefix: the (trimmed) body must start with the prefix
       (case-insensitive); the prefix is stripped before the file is
       written. Default: `crtx:`. This applies to note-to-self and
       external messages alike.

Default target inbox is `inboxes/signal/`. Watch drains that dedicated
messenger inbox as raw inbound data, separate from its own
`agents/watch/inbox/` conductor-directive queue. Delivered envelopes are
STATUS messages whose body starts with `TYPE: signal_message` so watch
can distinguish them from other status classes. Use `--inbox` to route
somewhere else if needed.

Lock caveat: `signal-cli receive` and `signal-cli send` share the same
account store lock. While a poll is running, concurrent `send` calls
will fail. The default server timeout (10s) plus a short gap between
iterations (2s) gives senders a reasonable window; if lock contention
becomes a real problem, switch to `signal-cli daemon --socket` and
route all sends via the socket.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import signal
import socket
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
CORTEX_DIR = Path(os.environ.get("CORTEX_DIR", str(SCRIPT_DIR.parent))).resolve()
DEFAULT_ACCOUNT = os.environ.get("SIGNAL_ACCOUNT", "").strip()
DEFAULT_INBOX = CORTEX_DIR / "inboxes/signal"
DEFAULT_LOG = CORTEX_DIR / "logs" / "signal_inbox_daemon.log"
DEFAULT_SENDER_ID = "signal"


stop_requested = False


def request_stop(signum: int, _frame: Any) -> None:
    global stop_requested
    stop_requested = True
    _log(f"received signal {signum}, shutting down after current poll", _current_log_path)


_current_log_path: Path | None = None


def _log(message: str, log_path: Path | None = None) -> None:
    ts = datetime.now().astimezone().isoformat(timespec="seconds")
    line = f"[{ts}] signal-inbox | {message}"
    print(line, flush=True)
    if log_path is not None:
        try:
            log_path.parent.mkdir(parents=True, exist_ok=True)
            with log_path.open("a", encoding="utf-8") as handle:
                handle.write(line + "\n")
        except Exception as exc:
            print(f"[{ts}] signal-inbox | failed to write log: {exc}", flush=True)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--account", default=DEFAULT_ACCOUNT,
                        help="Signal account (default: %(default)s)")
    parser.add_argument("--inbox", default=str(DEFAULT_INBOX),
                        help=("Target inbox directory. Absolute paths are used as-is; "
                              "relative paths resolve against $CORTEX_DIR. "
                              "Default: %(default)s"))
    parser.add_argument("--sender-id", default=DEFAULT_SENDER_ID,
                        help="Value written into the FROM header and filename. "
                             "Must match [A-Za-z0-9._-]+. Default: %(default)s")
    parser.add_argument("--allow-source", action="append", default=[],
                        metavar="NUMBER",
                        help="Restrict external (dataMessage) senders to these numbers "
                             "(E.164, e.g. +4369...). Repeat for multiple. "
                             "Default: empty — all external senders are accepted. "
                             "Note: being on this list grants NO extra trust; it is "
                             "a noise/spam filter only.")
    parser.add_argument("--include-self-sync", action="store_true",
                        help="Also ingest note-to-other-contact messages this account sent "
                             "from a linked device. Off by default (only note-to-self syncs).")
    parser.add_argument("--allow-group", action="append", default=[],
                        metavar="GROUP_ID",
                        help="Whitelist a group id. Repeat for multiple. If unset, "
                             "group messages are dropped. Note-to-self has no group id.")
    parser.add_argument("--trigger-prefix", default="crtx:",
                        help="If set, message body must start with this prefix "
                             "(case-insensitive); prefix is stripped before delivery.")
    parser.add_argument("--timeout", type=int, default=10,
                        help="Seconds signal-cli waits on the server per poll after the last "
                             "message. Default: %(default)s")
    parser.add_argument("--poll-interval", type=float, default=2.0,
                        help="Seconds to sleep between successful polls "
                             "(lets concurrent `signal-cli send` calls succeed). "
                             "Default: %(default)s")
    parser.add_argument("--backoff", type=float, default=15.0,
                        help="Seconds to sleep after a failed poll. Default: %(default)s")
    parser.add_argument("--wall-clock-extra", type=int, default=300,
                        help="Extra seconds beyond --timeout before the poll is force-killed. "
                             "Large backlogs can replay many envelopes and take a while. "
                             "Default: %(default)s")
    parser.add_argument("--log-file", default=str(DEFAULT_LOG),
                        help="Log file for daemon events. Default: %(default)s")
    parser.add_argument("--ignore-attachments", action="store_true",
                        help="Tell signal-cli not to download attachments "
                             "(body text still comes through).")
    parser.add_argument("--once", action="store_true",
                        help="Run one poll and exit (for testing).")
    parser.add_argument("--dry-run", action="store_true",
                        help="Do not write any files; log what would be delivered.")
    return parser.parse_args(argv)


def resolve_inbox(raw: str) -> Path:
    path = Path(raw)
    if not path.is_absolute():
        path = CORTEX_DIR / path
    return path.resolve()


def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(path)


def new_msg_id(ts: int) -> tuple[str, str]:
    suffix = f"{random.randint(0, 0xFFFF):04x}"
    return f"{ts}_{suffix}", suffix


def build_envelope(body: str, sender_id: str, ts: int) -> tuple[str, str]:
    msg_id, suffix = new_msg_id(ts)
    header = (
        f"MSG_ID: {msg_id}\n"
        f"FROM:   {sender_id}\n"
        f"TO:     conductor\n"
        f"TYPE:   STATUS\n"
        f"TIME:   {ts}\n"
        f"REF:    none\n"
        f"STATUS: pending\n"
        f"---\n"
    )
    return header + body, suffix


def extract_message(
    raw: dict[str, Any],
    account_number: str,
    include_self_sync: bool,
) -> dict[str, Any] | None:
    """Return a normalized dict for a text-bearing envelope, or None to skip.

    Does NOT apply source / group / prefix filters — the caller does that.
    """
    env = raw.get("envelope") if isinstance(raw.get("envelope"), dict) else raw
    if not isinstance(env, dict):
        return None

    source = env.get("sourceNumber") or env.get("source") or env.get("sourceUuid") or "unknown"
    source_name = env.get("sourceName") or ""
    ts_seconds = int(time.time())

    data = env.get("dataMessage")
    if isinstance(data, dict):
        text = data.get("message") or ""
        attachments = _extract_attachments(data)
        if text or attachments:
            return {
                "kind": "external",
                "source": source,
                "source_name": source_name,
                "ts": ts_seconds,
                "text": text,
                "attachments": attachments,
                "group": (data.get("groupInfo") or {}).get("groupId") or "",
                "destination": "",
            }

    sync = env.get("syncMessage")
    if isinstance(sync, dict):
        sent = sync.get("sentMessage")
        if isinstance(sent, dict):
            text = sent.get("message") or ""
            destination = sent.get("destination") or sent.get("destinationNumber") or ""
            group_id = (sent.get("groupInfo") or {}).get("groupId") or ""
            attachments = _extract_attachments(sent)
            if text or attachments:
                is_note_to_self = bool(destination) and destination == account_number
                if is_note_to_self or include_self_sync:
                    return {
                        "kind": "note-to-self" if is_note_to_self else "self-sync",
                        "source": source,
                        "source_name": source_name,
                        "ts": ts_seconds,
                        "text": text,
                        "attachments": attachments,
                        "group": group_id,
                        "destination": destination,
                    }

    return None


def passes_filters(
    parsed: dict[str, Any],
    allow_sources: set[str],
    allow_groups: set[str],
    trigger_prefix: str,
) -> dict[str, Any] | None:
    """Apply user filters. Returns a possibly-mutated copy to deliver, or None."""
    # Group scoping
    if parsed.get("group"):
        if not allow_groups or parsed["group"] not in allow_groups:
            return None

    # Source scoping — optional noise filter for external messages.
    # If allow_sources is non-empty, only those numbers pass through.
    # This step never filters note-to-self; the trigger-prefix gate below
    # still applies to all messages.
    if parsed["kind"] == "external":
        if allow_sources and parsed["source"] not in allow_sources:
            return None

    if trigger_prefix:
        stripped = parsed["text"].lstrip()
        if not stripped.lower().startswith(trigger_prefix.lower()):
            return None
        parsed = dict(parsed)
        parsed["text"] = stripped[len(trigger_prefix):].lstrip()

    return parsed


# Column-0 markers that a downstream envelope parser, the watch splitter, or
# the LLM prompt-assembler may treat as envelope-header / provenance-block /
# new-envelope boundaries. Any of these appearing at column 0 inside an
# attacker-controlled Signal body would let the sender impersonate envelope
# fields, open a fake `---` envelope, or forge a `CONDUCTOR_DIRECTIVES` block.
_ENVELOPE_HEADER_MARKERS = (
    "---",
    "FROM:", "TO:", "TYPE:", "TIME:", "STATUS:",
    "MSG_ID:", "REF:", "TASK_ID:", "KIND:",
    "SUMMARY:", "DETAILS:", "SELFCHECK:", "WATCH:",
    "SOURCE:", "SOURCE_NAME:", "GROUP_ID:",
    "DESTINATION:", "RECEIVED_AT:",
    "CONDUCTOR_DIRECTIVES", "SIGNAL_INBOUND",
)


def _neutralize_envelope_headers(text: str) -> str:
    """Prefix `> ` to any line at column 0 starting with an envelope marker.

    Column 0 is where envelope parsers / splitters anchor; pushing the marker
    one column over defangs it. The `> ` prefix also reads as a quote glyph
    to the watch LLM, matching `roles/all.instruct`'s data-framing guidance.
    Mid-line occurrences and indented lines are left alone — neither can be
    mistaken for an envelope boundary.
    """
    out = []
    for line in text.split("\n"):
        if any(line.startswith(m) for m in _ENVELOPE_HEADER_MARKERS):
            out.append("> " + line)
        else:
            out.append(line)
    return "\n".join(out)


def _sanitize_one_line(value: str) -> str:
    """Collapse whitespace so a single-line envelope field can't go multi-line."""
    return " ".join(value.split())


def _extract_attachments(message: dict[str, Any]) -> list[dict[str, str]]:
    """Return compact metadata for signal-cli downloaded attachments."""
    attachments = message.get("attachments")
    if not isinstance(attachments, list):
        return []

    out: list[dict[str, str]] = []
    for item in attachments:
        if not isinstance(item, dict):
            continue
        meta: dict[str, str] = {}
        for src, dst in (
            ("contentType", "content_type"),
            ("filename", "filename"),
            ("storedFilename", "stored_filename"),
            ("id", "id"),
            ("size", "size"),
            ("width", "width"),
            ("height", "height"),
        ):
            value = item.get(src)
            if value is not None:
                meta[dst] = _sanitize_one_line(str(value))
        if meta:
            out.append(meta)
    return out


def write_message(parsed: dict[str, Any], inbox: Path, sender_id: str, log_path: Path,
                  dry_run: bool) -> None:
    ts = parsed["ts"]
    ts_iso = datetime.fromtimestamp(ts, tz=timezone.utc).astimezone().isoformat(timespec="seconds")
    # Single-line metadata fields: collapse any internal whitespace (including
    # newlines) so a crafted sourceName / destination can't inject extra lines
    # into the envelope body.
    source = _sanitize_one_line(parsed["source"])
    source_name = _sanitize_one_line(parsed.get("source_name") or "")
    group = _sanitize_one_line(parsed.get("group") or "")
    destination = _sanitize_one_line(parsed.get("destination") or "")
    body_lines = [
        "TYPE: signal_message",
        f"KIND: {parsed['kind']}",
        f"SOURCE: {source}",
    ]
    if source_name:
        body_lines.append(f"SOURCE_NAME: {source_name}")
    if group:
        body_lines.append(f"GROUP_ID: {group}")
    if destination:
        body_lines.append(f"DESTINATION: {destination}")
    body_lines.append(f"RECEIVED_AT: {ts_iso}")
    attachments = parsed.get("attachments") or []
    if attachments:
        body_lines.append(f"ATTACHMENT_COUNT: {len(attachments)}")
        for idx, meta in enumerate(attachments, start=1):
            prefix = f"ATTACHMENT_{idx}"
            for key in (
                "content_type", "filename", "stored_filename", "id",
                "size", "width", "height",
            ):
                value = meta.get(key)
                if value:
                    body_lines.append(f"{prefix}_{key.upper()}: {value}")
    body_lines.append("")
    # Multi-line message body is attacker-controlled; neutralize any column-0
    # envelope-header markers before embedding it.
    text = parsed["text"].rstrip("\n")
    if text:
        body_lines.append(_neutralize_envelope_headers(text))
    elif attachments:
        body_lines.append("[attachment-only message]")
    body_lines.append("")
    body = "\n".join(body_lines)

    envelope_text, suffix = build_envelope(body, sender_id, ts)
    filename = f"{ts}_{sender_id}_{suffix}.msg"
    target = inbox / filename
    preview = parsed["text"].strip().replace("\n", " ")[:120]
    if not preview and attachments:
        preview = f"{len(attachments)} attachment(s)"

    if dry_run:
        _log(f"DRY-RUN would deliver {filename} (from={parsed['source']} "
             f"kind={parsed['kind']}): {preview}", log_path)
        return

    atomic_write(target, envelope_text)
    _log(f"delivered {filename} (from={parsed['source']} kind={parsed['kind']}): {preview}",
         log_path)


def acquire_singleton_lock(log_path: Path) -> socket.socket | None:
    """Use an abstract UNIX socket as a cheap single-instance lock."""
    lock_name = "\0signal_inbox_daemon::" + str(CORTEX_DIR)
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    try:
        sock.bind(lock_name)
    except OSError as exc:
        _log(f"another instance appears to be running ({exc}); exiting", log_path)
        sock.close()
        return None
    return sock


def run_one_poll(account: str, timeout: int, wall_clock_extra: int,
                 ignore_attachments: bool, log_path: Path) -> tuple[int, list[str]]:
    cmd = ["signal-cli", "-a", account, "-o", "json", "receive",
           "--timeout", str(timeout), "--ignore-stories"]
    if ignore_attachments:
        cmd.append("--ignore-attachments")
    wall_clock = max(timeout + wall_clock_extra, 60)
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=wall_clock,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        _log(f"signal-cli receive wall-clock timeout after {wall_clock}s: {exc}", log_path)
        return 124, []
    except FileNotFoundError:
        _log("signal-cli binary not found in PATH", log_path)
        return 127, []

    if proc.returncode != 0:
        stderr = (proc.stderr or "").strip().splitlines()[-1:] or [""]
        _log(f"signal-cli receive exit={proc.returncode}: {stderr[0]}", log_path)

    lines = [line for line in (proc.stdout or "").splitlines() if line.strip()]
    return proc.returncode, lines


def main(argv: list[str] | None = None) -> int:
    global _current_log_path

    args = parse_args(argv)
    if not args.account.strip():
        print("signal account is required (set SIGNAL_ACCOUNT or pass --account)", file=sys.stderr)
        return 2
    inbox = resolve_inbox(args.inbox)
    log_path = Path(args.log_file).expanduser().resolve()
    _current_log_path = log_path

    inbox.mkdir(parents=True, exist_ok=True)
    log_path.parent.mkdir(parents=True, exist_ok=True)

    allow_sources = set(args.allow_source)
    allow_groups = set(args.allow_group)

    _log(
        "starting "
        f"(account={args.account} inbox={inbox} sender_id={args.sender_id} "
        f"allow_sources={sorted(allow_sources) or 'all'} "
        f"allow_groups={sorted(allow_groups) or 'none'} "
        f"include_self_sync={args.include_self_sync} "
        f"trigger_prefix={args.trigger_prefix!r} "
        f"timeout={args.timeout}s poll_interval={args.poll_interval}s "
        f"dry_run={args.dry_run})",
        log_path,
    )

    lock = acquire_singleton_lock(log_path)
    if lock is None:
        return 1

    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)

    consecutive_failures = 0
    while not stop_requested:
        rc, lines = run_one_poll(
            args.account, args.timeout, args.wall_clock_extra,
            args.ignore_attachments, log_path,
        )

        for line in lines:
            try:
                raw = json.loads(line)
            except Exception as exc:
                _log(f"skip unparseable json ({exc}): {line[:200]}", log_path)
                continue

            parsed = extract_message(raw, args.account, args.include_self_sync)
            if parsed is None:
                continue

            delivered = passes_filters(
                parsed, allow_sources, allow_groups,
                args.trigger_prefix,
            )
            if delivered is None:
                continue

            try:
                write_message(delivered, inbox, args.sender_id, log_path, args.dry_run)
            except Exception as exc:
                _log(f"failed to deliver message: {exc}", log_path)
                continue

        if rc == 0:
            consecutive_failures = 0
            sleep_for = args.poll_interval
        else:
            consecutive_failures += 1
            sleep_for = min(args.backoff * max(1, consecutive_failures // 3 + 1), 300.0)

        if args.once:
            break

        end = time.monotonic() + sleep_for
        while not stop_requested and time.monotonic() < end:
            time.sleep(min(0.5, max(0.0, end - time.monotonic())))

    _log("stopped", log_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
