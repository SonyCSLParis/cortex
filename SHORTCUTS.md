# Cortex — Framework Shortcuts

Reusable recipes for operating the Cortex orchestration framework itself.
Project-specific shortcuts live in `projects/{project}/shortcuts.md`.
Cross-project reusable task recipes live here too.

Use TOC-first lookup: read only the matching `###` section, then update it after
acting if something durable and non-obvious was learned.

---

## Table of Contents

- [Starting the watch agent](#starting-the-watch-agent)
- [Starting a session-backed agent](#starting-a-session-backed-agent)
- [Restarting an agent fleet in parallel](#restarting-an-agent-fleet-in-parallel)
- [Starting a one-shot worker agent](#starting-a-one-shot-worker-agent)
- [Starting a persistent worker agent](#starting-a-persistent-worker-agent)
- [Starting the `sweep` experiment worker](#starting-the-sweep-experiment-worker)
- [Named worker launch matrix](#named-worker-launch-matrix)
- [Starting the `efficiency` worker](#starting-the-efficiency-worker)
- [Starting the `simplify` worker](#starting-the-simplify-worker)
- [Starting the `backup` worker](#starting-the-backup-worker)
- [Starting the `commit` worker](#starting-the-commit-worker)
- [Starting the `consistency` worker](#starting-the-consistency-worker)
- [Starting specialist review workers](#starting-specialist-review-workers)
- [Starting the `calibration` worker](#starting-the-calibration-worker)
- [Starting the `environment` worker](#starting-the-environment-worker)
- [Starting the `privacy` worker](#starting-the-privacy-worker)
- [Starting the `metacortex` worker](#starting-the-metacortex-worker)
- [Starting a deep-learning research cluster](#starting-a-deep-learning-research-cluster)
- [Starting the `supervisor` / `student` loop](#starting-the-supervisor--student-loop)
- [Running the control-plane smoke harness](#running-the-control-plane-smoke-harness)
- [Cross-platform command timeouts](#cross-platform-command-timeouts)
- [Watching the full agent roster](#watching-the-full-agent-roster)
- [Watching living agents in detail](#watching-living-agents-in-detail)
- [Checking a concise fleet snapshot](#checking-a-concise-fleet-snapshot)
- [Healing safe periodic jobs](#healing-safe-periodic-jobs)
- [Restarting the watch agent](#restarting-the-watch-agent)
- [Handling large project files in git](#handling-large-project-files-in-git)
- [Archiving old Done rows from a task board](#archiving-old-done-rows-from-a-task-board)
- [Promoting generalized user rules into Cortex specs](#promoting-generalized-user-rules-into-cortex-specs)
- [Checking whether a project path is actually shared](#checking-whether-a-project-path-is-actually-shared)
- [Syncing framework changes to the public cortex repo](#syncing-framework-changes-to-the-public-cortex-repo)
- [Quieting routine peer worker loops](#quieting-routine-peer-worker-loops)
- [Recovering split-brain watch conductor state](#recovering-split-brain-watch-conductor-state)
- [Selecting and killing low-epoch W&B sweep processes](#selecting-and-killing-low-epoch-wb-sweep-processes)
- [Stopping `wandb agent` sweep launchers](#stopping-wandb-agent-sweep-launchers)
- [Conductor startup routine](#conductor-startup-routine)
- [Conductor on-demand status overview](#conductor-on-demand-status-overview)
- [Queueing a commit-worker COMMAND](#queueing-a-commit-worker-command)
- [Draining the conductor inbox](#draining-the-conductor-inbox)
- [Conductor bookkeeping](#conductor-bookkeeping)

---

## Framework surface map

Where durable Cortex state lives, by category. Use this as a navigational
reference when deciding which file to read or write. Surfaces marked
`{user}` / `{project}` / `{env}` resolve via the routing notes in root
`user.instruct` and the active environment/project.

- **Wire spec and templates**: `PROTOCOL.md`; `roles/node.instruct` /
  `roles/worker.instruct` / `roles/self_check.instruct` /
  `roles/watch.instruct` / `roles/research.instruct`;
  `roles/{operational,framework,loop,research}/worker.<name>.instruct`
  (named-worker overrides appended after `worker.instruct`).
- **Conductor durable memory**: `agents/conductor/tasks.md` (cross-project /
  operational), `agents/conductor/logbook.md` (experiment / training /
  data-work narrative + numeric results of record),
  `agents/conductor/log.md` (terse append-only activity markers),
  `agents/conductor/inbox/*.msg` (unread responses + self-check alerts),
  `agents/conductor/sessions/{session}/prompt_log.txt` (optional per-session
  prompt + final-answer transcript).
- **User-scoped durable memory**: `user.instruct` (default-user routing
  note), `users/{user}/{user}.instruct` (durable preferences),
  `users/{user}/tasks.md` (reminders), `users/{user}/ideas.md`
  (speculative thoughts), `users/{user}/usage/usage.tsv` (provider usage /
  estimated-cost ledger).
- **Project-scoped durable memory**: `projects/{project}/{project}.instruct`
  (project-owned policies), `projects/{project}/tasks.md`,
  `projects/{project}/logbook.md` (durable project-development notes),
  `projects/{project}/shortcuts.md` (project-owned recipes).
- **Environment-scoped facts**: `environments/{env}/{env}.instruct`
  (concrete infrastructure facts referenced by generic prompts),
  `environments/{env}/cheat_sheet.md` (living reference for servers,
  deployment gotchas), `environments/{env}/backup_targets.txt` and
  `environments/{env}/backup_excludes/` (`backup` worker manifest).
- **Per-agent live state**: `agents/{id}/status`, `agents/{id}/heartbeat`,
  `agents/{id}/logbook.md` (optional local durable notes for persistent
  workers), `agents/watch/logbook.md` (durable watch-only incidents /
  actions — routine wakes stay in `agents/watch/log.md`).
- **Compressed history**: `agents/conductor/logbook.summary.md` and
  `projects/*/logbook.summary.md` / managed `agents/*/logbook.summary.md`
  are compressor-maintained arc summaries with `FIND:` lines pointing into
  live + `history/` shards.
- **Recipes and snippets**: this file (`SHORTCUTS.md`) for framework and
  cross-project recipes; `BASH_RECIPES.md` for bash snippets (status table,
  send COMMAND, Signal) read on demand.
- **Operational scripts**: `scripts/sync_public.sh` (sanitized framework
  export); `roles/operational/backup/backup_snapshot.sh` (deterministic
  snapshot script used by the `backup` worker); `scripts/periodics_check.sh`
  (manifest + enforcement for periodic/daemon jobs — reports `ok` /
  `disabled` / `advisory` / `unreachable` / `probe_error` / `down`; only
  `down` with `start` auto-heals; `cortex.sh` runs `heal` at chat entry;
  watch runs `heal` every wake; add jobs via `job_<name>` with `describe` /
  `check` / optional `start`); `scripts/control_plane_smoke.sh`
  (round-trip COMMAND→RESPONSE on a disposable worker plus
  `watch.sh --fast-path-reason` probe).

---

## Shortcuts

Before using the copy-paste snippets below in a clean shell, bootstrap
the symbolic defaults once:

```bash
CORTEX_DIR=${CORTEX_DIR:-$PWD}
source "${CORTEX_DIR}/config/cortex_defaults.sh"
```

Run that from the Cortex root, or set `CORTEX_DIR` first. Later
shortcuts assume those variables are already loaded.

### Cross-platform command timeouts

- **When**: a framework shell command needs a timeout but must also work on
  stock macOS.
- **Shortcut**: use `run_with_timeout <seconds> <command> [args...]` from
  `scripts/bash_compat.sh`; for a per-command environment value, use
  `run_with_timeout <seconds> env NAME=value <command> [args...]`.
- **Why / gotcha**: do not invoke `timeout` directly. The helper selects GNU
  `timeout`, Homebrew `gtimeout`, or a direct no-timeout fallback.
- **Last verified**: 2026-08-25.

### Starting the watch agent

- **When**: the user will be away and wants Cortex to keep watch without active chat.
- **Shortcut**: launch inside a screen session named `watch` so output stays visible and the process survives the chat:

  ```bash
  screen -dmS watch bash -lc \
    'exec > >(tee -a "${CORTEX_DEFAULT_TMP_LOG_DIR}/watch.log") 2>&1; \
     bash "${CORTEX_DEFAULT_START_AGENT_SCRIPT}" --role watch --watch "..."'
  ```

  (Equivalent: `bash ${CORTEX_DEFAULT_WATCH_SCRIPT} --watch "..."`. Omit
  `--interval` so the `META_wake_interval` default from `roles/watch.meta`
  applies; pass it only to override the manifest for one session.)

  The watch agent seeds `agents/watch/watch.txt`, reread on every wake, so edit `CORTEX_DEFAULT_WATCH_FILE` live to change instructions mid-session. To stop the watch without starting a new chat session: `bash ${CORTEX_DEFAULT_WATCH_SCRIPT} --stop`.
- **Why / gotcha**: the watch agent is the only sanctioned agent running unattended with conductor-level authority. Chat and watch coexist — both can run simultaneously. The lock at `agents/watch/lock/` is watch-exclusion only (prevents a second watch). Provider wakes default to Codex at the `META_tier` set in `roles/watch.meta` (mapped through the `CORTEX_DEFAULT_TIER_*` tuples), but quiet healthy wakes still use the fast-path gate and skip the provider entirely. If the watch file requests a routine Signal or Telegram every wake, the fast-path quiet check is bypassed so the notification fires even on healthy wakes. Watch now refreshes `SSH_AUTH_SOCK` at startup and before each wake by rebinding to the newest usable local `ssh-agent` socket for the current user, so a stale launch-time socket no longer forces a manual restart. If no usable local agent exists at all, remote SSH hops will still fail until one appears. Bare `bash scripts/watch.sh &` works functionally but loses the screen handle; always wrap in `screen -dmS watch` so operators can `screen -r watch` to inspect it live.
  On macOS, `watch.sh` now tolerates hosts that lack both `timeout` and `gtimeout`; install one only if you need hard per-wake provider deadlines rather than best-effort execution.
- **Last verified**: 2026-04-29.

### Starting a session-backed agent

- **When**: you want to start any long-lived node, worker, or watch agent without rebuilding the detached session + tee + `scripts/start_agent.sh` wrapper by hand.
- **Shortcut**:

  ```bash
  bash scripts/start_agent_screen.sh --role node --name <name>
  bash scripts/start_agent_screen.sh --role worker --name <name>
  WORKER_REVIEW_INTERVAL=<seconds> bash scripts/start_agent_screen.sh --role worker --name <name> --wake-seconds "${WORKER_REVIEW_INTERVAL}"
  bash scripts/start_agent_screen.sh --role watch   # interval from roles/watch.meta; add --wake-seconds N to override
  ```

  Default backend is `screen`. To use tmux explicitly without adding fallback
  probes:

  ```bash
  CORTEX_SESSION_BACKEND=tmux bash scripts/start_agent_screen.sh --role worker --name <name>
  ```

  Core operational workers are just normal named workers:

  ```bash
  bash scripts/start_agent_screen.sh --role worker --name backup
  bash scripts/start_agent_screen.sh --role worker --name commit
  bash scripts/start_agent_screen.sh --role worker --name compressor
  ```

- **Why / gotcha**: the helper chooses the canonical session name and tee log path, avoids duplicate starts when the selected backend session already exists, and waits briefly for a fresh heartbeat. `--wake-seconds` is role-aware: it becomes `WORKER_REVIEW_INTERVAL` for workers and `--interval` for watch, but is rejected for nodes because node poll cadence is not exposed through this wrapper. Verify both the expected session and a fresh heartbeat; a heartbeat alone is not enough if the expected session is absent. When launching from a sandboxed conductor shell fails to create the session, rerun the same helper outside the sandbox via an escalated command and record the working recovery here immediately. If the selected backend says no `worker_<id>` session exists but `pgrep -af 'scripts/start_agent.sh --role worker --name <id>'` still shows a live worker, treat the session listing as stale bookkeeping and stop the live worker PID directly instead of trusting the dead session entry. Use `--restart` only when you intend to stop the existing session first.
- **Last verified**: 2026-06-02.

### Restarting an agent fleet in parallel

- **When**: you need a coordinated restart of several long-lived agents and do not want to pay serialized launcher waits one worker at a time.
- **Shortcut**:

  ```bash
  agents=(research-lead research-theorist research-designer research-critic research-engineer research-runner)
  export CORTEX_RESEARCH_PROJECT=slap

  pids=()
  for name in "${agents[@]}"; do
    bash scripts/start_agent_screen.sh --role worker --name "${name}" --restart &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do
    wait "${pid}"
  done

  screen -ls | rg 'worker_research-(lead|theorist|designer|critic|engineer|runner)'
  ```

  Swap the `agents=(...)` list for the fleet you actually want. For non-research fleets, drop `CORTEX_RESEARCH_PROJECT`; for research fleets, keep it so the restarted workers pick up the active project fence and current broad-read bindings at launch.
- **Why / gotcha**: `start_agent_screen.sh --restart` already does the safe per-agent stop/start/heartbeat check, so fleet restarts should parallelize the wrapper invocations instead of hand-serializing them. Long-lived research workers only pick up new bind mounts at restart time, so a partial restart can leave the cluster on mixed sandbox generations. Always verify the expected screens after the batch, and if one launcher exits non-zero, rerun just that worker rather than redoing the whole fleet blindly.
- **Last verified**: 2026-05-31.

### Starting a one-shot worker agent

- **When**: conductor or watch wants a parallel elevated helper for one bounded task, rather than overloading the watch role or misusing a read-only node.
- **Shortcut**: give the worker an explicit id and `--once` so it exits after one personal COMMAND:

  ```bash
  bash scripts/start_agent_screen.sh --role worker --name <name> --provider codex --once
  ```

  Queue the COMMAND to `agents/<name>/inbox/` before or just after launch.

- **Shortcut**: queue a manual COMMAND into an agent inbox from the shell:
  ```bash
  ./send host-a Check current GPU/process status and report back.
  ```
  Use `./send --high ...` for priority `0_...` messages or `./send --inbox /path/to/inbox ...` for an explicit inbox path.
- **Why / gotcha**: worker launches are intentionally elevated and bypass the node sandbox, so they should always be explicit (`--name`) and bounded (`--once` when appropriate). Use `node` for read-only work and keep `watch` for unattended monitoring/escalation, not as the default worker pool.
- **Last verified**: 2026-04-23.

### Starting a persistent worker agent

- **When**: you want a long-lived elevated helper with a stable responsibility (for example `paper-worker`, `eval-worker`, `sync-worker`) rather than a disposable one-shot task runner.
- **Shortcut**:

  ```bash
  bash scripts/start_agent_screen.sh --role worker --name <name> --provider codex
  ```

  Persistent workers keep polling like nodes, but use the elevated worker prompt contract; `agents/<name>/logbook.md` is seeded on first launch for durable local notes.
- **Why / gotcha**: worker periodic self-checks and status reports are still **off by default**; that is just a launch default, not a structural limit. Enable them explicitly via env if this worker should self-monitor (`SELFCHECK_INTERVAL=... STATUSREPORT_INTERVAL=...`).
- **Last verified**: 2026-04-23.

### Starting the `sweep` experiment worker

- **When**: you want one autonomous, periodic deep-learning experiment worker to monitor runs, analyze results, search references, and launch the next mission-aligned experiment within its configured budget.
- **Shortcut**: configure `agents/sweep/config.env` and `agents/sweep/mission.txt`, then start or restart:

  ```bash
  bash scripts/start_agent_screen.sh --role worker --name sweep --provider codex --restart
  ```

  The seeded config owns the wake cadence and work budget via
  `SWEEP_WAKE_MINUTES` and `SWEEP_WORK_MINUTES`; edit those instead of
  hardcoding minute values in docs.
- **Why / gotcha**: `sweep` is intentionally write-capable and can launch runs
  when `SWEEP_LAUNCH_ALLOWED=yes`, so the mission must name the project,
  metrics, compute limits, and forbidden actions. It keeps active state in
  `agents/sweep/notes.txt`, stable facts in `agents/sweep/cheatsheet.md`, and
  repeatable commands in `agents/sweep/shortcuts.md`.
- **Last verified**: 2026-06-16.

### Named worker launch matrix

The live named-worker roster, canonical launch command, and default cadence
below are generated from `roles/**/worker.*.meta`. Use this as the overview
surface; keep deeper worker-specific gotchas in the hand-written sections that
follow.

<!-- BEGIN GENERATED: worker-launch-matrix -->
#### Operational workers

| Worker | Launch | Default cadence | Writes | Domain |
| --- | --- | --- | --- | --- |
| `backup` | `bash scripts/start_agent_screen.sh --role worker --name backup` | daily | yes | snapshot creation from backup_targets.txt; backup-freshness tracking |
| `cleanup` | `bash scripts/start_agent_screen.sh --role worker --name cleanup` | daily | yes | inbox, archive, and temp-file housekeeping across agent directories |
| `commit` | `bash scripts/start_agent_screen.sh --role worker --name commit` | every 12h | yes | git staging/commit/push for runtime dirt within the strict allow-list; never active source/policy without explicit COMMAND |
| `compressor` | `bash scripts/start_agent_screen.sh --role worker --name compressor` | every 12h | yes | logbook/task-board/archive size management via rotate/zip helpers; never rewrites live content |

#### Framework review workers

| Worker | Launch | Default cadence | Writes | Domain |
| --- | --- | --- | --- | --- |
| `calibration` | `bash scripts/start_agent_screen.sh --role worker --name calibration` | daily | no | per-agent behavior-vs-instruction drift; proposes targeted instruction edits |
| `consistency` | `bash scripts/start_agent_screen.sh --role worker --name consistency` | daily | no | ownership-boundary drift: project facts in wrong files, duplicated rules across layers |
| `efficiency` | `bash scripts/start_agent_screen.sh --role worker --name efficiency` | every 6h | no | workflow inefficiencies: repeated conductor work, avoidable token burn, missing shortcuts |
| `environment` | `bash scripts/start_agent_screen.sh --role worker --name environment` | daily | no | infrastructure ground-truth drift: cheat sheet vs ssh config; host/GPU/NAS/IP probes |
| `memory` | `bash scripts/start_agent_screen.sh --role worker --name memory` | daily | no | hygiene of durable memory surfaces: stale/duplicate rows, orphaned logbook entries |
| `metacortex` | `bash scripts/start_agent_screen.sh --role worker --name metacortex` | daily | no | philosophical self-reflection over Cortex as a whole; writes its treatise to own notes.txt on 24h cadence |
| `privacy` | `bash scripts/start_agent_screen.sh --role worker --name privacy` | daily | no | framework privacy boundary: concrete user/project/deployment details leaking into generic framework surfaces |
| `reliability` | `bash scripts/start_agent_screen.sh --role worker --name reliability` | daily | no | runtime health: stuck loops, stale heartbeats, failed periodics, missing recovery recipes |
| `security` | `bash scripts/start_agent_screen.sh --role worker --name security` | daily | no | security and sandbox posture: credential exposure, broad binds, permission drift |
| `simplify` | `bash scripts/start_agent_screen.sh --role worker --name simplify` | daily | no | deletion-biased review of code/spec/worker growth; every ticket proposes removal/consolidation (never addition) |

#### Closed-loop implementation workers

| Worker | Launch | Default cadence | Writes | Domain |
| --- | --- | --- | --- | --- |
| `student` | `bash scripts/start_agent_screen.sh --role worker --name student` | manual only | yes | loop experiment: implements rounds issued by the supervisor worker |
| `supervisor` | `bash scripts/start_agent_screen.sh --role worker --name supervisor` | short | yes | loop experiment: iterative review/repair loop driving the student worker |

#### Research workers

| Worker | Launch | Default cadence | Writes | Domain |
| --- | --- | --- | --- | --- |
| `research-analyst` | `CORTEX_RESEARCH_PROJECT=<project> bash scripts/start_agent_screen.sh --role worker --name research-analyst` | manual only | yes | research specialist: turning experiment artifacts into evidence |
| `research-critic` | `CORTEX_RESEARCH_PROJECT=<project> bash scripts/start_agent_screen.sh --role worker --name research-critic` | manual only | yes | research specialist: falsification and validity checks |
| `research-designer` | `CORTEX_RESEARCH_PROJECT=<project> bash scripts/start_agent_screen.sh --role worker --name research-designer` | manual only | yes | research specialist: turning hypotheses into concrete experiments |
| `research-engineer` | `CORTEX_RESEARCH_PROJECT=<project> bash scripts/start_agent_screen.sh --role worker --name research-engineer` | manual only | yes | research specialist: bounded implementation work for deep-learning experiments |
| `research-lead` | `CORTEX_RESEARCH_PROJECT=<project> bash scripts/start_agent_screen.sh --role worker --name research-lead` | hourly | yes | coordinator for the deep-learning research cluster; hypothesis synthesis |
| `research-literature` | `CORTEX_RESEARCH_PROJECT=<project> bash scripts/start_agent_screen.sh --role worker --name research-literature` | manual only | yes | research specialist: scientific context and prior-work grounding |
| `research-runner` | `CORTEX_RESEARCH_PROJECT=<project> bash scripts/start_agent_screen.sh --role worker --name research-runner` | manual only | yes | research specialist: launching and monitoring deep-learning experiments |
| `research-scribe` | `CORTEX_RESEARCH_PROJECT=<project> bash scripts/start_agent_screen.sh --role worker --name research-scribe` | manual only | yes | research specialist: maintaining project-local research notes |
| `research-theorist` | `CORTEX_RESEARCH_PROJECT=<project> bash scripts/start_agent_screen.sh --role worker --name research-theorist` | manual only | yes | research specialist: mechanisms, hypotheses, and expected outcomes |

#### Experiment workers

| Worker | Launch | Default cadence | Writes | Domain |
| --- | --- | --- | --- | --- |
| `sweep` | `bash scripts/start_agent_screen.sh --role worker --name sweep` | hourly | yes | autonomous deep-learning experiment sweeper: monitors, analyzes, launches, and iterates within its mission |
<!-- END GENERATED: worker-launch-matrix -->

### Watching the full agent roster

- **When**: you want the same full startup grid that `cortex.sh` prints, but as a standalone command you can refresh under `watch`.
- **Shortcut**:

  ```bash
  bash scripts/agent_roster.sh
  watch -c 'bash scripts/agent_roster.sh --color'
  ```

- **Why / gotcha**: `scripts/agent_roster.sh` is the extracted startup roster from `cortex.sh`. Membership is "last operated within 30 days", measured from the newest mtime of `agents/{id}/status` / `log.md`, because `agents/{id}/heartbeat` is deleted when an agent exits cleanly and so cannot answer that question. `heartbeat` still drives the colours: `none` plus no live session means stopped cleanly (grey), a stale heartbeat with no session means crash residue (red). Use `--color` with `watch -c` so the status colors survive the refresh loop; use `--no-color` when redirecting the output.
- **Last verified**: 2026-08-29.

### Watching living agents in detail

- **When**: you want a richer per-agent overview for the agents that are actually alive now, including their last logged action and most recent assigned command.
- **Shortcut**:

  ```bash
  bash scripts/living_agent_roster.sh
  bash scripts/living_agent_roster.sh --alive-hours 6
  watch -c 'bash scripts/living_agent_roster.sh --color --alive-hours 24'
  ```

- **Why / gotcha**: the default filter is heartbeat age `<= 24h`; change that with `--alive-hours N`, or use `--all` when you want to audit stale agents too. This script is intentionally richer than `scripts/agent_roster.sh`: it keeps the compact summary table, then adds per-agent detail blocks using each agent's latest `log.md` entry and newest `COMMAND` message from `archive/` or `inbox/`. This is the default evidence source when the user asks which agents are currently up / on / alive / running.
- **Last verified**: 2026-06-02.
### Checking a concise fleet snapshot

- **When**: you want the current high-signal Cortex state without re-reading agent dirs by hand.
- **Shortcut**:

  ```bash
  bash scripts/cortex_ops_snapshot.sh
  ```

  Add `--all` when you want the full fleet dump, including intentionally inactive agents.
- **Why / gotcha**: default mode is intentionally quiet. It suppresses agents inactive for more than 1 day unless `agents/watch/watch.txt` names them as expected-up. Unread inbox backlog only keeps an inactive agent visible when the newest unread message is itself fresh (<=1 day old); the output now shows that newest-message age inline so real backlog stands out from stale residue. It also suppresses stale transient smoke-agent homes (`manual-smoke-*`, `smoke-worker-*`) once they have been inactive for at least 1 hour, so failed one-shot test residue does not keep polluting normal status overviews. If you are auditing historical residue or stale agent homes, use `--all` rather than assuming the default view is exhaustive.
- **Last verified**: 2026-05-03.

### Healing safe periodic jobs

- **When**: watch has been offline, an always-on daemon needs a safe restart, or you want to re-run the manifest's auto-start actions by hand.
- **Shortcut**:

  ```bash
  bash scripts/periodics_check.sh heal
  bash scripts/periodics_check.sh status
  ```

- **Why / gotcha**: `heal` now touches only manifest jobs that actually define `start`; it skips advisory/manual jobs such as public-sync drift. `cortex.sh` runs `heal` before printing `status` at chat entry, and watch runs `heal` on every wake, so manual use is mainly for deterministic spot repairs or after longer watch-offline stretches.
- **Last verified**: 2026-05-03.

### Starting the `efficiency` worker

- **When**: you want a long-lived non-destructive worker that periodically audits Cortex itself for inefficiency, token waste, queueing/logging friction, observability gaps, over-specific or redundant framework structure that should be generalized, agent-communication patterns where better standing instructions would beat over-specified messages, agent context bundles/prompts that are larger than they need to be, and complexity creep such as extra abstractions, duplicate control paths, operator-surface growth, background automation churn, and stale machinery that should be removed.
- **Shortcut**:

  ```bash
  bash scripts/start_agent_screen.sh --role worker --name efficiency
  ```

  `roles/framework/worker.efficiency.instruct` is appended automatically because the worker id is `efficiency`.
- **Why / gotcha**: `efficiency` is still a `worker`, but its override narrows behavior back to analysis-only unless the conductor explicitly commands implementation. Its Codex path now stays inside the launcher `bwrap`, keeps only `agents/efficiency/` writable, and stages a minimal per-run `CODEX_HOME` in a private temp dir instead of mounting the full real `~/.codex` tree or writing auth into `agents/efficiency/`. Its sole durable memory is `agents/efficiency/logbook.md`; `agents/efficiency/log.md` is operational only. Its default periodic cadence comes from `roles/framework/worker.efficiency.meta` (`META_cadence=6h`), unless you override it at launch. Claude remains available only via explicit `--provider claude`.
- **Check output**: periodic checks should write concrete tickets/trends to `agents/efficiency/logbook.md` and keep the conductor reply short: finished, status, and where the report was written.
- **Last verified**: 2026-04-29.

### Starting the `simplify` worker

- **When**: you want a focused deletion-biased review of the framework, either as a standing daily worker or via an extra on-demand nudge. This is the long-horizon counterweight to `efficiency`; `simplify` exists separately because efficiency's broader mandate dilutes the deletion mindset.
- **Shortcut**: launch it as a persistent worker to use its default 24-hour cadence:

  ```bash
  bash scripts/start_agent_screen.sh --role worker --name simplify
  ```

  For an extra immediate pass without waiting for the next wake:

  ```bash
  ./send --inbox agents/simplify/inbox/ "Run a simplification pass per roles/framework/worker.simplify.instruct."
  ```

  `roles/framework/worker.simplify.instruct` is appended automatically because the worker id is `simplify`.
- **Why / gotcha**: every ticket the worker writes must be framed as `REMOVE:` / `MERGE:` / `SHRINK:` — never `ADD:`. If a finding genuinely requires adding something to land, the worker hands it to `efficiency` as a note instead of promoting it to a ticket. Output lives in `agents/simplify/logbook.md`; the conductor reply is a brief pointer. Cap per pass is 1-3 tickets — quality over quantity.
- **Check output**: read the newest section in `agents/simplify/logbook.md`. A pass that proposes "nothing to cut" is a legitimate outcome and should be respected, not pressured into producing tickets.
- **Last verified**: 2026-05-19.

### Starting the `backup` worker

- **When**: you want a long-lived worker that snapshots active source trees and other explicitly listed working dirs that are not yet safely committed.
- **Shortcut**:

  ```bash
  bash scripts/start_agent_screen.sh --role worker --name backup
  ```

  The worker reads the configured environment backup manifest, normally
  `environments/<env>/backup_targets.txt`, plus the sibling
  `environments/<env>/backup_excludes/*.txt` files, and runs
  `bash roles/operational/backup/backup_snapshot.sh` on its periodic cadence.
- **Why / gotcha**: `backup` is intentionally source-oriented. The default manifest protects the Cortex worktree plus the concrete live source trees listed in the configured environment manifest; worktree-style backups materialize unsafe symlink targets as real content, so external trees reached through in-repo symlinks do not need separate redundant manifest entries. It still does **not** mirror large checkpoint/output trees by default, because that would explode storage under current disk pressure. Add those paths explicitly only when you mean it. Override `BACKUP_ROOT`, `BACKUP_KEEP`, or `BACKUP_TARGETS_FILE` at launch if needed, and use the environment notes for the current concrete backup roots/mirrors.
- **Why / gotcha**: the launcher refuses to start this worker until the backup root is explicitly configured and the selected manifest contains an active target. Its `CONFIGURATION_REQUIRED` error names the missing setup action; have the user configure it before retrying.
- **Last verified**: 2026-04-24.

### Starting the `commit` worker

- **When**: you want a standing helper that can package explicit commit requests while chat continues.
- **Shortcut**:

  ```bash
  bash scripts/start_agent_screen.sh --role worker --name commit
  ```

  `roles/operational/worker.commit.instruct` is appended automatically because the worker id is `commit`.
- **Why / gotcha**: `commit` now has two lanes. The normal lane is still explicit: a broad request like "package the current safe/reasonable subset in this repo" is enough for it to infer sensible commit buckets, but source/docs/policy commits still require that explicit request. Separately, its periodic lane default comes from the role-owned metadata/shell files under `roles/`; that lane may autonomously commit only a strict runtime-dirt allow-list: agent `log.md`, `logbook.md`, `logbook.summary.md`, project `logbook.summary.md`, and archived `*.msg` audit files. It must not absorb `.instruct` edits, docs, scripts, environment files, central conductor bookkeeping, or live coordination state into that periodic lane. That periodic lane is threshold-gated: before it stages anything, it must run `python3 roles/operational/commit/commit_periodic_candidates.py --paths-only`; runtime text files stay uncommitted until they reach `CORTEX_COMMIT_PERIODIC_TEXT_MIN_CHANGED_LINES`, including `agents/commit/log.md`.
- **Why / gotcha**: the launcher refuses to start this worker until `CORTEX_DEFAULT_OPERATIONAL_REMOTE_URL` in the private environment settings matches a configured private Git push remote. A public export remote does not qualify; the `CONFIGURATION_REQUIRED` error tells the conductor to ask the user for setup rather than starting the worker.
- **Runtime note**: periodic `commit` wakes keep only `agents/commit/` writable. Explicit commit COMMANDs should name exact existing files/directories under `WRITABLE_PATHS:`; the launcher adds matching git metadata automatically and keeps `.git/hooks` read-only unless `COMMIT_RW_ALLOW_HOOKS: yes` is present.
- **Last verified**: 2026-05-07.

### Starting the `cleanup` worker

- **When**: you want a standing helper that periodically inspects the Cortex repo for stale, bounded cleanup candidates without interfering with active work.
- **Shortcut**:

  ```bash
  bash scripts/start_agent_screen.sh --role worker --name cleanup
  ```

  `roles/operational/worker.cleanup.instruct` is appended automatically because the worker id is `cleanup`.
- **Why / gotcha**: `cleanup` is suggest-only. Its default periodic cadence comes from `roles/operational/worker.cleanup.meta`, unless you override it at launch. It never stages, commits, pushes, or deletes during that standing loop. Its job is to surface candidate cleanup clusters and hand them off to `commit` or to you.
- **Last verified**: 2026-04-25.

### Starting the `consistency` worker

- **When**: you want a long-lived worker that checks whether Cortex instructions, docs, scripts, and examples contradict each other, have drifted apart, or carry material in the wrong durable home.
- **Shortcut**:

  ```bash
  bash scripts/start_agent_screen.sh --role worker --name consistency
  ```

  `roles/framework/worker.consistency.instruct` is appended automatically because the worker id is `consistency`.
- **Why / gotcha**: `consistency` is analysis-only by default. It is the right standing worker for ownership-boundary drift, including project-specific facts in environment sheets or framework rules buried in project docs. It defaults to Codex / `gpt-5.5` with high reasoning, writes periodic context to `agents/consistency/logbook.md`, and only forwards findings or problems to the conductor.
- **Last verified**: 2026-04-29.

### Starting specialist review workers

- **When**: you want recurring Cortex self-improvement review split by responsibility instead of one broad reviewer accumulating mixed findings.
- **Shortcut**:

  ```bash
  bash scripts/start_agent_screen.sh --role worker --name reliability
  bash scripts/start_agent_screen.sh --role worker --name memory
  ```

  Their named role overrides are appended automatically from `roles/framework/worker.reliability.instruct` and `roles/framework/worker.memory.instruct`.
- **Why / gotcha**: these are analysis-only recurring review workers with Codex / `gpt-5.5` / high-reasoning defaults and only their own agent directories writable. Their default periodic cadences come from their `worker.*.meta` files unless you override them at launch. Their Codex path uses a staged `CODEX_HOME`; keep the staged auth file present for the lifetime of the `codex exec` process, then remove the staged home after exit. Removing auth during startup/retry can produce `401 Unauthorized: Missing bearer` failures. `reliability` covers runtime health, stuck loops, stale agents, failed periodics, and recovery recipes. `memory` covers task/logbook/shortcut/archive hygiene and duplicate durable context. Commit/push/sync lag is now tracked by `cortex_doctor.sh --check git-sync-health` instead of a worker. They should report implementation-ready suggestions, not make repairs during periodic checks.
- **Last verified**: 2026-05-03.

### Starting the `calibration` worker

- **When**: you want a long-lived worker that reads each Cortex agent's logbook, recent log, and status traces and flags where the agent's observed behavior over time diverges from what its own role/instruct file describes (over-triggering, under-triggering, mandate drift, silent failures, repeated confusion patterns, instruction/environment mismatch).
- **Shortcut**:

  ```bash
  bash scripts/start_agent_screen.sh --role worker --name calibration
  ```

  `roles/framework/worker.calibration.instruct` is appended automatically because the worker id is `calibration`.
- **Why / gotcha**: `calibration` is analysis-only by default. Its deliverable is targeted instruction edits (which file, what passage, what tightening) rather than runtime repairs. Its default periodic cadence comes from `roles/framework/worker.calibration.meta`; only its own agent directory is writable. It rotates coverage across agents — do not expect every agent to be reviewed every wake. It is distinct from `consistency` (which checks file-vs-file agreement) and `reliability` (which checks runtime health).
- **Last verified**: 2026-05-18.

### Starting the `environment` worker

- **When**: you want a long-lived worker that verifies the recorded environment facts in `environments/<env>/cheat_sheet.md` and `environments/<env>/<env>.instruct` still match what the live hosts report (host inventory, GPU model/count, network identity, NAS topology, tooling presence).
- **Shortcut**:

  ```bash
  bash scripts/start_agent_screen.sh --role worker --name environment
  ```

  `roles/framework/worker.environment.instruct` is appended automatically because the worker id is `environment`.
- **Why / gotcha**: `environment` is analysis-only by default; it surfaces drift findings, the conductor applies the edits. It is the **only** Cortex worker with outbound SSH — the launcher gives it a narrow carve-out (read-only per-file binds for `~/.ssh/config` and `~/.ssh/known_hosts*` plus the live `SSH_AUTH_SOCK`, never the whole `~/.ssh` directory). Its default periodic cadence comes from `roles/framework/worker.environment.meta`; it rotates across 5 slices (inventory / GPU / network / NAS / tooling) so a full sweep completes every 4–5 wakes. Distinct from `consistency` (file-vs-file agreement), `reliability` (runtime health), and `security` (sandbox/credential posture).
- **Last verified**: 2026-05-18.

### Starting the `privacy` worker

- **When**: you want a long-lived worker that checks whether concrete user, project, host, path, or deployment-specific information has leaked upward into generic framework material.
- **Shortcut**:

  ```bash
  bash scripts/start_agent_screen.sh --role worker --name privacy
  ```

  `roles/framework/worker.privacy.instruct` is appended automatically because the worker id is `privacy`.
- **Why / gotcha**: `privacy` is analysis-only by default. It is narrower than `consistency`: `consistency` checks whether surfaces agree and whether knowledge lives in the right family of files, while `privacy` checks whether generic framework docs/scripts/prompts contain any concrete private deployment payload at all. Its default periodic cadence comes from `roles/framework/worker.privacy.meta`; durable findings go to `agents/privacy/logbook.md`.
- **Last verified**: 2026-06-02.

### Starting the `metacortex` worker

- **When**: you want Cortex to run one philosophical self-reflection cycle every
  24 hours and maintain its own living treatise.
- **Shortcut**:

  ```bash
  bash scripts/start_agent_screen.sh --role worker --name metacortex
  ```

- **Why / gotcha**: `metacortex` is a named framework worker. Its default
  cadence comes from `roles/framework/worker.metacortex.meta`; its durable
  philosophical surface is `agents/metacortex/notes.txt`. Periodic wakes should
  improve that notes file and report only a compact `CHECK: ok` response.
- **Last verified**: 2026-05-26.

### Worker periodic-check de-duplication

- **When**: a worker keeps reporting the same `CHECK: suggest`, provider `error`, or unparseable periodic result into `agents/conductor/inbox/`.
- **Shortcut**: inspect `agents/<worker>/worker_review_notify_state`; the launcher forwards the first non-OK fingerprint, forwards state/content changes immediately, suppresses exact repeats, and re-emits unchanged findings after 24h.
- **Why / gotcha**: this is only wrapper-side suppression. Workers should still use `agents/<worker>/logbook.md` as memory of what they already surfaced, avoid resending unchanged findings, and spend later checks on different bounded slices. Routine clean `CHECK: ok` results and recovery `CHECK: ok` results stay local; recovery is still recorded in `worker_review_notify_state` so a later recurrence is forwarded instead of suppressed.
- **Last verified**: 2026-05-14.

### Starting a deep-learning research cluster

- **When**: you want several persistent workers to collaborate on one scientific deep-learning problem with explicit roles instead of one broad agent doing planning, implementation, runs, and analysis.
- **Shortcut**:

  ```bash
  mkdir -p "${CORTEX_DEFAULT_ROOT}/projects/<project>/research"
  rsync -a "${CORTEX_DEFAULT_ROOT}/templates/research/" "${CORTEX_DEFAULT_ROOT}/projects/<project>/research/"

  export CORTEX_RESEARCH_PROJECT=<project>

  bash scripts/start_agent_screen.sh --role worker --name research-lead
  bash scripts/start_agent_screen.sh --role worker --name research-designer
  bash scripts/start_agent_screen.sh --role worker --name research-engineer
  bash scripts/start_agent_screen.sh --role worker --name research-runner
  bash scripts/start_agent_screen.sh --role worker --name research-analyst
  ```

  Fill `projects/<project>/research/mission.md`, then mirror the active mission into `agents/research-lead/mission.txt`. In that live mission, list only `research-lead` plus the specialists you actually launched for the cycle. Add optional specialists only when needed: `research-literature`, `research-theorist`, `research-critic`, and `research-scribe`.
- **Why / gotcha**: `research-lead` coordinates and runs the periodic check; the specialists are command-driven and report back to `research-lead`. Routine specialist↔lead handoffs should use `CONDUCTOR_NOTIFY: quiet`, so the conductor inbox only sees cycle-level summaries or explicit escalations instead of every internal step. The default lead cadence comes from `roles/research/worker.research-lead.meta`, unless you override it at launch. The launcher now binds write access only to inboxes for specialists named in the live mission and already launched, so an unlaunched optional specialist is a visible setup gap rather than a dark inbox. Setting `CORTEX_RESEARCH_PROJECT=<project>` (or passing it inline on each launch) auto-extends `CORTEX_WORKER_BWRAP_RW` to `projects/<project>/` for `research-lead` and every research specialist, so they can read/write the whole project tree without per-path enumeration. Add extra rw paths via `CORTEX_WORKER_BWRAP_RW` only when something outside `projects/<project>/` also needs writes. Final durable scientific conclusions still belong in the project logbook through the conductor.
- **Sandbox model — "broad read, fenced write"**: research workers read the **whole host read-only** (like the conductor) and write only inside their fence, so experiments never fight the environment and switching projects needs no read setup. Mechanics:
  - **Broad read**: `CORTEX_RESEARCH_RO_BASE` defaults to `/` — every research-team worker `--ro-bind`s the entire host. No per-project / per-dependency read allow-list ever (this is why scattered editable-install source roots under the user workspace, mounted dataset roots, and conda envs all just resolve). Set it to a narrower colon-list per host in `environments/<env>/settings.env` only if you want less than the whole host.
  - **Fenced write**: writes stay limited to `agents/<id>/` + the active project tree. The base is applied in the **pre-RW** layer so the RW binds (agent dir, project) override it for those subpaths; an autonomous loop cannot write anywhere else.
  - **Secrets masked**: `CORTEX_RESEARCH_RO_MASK` (default in `config/cortex_defaults.sh`) hides credential/secret paths back out of the broad read — `~/.ssh`, cloud creds (`~/.aws`, `~/.config/gcloud`), `~/.gnupg`, `~/.netrc`, `~/.git-credentials`, `~/.docker`, and `agents/conductor/secrets`. Dirs become an empty tmpfs, files an empty `/dev/null` bind. The **non-active provider's** creds are masked automatically too (a codex worker can't read `~/.claude*`, and vice-versa); the active provider's own creds stay available. Extend the mask per host in `settings.env` if you keep other secret paths.
  - Implemented in `roles/research/research.sh` (`append_research_ro_base` / `append_research_ro_mask`) + the pre-RW base and mask hook seams in `roles/worker.sh` + both launchers in `roles/worker.common.sh`; covered by the `research RO base` step in `scripts/tests/test_linux_framework_suite.sh`. The per-project `CORTEX_RESEARCH_PROJECT_RO_PATHS` in `research_runtime.env` remains as an additive post-RW escape hatch. Note: long-lived workers only pick up base/mask changes after a restart (binds are resolved at launch).
- **Last verified**: 2026-05-16.

### Starting the `supervisor` / `student` loop

- **When**: you want a bounded two-worker feedback loop where one worker reviews current state, assigns a small implementation round, and the other worker implements it and wakes the reviewer again.
- **Shortcut**:

  ```bash
  bash scripts/start_agent_screen.sh --role worker --name supervisor
  bash scripts/start_agent_screen.sh --role worker --name student
  ```

  Then write the live task into `agents/supervisor/mission.txt`. That
  file is the loop's watchfile-equivalent: a non-empty mission makes
  `supervisor` inspect, package the next round, and queue it to
  `student`; `student` implements the round and wakes `supervisor`
  again through the normal inbox transport.
- **Why / gotcha**: `supervisor` owns planning, not implementation. `student` is command-driven and should not invent side quests. `student` no longer gets repo-wide write access by default: each supervisor round must enumerate exact existing files/directories under `WRITABLE_PATHS:`, and the launcher derives a fresh per-round sandbox from that list (`TARGETS:` is accepted as a fallback for older rounds). Sensitive Cortex paths stay denied by default, including `.git/`, `roles/`, other agents' inboxes, and `agents/conductor/secrets/`; only a direct conductor COMMAND may override that with the wrapper-only line `STUDENT_RW_ALLOW_SENSITIVE: yes`. `supervisor` only gets partner-inbox write access by default, because its job is orchestration rather than editing. If you want the loop to stop after a bounded number of rounds, add `MAX_LOOPS: <N>` to `agents/supervisor/mission.txt`; once that many student rounds have been dispatched, the supervisor will stop and mark the mission `capped`.
- **Last verified**: 2026-04-26.

### Running the control-plane smoke harness

- **When**: you want a quick end-to-end check that worker COMMAND delivery, response envelopes, and the watch fast-path inbox guard still behave correctly.
- **Shortcut**:

  ```bash
  bash scripts/control_plane_smoke.sh
  ```

  Optional:

  ```bash
  bash scripts/control_plane_smoke.sh --agent efficiency
  bash scripts/control_plane_smoke.sh --timeout 180
  ```

- **Why / gotcha**: by default the harness launches a disposable one-shot worker, validates a real `COMMAND`→`RESPONSE` round-trip with colon-bearing `SUMMARY:` and multiline `DETAILS:`, then injects a synthetic unread conductor-inbox message into `agents/conductor/inbox/` and checks `scripts/watch.sh --fast-path-reason` reports `inbox has N unread` without consuming that message. The script cleans up its own temporary worker state and synthetic inbox/archive files afterward. Prefer this harness over ad-hoc `manual-smoke-*` workers; if an old transient smoke home does linger, default ops snapshots now hide it after 1 hour while `--all` still surfaces it for cleanup.
- **Last verified**: 2026-04-25.

### Restarting the watch agent

- **When**: the user asks to restart the currently running watch session (e.g. after a config tweak, stuck provider loop, or just to refresh). Watch file and interval should be preserved unless they say otherwise.
- **Shortcut**:

  ```bash
  # 1. capture current interval from the existing lock
  INTERVAL=$(awk -F= '/^INTERVAL=/{print $2}' \
    "${CORTEX_DEFAULT_ROOT}/agents/watch/lock/meta")

  # 2. stop current watch session (cooperative shutdown)
  bash "${CORTEX_DEFAULT_WATCH_SCRIPT}" --stop

  # 3. relaunch in the same screen session, reusing the existing
  #    watch file (default path) so the monitoring contract is preserved
  screen -dmS watch bash -lc \
    "exec > >(tee -a \"${CORTEX_DEFAULT_TMP_LOG_DIR}/watch.log\") 2>&1; \
     bash \"${CORTEX_DEFAULT_START_AGENT_SCRIPT}\" --role watch --interval \"${INTERVAL}\""

  # 4. verify
  cat "${CORTEX_DEFAULT_ROOT}/agents/watch/lock/meta" | \
    grep -E '^(MODE|PID|INTERVAL|START_TS)='
  screen -ls | grep watch
  ```

- **Why / gotcha**: do not pass `--watch` on restart — omitting it makes the watch agent reuse `agents/watch/watch.txt` verbatim, so custom instructions (e.g. "Signal every wake", "Telegram every wake", drunk-pirate tone, specific sweep focus) survive untouched. Restarts are still the right answer for config/provider issues, but they should no longer be needed just to refresh a stale launch-time `SSH_AUTH_SOCK`: watch now rebinds to a live local `ssh-agent` socket before each wake. Do not launch with a bare `&`; always wrap in `screen -dmS watch` to match the convention used at initial entry. Log the restart as a one-line `agents/conductor/log.md` entry; no central logbook entry (operational event). If a non-routine watch investigation needs a durable local note, it belongs in `agents/watch/logbook.md`.
- **Last verified**: 2026-04-24.

### Handling large project files in git

- **When**: deciding whether a bigger project file should be committed or kept out of normal git history.
- **Shortcut**: default `yes` for text-like, diff-friendly files up to `CORTEX_DEFAULT_GIT_TEXT_MAX_BYTES`, including logs, logbooks, message files, `*.csv`, configs, summaries, and similar files that are natural to git. Always track and commit `*.msg`, `*.py`, and `*.txt` files inside the repo, including untracked ones, unless they are secret-bearing, active live coordination files, or inside an explicitly excluded artifact tree. Always commit Cortex durable memory such as `agents/conductor/{tasks,log,logbook}.md`, `users/*/{tasks,ideas}.md`, `projects/*/logbook*.md`, and agent `log.md` / `logbook.md` memory files. Default `no` for binaries/media and artifact-style files such as checkpoints, model weights, images, PDFs, audio/video, tarballs, zips, and exported bundles. Also keep clearly ephemeral coordination files (`*.lock`, heartbeats, live status files, sockets, PID files, caches) out even though they may be text.
- **Why / gotcha**: this threshold is a default-yes limit for git-friendly text, not a license to add binary churn. The `backup` worker remains the fallback for larger live trees and bulky generated outputs.
- **Last verified**: 2026-04-25.

### Archiving retired task rows from a task board

- **When**: a `tasks.md` file has accumulated too many retired rows in `## Done` or `## Cancelled`, making active lookup noisy.
- **Shortcut**:

  ```bash
  bash roles/operational/compressor/rotate_tasks_done.sh
  ```

  Pass one or more paths for a targeted run, for example `bash roles/operational/compressor/rotate_tasks_done.sh projects/{project}/tasks.md users/{user}/tasks.md`. Override thresholds when needed, for example `KEEP_RECENT_DONE=15 DONE_ROTATE_MIN=25 KEEP_RECENT_CANCELLED=0 CANCELLED_ROTATE_MIN=5 ...`.
- **Why / gotcha**: this is now the deterministic execution path that the `compressor` worker should use for task-board retirement compaction. With no arguments, it scans task boards under `agents/`, `projects/`, and `users/`, then archives only boards whose live `## Done` rows exceed `DONE_ROTATE_MIN` or whose live `## Cancelled` rows exceed `CANCELLED_ROTATE_MIN`. It archives older retired rows verbatim into sibling `history/tasks_done_YYYY-MM-DD_HH-MM.md` or `history/tasks_cancelled_YYYY-MM-DD_HH-MM.md` shards, rebuilds each live pointer block, keeps the newest Done rows inline, and by default keeps no live Cancelled rows once that section is rotated. In no-arg / `--all` scan mode it now skips non-writable boards and section/status-mismatched boards with advisory warnings instead of aborting the whole sweep; if you target an explicit path and the board layout is invalid, it still exits non-zero so the drift gets surfaced directly. It never touches open/doing/blocked rows, and `memory` remains the worker that should detect when this cleanup is needed.
- **Last verified**: 2026-05-16.

### Promoting generalized user rules into Cortex specs

- **When**: the user gives a generalized operating rule or lasting preference rather than a one-off correction, for example commentary cadence, logging behavior, or how a whole class of tasks should be handled.
- **Shortcut**: apply the rule immediately, patch the governing spec in the same session (`roles/*.instruct`, root `user.instruct`, `users/{user}/{user}.instruct`, `PROTOCOL.md`, `README.md`, `projects/{project}/{project}.instruct`, or another source-of-truth file as appropriate), then update the owning task/logbook surface at the appropriate scope and commit. User-wide durable preferences belong in `users/{user}/{user}.instruct`; root `user.instruct` is only the default-user routing note. Project-specific rules belong in the owning project's `.instruct` file instead of the generic role specs. If the new rule is about inbox triage or agent reporting, encode the concrete `tasks.md` + user-surfacing behavior directly in `roles/conductor.instruct` rather than leaving it implicit. If the new rule fixes how an append-style file should be maintained, also correct any already-misordered live entry in that same session.
- **Why / gotcha**: if the rule lives only in chat, it will be lost on the next session. The durable spec edit is the real action; the bookkeeping just makes it discoverable later. Project-owned rules should stay close to the project rather than accreting inside `roles/conductor.instruct`. For inbox/reporting rules, vague wording is not enough; spell out when the conductor must create/update a task item and when the user must be told. If the rule changes a shared runtime convention such as where agent state lives, patch the launcher/runtime code, the protocol/docs (`PROTOCOL.md`, `README.md`), and any helper/allow-list files that encode that path (`scripts/control_plane_smoke.sh`, commit-worker scope rules, backup/sync helpers if applicable) in the same session. For logs and logbooks, "append-only" means chronological top-down: old at top, new at bottom.
- **Last verified**: 2026-04-25.

### Refreshing `watch.txt` when the mission changes

- **When**: the live workload being watched has changed materially mid-session, for example a new sweep batch replaces the old one, a dispatcher is intentionally retired, or a one-off watch mission has become obsolete.
- **Shortcut**: update `agents/watch/watch.txt` immediately in the same session so it names the current runs and current alert conditions; remove stale mission blocks instead of layering new instructions on top of obsolete ones. If the mission spans both shared-storage hosts and local-data hosts, say that explicitly and tell watch not to collapse status to the shared-storage subset.
- **Why / gotcha**: watch rereads `watch.txt` every wake and treats non-empty content as a live contract. If stale missions linger, watch keeps reasoning about the wrong runs and can generate repeated non-incidents. If mixed-host missions are phrased too loosely, watch may report only the easy shared-storage half and silently miss lost capacity on local-data hosts.
- **Last verified**: 2026-04-24.

### Checking whether a project path is actually shared

- **When**: about to fan a read-only inventory / classification task across multiple agents for a project dir.
- **Shortcut**: `readlink -f <path>` on one host first. If it resolves into a shared mount, only one agent needs to run the task.
- **Why / gotcha**: saves redundant work and avoids split-brain results when two agents inspect the same physical directory.
- **Last verified**: 2026-04-18.

### Syncing framework changes to the public cortex repo

- **When**: after any change to framework files (scripts, role prompts, specs) that should be reflected in the configured public `cortex` remote.
- **Shortcut**: `bash scripts/cortex_doctor.sh --check public-manifest --check public-sync` first. Inspect the diff since the latest public export plus its source commits, write one factual sentence describing the actual change, then run `bash scripts/sync_public.sh --dry-run` and `bash scripts/sync_public.sh --subject "cortex: ..."` only after the dry-run surface is clean. If the live worktree is dirty, run the dry-run from a clean clone or a clean branch checkout; a detached worktree is unsupported because the export records its symbolic source branch. The doctor should catch both known leak patterns and tracked public-looking framework files that were added outside the export manifest.
- **Why / gotcha**: git `master` keeps full commits (notes, logs, users, environments, projects, runtime state, experiment state). Public sync is an export operation, not a live-branch push. The export must include only sanitized framework files and templates, such as `user.instruct.example`, never the live private default-user router, per-user `users/<user>/<user>.instruct` profiles, live `environments/`, live `projects/`, `agents/`, inboxes, archives, logs, or private git history. Include the public `LICENSE` in the export manifest; its standard copyright line is intentionally allowed, while its remaining content is still scanned. The leak scan includes test fixtures, so sample hosts, users, and paths must be neutral too. A root commit is only appropriate when bootstrapping a missing public branch or intentionally replacing a contaminated public branch.
- **Last verified**: 2026-08-25.

### Quieting routine peer worker loops

- **When**: a pair of workers coordinates directly through each other's inboxes and the conductor is seeing every successful handoff mirrored back as redundant `RESPONSE` traffic.
- **Shortcut**: put `CONDUCTOR_NOTIFY: quiet` at the top of those inter-worker COMMAND bodies. `scripts/start_agent.sh` strips the line before prompting the worker and suppresses only the successful conductor echo for that one COMMAND.
- **Why / gotcha**: this keeps the direct inbox-to-inbox loop intact while still letting provider failures and worker `STATUS: warning|error` replies surface to the conductor.
- **Last verified**: 2026-04-26.

### Recovering split-brain watch conductor state

- **When**: `scripts/watch.sh` processes and `agents/watch/lock/meta` disagree, or more than one watch process tree is alive on the configured watch host.
- **Shortcut**: on the configured watch host, kill the known watch script / screen PIDs, clear `agents/watch/lock/`, then relaunch exactly one detached screen from the Cortex repo root:
  `screen -dmS watch bash -lc 'cd /path/to/cortex && bash ./scripts/watch.sh --interval 7200'`
- **Why / gotcha**: a stray watch process can survive after the lock owner dies, so "one process left" is not enough; the surviving process and the lock must match. Verify by checking both `screen -ls` and `agents/watch/lock/meta`.
- **Last verified**: 2026-04-21.

### Selecting and killing low-epoch W&B sweep processes

- **When**: you need to terminate only some `train.py` processes from a sweep based on epoch limits.
- **Shortcut**: `ps -eo pid=,args= | python` to filter on sweep id and `train.py`, then parse `--epochs`, `--max_epochs`, `--num_train_epochs`, etc., and `os.kill(pid, signal.SIGTERM)` only for values below the threshold.
- **Why / gotcha**: sweep agents often hide the epoch value in varied flag spellings, and the raw prompt text can contain `train.py` and the sweep id, so the executable/name filter matters before deciding to kill.
- **Last verified**: 2026-04-18.

### Stopping `wandb agent` sweep launchers

- **When**: you need to stop sweep config pickers but leave currently running `train.py` runs alone.
- **Shortcut**: `ps -eo pid=,ppid=,stat=,args= | rg 'wandb agent'` to collect launcher PIDs, `kill -TERM <pids>`, `sleep 5`, and `kill -KILL` any survivors; verify with `ps -p <pids>`.
- **Why / gotcha**: broad `ps | rg wandb` checks can match your own command line, so always verify the exact PID list before declaring success.
- **Last verified**: 2026-04-18.

### Conductor startup routine

- **When**: the conductor was started with `--startup-checks` (its initial prompt says "perform the startup-checks routine"). This is the opt-in full routine; the default startup path only reads instruction files, counts inbox filenames without inspecting their bodies, and gives its short startup message. Even the checks routine stays lightweight — see the role spec for the policy carve-outs (do not auto-read shortcut books, environment cheat sheets, or agent status files; pull them in on demand).
- **Shortcut**:
  1. Read the last 50 lines of `agents/conductor/log.md`.
  2. Read open conductor tasks with a targeted grep so only the open lines land in context:
     ```bash
     rg '^- \[open\]' agents/conductor/tasks.md
     ```
  3. Resolve the current user via root `user.instruct`, then read `[open]` lines in `users/{user}/tasks.md`. Reminders may carry `REMINDER (due YYYY-MM-DD): ...`; surface any whose due date is on or before today.
  4. Drain `agents/conductor/inbox/` — self-check alerts first (STATUS with body prefixed `TYPE: selfcheck_alert`), then other unread. Archive what you read; open or update a `tasks.md` item for any non-trivial agent message before continuing.
  5. Only if the log tail or inbox references an unclear experiment / training / data-work thread, read the last 1–2 `##` sections of `agents/conductor/logbook.md` (tail-first; expand upward only if still unclear).
  6. If root `user.instruct` is missing, suggest creating it and pointing it at `users/<user>/<user>.instruct`.
  7. If local setup is initialized, check whether the core persistent operational workers are actually running (derive from current framework metadata, not a hardcoded roster). Suggest starting any that are absent or stale.
  8. Give the user a short reminder of the last thread (plus any due reminders) and a summary of inbox items.
  9. If an obvious continuation follows, suggest at most 2 concrete next steps.
- **Why / gotcha**: this is the recipe form of the conductor's opt-in startup-checks routine (`--startup-checks`). The default minimal startup runs none of these steps. The policy carve-outs (lightweight only, no proactive shortcut/cheat-sheet read, non-trivial reports must be promoted to `tasks.md`) live in `roles/conductor.instruct` and stay there.
- **Last verified**: 2026-05-30.

### Conductor on-demand status overview

- **When**: the user asks for current system state, "what needs attention", or a startup-style overview. Do not run this proactively; the startup-checks routine already covers chat-entry state.
- **Shortcut**:
  1. ```bash
     bash scripts/cortex_ops_snapshot.sh
     ```
     Human-readable operator view (Critical / Warnings / Active / Quiet) covering queues, conductor task counts, active project runs, periodic health, core worker liveness / provider cooldowns, backup freshness, and `watch.txt` activity. Always start here to avoid ad-hoc directory digging.
  2. Last 50 lines of `agents/conductor/log.md`.
  3. If the thread is experiment / training / data-work related and still unclear, read the last 1–2 `##` sections of `agents/conductor/logbook.md` (expand upward only if unclear; use tags for cross-entry lookups).
  4. `agents/conductor/tasks.md` — only the lines the snapshot flagged or the tier calls for. Include open `users/{user}/tasks.md` lines when the request is general or when due reminders may be relevant.
  5. `agents/conductor/inbox/` — self-check alerts first, then other unread.
  6. If local setup is initialized and core persistent operational workers are not running, suggest starting the missing / stale ones as part of the overview.
  7. Tell the user where attention should go. If nothing urgent: one sentence on overall state.
  8. Update `tasks.md` and `log.md` per tier; update `logbook.md` only if the review surfaced experiment / training / data-work results or decisions that belong there.
- **Why / gotcha**: this is a deliberate, user-triggered snapshot pass (it overlaps the opt-in startup-checks routine but is on-demand). Keep it user-triggered — the conductor should not re-run it on every chat entry.
- **Last verified**: 2026-05-30.

### Queueing a commit-worker COMMAND

- **When**: routine commit packaging that the chat conductor does not need to block on, or any commit-scoped follow-up the `commit` worker should run for you.
- **Shortcut**: before queueing, do the conductor-owned bookkeeping the tier requires (update `tasks.md`, `agents/conductor/log.md`, and project logbooks at the right abstraction level). Then queue a precise COMMAND to `agents/commit/inbox/` naming:
  - the repo,
  - the branch expectation,
  - the commit scope (`all changes`, named files, or `staged-only`),
  - a `WRITABLE_PATHS:` block enumerating the exact existing files / directories the commit task may need (`TARGETS:` is a fallback for older commands, not the preferred form).
  Add `COMMIT_RW_ALLOW_HOOKS: yes` only when the command explicitly needs to write to `.git/hooks` — the launcher keeps that path read-only by default.
- **Why / gotcha**: outside its narrow autonomous periodic lane (runtime logs / logbook summaries / archive messages — see `roles/operational/worker.commit.instruct`), `commit` requires explicit COMMAND authorization and must never push, amend, reset, or include unrelated dirty state. Vague scope wording leads to over-broad commits; be specific.
- **Last verified**: 2026-05-30.

### Draining the conductor inbox

- **When**: the user asks "any updates from agents?" or you are working through unread `RESPONSE` / `STATUS` / `worker_periodic_check` messages in `agents/conductor/inbox/`.
- **Shortcut**:
  1. Read `agents/conductor/inbox/` and show the user each `RESPONSE` body. Self-check alerts (STATUS with body prefixed `TYPE: selfcheck_alert`) come first.
  2. For each message, ask: would future-you be annoyed if this stayed only in `agents/conductor/inbox/` / archive? If yes, the report is **non-trivial** — open or update a `tasks.md` entry capturing the follow-up, owner, and next step, and surface it to the user explicitly (immediately if chat is active; otherwise in the next startup reminder).
  3. Map matching `tasks.md` entries via `TASK_ID` / `REF`; archive what you read.
  4. To check whether a specific queued command is done, grep the inbox for `REF: <msg_id>` and inspect the agent's status file.
- **Why / gotcha**: periodic efficiency reports, worker clarification requests, failure reports, and substantive status findings are the most common non-trivial categories — do not bury them in archive-only handling. During active chat, report in chat; do not duplicate via Signal unless asked. Outgoing Signal is conductor-restricted to (a) explicit user requests in chat and (b) `tasks.md` delayed messages whose due date has arrived.
- **Last verified**: 2026-05-30.

### Conductor bookkeeping

- **When**: creating, updating, or closing standard/heavy work, or recording
  a durable result.
- **Shortcut**:
  - Place cross-project/fleet work in `agents/conductor/tasks.md`, user
    reminders in `users/{user}/tasks.md`, and project-owned work in
    `projects/{project}/tasks.md`.
  - Use `- [status] TASK_ID | owner | priority | summary | latest_msg | notes`
    with `TYYYYMMDD-XX` identifiers. Set `doing` only while an executor or
    fresh evidence exists; otherwise use `open`, `blocked`, or `cancelled`.
    Keep notes as an operational pointer, not a journal.
  - A tracked COMMAND includes `TASK_ID`, sets the owning row to `doing` with
    its `MSG_ID`, and maps its RESPONSE through `TASK_ID` / `REF`.
  - Every project task gets a project-logbook entry plus a one-line conductor
    log pointer. The central conductor logbook is only for cross-project or
    project-agnostic results-bearing technical work; routine coordination
    stays in `log.md`.
  - Logbook entries use `## [ISO_TIMESTAMP] — topic {#tag}` and terse bullets.
    Reuse a thread tag; include numeric results in the same form shown to the
    user. `compressor` owns rotation and summaries.
  - Closure pairings (same step, never a follow-up): a logbook entry naming a
    `TASK_ID` flips its row and puts the `{#tag}` in notes; archiving a
    RESPONSE with `TASK_ID`/`REF` first sets the row (`done`/`blocked`/`open`)
    with the new `MSG_ID`; a chat answer reporting a result closes the row
    before it is sent; a "launch X" row is `done` once the launch is verified
    (open a separate row only if a decision waits on the result); opening a
    superseding task marks the old one `cancelled` with `superseded by T...`.
- **Why / gotcha**: task state is current operational truth, while logbooks
  preserve conclusions and numeric results. Do not leave stale work as
  `doing`, or duplicate a project result in the central logbook. The
  2026-08-25 sweep cancelled 112 aged rows, about half already finished —
  closure had no trigger.
- **Last verified**: 2026-09-02.
