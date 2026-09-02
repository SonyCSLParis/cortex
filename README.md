<p align="center">
  <img src="assets/cortex_logo.png" alt="Cortex" width="220">
</p>

# Cortex

**A file-native operating environment for long-running human-agent work.**

Cortex gives you one conductor chat for coordinating projects, durable context,
specialist agents, and real machines across sessions. Its source of truth is a
workspace of transparent files that you own: tasks, logbooks, instructions,
inboxes, project notes, and operational state.

[Quickstart](#quickstart) · [How it works](#how-cortex-works) ·
[Who it is for](#who-cortex-is-for) · [Examples](#example-workflows)

## Give long-running work a durable home.

Research and engineering work may last for months, but AI conversations are
episodic. Decisions become scattered across chats, experiments outlive their
original context, agents repeat old work, and important knowledge disappears
into raw conversation history.

Cortex externalizes that context into structured work state that agents can
selectively reload. You use the conductor like a normal chat: ask a question,
discuss an idea, or request work in natural language. The conductor keeps the
relevant project files, tasks, results, and durable memories organized and can
delegate bounded work when another agent is useful (currently only on user
request).

Cortex helps a person organize and operate their own ongoing work with agents.

## Why Cortex

- **Project-centered continuity:** the durable object is the project, not just
  an agent or conversation. Decisions, tasks, experiments, references, and
  results survive individual chats.
- **One human-facing conductor:** you do not need to design an agent graph before
  Cortex becomes useful. Start with one chat and add specialist agents only
  when the work benefits from them.
- **Files as the source of truth:** normal text files keep the system
  inspectable, versionable, scriptable, backup-friendly, and portable.
- **Clear context boundaries:** framework, user, environment, and project facts
  have separate homes. Personalization stays private while reusable framework
  code can remain public.
- **Reusable knowledge:** task lists track planned and active work; logbooks
  preserve completed steps, decisions, and results; cheat sheets record stable
  facts; shortcut files retain proven procedures; and instruction files hold
  durable rules and preferences.
- **Operational reach:** workers and nodes can handle bounded implementation,
  research, monitoring, messaging, backup, and multi-machine work.
- **Natural-language adaptation:** tell the conductor about a recurring
  preference, missing rule, or workflow improvement and it can record that
  lesson in the durable surface that owns it.
- **Provider flexibility:** Cortex uses capable provider CLIs and their native
  sessions. Most of the workspace model is independent of any one LLM vendor.
- **Customizability:** Cortex was implemented using the Conductor agent who knows
  everything about the framework. If you want to know how things work, customize,
  extend or fix a bug in the framework, just talk to the Conductor.

## How Cortex Works

```mermaid
flowchart LR
    H[Human] --> C[Conductor]
    C <--> W[(File-native workspace)]
    W --> P[Projects and durable context]
    C <--> A[Specialist agents]
    C <--> M[Local and remote machines]
    A <--> M[Local and remote machines]
    A --> W
```

The conductor is the main entry point. For a typical request it:

1. identifies the relevant project, user preferences, and environment facts
2. inspects existing tasks, decisions, and artifacts instead of starting from
   an empty conversation
3. answers directly or delegates a bounded task to an appropriate agent (only
   on explicit request)
4. verifies the outcome and records only the information that should survive
5. returns a concise result to the user

Cortex remains useful with only the conductor. A larger fleet is optional:
read-only nodes can inspect or compute, workers can perform scoped changes, and
the watch agent can monitor unattended work or messaging channels. Framework
workers are available for auditing and advancing the framework itself. 

The workspace separates four kinds of context:

- **Framework:** reusable scripts, role definitions, defaults, and docs
- **User:** preferences, reminders, and provider usage information
- **Environment:** hostnames, paths, remotes, backup roots, and infrastructure
- **Project:** tasks, logbooks, references, rules, experiments, and results

This separation is what lets a live private checkout evolve without leaking
deployment details into a public framework release.

Multiple conductor windows can be open at once. Each has session-local runtime
metadata under `agents/conductor/sessions/`, while all windows share the same
project state and conductor inbox. Only one window should perform inbox triage
or agent dispatch at a time.

## Who Cortex Is For

Cortex is designed for technical individuals and small research or engineering
groups whose work spans projects, sessions, experiments, or machines. It is a
particularly good fit when you want agents to participate in real work while
leaving an understandable, durable record behind.

Cortex is deliberately a single-operator framework, not a multi-user system:
the `users/` folder keeps private preferences and reminders cleanly separated,
rather than providing accounts or shared-user coordination. It is probably not
the right layer if your primary goal is to build a customer-facing agent
application, define a production workflow graph, obtain an enterprise hosted
control plane, or use a turnkey chat assistant without maintaining a local
workspace.

## Quickstart

### Requirements

Minimum:

- Linux or macOS
- `bash`
- `git`
- Python 3
- one provider CLI that Cortex can launch: `claude` or `codex` (no other
  provider value is accepted)
- `bwrap` (bubblewrap) on Linux if you run workers: `scripts/start_agent.sh`
  refuses to start a worker without a usable sandbox backend. On macOS the
  `auto` backend falls back to `macos-direct` when `bwrap` is missing
  (`CORTEX_WORKER_SANDBOX_BACKEND`, resolver in `roles/sandbox.sh`).

Commonly useful:

- `screen` (default) or `tmux` for long-lived agents
- `ssh` for remote node setups
- optional Signal / Telegram tooling if you want messaging ingress
  (`scripts/signal_inbox_daemon.sh`, `scripts/telegram_inbox_daemon.sh`)

### Recommended first run

Clone the repo, then start the conductor:

```bash
git clone https://github.com/SonyCSLParis/cortex.git cortex
cd cortex
bash cortex.sh
```

On its first start, Cortex creates the local surfaces a real checkout needs,
including:

- `user.instruct` and `environment.instruct`
- `users/<user>/...`
- `environments/<env>/...`
- `agents/conductor/...`
- inbox, broadcast, and log directories

It does **not** require you to configure every optional subsystem up front.
A fresh clone can start cleanly without Signal, Telegram, watch, backup, or
public-sync setup.

On the first chat, Cortex asks about the first project before optional setup.
It asks follow-up questions only for capabilities you want to enable: shared
multi-machine operation, backups, Signal/Telegram, public export, or standing
workers. The private `environments/<env>/settings.env` file is the durable
home for optional runtime choices such as conductor/agent provider defaults,
backup retention, relay hosts, and a public export remote. Keep credentials in
`agents/conductor/secrets/`, never in that settings file.

Messaging ingress runs as daemons: `bash scripts/signal_inbox_daemon.sh
start|stop|restart|status|foreground` and `bash
scripts/telegram_inbox_daemon.sh start|stop|restart|status|foreground` write
incoming messages to `inboxes/signal` and `inboxes/telegram`. They source
`agents/conductor/secrets/signal.env` and `agents/conductor/secrets/telegram.env`
(`CORTEX_DEFAULT_SIGNAL_SECRETS_FILE`, `CORTEX_DEFAULT_TELEGRAM_SECRETS_FILE`).
Outbound Telegram messages go through `scripts/telegram_send.py`, which reads
`TELEGRAM_BOT_TOKEN` and `TELEGRAM_USER_CHAT_ID` from the environment.

Safe defaults are disclosed during that chat: nothing unattended starts by
itself; the conductor defaults to Codex and general agents to Claude unless
configured otherwise; provider permission behavior remains unchanged unless
overridden; and the initial backup manifest covers only the Cortex worktree.
Public release is always a sanitized export via `scripts/sync_public.sh`, never
a push of the live operational branch.

Codex is under constant development and the behavior of agents (in particular
the Conductor agent) can be easily customized. The framework was built with
the Conductor agent and can further be modified and extended by prompting the
Conductor. Work on the Cortex framework automatically gets its own project
folder and will be treated like any other project (e.g., logfiles and shortcuts
will automatically be maintained by the Conductor).

If required local state is missing and you are in an interactive shell,
`bash cortex.sh` will offer the same bootstrap flow automatically. Use
`--no-init` to suppress that behavior, or `--init [--user NAME] [--env NAME]`
to create the local user/environment/conductor state and exit without
starting a chat. `--startup-checks` replaces the default minimal startup
routine with the full one (log/tasks review, inbox drain, worker liveness,
next-step suggestions).

Until the checkout has at least one project under `projects/`, the conductor
also follows `setup.instruct` on startup to guide the first-project setup.

You can begin with ordinary requests such as:

> Create a project for my new experiment and help me turn the idea into a plan.

> Before we ran the experiment with the dummy dataset, now plug in the actual
> dataset and start three runs, with the three different architectures we
> designed before. You can use any free GPUs you can find on our servers.

> What did we conclude the last time we worked on this project?

> My experiments should meanwhile be finished, can you show me the results?

> Inspect the current implementation, make the change, run the relevant tests,
> and record the durable outcome.

For a multi-machine setup, a shared NAS-mounted checkout can be linked at the
same path on each host. Environment-specific hostnames, paths, and credentials
belong in the private environment layer, not in framework files.

## Provider and Session Options

By default, `cortex.sh` starts a fresh conductor session with Codex. Codex
launches always run inline so the launcher view stays in normal terminal
scrollback; `--no-alt-screen` is a Codex-only explicit compatibility flag for
that behavior and is rejected together with `--provider claude`. You can
override the provider explicitly:

```bash
bash cortex.sh --provider codex
bash cortex.sh --provider claude
bash cortex.sh --label paper
```

To pick a specific model, pass `--model` with a short version alias. The
accepted aliases are:

- `--provider claude --model fable-5` → Claude Fable 5 (`claude-fable-5`)
- `--provider claude --model sonnet-5` → Claude Sonnet 5 (`claude-sonnet-5`)
- `--provider claude --model 4.8` → Claude Opus 4.8 (`claude-opus-4-8`)
- `--provider claude --model 4.7` → Claude Opus 4.7 (`claude-opus-4-7`)
- `--provider claude --model 4.6` → Claude Sonnet 4.6 (`claude-sonnet-4-6`)
- `--provider codex  --model 5.6` → GPT-5.6 Sol through the `gpt-5.6` alias
- `--provider codex  --model 5.6-sol` → GPT-5.6 Sol (`gpt-5.6-sol`)
- `--provider codex  --model 5.6-terra` → GPT-5.6 Terra (`gpt-5.6-terra`)
- `--provider codex  --model 5.6-luna` → GPT-5.6 Luna (`gpt-5.6-luna`)
- `--provider codex  --model 5.5` → Codex `gpt-5.5`
- `--provider codex  --model 5.4` → Codex `gpt-5.4`

Anything else is rejected with the accepted-alias list. Omit `--model` to fall
back to the provider's own default. For onboarding another CLI model, just ask
it to "Read the CONDUCTOR.md and follow it." and then ask it to extend the
framework to that very model.

Instead of a specific model, `--tier weak|medium|strong` (aliases `low` →
`weak`, `high` → `strong`; env default `CORTEX_CONDUCTOR_TIER`) applies a
shared model/effort tier for the chosen provider. The tier → model/effort
tuples are defined in `config/cortex_defaults.sh`
(`CORTEX_DEFAULT_TIER_<TIER>_{CODEX,CLAUDE}_MODEL`,
`CORTEX_DEFAULT_TIER_<TIER>_CODEX_REASONING`,
`CORTEX_DEFAULT_TIER_<TIER>_CLAUDE_EFFORT`). An explicit `--model` still wins,
and `--tier` combines with `--resume`. Worker roles declare their default tier
in their `.meta` file via `META_tier`; `roles/watch.meta` does the same for
watch.

To resume the most recent conductor chat with its existing model/context, use:

```bash
bash cortex.sh --resume
```

`--resume` reuses the last conductor provider and its native session history.
If you pass `--provider` together with `--resume`, Cortex warns and ignores
`--provider` so it can resume the correct provider session cleanly. `--model`
can be combined with `--resume` to switch the model on the resumed session.

For explicit interactive conductor permission settings, use:

```bash
bash cortex.sh --provider codex --permission default
bash cortex.sh --provider codex --permission auto-review
bash cortex.sh --provider codex --permission full-access
bash cortex.sh --permission-all
```

Codex supports the same user-facing permission presets as its permissions
menu: `default` uses workspace-write with ordinary user approvals,
`auto-review` uses the same workspace-write scope while routing eligible
on-request approvals through the auto-reviewer subagent, and `full-access`
adds `--dangerously-bypass-approvals-and-sandbox`. Claude support is
deliberately limited to verified modes: `default` and `full-access`, where
`full-access` adds `--dangerously-skip-permissions`. `--permission-all` is a
global shorthand for `--permission full-access`; `--permission-default`
remains a compatibility shorthand. `CORTEX_CONDUCTOR_PERMISSION_MODE` sets
the permission preset default. If no permission flag or environment default
is provided, Cortex leaves the provider's existing permission configuration
unchanged. Cortex role, user, project, and environment safety rules still apply.

If the chosen provider CLI is not installed, Cortex fails early with a plain
setup error.

Most of Cortex is deliberately independent of the LLM provider. Provider-specific
dependencies are mainly in the edges where the framework has to talk to a
provider's native session/runtime format, such as token-cost accounting,
conductor chat transcript capture, and provider-specific launch/resume glue.
The conductor should also be able to onboard a new provider when asked by
patching those boundaries rather than treating Cortex as tied to one vendor.

If another conductor window is already active, `cortex.sh` warns at startup and
prints an exhaustive color-coded agent roster before the operator snapshot;
the operator view also reports new public-remote commits not represented in
local `master`. The operator snapshot also shows the active session count. The top-level
`agents/conductor/{info,status,heartbeat}` files are now aggregate views derived
from the live per-session runtime files.

## Operator Commands

Start the conductor:

```bash
bash cortex.sh
bash cortex.sh --resume
bash cortex.sh --permission-all
```

Other agents should usually be started by the conductor agent. For manual/custom runs:

Start a node agent on the current machine:

```bash
bash scripts/start_agent_screen.sh --role node --provider codex
```

Node agents on several servers can share one Cortex checkout. On every node
host, create a symlink to the same central Cortex directory (for example, on
shared storage reachable from every server) so the agents use one shared
control plane. The conductor must be able to SSH to each node host; keep the
actual host and access details in `environments/{env}/cheat_sheet.md`.

Start a named worker:

```bash
bash scripts/start_agent_screen.sh --role worker --name commit --provider codex
WORKER_REVIEW_INTERVAL=<seconds> bash scripts/start_agent_screen.sh --role worker --name cleanup --wake-seconds "${WORKER_REVIEW_INTERVAL}"
```

If a worker should fall back to another provider after quota/auth failures,
launch it with `FALLBACK_PROVIDER=claude` (or `codex`) and optionally
`PROVIDER_FAILURE_COOLDOWN_SECONDS=<seconds>`.

`start_agent_screen.sh` uses `screen` by default; pass `--backend tmux` or
set `CORTEX_SESSION_BACKEND` (default `CORTEX_DEFAULT_SESSION_BACKEND` in
`config/cortex_defaults.sh`) to use tmux instead. The backend helpers live in
`scripts/session_backend.sh`. The helper is idempotent: if the matching
session already exists, it prints the current status/heartbeat age instead of
starting a duplicate.
Routine startup registration is local-only by default; set
`AGENT_REGISTER_NOTIFY=1` when a launch should explicitly notify the
conductor inbox.

Start the watch agent:

```bash
bash scripts/start_agent_screen.sh --role watch
bash scripts/start_agent_screen.sh --role watch --wake-seconds N
```

`--wake-seconds N` is role-aware in the session helper: for `worker` it sets
the periodic worker-check cadence via `WORKER_REVIEW_INTERVAL`, and for
`watch` it is passed through as `scripts/watch.sh --interval N`. When omitted,
the watch interval defaults to `META_wake_interval` in `roles/watch.meta`
(with `CORTEX_DEFAULT_WATCH_INTERVAL_SECONDS` from `config/cortex_defaults.sh`
as the last fallback). It is rejected for `node` starts.

For long-lived agents, run them in `screen` or `tmux` and keep output visible
inside the session. The framework rules assume you can reconnect and inspect
live output.

Run framework validators:

```bash
bash scripts/cortex_doctor.sh
bash scripts/cortex_doctor.sh --check tasks
bash scripts/cortex_doctor.sh --list-checks
```

`cortex_doctor.sh` is a deterministic drift check for task-board layout,
metadata-driven worker docs/ownership, public/private sync boundaries, sandbox
exposure, commit-worker git guardrails, and local repository hygiene. It exits
non-zero when a check needs operator attention, so it is suitable before
framework commits or public-sync work. `--list-checks` prints the available
check names.

Other deterministic operator views (no LLM calls):

- `scripts/cortex_ops_snapshot.sh`: the critical/warnings/active/quiet
  snapshot that `cortex.sh` prints at conductor start
- `scripts/agent_roster.sh [--color|--no-color]`: the startup agent roster as
  a standalone report
- `scripts/task_board_report.sh [--stale|--count]`: stale/overdue task rows
  across all boards (`--stale` lists them, `--count` prints the number)
- `scripts/usage_report.py [--since 24h|7d] [--quiet-line] [--ledger PATH]`:
  provider-usage summary from the user ledger; `scripts/usage_lib.sh` holds
  the shared accounting helpers the launchers use to write that ledger.
  Claude runs are attributed by identity: every launch pins a `--session-id`
  and only that transcript (plus its subagent transcripts) is summed, so
  concurrent sessions in the same checkout do not bleed into each other;
  sandboxed workers/nodes additionally write their transcript into a per-run
  stage so the read-only `~/.claude` mount does not lose it
- `scripts/research_dashboard.sh [--watch [N]]`: read-only status board for
  the research cluster
- `scripts/periodics_check.sh [status|heal]`: manifest and health of the
  scheduled/continuous jobs; `heal` restarts down jobs that are safe to
  auto-start (`cortex.sh` runs `heal` at chat entry, watch runs it on every
  wake)
- `scripts/prompt_log_sync_daemon.sh --cwd <repo> --session-dir <dir>
  [--interval N] [--parent-pid PID]`: per-session conductor prompt-log sync
  loop, started by `cortex.sh`

## Example Workflows

### Research (e.g., Deep Learning)

Use Cortex for research that lasts longer than one chat: develop an idea,
inspect what has already been tried, launch a bounded run on a suitable server,
and return days later to a project record that explains what ran and why. Cortex
keeps environment-specific knowledge about the available machines, their
capabilities, and their setup, so it can place work without rebuilding that
context each time. While a run is active, the watch agent can monitor it and
notify you via Signal or Telegram (the inbox daemons and
`scripts/telegram_send.py` above) about meaningful failures or changes.
Configurations, output locations, results, and durable conclusions stay with
the project, making new work easier to compare against earlier runs without
relying on chat history alone.

### Bring an existing project into Cortex

Point Cortex at an existing repository, even if it has months of runs and
uneven documentation. Cortex links the project instead of copying it,
inventories the surviving code and artifacts, and creates a concise project
record.

It writes down what can still be checked—saved configs, checkpoints, metrics,
and Git commits—and clearly marks what is missing. The next conversation can
start from that project record: what was tried, what is known, what remains
uncertain, and what to do next.

### Create your own agent

Create a small specialist agent for a responsibility you want Cortex to remember
over time. For example, a scheduling agent can work with a connected calendar,
your reminders, and project deadlines to maintain a clear view of the coming days.

It could prepare a short daily agenda, flag conflicts between meetings and focused
work, and turn a note such as “make time to finish the revision before Friday” into
a tracked reminder. If a deadline moves, it can identify affected plans and suggest
a revised schedule. It should ask before sending invitations, changing calendar
events, or messaging anyone; its durable record remains in your own Cortex
workspace, alongside the projects it supports.

The exact actions available in each workflow depend on the permissions and
filesystem or host access granted to the active agents.

## Agent Types

### Conductor

The conductor is the human-facing control plane.

- launched with `bash cortex.sh`
- owns cross-project operational bookkeeping
- reads context and updates durable memory
- starts worker agents, like the commit or backup agent
- reads agent reports (from its inbox)
- sends bounded work to other agents (only on explicit request)
- receives and summarizes their responses

If you use only one Cortex role, this is the one.

### Node

Nodes are the lightweight read/compute agents.

- started directly with `bash scripts/start_agent.sh`, or in a managed
screen with `bash scripts/start_agent_screen.sh --role node`
- usually one per machine, though you can run more via `--name`
- good for inspection, status checks, analysis, and bounded compute tasks
- not meant to perform freeform write-capable host operations

For a single-machine setup, you may not need dedicated nodes at all. They
become more useful once you spread work across several servers.

### Watch

The watch agent is the unattended monitoring role.

- started directly with `bash scripts/start_agent.sh --role watch`, or in a
managed screen with `bash scripts/start_agent_screen.sh --role watch`
- runs on an interval loop
- can monitor state, wake on inbox activity, and send notifications
- is useful when Cortex should keep an eye on things while you are away

Watch is optional. A lot of Cortex use is perfectly fine with only the
conductor plus a few workers.

### Worker

Workers are elevated task-execution agents.

- started directly with `bash scripts/start_agent.sh --role worker --name <id>`,
or in a managed screen with `bash scripts/start_agent_screen.sh --role worker --name <id>`
- can be one-shot (`--once`) or persistent
- use the same inbox/response model as nodes
- are intended for bounded write-capable or operations-capable work

Workers are where Cortex becomes a real multi-agent system rather than a
single chat with helper scripts.

## Worker Role Reference

Cortex supports plain generic workers, but the framework also ships with
specialized named worker roles. This catalog is reference material rather than
a recommended default fleet - only commit, backup and compressor are recommended.
The roles are defined by `roles/<category>/worker.<name>.instruct` plus
`roles/<category>/worker.<name>.meta`.
If a new worker role should be created, just ask the Conductor to do so.

<!-- BEGIN GENERATED: worker-role-catalog -->
### Operational workers

These are the workers that keep the system tidy and durable over time.

| Worker | Lifecycle | Default cadence | Writes | Domain |
| --- | --- | --- | --- | --- |
| `backup` | persistent | daily | yes | snapshot creation from backup_targets.txt; backup-freshness tracking |
| `cleanup` | persistent | daily | yes | inbox, archive, and temp-file housekeeping across agent directories |
| `commit` | persistent | every 12h | yes | git staging/commit/push for runtime dirt within the strict allow-list; never active source/policy without explicit COMMAND |
| `compressor` | persistent | every 12h | yes | logbook/task-board/archive size management via rotate/zip helpers; never rewrites live content |

### Framework review workers

These workers are analysis-first by default: they inspect one framework/runtime slice, report findings, and repair only on explicit COMMAND. They audit and improve Cortex itself by turning otherwise stochastic agent behavior into inspectable evidence, durable findings, and explicit follow-up rules or repairs. They cannot make an LLM deterministic, but they make the surrounding framework as repeatable and accountable as practical.

| Worker | Lifecycle | Default cadence | Writes | Domain |
| --- | --- | --- | --- | --- |
| `calibration` | persistent | daily | no | per-agent behavior-vs-instruction drift; proposes targeted instruction edits |
| `consistency` | persistent | daily | no | ownership-boundary drift: project facts in wrong files, duplicated rules across layers |
| `efficiency` | persistent | every 6h | no | workflow inefficiencies: repeated conductor work, avoidable token burn, missing shortcuts |
| `environment` | persistent | daily | no | infrastructure ground-truth drift: cheat sheet vs ssh config; host/GPU/NAS/IP probes |
| `memory` | persistent | daily | no | hygiene of durable memory surfaces: stale/duplicate rows, orphaned logbook entries |
| `metacortex` | persistent | daily | no | philosophical self-reflection over Cortex as a whole; writes its treatise to own notes.txt on 24h cadence |
| `privacy` | persistent | daily | no | framework privacy boundary: concrete user/project/deployment details leaking into generic framework surfaces |
| `reliability` | persistent | daily | no | runtime health: stuck loops, stale heartbeats, failed periodics, missing recovery recipes |
| `security` | persistent | daily | no | security and sandbox posture: credential exposure, broad binds, permission drift |
| `simplify` | persistent | daily | no | deletion-biased review of code/spec/worker growth; every ticket proposes removal/consolidation (never addition) |

### Closed-loop implementation workers

Use these when you want a bounded review/repair loop without the conductor hand-authoring every round.

| Worker | Lifecycle | Default cadence | Writes | Domain |
| --- | --- | --- | --- | --- |
| `student` | on-demand | manual only | yes | loop experiment: implements rounds issued by the supervisor worker |
| `supervisor` | on-demand | short | yes | loop experiment: iterative review/repair loop driving the student worker |

### Research workers

These are mission-scoped specialist roles for the current research cycle; launch only the specialists that match the active mission.

| Worker | Lifecycle | Default cadence | Writes | Domain |
| --- | --- | --- | --- | --- |
| `research-analyst` | persistent / specialist | manual only | yes | research specialist: turning experiment artifacts into evidence |
| `research-critic` | persistent / specialist | manual only | yes | research specialist: falsification and validity checks |
| `research-designer` | persistent / specialist | manual only | yes | research specialist: turning hypotheses into concrete experiments |
| `research-engineer` | persistent / specialist | manual only | yes | research specialist: bounded implementation work for deep-learning experiments |
| `research-lead` | research-cycle / lead | hourly | yes | coordinator for the deep-learning research cluster; hypothesis synthesis |
| `research-literature` | persistent / specialist | manual only | yes | research specialist: scientific context and prior-work grounding |
| `research-runner` | persistent / specialist | manual only | yes | research specialist: launching and monitoring deep-learning experiments |
| `research-scribe` | persistent / specialist | manual only | yes | research specialist: maintaining project-local research notes |
| `research-theorist` | persistent / specialist | manual only | yes | research specialist: mechanisms, hypotheses, and expected outcomes |

### Experiment workers

These workers own autonomous, mission-scoped experiment improvement loops with local notes, cheatsheets, and launch recipes.

| Worker | Lifecycle | Default cadence | Writes | Domain |
| --- | --- | --- | --- | --- |
| `sweep` | persistent | hourly | yes | autonomous deep-learning experiment sweeper: monitors, analyzes, launches, and iterates within its mission |
<!-- END GENERATED: worker-role-catalog -->

### Research as an extension pattern

The research fleet is the clearest example of how Cortex is meant to be
*extended* rather than just configured. Cortex does not treat "research" as a
hard-wired capability: the whole cluster is a self-contained bundle of role
instructions, metadata, and helpers under `roles/research/`, added the same way
you would add your own specialized fleet for a different domain. If you want to
grow Cortex for new kinds of work, this bundle is the worked example to copy —
see `roles/agent_building.md` for the bundle/layout spec that any new agent
fleet should follow, and `roles/research.instruct` for this cluster's codified
workflow.

Research workers run under a "broad read, fenced write" sandbox implemented
by `roles/research/research.sh` on top of the shared `roles/sandbox.sh`: the
read base is `CORTEX_RESEARCH_RO_BASE` (default `/`, mounted read-only), the
secret/credential paths listed in `CORTEX_RESEARCH_RO_MASK` are masked back
out of it, and writes stay fenced to the agent directory plus the active
project tree (`CORTEX_RESEARCH_PROJECT`). Both variables are defined in
`config/cortex_defaults.sh` and can be overridden per host in
`environments/<env>/settings.env`. `templates/research/` is the project
scaffold (mission, hypotheses, experiments, results, claims, open questions)
to copy into `projects/<project>/research/` before starting a cluster.

You do not need every research specialist on every mission. Launch only the
workers that match the active cycle.

## Important Directories

You do not need the full tree memorized. The main surfaces are:

- `cortex.sh`: chat entry point for the conductor
- `scripts/`: runtime and helper scripts
- `roles/`: agent instructions and named worker role definitions
- `config/`: framework defaults (`config/cortex_defaults.sh`)
- `templates/`: project scaffolds to copy, currently `templates/research/`
- `users/`: user-specific durable state, including `users/<user>/usage/usage.tsv`
  and user preferences/reminders
- `agents/conductor/sessions/`: per-window conductor runtime state, including
  optional session-local transcript logs such as
  `agents/conductor/sessions/<session>/prompt_log.txt`
- `environments/`: deployment-specific settings and infrastructure facts
- `projects/`: project homes
- `agents/`: live agent homes, inboxes, logs, and local runtime memory
- `broadcast/`: shared outbound messages from the conductor

If you are new to the framework, focus first on `cortex.sh`, `roles/`,
`projects/`, and the `agents/conductor/` home.

## Safety and Ownership

Cortex makes agent work inspectable, but inspectability is not isolation.
Agents launched with elevated permissions can modify or delete any data their
runtime is allowed to reach. Start with the narrowest useful role and access
level, keep important work versioned or backed up, and review environment and
permission settings before enabling unattended operation.

The framework distinguishes read-oriented nodes, write-capable workers, and
role-specific rules so authority can be bounded. Destructive actions still
require explicit care; installing Cortex does not make an otherwise unsafe
host or agent tool safe automatically.

## Local vs Public State

Cortex is designed so a live working checkout can stay private while the
framework itself can be published.

In practice:

- framework files should stay generic and reusable
- live `users/`, `environments/`, `projects/`, agent state, inboxes, and logs
  are operational/private by default
- public publication should go through `scripts/sync_public.sh`, which builds a
  fresh sanitized export instead of pushing the live operational branch

If you are adapting Cortex for your own work, keep private facts in the user or
environment layer rather than baking them into framework docs or scripts.
Deployment-specific public-sync leak patterns can live in
`config/public_forbidden_patterns.local`,
`environments/<env>/public_forbidden_patterns.txt`, or
`agents/conductor/secrets/public_forbidden_patterns.txt`; those paths are not
part of the public export manifest.

## License

Released under the [MIT License](LICENSE).

## When To Add More Agents

Start small.

A good progression is:

1. conductor only
2. conductor + one or two workers you actually need (good candidates for
   everyday use are the "operational workers" above)
3. add watch if unattended monitoring becomes useful
4. add remote nodes or research specialists when the workload genuinely wants
   parallelism

Do not launch a full fleet just because the roles exist. Cortex is more useful
when the running agents reflect the real workload.

## Where To Read Next

- [PROTOCOL.md](PROTOCOL.md): wire-level contract, message envelopes, and agent
  lifecycle
- [CONDUCTOR.md](CONDUCTOR.md): the context the conductor loads at startup
- [SECURITY.md](SECURITY.md): security policy and vulnerability reporting
- [roles/conductor.instruct](roles/conductor.instruct): how the conductor is
  supposed to behave
- [roles/agent_building.md](roles/agent_building.md): bundle/layout spec for
  new agent fleets
- [roles/worker.instruct](roles/worker.instruct): generic worker rules
- [roles/watch.instruct](roles/watch.instruct): watch-agent behavior
- [BASH_RECIPES.md](BASH_RECIPES.md): reusable operator snippets
- [SHORTCUTS.md](SHORTCUTS.md): framework-level task recipes

If you want to understand the system quickly, read this README first, then
`PROTOCOL.md`, then the role file for the agent you actually plan to run.
