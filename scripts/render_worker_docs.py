#!/usr/bin/env python3
"""Render metadata-driven worker catalog blocks in framework docs."""

from __future__ import annotations

import argparse
import re
import shlex
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

CATEGORY_ORDER = ["operational", "framework", "loop", "research", "experiment"]
CATEGORY_INFO = {
    "operational": {
        "title": "Operational workers",
        "description": "These are the workers that keep the system tidy and durable over time.",
    },
    "framework": {
        "title": "Framework review workers",
        "description": (
            "These workers are analysis-first by default: they inspect one framework/runtime slice, "
            "report findings, and repair only on explicit COMMAND. They audit and improve Cortex "
            "itself by turning otherwise stochastic agent behavior into inspectable evidence, durable "
            "findings, and explicit follow-up rules or repairs. They cannot make an LLM deterministic, "
            "but they make the surrounding framework as repeatable and accountable as practical."
        ),
    },
    "loop": {
        "title": "Closed-loop implementation workers",
        "description": "Use these when you want a bounded review/repair loop without the conductor hand-authoring every round.",
    },
    "research": {
        "title": "Research workers",
        "description": "These are mission-scoped specialist roles for the current research cycle; launch only the specialists that match the active mission.",
    },
    "experiment": {
        "title": "Experiment workers",
        "description": "These workers own autonomous, mission-scoped experiment improvement loops with local notes, cheatsheets, and launch recipes.",
    },
}

README_MARKER = "worker-role-catalog"
SHORTCUTS_MARKER = "worker-launch-matrix"
README_PATH = ROOT / "README.md"
SHORTCUTS_PATH = ROOT / "SHORTCUTS.md"


@dataclass(frozen=True)
class Worker:
    worker_id: str
    category: str
    meta_path: Path
    domain: str
    lifecycle: str
    cadence: str
    write_capable: str
    core: str
    team: str
    role_in_team: str
    collaborates_with: tuple[str, ...]
    owns_scripts: tuple[str, ...]


def parse_meta_scalar(raw: str) -> str:
    tokens = shlex.split(raw, posix=True)
    return " ".join(tokens)


def parse_meta_list(raw: str) -> tuple[str, ...]:
    tokens = shlex.split(raw, posix=True)
    if len(tokens) == 1:
        return tuple(tokens[0].split())
    return tuple(tokens)


def load_worker(meta_path: Path) -> Worker:
    values: dict[str, str] = {}
    list_fields = {"META_collaborates_with", "META_owns_scripts"}
    for raw_line in meta_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, raw_value = line.split("=", 1)
        if not key.startswith("META_"):
            continue
        if key in list_fields:
            values[key] = "\n".join(parse_meta_list(raw_value))
        else:
            values[key] = parse_meta_scalar(raw_value)

    worker_id = meta_path.name[len("worker.") : -len(".meta")]
    return Worker(
        worker_id=worker_id,
        category=values.get("META_category", ""),
        meta_path=meta_path.relative_to(ROOT),
        domain=values.get("META_domain", ""),
        lifecycle=values.get("META_lifecycle", ""),
        cadence=values.get("META_cadence", ""),
        write_capable=values.get("META_write_capable", ""),
        core=values.get("META_core", ""),
        team=values.get("META_team", ""),
        role_in_team=values.get("META_role_in_team", ""),
        collaborates_with=tuple(filter(None, values.get("META_collaborates_with", "").splitlines())),
        owns_scripts=tuple(filter(None, values.get("META_owns_scripts", "").splitlines())),
    )


def discover_workers() -> list[Worker]:
    workers = [load_worker(path) for path in sorted(ROOT.glob("roles/*/worker.*.meta"))]
    workers.sort(
        key=lambda worker: (
            CATEGORY_ORDER.index(worker.category)
            if worker.category in CATEGORY_ORDER
            else len(CATEGORY_ORDER),
            worker.worker_id,
        )
    )
    return workers


def lifecycle_display(worker: Worker) -> str:
    lifecycle = worker.lifecycle or "default"
    if worker.role_in_team:
        return f"{lifecycle} / {worker.role_in_team}"
    return lifecycle


def cadence_display(cadence: str) -> str:
    return {
        "": "framework default",
        "disabled": "manual only",
        "short": "short",
        "hourly": "hourly",
        "6h": "every 6h",
        "12h": "every 12h",
        "daily": "daily",
    }.get(cadence, cadence)


def write_display(worker: Worker) -> str:
    return "yes" if worker.write_capable == "yes" else "no"


def escape_cell(text: str) -> str:
    return text.replace("|", r"\|")


def launch_command(worker: Worker) -> str:
    base = f"bash scripts/start_agent_screen.sh --role worker --name {worker.worker_id}"
    if worker.category == "research":
        return f"CORTEX_RESEARCH_PROJECT=<project> {base}"
    return base


