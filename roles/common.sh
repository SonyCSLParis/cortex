#!/usr/bin/env bash

CORTEX_ENVELOPE_HEADER_MARKERS=(
    "---"
    "FROM:" "TO:" "TYPE:" "TIME:" "STATUS:"
    "MSG_ID:" "REF:" "TASK_ID:" "KIND:"
    "SUMMARY:" "DETAILS:" "MESSAGE:" "OUTPUT:"
    "CHECK:" "WATCH:" "WATCH_STATE:" "SELFCHECK:"
    "ROUND_STATUS:"
    "CONDUCTOR_DIRECTIVES" "SIGNAL_INBOUND"
)

neutralize_envelope_header_lines() {
    # Prefix quote glyphs onto column-0 header-like lines so envelope readers
    # cannot mistake embedded payload text for real headers or boundaries.
    local text="${1-}" line marker guarded="" first=1 matched

    while IFS= read -r line || [[ -n "${line}" ]]; do
        matched=0
        for marker in "${CORTEX_ENVELOPE_HEADER_MARKERS[@]}"; do
            if [[ "${line}" == "${marker}"* ]]; then
                line="> ${line}"
                matched=1
                break
            fi
        done
        if (( first )); then
            guarded="${line}"
            first=0
        else
            guarded+=$'\n'"${line}"
        fi
    done <<< "${text}"

    if (( first == 1 )) && [[ -z "${text}" ]]; then
        return 0
    fi
    printf '%s' "${guarded}"
}

resolve_worker_override_template() {
    local worker_id="$1"
    find "${CORTEX_DIR}/roles" -mindepth 1 -maxdepth 2 -type f -name "worker.${worker_id}.instruct" | sort | head -n 1
}

worker_id_from_meta_path() {
    local meta_path="$1" meta_name
    meta_name="$(basename "${meta_path}")"
    meta_name="${meta_name#worker.}"
    printf '%s\n' "${meta_name%.meta}"
}

worker_meta_records() {
    local meta_path worker_id
    while IFS= read -r meta_path; do
        [[ -n "${meta_path}" ]] || continue
        worker_id="$(worker_id_from_meta_path "${meta_path}")"
        (
            unset META_team META_role_in_team
            # shellcheck disable=SC1090
            source "${meta_path}"
            printf '%s\t%s\t%s\n' "${worker_id}" "${META_team:-}" "${META_role_in_team:-}"
        )
    done < <(find "${CORTEX_DIR}/roles" -mindepth 2 -maxdepth 2 -type f -name 'worker.*.meta' | sort)
}

worker_ids_for_team_role() {
    local team="$1" role="${2:-}" worker_id meta_team meta_role
    while IFS=$'\t' read -r worker_id meta_team meta_role; do
        [[ "${meta_team}" == "${team}" ]] || continue
        [[ -z "${role}" || "${meta_role}" == "${role}" ]] || continue
        printf '%s\n' "${worker_id}"
    done < <(worker_meta_records)
}

worker_id_has_team_role() {
    local expected_worker_id="$1" team="$2" role="${3:-}" worker_id meta_team meta_role
    while IFS=$'\t' read -r worker_id meta_team meta_role; do
        [[ "${worker_id}" == "${expected_worker_id}" ]] || continue
        [[ "${meta_team}" == "${team}" ]] || return 1
        [[ -z "${role}" || "${meta_role}" == "${role}" ]] || return 1
        return 0
    done < <(worker_meta_records)
    return 1
}

append_cortex_worker_bwrap_rw() {
    local extra_path="$1"
    [[ -n "${extra_path}" ]] || return 0
    if [[ -z "${CORTEX_WORKER_BWRAP_RW:-}" ]]; then
        CORTEX_WORKER_BWRAP_RW="${extra_path}"
    else
        CORTEX_WORKER_BWRAP_RW="${CORTEX_WORKER_BWRAP_RW}:${extra_path}"
    fi
}

role_apply_defaults() {
    case "${AGENT_ROLE}" in
        node)
            node_apply_defaults
            ;;
        worker)
            worker_apply_defaults
            ;;
    esac
    if [[ "${MODEL_TIER_APPLIED:-0}" -eq 0 ]]; then
        apply_model_tier weak
    fi
    [[ -n "${WORKER_REVIEW_INTERVAL}" ]] || WORKER_REVIEW_INTERVAL="${DEFAULT_WORKER_REVIEW_INTERVAL_DISABLED}"
}

role_select_instruction_templates() {
    case "${AGENT_ROLE}" in
        node)
            node_select_instruction_templates
            ;;
        worker)
            worker_select_instruction_templates
            ;;
        *)
            echo "Unsupported runtime role: ${AGENT_ROLE}" >&2
            exit 2
            ;;
    esac
}

role_set_run_mode() {
    AGENT_RUN_MODE="persistent"
    if [[ "${AGENT_ROLE}" == "worker" && "${RUN_ONCE}" -eq 1 ]]; then
        AGENT_RUN_MODE="one_shot"
    fi
}

role_validate_launch() {
    if [[ "${AGENT_ROLE}" == "worker" && "${AGENT_NAME_EXPLICIT}" -ne 1 ]]; then
        echo "Worker launches require an explicit --name (or AGENT_NAME)." >&2
        exit 2
    fi

    if [[ ! "${AGENT_ID}" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "Invalid agent id: '${AGENT_ID}' (must match [A-Za-z0-9._-]+)" >&2
        exit 2
    fi
}

role_prepare_command_scope() {
    case "${AGENT_ROLE}" in
        worker)
            worker_prepare_command_scope "$@"
            ;;
        *)
            return 0
            ;;
    esac
}

role_reset_command_scope() {
    case "${AGENT_ROLE}" in
        worker)
            worker_reset_command_scope
            ;;
    esac
}

role_prepare_registration() {
    case "${AGENT_ROLE}" in
        worker)
            worker_prepare_registration
            ;;
    esac
}

role_resolve_state_dir() {
    case "${AGENT_ROLE}" in
        worker)
            worker_resolve_state_dir
            ;;
        *)
            return 0
            ;;
    esac
}

role_run_provider_cli() {
    ROLE_CLI_USAGE_CODEX_HOME=""
    ROLE_CLI_USAGE_CLAUDE_PROJECT_DIR=""
    ROLE_CLI_USAGE_CLAUDE_SESSION_ID=""
    case "${AGENT_ROLE}" in
        node)
            node_run_provider_cli "$@"
            ;;
        worker)
            worker_run_provider_cli "$@"
            ;;
        *)
            echo "Unsupported runtime role: ${AGENT_ROLE}" >&2
            return 2
            ;;
    esac
}

role_maybe_run_periodic_work() {
    case "${AGENT_ROLE}" in
        worker)
            worker_maybe_run_periodic_review
            ;;
    esac
}

role_should_drain_inbox_before_periodic() {
    case "${AGENT_ROLE}" in
        worker)
            worker_should_drain_inbox_before_periodic
            ;;
        *)
            return 1
            ;;
    esac
}
