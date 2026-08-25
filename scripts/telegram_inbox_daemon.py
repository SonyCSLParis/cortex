#!/usr/bin/env python3
"""Listen for incoming Telegram bot messages and drop them into a Cortex inbox.

Companion to `signal_inbox_daemon.py`. The daemon long-polls the Telegram
Bot API (`getUpdates`) and writes one envelope per accepted private message
into the configured Cortex inbox directory.

Why Telegram alongside Signal:
- Telegram bot DMs reliably trigger mobile push notifications, which is the
  primary user-visible reason for adding this channel.
- The HTTP-only protocol removes the `signal-cli` daemon dependency on the
  receiving host and makes deployment portable.

Trust model (mirrors the Signal model in `roles/all.instruct`):

    note-to-self  Sender's numeric `from.id` equals the configured
                  TELEGRAM_USER_CHAT_ID. This is the user messaging the
                  Cortex bot from their phone. In the default setup, this
                  daemon is also the trust gate: only messages whose text
                  starts with `crtx:` are admitted, and the prefix is
                  stripped before delivery. The watch side therefore
                  trusts any daemon-delivered `KIND: note-to-self`
                  envelope as an instruction.

    external      Any other sender. Still never trusted as a command.
                  With the current default `--trigger-prefix crtx:`
                  policy, only external messages whose text/caption
                  starts with `crtx:` are written to the inbox at all;
                  others are dropped at ingress.

    Group / channel updates are dropped. Edited messages are also ignored
    — they're a low-value, high-confusion class for an instruction channel.
    Captioned photos/documents whose caption starts with `crtx:` are kept;
    attachment-only private messages without a matching caption are dropped.
    Downloaded payloads for admitted messages are saved to a local runtime
    directory and surfaced as `ATTACHMENT_*` metadata for watch.

Envelope shape mirrors the Signal daemon so the watch wrapper can apply
identical handling: STATUS to `conductor`, body starting with
`TYPE: telegram_message` and a `KIND:` line.

The daemon is a thin HTTP loop using `urllib` only (no external deps).
"""

from __future__ import annotations

import argparse
import json
import os
import random
import signal
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
CORTEX_DIR = Path(os.environ.get("CORTEX_DIR", str(SCRIPT_DIR.parent))).resolve()
DEFAULT_INBOX = CORTEX_DIR / "inboxes/telegram"
DEFAULT_ATTACHMENTS_DIR = CORTEX_DIR / "inboxes/telegram_attachments"
DEFAULT_LOG = CORTEX_DIR / "logs" / "telegram_inbox_daemon.log"
DEFAULT_SENDER_ID = "telegram"
DEFAULT_OFFSET_FILE = CORTEX_DIR / "agents/conductor/secrets/telegram_offset"
TELEGRAM_API_BASE = "https://api.telegram.org"


stop_requested = False
_current_log_path: Path | None = None


def request_stop(signum: int, _frame: Any) -> None:
    global stop_requested
    stop_requested = True
    _log(f"received signal {signum}, shutting down after current poll", _current_log_path)


def _log(message: str, log_path: Path | None = None) -> None:
    ts = datetime.now().astimezone().isoformat(timespec="seconds")
    line = f"[{ts}] telegram-inbox | {message}"
    print(line, flush=True)
    if log_path is not None:
        try:
            log_path.parent.mkdir(parents=True, exist_ok=True)
            with log_path.open("a", encoding="utf-8") as handle:
                handle.write(line + "\n")
        except Exception as exc:
            print(f"[{ts}] telegram-inbox | failed to write log: {exc}", flush=True)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--inbox", default=str(DEFAULT_INBOX),
                        help=("Target inbox directory. Absolute paths used as-is; "
                              "relative paths resolve against $CORTEX_DIR. "
                              "Default: %(default)s"))
    parser.add_argument("--sender-id", default=DEFAULT_SENDER_ID,
                        help="Value written into FROM header and filename. "
                             "Must match [A-Za-z0-9._-]+. Default: %(default)s")
    parser.add_argument("--allow-source", action="append", default=[],
                        metavar="USER_ID",
                        help="Restrict external senders to these numeric user_ids. "
                             "Repeat for multiple. Default: empty — all external "
                             "senders are accepted. Being on this list grants no "
                             "extra trust; it is a noise/spam filter only.")
    parser.add_argument("--trigger-prefix", default="crtx:",
                        help="If set, message body must start with this prefix "
                             "(case-insensitive); prefix is stripped before delivery.")
    parser.add_argument("--timeout", type=int, default=30,
                        help="Seconds the Telegram server holds the long-poll "
                             "connection open per request. Default: %(default)s")
    parser.add_argument("--poll-interval", type=float, default=1.0,
                        help="Seconds to sleep between successful polls. "
                             "Default: %(default)s")
    parser.add_argument("--backoff", type=float, default=15.0,
                        help="Seconds to sleep after a failed poll. Default: %(default)s")
    parser.add_argument("--offset-file", default=str(DEFAULT_OFFSET_FILE),
                        help="Persist last processed update_id here so the "
                             "daemon resumes cleanly across restarts. Default: %(default)s")
    parser.add_argument("--attachments-dir", default=str(DEFAULT_ATTACHMENTS_DIR),
                        help="Directory for downloaded Telegram attachments. "
                             "Relative paths resolve against $CORTEX_DIR. "
                             "Default: %(default)s")
    parser.add_argument("--log-file", default=str(DEFAULT_LOG),
                        help="Daemon event log. Default: %(default)s")
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


