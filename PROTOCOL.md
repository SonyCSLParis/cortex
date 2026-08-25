# Cortex Protocol v1.0

**Cortex** is a lightweight file-based orchestration framework for distributed agent CLIs.

## Overview

Cortex is a fleet of agents. Each agent lives under `agents/{id}/` and
communicates via file-based inbox queues. Agents differ by **role**:

- `conductor` — on-demand interactive agent at `agents/conductor/`. The
  one human-facing role: one or more chat sessions with the user that
  coordinate the rest of the fleet. Other agents send work **upward** to
  `agents/conductor/inbox/`; the conductor sends work **downward** to
  `agents/{id}/inbox/`. Parallel conductor windows share inbox and
  bookkeeping files; only runtime metadata is split per session under
  `agents/conductor/sessions/`. An offline `agents/conductor/` between
  sessions is normal.
- `node` — read/compute-only agent, one per server (default).
  Started directly by `scripts/start_agent.sh` (or `scripts/start_agent.sh --role node`);
  long-lived screen-backed launches can use `scripts/start_agent_screen.sh --role node`.
- `worker` — elevated task-execution agent using the same inbox /
  response runtime as `node`, but with full host permissions and a
  stricter destructive-action contract. Started directly by
  `scripts/start_agent.sh --role worker --name <id>`; long-lived
  screen-backed launches can use
  `scripts/start_agent_screen.sh --role worker --name <id>`.
  Workers come in two runtime modes:
  - `one_shot` — typically launched with `--once`; exits after one
    personal COMMAND
  - `persistent` — long-lived named worker with a stable
    responsibility; may keep a local `agents/{id}/logbook.md`
- `watch` — elevated-permission agent at `agents/watch/`, running
  on an interval loop. Can queue COMMANDs to other agents and send
  Signal. Started by `scripts/start_agent.sh --role watch` (which execs
  `scripts/watch.sh`). Coexists with the conductor; only one
  watch session may run at a time, enforced by a watch-exclusion
  lock at `agents/watch/lock/`. Raw messenger ingress is separate from
  the watch agent's own inbox: Signal and Telegram inbox daemons write
  to `inboxes/signal/` and `inboxes/telegram/`, and the watch wrapper
  drains those as inbound data.

Adding a new agent type means defining its role addendum (an
`agent_<role>.instruct` file) and starting it with the appropriate
launcher. The wire protocol is the same for every role.

Provider choice does **not** override role permissions. Node agents stay
read/compute-only regardless of provider; the launcher must keep them in a
non-destructive mode rather than bypassing approvals/sandboxing. Worker agents
must stay inside launcher-enforced sandboxes: the worker's own
`agents/{id}` directory is writable by default, and any broader write access
must be a narrow named allow-list (for example `backup`'s snapshot root or
`CORTEX_WORKER_BWRAP_RW` at launch). Current enforcement: Codex nodes run with
a read-only Codex sandbox; Codex workers run inside launcher `bwrap`
sandboxes with explicit write allow-lists plus a staged minimal `CODEX_HOME`
copy in a private per-run temp directory so the full real `~/.codex` tree is
not mounted into the worker filesystem or left behind under `agents/*`. The
launcher may also be given a fallback provider (`FALLBACK_PROVIDER`) plus a
cooldown window for quota/auth failures; this changes retry behavior only, not
the role's permissions or sandbox boundaries. The
`student` worker is narrower still: beyond its own local
state and `agents/supervisor/inbox/`, it gets per-COMMAND write access only
to exact existing files/directories named under `WRITABLE_PATHS:` (or
`TARGETS:` as a compatibility fallback), while `.git/`, `roles/`, other
agents' inboxes, and `agents/conductor/secrets/` stay denied unless the
conductor sends a direct one-off student COMMAND with the wrapper-only line
`STUDENT_RW_ALLOW_SENSITIVE: yes`. The `commit` worker is also special:
its periodic checks keep only `agents/commit/` writable by default, while
explicit COMMANDs may grant exact `WRITABLE_PATHS:` / `TARGETS:` plus the
matching repo's git metadata; `.git/hooks` stays read-only unless the
conductor explicitly adds `COMMIT_RW_ALLOW_HOOKS: yes`. Claude nodes and workers run inside a
`bwrap` sandbox with PID isolation, and Claude gets only a scratch
`~/.claude/session-env` bind writable.

