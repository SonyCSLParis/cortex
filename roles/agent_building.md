# Agent Build Spec

Persistent framework guidance for creating new Cortex agents.
It is the standing bundle/layout spec for new agents, not a migration
plan.

## Design goal

New agents should be self-contained bundles by construction.

Adding or removing an agent should mostly mean adding or removing one
directory subtree under `roles/`, plus its runtime instance under
`agents/{id}/` when that agent is actually used. Avoid central
registries and shared-file special cases whenever metadata or naming
conventions can express the same thing.

## Bundle shape

An agent bundle lives under `roles/<category>/` and owns:

- `worker.<id>.instruct`: the role-specific prompt addendum
- `worker.<id>.meta`: the declarative manifest
- `worker.<id>.sh`: optional runtime hooks for behavior that cannot be a
  literal
- role-local helper scripts owned only by that agent

Recommended layout:

```text
roles/<category>/
  worker.<id>.instruct
  worker.<id>.meta
  worker.<id>.sh
  <id>/
    owned_helper_1.sh
    owned_helper_2.py
```

Co-locate single-owner helper logic with the bundle instead of placing
it in shared `scripts/` without ownership markers.

## What belongs where

Keep the three-way split clean:

- bundle: code, prompt, manifest, owned scripts
- `agents/{id}/`: runtime instance state, inboxes, heartbeats, logs,
  logbooks, and optional local memory files
- `users/`, `environments/`, `projects/`: private facts, deployment
  specifics, and project data

Generic framework files must stay reusable and public-safe. Do not
embed user identities, hostnames, remotes, private paths, dataset
locations, or deployment-specific literals in bundle docs or manifests.
Refer to the owning private surface instead.

## Shared-surface rule

Role-local bundle code may point downward to files it owns inside the
same bundle subtree.

Shared framework surfaces must not point upward into a specific bundle.
That means files such as `roles/worker.sh`, shared `scripts/`, generic
ops views, and generic docs should discover agent behavior through:

- metadata
- naming conventions
- optional role-local hooks

They should not hardcode specific agent ids, team rosters, or bundle
exception paths.

## Meta manifest

The manifest is a sourceable shell fragment containing `META_*`
variables. It stores values, not behavior.

Example:

```sh
META_category=operational
META_domain="snapshot creation + backup-freshness tracking"
META_core=yes
META_tier=weak
META_cadence=hourly
META_review_timeout=short
META_write_capable=yes
META_writable_paths="env:backup_targets"
META_periodic_health=yes
META_collaborates_with="environment"
META_owns_scripts="roles/operational/backup/backup_snapshot.sh roles/operational/backup/test_backup_freshness_predicate.sh"
```

### Required fields

- `META_category`: bundle family such as `operational`, `framework`,
  `loop`, or `research`
- `META_domain`: one-line description of the agent's exclusive domain

### Common optional fields

Identity and grouping:

- `META_core=yes|no`
- `META_lifecycle=persistent|on-demand|research-cycle`
- `META_team=<name>`
- `META_role_in_team=<role>`

Scheduling and health:

- `META_cadence=disabled|short|hourly|6h|12h|daily`
- `META_review_timeout=default|short`
- `META_selfcheck_interval=<seconds-or-0>`
- `META_statusreport_interval=<seconds-or-0>`
- `META_periodic_health=yes|no`

Model/provider defaults:

- `META_tier=weak|medium|strong`
- `META_provider_pin=<provider>`
- `META_effort_override=<value>`

Capabilities and safety:

- `META_write_capable=yes|no`
- `META_writable_paths="<anchor> ..."`
- `META_command_scope=default|custom`
- `META_sandbox_extra="<declaration> ..."`

Boundary and ownership:

- `META_collaborates_with="<agent-id> ..."`
- `META_owns_scripts="<path> ..."`

Optional local-memory toggles:

- `META_use_notes=yes|no`
- `META_use_cheatsheet=yes|no`
- `META_use_shortcuts=yes|no`

These toggles control agent-local memory under `agents/{id}/`; they do
not make those files part of the reusable bundle.

## Meta rules

1. Values, not behavior.
   If something needs logic, keep it in `worker.<id>.sh`. The manifest
   may only hold literals and simple flags.
2. Reference private data; do not embed it.
   `META_writable_paths` should use symbolic anchors such as
   `cortex_tree`, `git_metadata`, or `env:backup_targets`, not concrete
   `/media/...` paths.
3. Keep the manifest small.
   Only add fields that an existing framework surface actually reads.
   Omitted optional fields mean "use the framework default".

## Hooks

Use `worker.<id>.sh` only for behavior that cannot be expressed as a
literal manifest value, such as:

- custom default selection logic
- custom command-scope setup/reset
- computed writable-path expansion
- team-level shared behavior

The manifest can flag that a custom hook exists, but the behavior itself
stays in shell code.

## Runtime memory and temporary notes

Runtime files are not part of the bundle.

- `agents/{id}/log.md` and `agents/{id}/logbook.md` are durable runtime
  records
- `agents/{id}/notes.txt` is temporary scratch reasoning
- `agents/{id}/cheatsheet.md` and `agents/{id}/shortcuts.md` are
  optional agent-local reference files when enabled by meta

Do not define agent behavior by storing framework rules in those
runtime files.

## Checklist for a new agent

1. Create `worker.<id>.instruct` with the role-specific mandate.
2. Create `worker.<id>.meta` with at least `META_category` and
   `META_domain`.
3. Add `worker.<id>.sh` only if literals are insufficient.
4. Co-locate owned helper scripts inside the bundle subtree.
5. Keep private facts in `users/`, `environments/`, or `projects/`,
   not in the bundle.
6. Ensure shared framework surfaces can discover the new bundle without
   hardcoded edits beyond the supported metadata/naming conventions.