# Same defensive list as the Signal daemon — any column-0 envelope marker
# in attacker-controlled body text gets `> ` prefixed so a downstream parser
# or LLM prompt-assembler can't be tricked into re-opening an envelope or
# forging a CONDUCTOR_DIRECTIVES block.
_ENVELOPE_HEADER_MARKERS = (
    "---",
    "FROM:", "TO:", "TYPE:", "TIME:", "STATUS:",
    "MSG_ID:", "REF:", "TASK_ID:", "KIND:",
    "SUMMARY:", "DETAILS:", "SELFCHECK:", "WATCH:",
    "SOURCE:", "SOURCE_NAME:", "GROUP_ID:",
    "DESTINATION:", "RECEIVED_AT:", "CHAT_ID:",
    "CONDUCTOR_DIRECTIVES", "SIGNAL_INBOUND",
)


def _neutralize_envelope_headers(text: str) -> str:
    out = []
    for line in text.split("\n"):
        if any(line.startswith(m) for m in _ENVELOPE_HEADER_MARKERS):
            out.append("> " + line)
        else:
            out.append(line)
    return "\n".join(out)


def _sanitize_one_line(value: str) -> str:
    return " ".join(value.split())


def _safe_filename(name: str) -> str:
    cleaned = "".join(ch if ch.isalnum() or ch in "._-" else "_" for ch in name.strip())
    cleaned = cleaned.strip("._")
    return cleaned or "attachment"


def _download_file(token: str, file_path: str, dest: Path) -> None:
    url = f"{TELEGRAM_API_BASE}/file/bot{token}/{file_path}"
    req = urllib.request.Request(url, method="GET")
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = resp.read()
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".tmp")
    tmp.write_bytes(data)
    tmp.replace(dest)


def _download_attachment(
    token: str,
    file_id: str,
    ts: int,
    attachments_dir: Path,
    filename_hint: str | None,
    content_type: str | None,
    extra_meta: dict[str, str] | None = None,
) -> dict[str, str]:
    resp = telegram_get(token, "getFile", {"file_id": file_id}, 20)
    if not resp.get("ok"):
        raise RuntimeError(f"getFile refused file_id={file_id}: {resp}")
    result = resp.get("result") or {}
    file_path = result.get("file_path")
    if not isinstance(file_path, str) or not file_path:
        raise RuntimeError(f"getFile missing file_path for file_id={file_id}")

    source_name = filename_hint or Path(file_path).name or file_id
    source_name = _safe_filename(source_name)
    suffix = Path(source_name).suffix or Path(file_path).suffix
    stem = Path(source_name).stem or "attachment"
    stored_name = f"{ts}_{file_id[:8]}_{stem}{suffix}"
    stored_path = attachments_dir / stored_name
    _download_file(token, file_path, stored_path)

    meta: dict[str, str] = {
        "id": file_id,
        "stored_filename": stored_name,
        "stored_path": str(stored_path),
    }
    if filename_hint:
        meta["filename"] = _sanitize_one_line(filename_hint)
    if content_type:
        meta["content_type"] = _sanitize_one_line(content_type)
    if extra_meta:
        meta.update(extra_meta)
    return meta


