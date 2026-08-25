#!/usr/bin/env python3
"""Send a Telegram message via the configured Cortex bot.

Reads `TELEGRAM_BOT_TOKEN` and (by default) `TELEGRAM_USER_CHAT_ID`
from env. Use --chat-id to send somewhere else (e.g. group, contact).

Usage:
    set -a; . "$CORTEX_DEFAULT_TELEGRAM_SECRETS_FILE"; set +a
    python scripts/telegram_send.py "your message"
    python scripts/telegram_send.py --chat-id 12345 "to a different chat"
    echo "stdin works too" | python scripts/telegram_send.py -

Exit codes: 0 on success, 1 on send error, 2 on bad config / args.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request


TELEGRAM_API_BASE = "https://api.telegram.org"


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("message", nargs="?",
                        help="Message text. Use '-' or omit to read from stdin.")
    parser.add_argument("--chat-id", default=None,
                        help="Override TELEGRAM_USER_CHAT_ID for this send.")
    parser.add_argument("--parse-mode", default=None, choices=[None, "MarkdownV2", "HTML"],
                        help="Optional parse mode. Default: plain text.")
    parser.add_argument("--disable-notification", action="store_true",
                        help="Send silently (no push). Defaults to noisy — the whole "
                             "point of this channel is reliable notifications.")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    token = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
    if not token:
        print("TELEGRAM_BOT_TOKEN env var is required", file=sys.stderr)
        return 2

    chat_id = (args.chat_id or os.environ.get("TELEGRAM_USER_CHAT_ID", "")).strip()
    if not chat_id:
        print("chat_id is required (set TELEGRAM_USER_CHAT_ID or pass --chat-id)",
              file=sys.stderr)
        return 2

    if args.message is None or args.message == "-":
        text = sys.stdin.read()
    else:
        text = args.message
    if not text or not text.strip():
        print("refusing to send empty message", file=sys.stderr)
        return 2

    # Telegram caps at 4096 chars per message; truncate with a marker so a
    # too-long alert still gets through instead of failing silently.
    if len(text) > 4000:
        text = text[:3990] + "\n…[truncated]"

    payload = {"chat_id": chat_id, "text": text}
    if args.parse_mode:
        payload["parse_mode"] = args.parse_mode
    if args.disable_notification:
        payload["disable_notification"] = "true"

    url = f"{TELEGRAM_API_BASE}/bot{token}/sendMessage"
    data = urllib.parse.urlencode(payload).encode("utf-8")
    try:
        with urllib.request.urlopen(url, data=data, timeout=15) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body_text = exc.read().decode("utf-8", errors="replace") if exc.fp else ""
        print(f"sendMessage HTTP {exc.code}: {body_text or exc.reason}", file=sys.stderr)
        return 1
    except Exception as exc:
        print(f"sendMessage failed: {exc}", file=sys.stderr)
        return 1

    if not body.get("ok"):
        print(f"Telegram refused send: {body}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