def render_category_table(workers: list[Worker], *, include_launch: bool) -> list[str]:
    if include_launch:
        lines = [
            "| Worker | Launch | Default cadence | Writes | Domain |",
            "| --- | --- | --- | --- | --- |",
        ]
        for worker in workers:
            lines.append(
                f"| `{worker.worker_id}` | `{launch_command(worker)}` | {cadence_display(worker.cadence)} | "
                f"{write_display(worker)} | {escape_cell(worker.domain)} |"
            )
        return lines

    lines = [
        "| Worker | Lifecycle | Default cadence | Writes | Domain |",
        "| --- | --- | --- | --- | --- |",
    ]
    for worker in workers:
        lines.append(
            f"| `{worker.worker_id}` | {escape_cell(lifecycle_display(worker))} | "
            f"{cadence_display(worker.cadence)} | {write_display(worker)} | "
            f"{escape_cell(worker.domain)} |"
        )
    return lines


def render_readme_catalog(workers: list[Worker]) -> str:
    lines: list[str] = []
    for category in CATEGORY_ORDER:
        category_workers = [worker for worker in workers if worker.category == category]
        if not category_workers:
            continue
        info = CATEGORY_INFO[category]
        lines.append(f"### {info['title']}")
        lines.append("")
        lines.append(info["description"])
        lines.append("")
        lines.extend(render_category_table(category_workers, include_launch=False))
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def render_shortcuts_matrix(workers: list[Worker]) -> str:
    lines: list[str] = []
    for category in CATEGORY_ORDER:
        category_workers = [worker for worker in workers if worker.category == category]
        if not category_workers:
            continue
        info = CATEGORY_INFO[category]
        lines.append(f"#### {info['title']}")
        lines.append("")
        lines.extend(render_category_table(category_workers, include_launch=True))
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def replace_generated_block(text: str, marker: str, body: str) -> str:
    begin = f"<!-- BEGIN GENERATED: {marker} -->"
    end = f"<!-- END GENERATED: {marker} -->"
    pattern = re.compile(rf"{re.escape(begin)}\n.*?{re.escape(end)}", re.DOTALL)
    replacement = f"{begin}\n{body.rstrip()}\n{end}"
    updated, count = pattern.subn(replacement, text, count=1)
    if count != 1:
        raise ValueError(f"missing generated block markers for {marker}")
    return updated


def build_expected_updates(workers: list[Worker]) -> dict[Path, str]:
    return {
        README_PATH: replace_generated_block(
            README_PATH.read_text(encoding="utf-8"),
            README_MARKER,
            render_readme_catalog(workers),
        ),
        SHORTCUTS_PATH: replace_generated_block(
            SHORTCUTS_PATH.read_text(encoding="utf-8"),
            SHORTCUTS_MARKER,
            render_shortcuts_matrix(workers),
        ),
    }


def validate_workers(workers: list[Worker]) -> list[str]:
    errors: list[str] = []
    seen_ids: set[str] = set()

    for worker in workers:
        if worker.worker_id in seen_ids:
            errors.append(f"duplicate worker id: {worker.worker_id}")
        seen_ids.add(worker.worker_id)

        category_dir = worker.meta_path.parent.name
        if not worker.category:
            errors.append(f"{worker.meta_path}: missing META_category")
        elif worker.category != category_dir:
            errors.append(
                f"{worker.meta_path}: META_category={worker.category} does not match roles/{category_dir}/"
            )
        if not worker.domain:
            errors.append(f"{worker.meta_path}: missing META_domain")

        instruct_path = ROOT / f"roles/{category_dir}/worker.{worker.worker_id}.instruct"
        if not instruct_path.is_file():
            errors.append(f"{worker.meta_path}: missing instruct file {instruct_path.relative_to(ROOT)}")

        bundle_prefix = f"roles/{category_dir}/{worker.worker_id}/"
        for owned_script in worker.owns_scripts:
            owned_path = ROOT / owned_script
            if not owned_path.is_file():
                errors.append(f"{worker.meta_path}: META_owns_scripts path missing: {owned_script}")
            if not owned_script.startswith(bundle_prefix):
                errors.append(
                    f"{worker.meta_path}: META_owns_scripts path must stay under {bundle_prefix}: {owned_script}"
                )

    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--write", action="store_true", help="rewrite generated blocks in place")
    group.add_argument("--check", action="store_true", help="verify generated blocks are up to date")
    args = parser.parse_args()

    workers = discover_workers()
    errors = validate_workers(workers)
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1

    try:
        expected_updates = build_expected_updates(workers)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    if args.write:
        changed = []
        for path, expected_text in expected_updates.items():
            current_text = path.read_text(encoding="utf-8")
            if current_text != expected_text:
                path.write_text(expected_text, encoding="utf-8")
                changed.append(path.relative_to(ROOT))
        if changed:
            for path in changed:
                print(f"updated {path}")
        else:
            print("worker docs already up to date")
        return 0

    stale_paths = [
        path.relative_to(ROOT)
        for path, expected_text in expected_updates.items()
        if path.read_text(encoding="utf-8") != expected_text
    ]
    if stale_paths:
        for path in stale_paths:
            print(f"stale generated worker docs: {path}", file=sys.stderr)
        print("run: python3 scripts/render_worker_docs.py --write", file=sys.stderr)
        return 1

    print("worker metadata docs and owned-script paths are in sync")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