All communication happens by writing/reading files under `CORTEX_DEFAULT_ROOT`.
This directory must be shared or replicated across servers (e.g. NFS, rsync, or
each server has its own copy and you SSH in to plant commands).

---

## Directory Layout

```
${CORTEX_DEFAULT_ROOT}/
├── PROTOCOL.md              ← this file (wire spec)
├── user.instruct            ← private local default-user routing note
├── user.instruct.example    ← sanitized public template for that routing note
├── environment.instruct     ← private local default-environment routing note
├── environment.instruct.example ← sanitized public template for that routing note
├── CONDUCTOR.md             ← provider-neutral conductor bootstrap context
├── CLAUDE.md                ← Claude auto-load shim; points to CONDUCTOR.md
├── roles/
│   ├── conductor.instruct      ← conductor's complete operating manual
│   ├── node.instruct  ← node-role template (prepended to every COMMAND)
│   ├── worker.instruct ← worker-role template (prepended to worker COMMANDs)
│   ├── operational/
│   │   └── worker.<name>.instruct ← named worker overrides for operational roles
│   ├── framework/
│   │   └── worker.<name>.instruct ← named worker overrides for framework review roles
│   ├── loop/
│   │   └── worker.<name>.instruct ← named worker overrides for supervisor/student loops
│   ├── research/
│   │   └── worker.<name>.instruct ← named worker overrides for research specialists
│   ├── watch.instruct ← watch-agent role template
│   └── self_check.instruct  ← node periodic-self-check prompt template
├── environments/
│   └── <env>/
│       ├── <env>.instruct    ← private infrastructure facts used by prompts
│       ├── settings.env      ← private runtime defaults for this environment
│       ├── backup_targets.txt ← private backup manifest for this environment
│       ├── backup_excludes/  ← private per-mode rsync exclude files for backup
│       └── cheat_sheet.md    ← private environment reference / gotchas
├── projects/
│   └── {project}/
│       ├── tasks.md         ← project-owned task board
│       ├── {project}.instruct ← optional project-owned durable instructions / policies
│       ├── logbook.md       ← project-specific durable work log
│       ├── runs/            ← one Markdown record per tracked run/job
│       ├── shortcuts.md     ← project-specific reusable recipes and gotchas
│       └── ...              ← project-specific notes / helpers when needed
├── users/
│   └── {user}/
│       ├── {user}.instruct  ← user-specific durable preferences across projects
│       ├── tasks.md         ← user-specific reminders and follow-up
│       ├── ideas.md         ← user-specific speculative thoughts
│       └── usage/usage.tsv  ← user-owned provider usage/cost ledger
├── cortex.sh                ← chat conductor launcher (operator view + drop into Claude/Codex)
├── scripts/watch.sh          ← watch-agent loop (aliased via scripts/start_agent.sh --role watch)
├── scripts/start_agent.sh           ← agent bootstrap (--role node|worker|watch)
├── scripts/start_agent_screen.sh    ← idempotent screen wrapper for node/worker/watch starts
├── scripts/run_registry.py          ← create/update/list project run records
├── scripts/usage_report.py          ← summarize user-owned provider usage/costs
├── inboxes/
│   ├── signal/              ← inbound Signal envelopes for watch (daemon-written)
│   └── telegram/            ← inbound Telegram envelopes for watch (daemon-written)
│
├── agents/                  ← live agent registry (one subdir per agent)
│   ├── conductor/           ← on-demand interactive control-plane agent
│   │   ├── info             ← aggregate conductor runtime metadata
│   │   ├── heartbeat        ← latest active conductor heartbeat
│   │   ├── status           ← aggregate idle | offline
│   │   ├── active_sessions.tsv ← current live conductor sessions
│   │   ├── tasks.md         ← conductor cross-project / operational task board
│   │   ├── log.md           ← terse append-only activity log
│   │   ├── logbook.md       ← experiment / training / data-work log
│   │   ├── logbook.summary.md ← compact index over live + history
│   │   ├── history/         ← archived full logbook sections
│   │   ├── inbox/           ← upward queue from agents to conductor
│   │   ├── archive/         ← conductor-archived inbox messages
│   │   └── sessions/        ← per-window runtime state (`info`, `heartbeat`, `status`)
│   ├── {agent_id}/          ← node or worker agent
│   │   ├── info             ← static metadata written on registration
│   │   ├── heartbeat        ← unix timestamp, overwritten every poll cycle
│   │   ├── status           ← idle | busy | selfcheck | offline
│   │   ├── log.md           ← terse append-only activity log (agent-exclusive)
│   │   ├── logbook.md       ← optional local durable notes for persistent workers
│   │   ├── inbox/           ← commands queued for this agent (FIFO by name)
│   │   ├── archive/         ← processed COMMANDs and broadcast .seen markers
│   │   ├── status_latest.snapshot      ← current periodic node status snapshot
│   │   ├── selfcheck_latest.snapshot   ← most recent self-check snapshot
│   │   ├── selfcheck_previous.snapshot ← prior snapshot (kept for diffing)
│   │   └── selfcheck_last_ts           ← unix ts of last self-check run
│   └── watch/               ← watch agent (single instance per fleet)
│       ├── info             ← registration metadata
│       ├── heartbeat        ← ticked every 10 s while the loop is alive
│       ├── status           ← idle | busy | offline
│       ├── log.md           ← terse append-only activity log (watch-exclusive)
│       ├── logbook.md       ← durable watch-only incident / action log
│       ├── inbox/           ← per-wake conductor directives addressed to watch
│       ├── archive/         ← processed watch-inbox commands
│       ├── watch.txt        ← free-form mission contract (reread every wake)
│       ├── last_signal      ← outgoing-Signal dedup state
│       └── lock/            ← watch-exclusion lock + stop_requested / wake_now flags
│
├── broadcast/               ← conductor writes here; every agent picks up & responds
├── logs/                    ← per-agent append-only wrapper logs
│   └── {agent_id}.log
└── archive/                 ← legacy/historical root-level archives only (if any)
```