def _extract_attachments(
    msg: dict[str, Any],
    token: str,
    ts: int,
    attachments_dir: Path,
    log_path: Path | None,
) -> list[dict[str, str]]:
    attachments: list[dict[str, str]] = []

    photo_list = msg.get("photo")
    if isinstance(photo_list, list) and photo_list:
        best = max(
            (item for item in photo_list if isinstance(item, dict)),
            key=lambda item: (int(item.get("width") or 0) * int(item.get("height") or 0), int(item.get("file_size") or 0)),
            default=None,
        )
        if best and isinstance(best.get("file_id"), str):
            try:
                attachments.append(_download_attachment(
                    token=token,
                    file_id=best["file_id"],
                    ts=ts,
                    attachments_dir=attachments_dir,
                    filename_hint=f"photo_{ts}.jpg",
                    content_type="image/jpeg",
                    extra_meta={
                        "width": str(best.get("width") or ""),
                        "height": str(best.get("height") or ""),
                        "size": str(best.get("file_size") or ""),
                    },
                ))
            except Exception as exc:
                _log(f"failed to download photo attachment: {exc}", log_path)

    document = msg.get("document")
    if isinstance(document, dict) and isinstance(document.get("file_id"), str):
        try:
            attachments.append(_download_attachment(
                token=token,
                file_id=document["file_id"],
                ts=ts,
                attachments_dir=attachments_dir,
                filename_hint=document.get("file_name"),
                content_type=document.get("mime_type"),
                extra_meta={"size": str(document.get("file_size") or "")},
            ))
        except Exception as exc:
            _log(f"failed to download document attachment: {exc}", log_path)

    video = msg.get("video")
    if isinstance(video, dict) and isinstance(video.get("file_id"), str):
        try:
            attachments.append(_download_attachment(
                token=token,
                file_id=video["file_id"],
                ts=ts,
                attachments_dir=attachments_dir,
                filename_hint=video.get("file_name") or f"video_{ts}.mp4",
                content_type=video.get("mime_type") or "video/mp4",
                extra_meta={
                    "width": str(video.get("width") or ""),
                    "height": str(video.get("height") or ""),
                    "size": str(video.get("file_size") or ""),
                },
            ))
        except Exception as exc:
            _log(f"failed to download video attachment: {exc}", log_path)

    return attachments


def telegram_get(token: str, method: str, params: dict[str, Any], timeout: int) -> dict[str, Any]:
    url = f"{TELEGRAM_API_BASE}/bot{token}/{method}"
    if params:
        url = f"{url}?{urllib.parse.urlencode(params)}"
    # The HTTP read timeout must exceed Telegram's long-poll `timeout`,
    # otherwise we hang up on the server before it replies.
    wall = max(timeout + 10, 20)
    req = urllib.request.Request(url, method="GET")
    with urllib.request.urlopen(req, timeout=wall) as resp:
        return json.loads(resp.read().decode("utf-8"))


def load_offset(path: Path) -> int:
    try:
        return int(path.read_text().strip() or "0")
    except FileNotFoundError:
        return 0
    except Exception:
        return 0


