#!/usr/bin/env bash

worker_supervisor_apply_defaults() {
    worker_set_codex_defaults medium "${DEFAULT_WORKER_REVIEW_INTERVAL_SHORT}" "${DEFAULT_WORKER_REVIEW_TIMEOUT_LONG_SECONDS}"
    append_cortex_worker_bwrap_rw "${CORTEX_DIR}/agents/student/inbox"
}

worker_supervisor_prepare_registration() {
    mkdir -p "${CORTEX_DIR}/agents/student/inbox"

    if [[ -e "${AGENT_DIR}/mission.txt" ]]; then
        return 0
    fi

    write_msg "${AGENT_DIR}/mission.txt" <<'EOF'
# Supervisor mission

# This file is the live standing task for the supervisor/student loop.
# The supervisor rereads it on every periodic check and normal wake.
# For paper/editorial missions, removing redundancy and unnecessary
# detail is a default goal unless the mission says otherwise.
#
# Empty or whitespace-only mission.txt means the loop is idle.

SCOPE:
- repo / paths to inspect

MAX_LOOPS:
- unlimited, or a positive integer round cap

OBJECTIVE:
- desired end state

CONSTRAINTS:
- things not to touch
- scope limits

VERIFY:
- checks / tests to run if feasible

DONE_WHEN:
- explicit completion condition
EOF
}