---

## Agent Identity

`AGENT_ID` defaults to `$(hostname)` and must be unique across the whole
fleet. To run more than one agent on a single server, launch each with a
distinct id via `scripts/start_agent.sh --name <id>` (or the `AGENT_NAME` env var).
Valid ids match `[A-Za-z0-9._-]+`. Names identify the agent by purpose or
server, never by model or provider. Prefer direct responsibility names for
named workers, using the current role-owned worker ids rather than
metaphorical labels or a protocol-local roster copy. Common conventions when multiplexing: `host-a-1` /
`host-a-2`, or purpose suffixes like `trainer` / `eval`.
The underlying provider or model is internal configuration, not part of the
identity.

All keying (`agents/{id}/`, `agents/{id}/archive/`, `logs/{id}.log`, and the
`{id}` slot in conductor-inbox filenames) uses `AGENT_ID`, so two agents on the
same host get fully independent state as long as their ids differ.

---

## Public / Private Boundary

The wire protocol and framework runtime are public framework material;
live operational state is not. Generic protocol/docs/scripts may define
paths such as `users/{user}/`, `environments/{env}/`, and
`projects/{project}/`, but they must not embed the concrete values from a
live deployment.

Public framework exports may include sanitized templates and examples,
but must exclude live user profiles, environment folders, project
folders, agent homes, inbox/archive contents, logs, status snapshots,
heartbeats, locks, and private git history. Concrete deployment facts
belong in `users/`, `environments/`, or `projects/` inside the private
operational checkout.

---

## Run Records

Project run records live under `projects/{project}/runs/RYYYYMMDD-NN.md`.
They track concrete execution instances that Cortex may need to revisit:
experiments, evals, sweeps, server processes, and long-running remote data
jobs. A run is the logical job. A multi-host sweep remains one run with
multiple execution lines inside the same file.

Use `scripts/run_registry.py` to create/update/list records. The file remains
plain Markdown, with simple header fields (`RUN_ID`, `PROJECT`, `TASK_ID`,
`STATUS`, `TITLE`, timestamps, `WATCH_POLICY`, `SUMMARY`) followed by
`## Executions`, `## Outputs`, and `## Notes`.

Use `scripts/reconcile_runs.py` to compare active records with observed
environment state. The reconciler may add or update `OBSERVED_STATUS`,
`OBSERVED_PHASE`, `OBSERVED_GPU`, `LAST_OBSERVED_AT`,
`LAST_OBSERVED_SOURCE`, and `OBSERVED_DETAIL`. These fields are operational
evidence, not commands: reconciliation never authorizes killing, restarting,
or launching a process.

