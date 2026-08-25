# Cortex Research Cluster Template

Copy these files into `projects/<project>/research/` before starting a
research-worker cluster. The files are intentionally plain Markdown so
agents and humans can edit them without a schema migration.

Recommended startup:

1. Fill in `mission.md`.
   Set explicit planning/context/model budgets unless you have a reason
   to override the defaults.
2. Put the same mission summary into `agents/research-lead/mission.txt`
   or ask the conductor to do it.
3. Start `research-lead` plus only the specialists needed for the first
   cycle.
   Keep first-pass planning cheap: launch only the minimal read-only
   set first, and avoid broad context dumps in specialist handoffs.
4. Keep final durable results in the project logbook via the conductor;
   use this folder for live working state.
