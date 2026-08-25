#!/usr/bin/env python3
"""Insert a newline after likely sentence-ending periods in a TeX file."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


SENTENCE_PERIOD = re.compile(r"\.(?!\r?\n)(?P<ws>[ \t]+)(?=(?:[A-Z\\]))")
ABBREVIATION_TAILS = {
    "e.g",
    "i.e",
    "etc",
    "vs",
    "cf",
    "fig",
    "eq",
    "sec",
    "dr",
    "mr",
    "mrs",
    "ms",
    "prof",
    "al",
}


def should_break(text: str, period_index: int) -> bool:
    window = text[max(0, period_index - 16) : period_index]
    tail = re.search(r"([A-Za-z.]+)$", window)
    if not tail:
        return True
    return tail.group(1).lower() not in ABBREVIATION_TAILS


def transform(text: str) -> str:
    pieces: list[str] = []
    last = 0
    for match in SENTENCE_PERIOD.finditer(text):
        period_index = match.start()
        pieces.append(text[last:period_index + 1])
        if should_break(text, period_index):
            pieces.append("\n")
        else:
            pieces.append(match.group("ws"))
        last = match.end()
    pieces.append(text[last:])
    return "".join(pieces)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Add a line break after likely sentence-ending periods in a TeX "
            "file, unless the period is already followed by a newline."
        )
    )
    parser.add_argument("path", type=Path, help="Path to the .tex file to rewrite")
    parser.add_argument(
        "--stdout",
        action="store_true",
        help="Print the transformed file instead of overwriting it",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Exit with status 1 if the file would change, 0 otherwise",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    original = args.path.read_text(encoding="utf-8")
    updated = transform(original)

    if args.check:
        return 1 if updated != original else 0

    if args.stdout:
        sys.stdout.write(updated)
        return 0

    tmp_path = args.path.with_name(args.path.name + ".tmp")
    tmp_path.write_text(updated, encoding="utf-8")
    tmp_path.replace(args.path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