Status values are:

- run-level: `planned`, `running`, `unknown`, `done`, `failed`, `stopped`
- execution-level: the same values, one line per host/session/process slot

`scripts/cortex_ops_snapshot.sh` lists active run records (`planned`,
`running`, `unknown`) so the operator view is aware of tracked work, not only
agent heartbeats.

---

## Message Envelope

Every file (command, response, broadcast, ack) uses the same format:

```
MSG_ID: {unix_ts}_{4hex}
FROM:   {agent_id | conductor}
TO:     {agent_id | conductor | broadcast}
TYPE:   {COMMAND | RESPONSE | BROADCAST | STATUS | worker_periodic_check}
TIME:   {unix_epoch}
REF:    {msg_id of the message this replies to, or none}
STATUS: {pending | done | error | warning}  # status of the work being reported
---
{free-form body — output, instructions, logs, JSON, etc.}
```

`TIME` is always the local system time of the machine that wrote the
envelope, captured at envelope-write time. It is never a provider
artifact timestamp, remote messenger timestamp, or other copied external
event time.

### Parsing
- Headers: `KEY: VALUE` (grep `^KEY:`, awk on `: `)
- Body: everything after the first `---` line
- **Atomic writes**: always write to `{file}.tmp` then `mv` to `{file}`
  (prevents partial reads by the other side)
- Wrapper-consumed control lines may appear at the top of a COMMAND
  body. Current control lines:
  `CONDUCTOR_NOTIFY: quiet` suppresses the usual successful
  COMMAND→conductor `RESPONSE` echo for that one COMMAND, while still
  forwarding warning/error outcomes. The research cluster uses this for
  routine specialist↔lead handoffs so internal progress stays inside the
  cluster unless an explicit blocker/escalation is being raised.
  `STUDENT_RW_ALLOW_SENSITIVE: yes` lets a direct conductor→student
  COMMAND opt into otherwise-denied sensitive paths.
  `COMMIT_RW_ALLOW_HOOKS: yes` lets a direct conductor→commit COMMAND
  make `.git/hooks` writable when the task explicitly requires hook
  edits.
  The launcher strips wrapper-only control lines before invoking the
  provider CLI.

---

## File Naming

### Agent inbox
```
{priority}_{unix_ts}_{4hex}.msg
```
- priority digit: `0`=high · `1`=normal · `2`=low
- alphabetical sort → priority-then-FIFO order (priority first so a
  `0_...` message jumps ahead of any `1_...`/`2_...` already queued)

Example: `1_1713123456_a3f2.msg`

### Conductor inbox / broadcast
```
{unix_ts}_{from_agent}_{4hex}.msg
```

---

## Message Types

| Type        | Direction        | Purpose                                  |
|-------------|------------------|------------------------------------------|
| `COMMAND`   | conductor → agent   | Task for a specific agent                |
| `BROADCAST` | conductor → all     | Task or notice sent to every agent       |
| `RESPONSE`  | agent → conductor   | Result of a COMMAND or BROADCAST         |
| `STATUS`    | agent → conductor   | Unprompted status update (online announce, self-check alert) |
| `worker_periodic_check` | worker → conductor | Result of a persistent worker's periodic check |

---

## Node / Worker Lifecycle

```
scripts/start_agent.sh starts (`node` or `worker`)
       │
       ▼
  register()        ← write agents/{id}/info + agents/{id}/status = idle
                   ← persistent workers also seed agents/{id}/logbook.md
       │
       ▼
  announce_online() ← drop STATUS msg in agents/conductor/inbox
       │
       ▼
  ┌── POLL LOOP every 10 s ─────────────────────────────────────────┐
  │  1. echo $(date +%s) > agents/{id}/heartbeat                    │
  │  2. for each unseen file in broadcast/ (sorted):                │
  │       process, RESPONSE to agents/conductor/inbox, touch .seen  │
  │       marker                                                    │
  │       (broadcast file is NOT moved — other agents need it too)  │
  │  3. cmd = oldest file in agents/{id}/inbox/                     │
  │     if exists:                                                   │
  │       set status = busy                                          │
  │       result = {provider_cli} "{agent_<role>.instruct}\n\nCOMMAND:\n{body}" │
  │       write RESPONSE to agents/conductor/inbox/                 │
  │       move cmd to agents/{id}/archive/                           │
  │       set status = idle                                          │
  │  4. if role=worker and persistent and                            │
  │         now - worker_review_last_ts >= WORKER_REVIEW_INTERVAL:   │
  │       run periodic worker check (optional; role-specific)        │
  │  5. if idle and now - selfcheck_last_ts >= SELFCHECK_INTERVAL:   │
  │       set status = selfcheck                                     │
  │       run_self_check() (see Periodic Self-Check section)         │
  │       set status = idle                                          │
  │  6. if idle and now - statusreport_last_ts >= STATUSREPORT_INTERVAL: │
  │       run_status_report() — bash-only GPU+screen → agents/{id}/status_latest.snapshot │
  └─────────────────────────────────────────────────────────────────┘
```

