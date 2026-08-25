#!/usr/bin/env python3
"""Summarize Cortex provider usage from the current user's ledger."""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def default_user_home(root: Path) -> Path:
    pointer = root / "user.instruct"
    if pointer.exists():
        text = pointer.read_text(errors="replace")
        match = re.search(r"users/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\.instruct", text)
        if match:
            return root / Path(match.group(0)).parent

    users = sorted((root / "users").glob("*/*.instruct"))
    if len(users) == 1:
        return users[0].parent
    return root / "users" / "unknown"


def default_ledger(root: Path) -> Path:
    return default_user_home(root) / "usage" / "usage.tsv"


def parse_since(value: str, now: int) -> int:
    value = value.strip().lower()
    match = re.fullmatch(r"(\d+)([smhdw])", value)
    if not match:
        raise argparse.ArgumentTypeError("use a duration like 24h, 7d, or 1w")
    amount = int(match.group(1))
    unit = match.group(2)
    scale = {"s": 1, "m": 60, "h": 3600, "d": 86400, "w": 604800}[unit]
    return now - amount * scale


def compact_tokens(n: int) -> str:
    if n >= 1_000_000:
        return f"{n / 1_000_000:.2f}M"
    if n >= 1_000:
        return f"{n / 1_000:.1f}k"
    return str(n)


def read_rows(ledger: Path, since_epoch: int) -> list[dict[str, str]]:
    if not ledger.exists():
        return []
    with ledger.open(newline="", errors="replace") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        rows = []
        for row in reader:
            try:
                epoch = int(row.get("epoch") or "0")
            except ValueError:
                continue
            if epoch >= since_epoch:
                rows.append(row)
        return rows


# Hard ceiling on any single per-call token field — matches the bound used
# by cortex_usage_token_plausible() in usage_lib.sh. Any ledger row whose
# total_tokens (or split fields, if we add cross-checks later) exceeds this
# is treated as poisoned and excluded from the aggregate so a single bad
# scrape cannot dominate the headline number.
MAX_TOKENS_PER_CALL = 100_000_000


def summarize(rows: list[dict[str, str]]) -> dict[str, object]:
    calls = 0
    total_tokens = 0
    estimated_usd = 0.0
    estimated_rows = 0
    no_usage_rows = 0
    unknown_price_rows = 0
    rejected_rows = 0
    voided_rows = 0
    by_model: dict[tuple[str, str], dict[str, float]] = {}

    for row in rows:
        note = row.get("estimate_note") or ""
        try:
            tokens = int(row.get("total_tokens") or "0")
        except ValueError:
            tokens = 0
        # Defensive: reject any row whose recorded total exceeds the
        # plausibility bound, even if it was not marked rejected at write
        # time. This protects historical rows captured before the writer
        # gained its own bound.
        if tokens > MAX_TOKENS_PER_CALL or note == "rejected_implausible":
            rejected_rows += 1
            continue
        # Rows retroactively voided as foreign-session mis-attributions.
        # Token columns are kept for forensics but excluded from all totals.
        if note == "voided_misattributed":
            voided_rows += 1
            continue

        calls += 1
        total_tokens += tokens
        if note == "no_usage_found":
            no_usage_rows += 1
        if note == "unknown_price":
            unknown_price_rows += 1
        if note.startswith("estimated_"):
            estimated_rows += 1
        cost_text = row.get("estimated_usd") or ""
        try:
            cost = float(cost_text) if cost_text else 0.0
        except ValueError:
            cost = 0.0
        estimated_usd += cost

        key = (row.get("provider") or "unknown", row.get("model") or "unknown")
        slot = by_model.setdefault(key, {"calls": 0, "tokens": 0, "usd": 0.0})
        slot["calls"] += 1
        slot["tokens"] += tokens
        slot["usd"] += cost

    return {
        "calls": calls,
        "total_tokens": total_tokens,
        "estimated_usd": estimated_usd,
        "estimated_rows": estimated_rows,
        "no_usage_rows": no_usage_rows,
        "unknown_price_rows": unknown_price_rows,
        "rejected_rows": rejected_rows,
        "voided_rows": voided_rows,
        "by_model": by_model,
    }


def quiet_line(summary: dict[str, object], label: str, ledger: Path) -> str:
    calls = int(summary["calls"])
    if calls == 0:
        if ledger.exists():
            return f"Usage {label}: no provider calls recorded."
        return f"Usage {label}: no ledger yet."

    total_tokens = int(summary["total_tokens"])
    usd = float(summary["estimated_usd"])
    estimated_rows = int(summary["estimated_rows"])
    no_usage_rows = int(summary["no_usage_rows"])
    unknown_price_rows = int(summary["unknown_price_rows"])
    rejected_rows = int(summary["rejected_rows"])
    voided_rows = int(summary["voided_rows"])
    caveats = []
    if estimated_rows:
        caveats.append(f"{estimated_rows} split-estimated")
    if unknown_price_rows:
        caveats.append(f"{unknown_price_rows} unknown-price")
    if no_usage_rows:
        caveats.append(f"{no_usage_rows} no-usage")
    if rejected_rows:
        caveats.append(f"{rejected_rows} rejected-implausible")
    if voided_rows:
        caveats.append(f"{voided_rows} voided-misattributed")
    suffix = f" ({', '.join(caveats)})" if caveats else ""
    return f"Usage {label}: {calls} calls, {compact_tokens(total_tokens)} tokens, est. ${usd:.4f}{suffix}."


def main() -> int:
    now = int(dt.datetime.now(dt.timezone.utc).timestamp())
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ledger", type=Path, default=default_ledger(ROOT))
    parser.add_argument("--since", default="24h", help="duration to include, e.g. 24h or 7d")
    parser.add_argument("--quiet-line", action="store_true", help="print one operator-view line")
    args = parser.parse_args()

    since_epoch = parse_since(args.since, now)
    rows = read_rows(args.ledger, since_epoch)
    summary = summarize(rows)
    label = f"last {args.since}"

    if args.quiet_line:
        print(quiet_line(summary, label, args.ledger))
        return 0

    print(quiet_line(summary, label, args.ledger))
    print(f"Ledger: {args.ledger}")

    by_model = summary["by_model"]
    if by_model:
        print()
        print("By provider/model:")
        for (provider, model), values in sorted(
            by_model.items(), key=lambda item: (-item[1]["usd"], -item[1]["tokens"], item[0])
        ):
            print(
                f"- {provider}/{model}: {int(values['calls'])} calls, "
                f"{compact_tokens(int(values['tokens']))} tokens, est. ${values['usd']:.4f}"
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
