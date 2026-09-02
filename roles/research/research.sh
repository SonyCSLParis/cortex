#!/usr/bin/env bash

worker_research_is_lead() {
    [[ "${META_role_in_team:-}" == "lead" ]]
}

worker_research_is_specialist() {
    [[ "${META_role_in_team:-}" == "specialist" ]]
}

worker_team_research_should_drain_inbox_before_periodic() {
    worker_research_is_lead
}

# Is an ssh-agent answering at the given socket? rc 0 (has keys) and rc 1
# (reachable but empty) both mean the agent is live; rc 2 / timeout mean stale.
worker_research_ssh_agent_live() {
    local sock="$1" rc
    [[ -S "${sock}" ]] || return 1
    run_with_timeout 4 env SSH_AUTH_SOCK="${sock}" ssh-add -l >/dev/null 2>&1
    rc=$?
    [[ ${rc} -eq 0 || ${rc} -eq 1 ]]
}

# Ensure a persistent, login-independent ssh-agent for research remote launches.
# A forwarded login-session agent dies when the SSH session that started the
# worker screen ends, leaving the long-lived worker pointed at a dead socket and
# hanging publickey auth to remote launch hosts. When CORTEX_RESEARCH_SSH_AGENT_SOCK
# is configured (typically via a project research_runtime.env), make sure an agent
# is live at that socket with the configured key loaded, and pin SSH_AUTH_SOCK to
# it. No-op when unconfigured, so other workers are unaffected. Best-effort: on any
# failure it warns and leaves the inherited SSH_AUTH_SOCK untouched.
worker_research_ensure_ssh_agent() {
    local sock="${CORTEX_RESEARCH_SSH_AGENT_SOCK:-}"
    local key="${CORTEX_RESEARCH_SSH_AGENT_KEY:-}"
    [[ -n "${sock}" ]] || return 0
    command -v ssh-agent >/dev/null 2>&1 || return 0

    mkdir -p "$(dirname "${sock}")" 2>/dev/null || true

    if ! worker_research_ssh_agent_live "${sock}"; then
        rm -f "${sock}" 2>/dev/null || true
        if ! eval "$(ssh-agent -a "${sock}" 2>/dev/null)" >/dev/null 2>&1; then
            printf '[cortex] research ssh-agent could not start at %s; remote launches may fail\n' "${sock}" >&2
            return 0
        fi
    fi

    export SSH_AUTH_SOCK="${sock}"

    # Load the configured key only if the agent currently holds none (rc 0 = has keys).
    if [[ -n "${key}" && -f "${key}" ]] \
        && ! run_with_timeout 4 env SSH_AUTH_SOCK="${sock}" ssh-add -l >/dev/null 2>&1; then
        run_with_timeout 8 env SSH_AUTH_SOCK="${sock}" ssh-add "${key}" >/dev/null 2>&1 \
            || printf '[cortex] research ssh-agent could not load key %s\n' "${key}" >&2
    fi
    return 0
}

worker_team_research_append_ssh_binds() {
    local ssh_binds_ref="$1"
    worker_research_ensure_ssh_agent
    worker_append_safe_ssh_binds "${ssh_binds_ref}"
}

worker_team_research_append_bwrap_device_args() {
    local device_args_ref="$1"
    security_bwrap_append_nvidia_device_binds "${device_args_ref}"
}

worker_research_lead_id() {
    worker_ids_for_team_role research lead | head -n 1
}

research_mission_file() {
    local lead_id
    lead_id="$(worker_research_lead_id)"
    [[ -n "${lead_id}" ]] || return 1
    printf '%s/agents/%s/mission.txt\n' "${CORTEX_DIR}" "${lead_id}"
}

research_extract_first_list_value() {
    local key="$1" text="$2"
    printf '%s\n' "${text}" | awk -v key="${key}" '
        BEGIN { in_block=0 }
        match($0, "^" key ":[[:space:]]*$") { in_block=1; next }
        in_block && /^[A-Z][A-Z0-9_ ]*:[[:space:]]*$/ { exit }
        in_block {
            line=$0
            sub(/^[[:space:]]*[-*][[:space:]]*/, "", line)
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (line != "" && line !~ /^#/) {
                print line
                exit
            }
        }
    '
}