One command at a time per agent. The inbox is a stable queue. Workers may be
launched with `--once`, in which case they run in `one_shot` mode and exit
after completing one personal COMMAND. Without `--once`, workers run in
`persistent` mode by default.

---

## Periodic Self-Check

Each node agent runs a scheduled self-check every `SELFCHECK_INTERVAL`
seconds (default: `CORTEX_DEFAULT_SELFCHECK_INTERVAL_SECONDS`; set to `0` to disable). The goal is
for agents to proactively surface problems — dead training runs, NaN loss,
OOMs, disk pressure, missing screens — without the conductor having to poll.
Workers default to `SELFCHECK_INTERVAL=0` and `STATUSREPORT_INTERVAL=0`,
because they are intended for task execution rather than ambient monitoring.
These are defaults, not structural restrictions: a persistent worker may opt
into periodic self-checks or status reports via env at launch time.
Persistent workers may also opt into a worker-specific periodic check loop via
`WORKER_REVIEW_INTERVAL`. That check uses the normal worker prompt plus any
optional `roles/<category>/worker.<name>.instruct` override and is intended for
responsibility-specific analysis (for example a named `efficiency` worker).
Named-check workers may define stricter check output contracts in their
override; `efficiency` uses this to package periodic findings as
implementation-ready optimization tickets, `backup` uses the same
periodic-check hook to run the deterministic
`roles/operational/backup/backup_snapshot.sh`
maintenance flow against the configured environment backup manifest, and `commit` uses it for
a narrow autonomous runtime-dirt commit lane while still requiring
explicit COMMANDs for everything broader.
The named `consistency` worker uses the hook to write local logbook
reports about instruction / spec drift. Like other workers, clean
`CHECK: ok` results stay local.
The named `reliability` and `memory` workers are narrower
analysis-only review specialists: runtime health/recovery and
durable-state hygiene respectively. They
write local logbook reports and surface only changed findings or recovery
states upward under the normal worker periodic-check de-duplication
rules.
The `research-*` workers are a project-facing deep-learning research
cluster. `research-lead` reads `agents/research-lead/mission.txt`, runs
a 15-minute coordination check by default, and queues bounded work to
specialists such as `research-designer`, `research-engineer`,
`research-runner`, and `research-analyst`. Specialists are
command-driven by default and report back to `research-lead` via quiet
internal COMMAND handoffs; routine specialist progress stays local, and
the conductor inbox should see only cycle-level lead summaries or
explicit fallback escalations. Research-worker sandboxing follows the
live broad-read / fenced-write contract: `CORTEX_RESEARCH_RO_BASE`
defaults to `/` for host-wide read-only visibility, `CORTEX_RESEARCH_PROJECT`
auto-adds `projects/<project>/` as the active write fence, and
`CORTEX_RESEARCH_PROJECT_RO_PATHS` remains an additive read-only escape
hatch for extra paths. When the mission names an existing
`TARGET_FOLDER`, research-worker local state files (`log.md`,
`logbook.md`, lead `cluster_state.md` / `last_cycle.md`, and similar
worker-owned notes) live under `TARGET_FOLDER/<agent-id>/`, while
control-plane files stay under `agents/<id>/`.

The wrapper de-duplicates repeated non-OK worker periodic-check reports
per worker. It records the last reported `error` / `suggest` /
`unparseable` fingerprint in `agents/{id}/worker_review_notify_state`,
forwards state or fingerprint changes immediately, and re-emits an
unchanged finding after 24 hours. A worker that recovers from a
previously forwarded non-OK state records the recovery locally as
`CHECK: ok`, so a future recurrence is forwarded instead of suppressed;
the recovery itself stays out of the conductor inbox. Routine clean
checks remain local.

