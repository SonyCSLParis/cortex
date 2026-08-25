# Research Mission

PROJECT:
- <project id>

RESEARCH_HOME:
- projects/<project>/research/

PLANNING_BUDGET:
- design_cycles_before_engineering: 1
- corrective_lock_cycles_before_engineering: 1
- extra_read_only_cycles_without_new_high_severity_blocker: 0

CONTEXT_BUDGET:
- max_context_bullets_per_dispatch: 6
- handoff_rule: reference state/artifact paths instead of restating history

MODEL_BUDGET:
- first_pass_planning_tier: weak
- execution_and_synthesis_tier: medium

OBJECTIVE:
- <scientific question / target result>

BACKGROUND:
- <short context and relevant prior state>

HYPOTHESES:
- <initial hypothesis or unknown>

CONSTRAINTS:
- compute budget:
- allowed hosts / GPUs:
- datasets or artifacts not to touch:
- actions requiring conductor approval:

METRICS:
- primary:
- secondary:
- acceptance criteria:

WORKERS:
- research-lead
- research-designer
- research-engineer
- research-runner
- research-analyst

DONE_WHEN:
- <explicit stopping condition>