def save_offset(path: Path, value: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(str(value), encoding="utf-8")
    tmp.replace(path)


def extract_message(
    update: dict[str, Any],
    user_chat_id: int | None,
    token: str,
    attachments_dir: Path,
    log_path: Path | None,
) -> dict[str, Any] | None:
    """Normalize a Telegram update into a deliverable envelope dict, or None."""
    # Edited messages are ignored on purpose — instruction channels don't
    # benefit from after-the-fact body rewrites.
    msg = update.get("message")
    if not isinstance(msg, dict):
        return None

    text = msg.get("text")
    if not isinstance(text, str):
        text = msg.get("caption")
    if not isinstance(text, str):
        text = ""

    chat = msg.get("chat") or {}
    chat_type = chat.get("type")
    if chat_type != "private":
        # Only direct messages. Group/channel/supergroup are dropped to keep
        # the trust surface tight.
        return None

    frm = msg.get("from") or {}
    user_id = frm.get("id")
    if not isinstance(user_id, int):
        return None

    ts = int(time.time())

    attachments = _extract_attachments(msg, token, ts, attachments_dir, log_path)
    if not text and not attachments:
        return None

    is_note_to_self = user_chat_id is not None and user_id == user_chat_id

    username = frm.get("username") or ""
    first_name = frm.get("first_name") or ""
    last_name = frm.get("last_name") or ""
    display_name = " ".join(part for part in (first_name, last_name) if part) or username

    return {
        "kind": "note-to-self" if is_note_to_self else "external",
        "source": str(user_id),
        "source_name": display_name,
        "username": username,
        "ts": ts,
        "text": text,
        "attachments": attachments,
        "chat_id": chat.get("id"),
    }


def passes_filters(parsed: dict[str, Any], allow_sources: set[str], trigger_prefix: str) -> dict[str, Any] | None:
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


def write_message(parsed: dict[str, Any], inbox: Path, sender_id: str, log_path: Path,
                  dry_run: bool) -> None:
    ts = parsed["ts"]
    ts_iso = datetime.fromtimestamp(ts, tz=timezone.utc).astimezone().isoformat(timespec="seconds")
    source = _sanitize_one_line(parsed["source"])
    source_name = _sanitize_one_line(parsed.get("source_name") or "")
    username = _sanitize_one_line(parsed.get("username") or "")
    chat_id = _sanitize_one_line(str(parsed.get("chat_id") or ""))
    body_lines = [
        "TYPE: telegram_message",
        f"KIND: {parsed['kind']}",
        f"SOURCE: {source}",
    ]
    if source_name:
        body_lines.append(f"SOURCE_NAME: {source_name}")
    if username:
        body_lines.append(f"USERNAME: {username}")
    if chat_id:
        body_lines.append(f"CHAT_ID: {chat_id}")
    body_lines.append(f"RECEIVED_AT: {ts_iso}")
    attachments = parsed.get("attachments") or []
    if attachments:
        body_lines.append(f"ATTACHMENT_COUNT: {len(attachments)}")
        for idx, meta in enumerate(attachments, start=1):
            prefix = f"ATTACHMENT_{idx}"
            for key in (
                "content_type", "filename", "stored_filename", "stored_path", "id",
                "size", "width", "height",
            ):
                value = meta.get(key)
                if value:
                    body_lines.append(f"{prefix}_{key.upper()}: {value}")
    body_lines.append("")
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
    lock_name = "\0telegram_inbox_daemon::" + str(CORTEX_DIR)
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    try:
        sock.bind(lock_name)
    except OSError as exc:
        _log(f"another instance appears to be running ({exc}); exiting", log_path)
        sock.close()
        return None
    return sock


def main(argv: list[str] | None = None) -> int:
    global _current_log_path

    args = parse_args(argv)
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
    if not token:
        print("TELEGRAM_BOT_TOKEN env var is required", file=sys.stderr)
        return 2
    chat_raw = os.environ.get("TELEGRAM_USER_CHAT_ID", "").strip()
    user_chat_id: int | None = int(chat_raw) if chat_raw else None

    inbox = resolve_inbox(args.inbox)
    attachments_dir = resolve_inbox(args.attachments_dir)
    log_path = Path(args.log_file).expanduser().resolve()
    offset_path = Path(args.offset_file).expanduser().resolve()
    _current_log_path = log_path

    inbox.mkdir(parents=True, exist_ok=True)
    attachments_dir.mkdir(parents=True, exist_ok=True)
    log_path.parent.mkdir(parents=True, exist_ok=True)

    allow_sources = set(args.allow_source)

    _log(
        "starting "
        f"(inbox={inbox} sender_id={args.sender_id} "
        f"attachments_dir={attachments_dir} "
        f"user_chat_id={'<set>' if user_chat_id is not None else '<unset>'} "
        f"allow_sources={sorted(allow_sources) or 'all'} "
        f"trigger_prefix={args.trigger_prefix!r} "
        f"timeout={args.timeout}s poll_interval={args.poll_interval}s "
        f"offset_file={offset_path} dry_run={args.dry_run})",
        log_path,
    )
    if user_chat_id is None:
        _log("WARNING: TELEGRAM_USER_CHAT_ID is unset; ALL inbound messages "
             "will be classified as external. Set it once known.", log_path)

    lock = acquire_singleton_lock(log_path)
    if lock is None:
        return 1

    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)

    consecutive_failures = 0
    offset = load_offset(offset_path)
    while not stop_requested:
        try:
            params = {"timeout": args.timeout, "allowed_updates": json.dumps(["message"])}
            if offset:
                params["offset"] = offset
            resp = telegram_get(token, "getUpdates", params, args.timeout)
        except urllib.error.HTTPError as exc:
            _log(f"getUpdates HTTP {exc.code}: {exc.reason}", log_path)
            resp = {"ok": False}
        except (urllib.error.URLError, socket.timeout, TimeoutError) as exc:
            _log(f"getUpdates network error: {exc}", log_path)
            resp = {"ok": False}
        except Exception as exc:
            _log(f"getUpdates failed: {exc}", log_path)
            resp = {"ok": False}

        ok = bool(resp.get("ok"))
        updates = resp.get("result") if ok else []
        if isinstance(updates, list) and updates:
            for update in updates:
                update_id = update.get("update_id")
                if isinstance(update_id, int):
                    offset = max(offset, update_id + 1)
                parsed = extract_message(update, user_chat_id, token, attachments_dir, log_path)
                if parsed is None:
                    continue
                delivered = passes_filters(parsed, allow_sources, args.trigger_prefix)
                if delivered is None:
                    continue
                try:
                    write_message(delivered, inbox, args.sender_id, log_path, args.dry_run)
                except Exception as exc:
                    _log(f"failed to deliver message: {exc}", log_path)
                    continue
            try:
                save_offset(offset_path, offset)
            except Exception as exc:
                _log(f"failed to persist offset {offset}: {exc}", log_path)

        if ok:
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