This wrapper de-duplication is only a delivery backstop. Review-style
agents are expected to use their own local logbook memory to avoid
re-reporting unchanged findings upward and to use later wakes on
different bounded slices unless the evidence materially changed or the
conductor explicitly asked for the old issue again.

Every provider prompt includes `MACHINE_TIME_UTC`,
`MACHINE_TIME_LOCAL`, and `MACHINE_EPOCH_UTC`. Agents must use those
fields, or a fresh `date` call, when writing log/logbook timestamps; the
model's memory or prose estimate is not a timestamp source.

### Cadence
- Triggered by `scripts/start_agent.sh` at the end of each poll cycle, **only when
  `status == idle`**. If a COMMAND is in flight the check waits until next
  cycle.
- Self-check cadence is configurable via the `SELFCHECK_INTERVAL` env var at
  agent launch.
- Worker-specific periodic review cadence is separately configurable via
  `WORKER_REVIEW_INTERVAL`.

### Snapshot
Before invoking the provider CLI, the wrapper gathers a bounded,
deterministic snapshot of server + experiment state. The snapshot is
written atomically to `agents/{id}/selfcheck_latest.snapshot` (prior
snapshot rotated to `selfcheck_previous.snapshot` so the LLM can diff).

Snapshot contents (kept cheap, total ≲10 KB):
- `nvidia-smi` query-gpu table + compute-apps table
- Training-ish processes under the current Unix user (`ps` filtered by pattern)
- Disk usage (`df -hT`)
- Active `screen` and `tmux` sessions
- Tails (~15 lines) of `*.log` files modified in the last 60 min under
  `~/logs`, `~/workspace`, `/tmp`
- Recent error-pattern hits (`Traceback|CUDA error|RuntimeError|OOM|\bnan\b`)
  from those logs
- `uptime` + `free -h`

### Invocation
The wrapper builds a prompt from `roles/self_check.instruct` + the current
snapshot + the previous snapshot, and invokes the provider CLI exactly
once. **The LLM must not run additional tools** — it works only from the
snapshot.

### Response contract
The provider CLI returns exactly one of two shapes:

- `SELFCHECK: ok` — everything looks normal; the wrapper logs and stays
  silent.
- `SELFCHECK: alert` followed by `SUMMARY:`, `DETAILS:`, and
  `SUGGESTED_ACTION:` lines — the wrapper posts a STATUS message to
  `agents/conductor/inbox/` with body prefixed by `TYPE: selfcheck_alert`.

Unparseable responses are treated as `ok` (logged only). See
`roles/self_check.instruct` for the full prompt.

### Master handling
Self-check alerts arrive as STATUS messages in `agents/conductor/inbox/` with body
prefixed `TYPE: selfcheck_alert`. Master triage is defined in
`conductor.instruct` (§ "Self-check alerts"), including when to escalate to
the user via Signal.

---

## Periodic Status Report

Each node overwrites its current local status snapshot at
`agents/{id}/status_latest.snapshot` every `STATUSREPORT_INTERVAL`
seconds (default `CORTEX_DEFAULT_STATUSREPORT_INTERVAL_SECONDS`). This is a local wrapper-side
operation — no LLM is invoked.

Snapshot format:
```
STATUS: periodic status report
TIME: {ISO_TIMESTAMP}
AGENT: {agent_id}
  - gpus: GPU0:42% 7202MiB/24576MiB  GPU1:90% 7282MiB/24576MiB  ...
  - screens: sigreg_9lfzilji_gpu0 ema_teacher_zqol0g5j_gpu2 ...
  - run: ema_teacher_m27n2yf5_gpu0 | ep 14/48 | epoch 63% | total 28.4% | elapsed 1h38m | eta 4h25m
  - run: contrastive_kqq0u8rz_gpu1 | ep 11/64 | epoch 22% | total 15.9% | elapsed 1h41m | eta 8h55m
```

The `run:` lines are best-effort progress summaries derived from local
training logs plus process elapsed time. They are intended to make the
node reports directly answer "where are the current runs?" questions
without an immediate SSH hop.
When a GPU reads `0%`, the wrapper waits about 30 seconds, samples
again, and keeps the higher utilization reading so a brief idle instant
does not dominate the report.