research_mission_target_folder() {
    local mission_file mission_text target_value target_path target_real cortex_real
    mission_file="$(research_mission_file)" || return 0
    [[ -f "${mission_file}" ]] || return 0
    mission_text="$(cat "${mission_file}")"
    target_value="$(research_extract_first_list_value "TARGET_FOLDER" "${mission_text}" || true)"
    [[ -n "${target_value}" ]] || return 0

    if [[ "${target_value}" == /* ]]; then
        target_path="${target_value}"
    else
        target_path="${CORTEX_DIR}/${target_value}"
    fi
    [[ -d "${target_path}" ]] || return 0

    target_real="$(realpath_m_compat "${target_path}")"
    cortex_real="$(realpath_m_compat "${CORTEX_DIR}")"
    if [[ "${target_real}" != "${cortex_real}" && "${target_real}" != "${cortex_real}/"* ]]; then
        printf '[cortex] research TARGET_FOLDER=%q resolves outside %s; ignoring\n' \
            "${target_value}" "${cortex_real}" >&2
        return 0
    fi

    printf '%s\n' "${target_real}"
}

research_agent_state_dir() {
    local target_dir
    target_dir="$(research_mission_target_folder)"
    if [[ -z "${target_dir}" ]]; then
        printf '%s\n' "${AGENT_DIR}"
        return 0
    fi
    printf '%s/%s\n' "${target_dir}" "${AGENT_ID}"
}

research_project_dir() {
    [[ -n "${CORTEX_RESEARCH_PROJECT:-}" ]] || return 0
    if [[ ! "${CORTEX_RESEARCH_PROJECT}" =~ ^[A-Za-z0-9._-]+$ ]]; then
        printf '[cortex] CORTEX_RESEARCH_PROJECT=%q rejected: must match ^[A-Za-z0-9._-]+$ (no slashes, no traversal)\n' \
            "${CORTEX_RESEARCH_PROJECT}" >&2
        exit 1
    fi
    local projects_root project_dir resolved_project resolved_root
    projects_root="${CORTEX_DIR}/projects"
    project_dir="${projects_root}/${CORTEX_RESEARCH_PROJECT}"
    if [[ ! -d "${project_dir}" ]]; then
        printf '[cortex] CORTEX_RESEARCH_PROJECT=%s but %s does not exist; skipping research project rw\n' \
            "${CORTEX_RESEARCH_PROJECT}" "${project_dir}" >&2
        return 0
    fi
    resolved_project="$(realpath_m_compat "${project_dir}")"
    resolved_root="$(realpath_m_compat "${projects_root}")"
    if [[ "${resolved_project}" != "${resolved_root}"/* ]]; then
        printf '[cortex] CORTEX_RESEARCH_PROJECT=%q resolves to %s, outside %s; refusing to bind RW\n' \
            "${CORTEX_RESEARCH_PROJECT}" "${resolved_project}" "${resolved_root}" >&2
        exit 1
    fi
    printf '%s\n' "${resolved_project}"
}

append_research_project_rw() {
    local resolved_project target_dir path_spec extra_path extra_real
    resolved_project="$(research_project_dir)"
    [[ -n "${resolved_project}" ]] && append_cortex_worker_bwrap_rw "${resolved_project}"
    target_dir="$(research_mission_target_folder)"
    [[ -n "${target_dir}" ]] || :
    [[ -n "${target_dir}" ]] && append_cortex_worker_bwrap_rw "${target_dir}"

    path_spec="${CORTEX_RESEARCH_PROJECT_RW_PATHS:-}"
    [[ -n "${path_spec}" ]] || return 0

    local IFS=:
    for extra_path in ${path_spec}; do
        [[ -n "${extra_path}" ]] || continue
        extra_real="$(realpath_m_compat "${extra_path}")"
        if [[ ! -e "${extra_real}" ]]; then
            printf '[cortex] research project RW path does not exist: %s\n' "${extra_path}" >&2
            return 1
        fi
        append_cortex_worker_bwrap_rw "${extra_real}"
    done
}

append_research_runner_screen_rw() {
    local screen_dir=""

    [[ "${AGENT_ID}" == "research-runner" ]] || return 0

    screen_dir="/run/screen/S-$(id -un)"
    [[ -d "${screen_dir}" ]] || return 0
    append_cortex_worker_bwrap_rw "${screen_dir}"
}

worker_research_runner_append_bwrap_pid_args() {
    local pid_args_ref="$1"
    named_array_clear "${pid_args_ref}"
    # Keep detached launch sessions outside a sandbox-local PID namespace so
    # a later runner restart cannot reap approved training jobs as collateral.
    return 0
}

worker_research_reset_round_scope() {
    RESEARCH_ROUND_RW_PATHS=()
}

worker_research_collect_round_scope() {
    local body_raw="$1"
    worker_research_reset_round_scope

    local scope_block
    scope_block="$(extract_command_block "WRITABLE_PATHS" "${body_raw}")"
    [[ -n "${scope_block}" ]] || return 0

    local cortex_real raw_line candidate
    cortex_real="$(realpath "${CORTEX_DIR}" 2>/dev/null || printf '%s' "${CORTEX_DIR}")"
    while IFS= read -r raw_line; do
        candidate="$(trim_whitespace "${raw_line}")"
        [[ -n "${candidate}" ]] || continue
        [[ "${candidate}" == \#* ]] && continue
        while [[ "${candidate}" == -* || "${candidate}" == \** ]]; do
            candidate="${candidate#?}"
            candidate="$(trim_whitespace "${candidate}")"
        done
        candidate="${candidate#\`}"
        candidate="${candidate%\`}"
        candidate="$(trim_whitespace "${candidate}")"
        case "${candidate}" in
            ""|none|NONE)
                continue
                ;;
        esac

        if [[ "${candidate}" != /* ]]; then
            candidate="${cortex_real}/${candidate}"
        fi
        candidate="$(realpath_m_compat "${candidate}")"

        if [[ ! -e "${candidate}" ]]; then
            printf 'research writable path does not exist: `%s`; enumerate existing files or directories in `WRITABLE_PATHS:`.\n' "${candidate}"
            return 1
        fi

        named_array_append_unique RESEARCH_ROUND_RW_PATHS "${candidate}"
    done <<< "${scope_block}"

    return 0
}

load_research_project_runtime_env() {
    local project_dir env_file raw_line line key value
    project_dir="$(research_project_dir)"
    [[ -n "${project_dir}" ]] || return 0
    env_file="${project_dir}/research_runtime.env"
    [[ -f "${env_file}" ]] || return 0

    while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
        line="$(trim_whitespace "${raw_line}")"
        [[ -n "${line}" ]] || continue
        [[ "${line}" == \#* ]] && continue
        if [[ "${line}" == export\ * ]]; then
            line="$(trim_whitespace "${line#export }")"
        fi
        if [[ "${line}" != *=* ]]; then
            printf '[cortex] invalid research runtime env line in %s: %s\n' "${env_file}" "${raw_line}" >&2
            return 1
        fi
        key="$(trim_whitespace "${line%%=*}")"
        value="$(trim_whitespace "${line#*=}")"
        if [[ ! "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            printf '[cortex] invalid research runtime env key in %s: %s\n' "${env_file}" "${key}" >&2
            return 1
        fi
        if [[ "${value}" == \"*\" && "${value}" == *\" && "${#value}" -ge 2 ]]; then
            value="${value:1:${#value}-2}"
        elif [[ "${value}" == \'* && "${value}" == *\' && "${#value}" -ge 2 ]]; then
            value="${value:1:${#value}-2}"
        fi
        export "${key}=${value}"
    done < "${env_file}"
}

append_research_project_ro_binds() {
    local ro_binds_ref="$1"
    local path_spec="${CORTEX_RESEARCH_PROJECT_RO_PATHS:-}"
    local extra_path extra_real
    [[ -n "${path_spec}" ]] || return 0

    local IFS=:
    for extra_path in ${path_spec}; do
        [[ -n "${extra_path}" ]] || continue
        extra_real="$(realpath_m_compat "${extra_path}")"
        if [[ ! -e "${extra_real}" ]]; then
            printf '[cortex] research project RO path does not exist: %s\n' "${extra_path}" >&2
            return 1
        fi
        if research_rw_spec_overlaps_path "${extra_real}"; then
            continue
        fi
        named_array_append "${ro_binds_ref}" --ro-bind "${extra_real}" "${extra_path}"
    done
}

research_rw_spec_overlaps_path() {
    local candidate_path="$1"
    local candidate_real rw_path entry
    local -a rw_entries=()

    [[ -n "${candidate_path}" ]] || return 1

    candidate_real="$(realpath_m_compat "${candidate_path}")"
    if [[ -n "${CORTEX_WORKER_BWRAP_RW:-}" ]]; then
        local IFS=:
        for entry in ${CORTEX_WORKER_BWRAP_RW}; do
            [[ -n "${entry}" ]] && rw_entries+=("${entry}")
        done
    fi
    if (( $(bash_array_len RESEARCH_ROUND_RW_PATHS) > 0 )); then
        for entry in "${RESEARCH_ROUND_RW_PATHS[@]}"; do
            [[ -n "${entry}" ]] && rw_entries+=("${entry}")
        done
    fi
    (( ${#rw_entries[@]} > 0 )) || return 1

    for entry in "${rw_entries[@]}"; do
        [[ -n "${entry}" ]] || continue
        rw_path="$(realpath_m_compat "${entry}")"
        [[ -e "${rw_path}" ]] || continue
        if research_paths_overlap "${candidate_real}" "${rw_path}"; then
            return 0
        fi
    done
    return 1
}

research_paths_overlap() {
    local a="$1" b="$2"
    [[ "${a}" == "${b}" || "${a}" == "${b}/"* || "${b}" == "${a}/"* ]]
}

# Broad read base for ALL research-team workers: by default "/" (the whole host,
# read-only) so research workers read like the conductor and never need a
# per-project read allow-list — switching projects exposes no new bind work.
# Secrets are masked back out by append_research_ro_mask, and writes stay fenced
# to the agent dir + active project tree (the RW binds, applied after this, win
# for those subpaths). Configured via CORTEX_RESEARCH_RO_BASE (default "/"); a
# non-"/" colon list is a narrower opt-in, and a missing narrow root is skipped
# with a warning.
append_research_ro_base() {
    local ro_binds_ref="$1"
    local path_spec="${CORTEX_RESEARCH_RO_BASE:-}"
    local base_path base_real
    [[ -n "${path_spec}" ]] || return 0

    local IFS=:
    for base_path in ${path_spec}; do
        [[ -n "${base_path}" ]] || continue
        if [[ "${base_path}" == "/" ]]; then
            named_array_append "${ro_binds_ref}" --ro-bind / /
            continue
        fi
        base_real="$(realpath_m_compat "${base_path}")"
        if [[ ! -e "${base_real}" ]]; then
            printf '[cortex] research RO base path not present, skipping: %s\n' "${base_path}" >&2
            continue
        fi
        named_array_append "${ro_binds_ref}" --ro-bind "${base_real}" "${base_path}"
    done
}

# Credential paths of the provider this worker is NOT using. With a broad read
# base the host's other-provider creds would otherwise be readable; the active
# provider's own creds are left alone (the launcher binds/needs them).
research_other_provider_cred_paths() {
    case "${AGENT_PROVIDER:-}" in
        codex)
            printf '%s\n' "${HOME}/.claude" "${HOME}/.claude.json" "${HOME}/.local/share/claude"
            ;;
        claude)
            printf '%s\n' "${HOME}/.codex"
            ;;
    esac
}

# Mask secrets/credentials back out of the broad read base: an existing dir
# becomes an empty tmpfs, an existing file becomes an empty read-only bind
# (/dev/null), so an autonomous research worker cannot read them even though "/"
# is mounted read-only. The set is CORTEX_RESEARCH_RO_MASK plus the other
# provider's creds. Applied LAST among the read binds (after rw + per-project
# overlays) so nothing re-exposes them.
append_research_ro_mask() {
    local mask_ref="$1"
    local -a targets=()
    local p real entry

    local IFS=:
    for entry in ${CORTEX_RESEARCH_RO_MASK:-}; do
        [[ -n "${entry}" ]] && targets+=("${entry}")
    done
    unset IFS
    while IFS= read -r p; do
        [[ -n "${p}" ]] && targets+=("${p}")
    done < <(research_other_provider_cred_paths)

    for p in "${targets[@]}"; do
        real="$(realpath_m_compat "${p}")"
        [[ -e "${real}" ]] || continue
        if [[ -d "${real}" ]]; then
            named_array_append "${mask_ref}" --tmpfs "${p}"
        else
            named_array_append "${mask_ref}" --ro-bind /dev/null "${p}"
        fi
    done
}

research_mission_active_specialists() {
    local mission_file
    mission_file="$(research_mission_file)" || return 0
    [[ -f "${mission_file}" ]] || return 0

    local mission_text block raw_line candidate
    mission_text="$(cat "${mission_file}")"
    block="$(extract_command_block "ACTIVE_SPECIALISTS" "${mission_text}")"
    if [[ -z "$(printf '%s' "${block}" | tr -d '[:space:]')" ]]; then
        block="$(extract_command_block "WORKERS" "${mission_text}")"
    fi
    [[ -n "${block}" ]] || return 0

    while IFS= read -r raw_line; do
        candidate="$(trim_whitespace "${raw_line}")"
        [[ -n "${candidate}" ]] || continue
        [[ "${candidate}" == \#* ]] && continue
        while [[ "${candidate}" == -* || "${candidate}" == \** ]]; do
            candidate="${candidate#?}"
            candidate="$(trim_whitespace "${candidate}")"
        done
        candidate="${candidate#\`}"
        candidate="${candidate%\`}"
        candidate="$(trim_whitespace "${candidate}")"
        worker_id_has_team_role "${candidate}" research specialist || continue
        printf '%s\n' "${candidate}"
    done <<< "${block}"
}

worker_research_apply_defaults() {
    if worker_research_is_lead; then
        worker_set_codex_defaults "${META_tier:-medium}" "${DEFAULT_WORKER_REVIEW_INTERVAL_SHORT}" "${DEFAULT_WORKER_REVIEW_TIMEOUT_RESEARCH_SECONDS}"
        load_research_project_runtime_env || return 1
        worker_environment_export_wandb_api_key_from_netrc || return 1
        append_research_project_rw
    elif worker_research_is_specialist; then
        worker_set_codex_defaults "${META_tier:-medium}" "${DEFAULT_WORKER_REVIEW_INTERVAL_DISABLED}" "${DEFAULT_WORKER_REVIEW_TIMEOUT_RESEARCH_SECONDS}"
        load_research_project_runtime_env || return 1
        worker_environment_export_wandb_api_key_from_netrc || return 1
        # Active research specialists stay alive for inbox work, but should not
        # run an autonomous periodic-review lane unless a mission explicitly
        # opts them into one.
        WORKER_REVIEW_INTERVAL="${DEFAULT_WORKER_REVIEW_INTERVAL_DISABLED}"
        local lead_id
        lead_id="$(worker_research_lead_id)"
        [[ -n "${lead_id}" ]] && append_cortex_worker_bwrap_rw "${CORTEX_DIR}/agents/${lead_id}/inbox"
        append_research_project_rw
        append_research_runner_screen_rw
    fi
}

worker_research_select_instruction_templates() {
    if worker_research_is_lead || worker_research_is_specialist; then
        INSTRUCT_TEAM_TEMPLATE="${CORTEX_DIR}/roles/research.instruct"
    fi
}

worker_research_resolve_state_dir() {
    if worker_research_is_lead || worker_research_is_specialist; then
        research_agent_state_dir
    fi
}

worker_research_prepare_command_scope() {
    if worker_research_is_lead || worker_research_is_specialist; then
        worker_research_collect_round_scope "$@"
    fi
}

worker_research_reset_scope() {
    worker_research_reset_round_scope
}

worker_research_append_rw_paths() {
    local rw_paths_ref="${2:-$1}"
    local research_rw_path

    if (( $(bash_array_len RESEARCH_ROUND_RW_PATHS) > 0 )); then
        for research_rw_path in "${RESEARCH_ROUND_RW_PATHS[@]}"; do
            append_unique_path "${research_rw_path}" "${rw_paths_ref}"
        done
    fi

    if ! worker_research_is_lead; then
        return 0
    fi

    local research_agent_id research_inbox
    while IFS= read -r research_agent_id; do
        [[ -n "${research_agent_id}" ]] || continue
        research_inbox="$(realpath_m_compat "${CORTEX_DIR}/agents/${research_agent_id}/inbox")"
        [[ -d "${research_inbox}" ]] || continue
        append_unique_path "${research_inbox}" "${rw_paths_ref}"
    done < <(research_mission_active_specialists)
}

worker_research_prepare_registration() {
    if worker_research_is_specialist; then
        local lead_id
        lead_id="$(worker_research_lead_id)"
        [[ -n "${lead_id}" ]] && mkdir -p "${CORTEX_DIR}/agents/${lead_id}/inbox"
        return 0
    fi

    if ! worker_research_is_lead || [[ -e "${AGENT_DIR}/mission.txt" ]]; then
        return 0
    fi

    {
        cat <<'EOF'
# Research mission

# This file is the live standing task for the deep-learning research
# cluster. Empty or whitespace-only mission.txt means the cluster is idle.

PROJECT:
- project id, for example my-project

RESEARCH_HOME:
- projects/<project>/research/

TARGET_FOLDER:
- optional existing project-owned experiment folder, for example
  projects/<project>/research/R001

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

MAX_CYCLES:
- unlimited, or a positive integer cycle cap

OBJECTIVE:
- scientific question / target result

HYPOTHESES:
- initial hypothesis or unknown

CONSTRAINTS:
- compute budget
- hosts / GPUs allowed
- datasets / artifacts not to touch
- actions requiring conductor approval

METRICS:
- primary metrics and acceptance criteria

WORKERS:
- add launched worker ids here
- add launched specialist ids here

# Only list specialists that are actually active for this mission.
# Available specialists discovered from metadata:
EOF
        worker_ids_for_team_role research specialist | while IFS= read -r specialist_id; do
            printf '# - %s\n' "${specialist_id}"
        done
        cat <<'EOF'

DONE_WHEN:
- explicit condition for stopping or asking the conductor for a decision
EOF
    } | write_msg "${AGENT_DIR}/mission.txt"
}

worker_team_research_apply_defaults() {
    worker_research_apply_defaults
}

worker_team_research_select_instruction_templates() {
    worker_research_select_instruction_templates
}

worker_team_research_resolve_state_dir() {
    worker_research_resolve_state_dir
}

worker_team_research_prepare_command_scope() {
    worker_research_prepare_command_scope "$@"
}

worker_team_research_reset_scope() {
    worker_research_reset_scope
}

worker_team_research_append_rw_paths() {
    worker_research_append_rw_paths "$@"
}

# Pre-RW hook: the standing read-only base is a base layer (like cortex_real,
# /usr), applied BEFORE the RW binds so the agent dir + project tree — which
# live under the base roots — override it and stay writable. Putting the base
# in the post-RW overlay instead would shadow those RW children and make the
# worker's own dir read-only.
worker_team_research_append_ro_base() {
    append_research_ro_base "$@"
}

# Post-RW hook: per-project read-only paths outside the base (rare). These are
# meant to win over RW, so they correctly stay in the post-RW overlay.
worker_team_research_append_ro_binds() {
    append_research_project_ro_binds "$@"
}

# Mask hook: secrets/credentials masked back out of the broad read base. Applied
# last among the read binds so they are never re-exposed.
worker_team_research_append_ro_masks() {
    append_research_ro_mask "$@"
}

worker_team_research_prepare_registration() {
    worker_research_prepare_registration
}