The write is `flock`-guarded (`.lock` sidecar file) and atomic
(`.tmp` + `mv`) so readers either see the previous full snapshot or the
new one, never a partial rewrite.

**Conductor/watch lookup rule**: when server or run status is requested,
inspect `agents/{id}/status_latest.snapshot` first. Role files decide
how fresh is fresh enough for the current context: `conductor.instruct`
uses a stricter rule for repeated status questions in active chat, and
direct SSH is still required when no node exists or node evidence is
stale/insufficient.

---

## Heartbeat Contract

| State    | Condition                        |
|----------|----------------------------------|
| alive    | `now - heartbeat ≤ CORTEX_DEFAULT_HEARTBEAT_ALIVE_SECONDS` |
| stale    | `CORTEX_DEFAULT_HEARTBEAT_ALIVE_SECONDS < now - heartbeat ≤ CORTEX_DEFAULT_HEARTBEAT_STALE_SECONDS` |
| offline  | `now - heartbeat > CORTEX_DEFAULT_HEARTBEAT_STALE_SECONDS` |

Note: during a self-check run the agent's `status` file shows `selfcheck`
(instead of `idle`/`busy`). Heartbeat continues as normal.

**Heartbeat during work.** While the provider CLI is running (long COMMAND,
BROADCAST, or self-check), the poll loop is blocked inside `run_agent_cli`.
A background ticker therefore writes the heartbeat every
`WORK_HEARTBEAT_INTERVAL` seconds (default 10 s) so the conductor does not see
the agent go stale while it is actively working. The ticker is started
right before the CLI invocation and stopped as soon as it returns; if the
agent script dies unexpectedly, the ticker self-terminates by watching its
parent PID.

---

## Error Handling

- Failed commands: agent sends `STATUS: error` RESPONSE, returns to `idle`
- High-token commands without explicit approval: agent sends `STATUS: warning` RESPONSE,
  explains why it stopped, and waits for the conductor to re-queue with
  `TOKEN_OVERRIDE: approved` in the command body if the user wants to proceed
- Hung provider CLI: each invocation is wrapped in `timeout`
  (`COMMAND_TIMEOUT`, default 30 min for COMMAND/BROADCAST;
  `SELFCHECK_TIMEOUT`, default 3 min for self-checks). A timeout kills the
  CLI, tags the RESPONSE body with a `[cortex] provider CLI ... was killed`
  marker, and lets the agent return to `idle` instead of stalling silently
- Unparseable self-check response: the wrapper logs it and saves the raw
  output to `agents/{id}/selfcheck_unparseable_{ts}.txt` rather than
  silently treating it as `ok`
- Master re-queues by writing a new COMMAND if retry is desired
- Agents never exit on error — they stay in the loop

---

## Conductor-side files

`agents/conductor/tasks.md`, `agents/conductor/logbook.md`,
`agents/conductor/log.md`, the current user's files under `users/`, and
the live environment references under `environments/{env}/` are
maintained by the conductor. Their purpose, format, and upkeep rules
are in `conductor.instruct` — not repeated here to avoid drift. The
watch agent's durable exception is
`agents/watch/logbook.md`, which is its local watch-only incident /
action log for important alerts, directives, one-offs, repairs, and
other durable watch events. Routine wake traces stay in
`agents/watch/log.md`. Persistent workers may also keep local
`agents/{id}/logbook.md` files, but those are worker-owned runtime notes
rather than conductor-owned central/project logbooks. Workers do **not**
write `agents/conductor/logbook.md` or any `projects/*/logbook.md`.

---

## Conventions

- Agents do **not** delete files — they move COMMANDs to `agents/{id}/archive/`
- Tracked commands should include `TASK_ID: ...` in the command body
- Agents should echo `TASK_ID: ...` in their final response when one was provided
- For BROADCASTs, agents create a `.seen` marker in `agents/{id}/archive/` but leave
  the original in `broadcast/` so other agents can still process it.
  The **conductor** cleans `broadcast/` once all expected responses are in.
- Conductor may clean stale legacy directories under `archive/` periodically
  (not required for correctness)
- `agents/conductor/inbox/` is append-only from agents; conductor moves read
  files to `agents/conductor/archive/`
