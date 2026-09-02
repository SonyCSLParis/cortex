#!/usr/bin/env bash

source "${CORTEX_DIR}/roles/worker.common.sh"

worker_source_role_modules() {
    local role_module
    while IFS= read -r role_module; do
        # shellcheck disable=SC1090
        source "${role_module}"
    done < <(find "${CORTEX_DIR}/roles" -mindepth 2 -maxdepth 2 -type f -name '*.sh' | sort)
}

worker_source_role_modules

WORKER_META_LOADED_FOR=""
WORKER_META_PRESENT=0

worker_meta_reset() {
    unset \
        META_category \
        META_core \
        META_lifecycle \
        META_tier \
        META_cadence \
        META_review_timeout \
        META_selfcheck_interval \
        META_statusreport_interval \
        META_periodic_health \
        META_provider_pin \
        META_effort_override \
        META_write_capable \
        META_writable_paths \
        META_command_scope \
        META_sandbox_extra \
        META_collaborates_with \
        META_owns_scripts \
        META_use_notes \
        META_use_cheatsheet \
        META_use_shortcuts \
        META_domain \
        META_team \
        META_role_in_team
}

resolve_worker_meta_file() {
    local worker_id="$1"
    find "${CORTEX_DIR}/roles" -mindepth 2 -maxdepth 2 -type f -name "worker.${worker_id}.meta" | sort | head -n 1
}

worker_load_meta() {
    if [[ "${WORKER_META_LOADED_FOR:-}" == "${AGENT_ID}" ]]; then
        [[ "${WORKER_META_PRESENT:-0}" -eq 1 ]]
        return $?
    fi

    worker_meta_reset
    WORKER_META_LOADED_FOR="${AGENT_ID}"
    WORKER_META_PRESENT=0

    local meta_file=""
    meta_file="$(resolve_worker_meta_file "${AGENT_ID}" || true)"
    [[ -n "${meta_file}" ]] || return 1

    # shellcheck disable=SC1090
    source "${meta_file}"
    WORKER_META_PRESENT=1
    return 0
}

worker_sanitize_hook_token() {
    printf '%s' "${1:-}" | tr '.-' '__'
}

worker_resolve_hook_name() {
    local suffix="$1"
    local fn_name=""
    local agent_token=""
    agent_token="$(worker_sanitize_hook_token "${AGENT_ID}")"
    fn_name="worker_${agent_token}_${suffix}"
    if declare -F "${fn_name}" >/dev/null 2>&1; then
        printf '%s\n' "${fn_name}"
        return 0
    fi

    if worker_load_meta && [[ -n "${META_team:-}" ]]; then
        local team_token=""
        team_token="$(worker_sanitize_hook_token "${META_team}")"
        fn_name="worker_team_${team_token}_${suffix}"
        if declare -F "${fn_name}" >/dev/null 2>&1; then
            printf '%s\n' "${fn_name}"
            return 0
        fi
    fi

    return 1
}

worker_meta_cadence_seconds() {
    case "${1:-}" in
        ""|default)
            return 1
            ;;
        disabled)
            printf '%s\n' "${DEFAULT_WORKER_REVIEW_INTERVAL_DISABLED}"
            ;;
        short)
            printf '%s\n' "${DEFAULT_WORKER_REVIEW_INTERVAL_SHORT}"
            ;;
        hourly)
            printf '%s\n' "${DEFAULT_WORKER_REVIEW_INTERVAL_HOURLY}"
            ;;
        6h)
            printf '%s\n' "${DEFAULT_WORKER_REVIEW_INTERVAL_6H}"
            ;;
        12h)
            printf '%s\n' "${DEFAULT_WORKER_REVIEW_INTERVAL_12H}"
            ;;
        daily)
            printf '%s\n' "${DEFAULT_WORKER_REVIEW_INTERVAL_DAILY}"
            ;;
        *)
            printf '[cortex] worker %s has unknown META_cadence=%s\n' "${AGENT_ID}" "${1}" >&2
            return 1
            ;;
    esac
}

worker_meta_review_timeout_seconds() {
    case "${1:-}" in
        ""|default)
            printf '%s\n' "${DEFAULT_WORKER_REVIEW_TIMEOUT_SECONDS}"
            ;;
        short)
            printf '%s\n' "${DEFAULT_WORKER_REVIEW_TIMEOUT_SHORT_SECONDS}"
            ;;
        long)
            printf '%s\n' "${DEFAULT_WORKER_REVIEW_TIMEOUT_LONG_SECONDS}"
            ;;
        research)
            printf '%s\n' "${DEFAULT_WORKER_REVIEW_TIMEOUT_RESEARCH_SECONDS}"
            ;;
        *)
            printf '[cortex] worker %s has unknown META_review_timeout=%s\n' "${AGENT_ID}" "${1}" >&2
            return 1
            ;;
    esac
}

worker_apply_meta_defaults() {
    worker_load_meta || return 0

    local cadence_seconds=""
    local review_timeout_seconds=""
    if [[ -n "${META_cadence:-}" ]]; then
        cadence_seconds="$(worker_meta_cadence_seconds "${META_cadence}")" || return 1
    fi
    review_timeout_seconds="$(worker_meta_review_timeout_seconds "${META_review_timeout:-default}")" || return 1

    if [[ -n "${META_tier:-}" ]]; then
        if [[ "${AGENT_PROVIDER_EXPLICIT}" -eq 0 ]]; then
            AGENT_PROVIDER="${META_provider_pin:-codex}"
        fi
        apply_model_tier "${META_tier}"
    fi

    if [[ -n "${META_effort_override:-}" ]]; then
        case "${META_provider_pin:-${AGENT_PROVIDER:-}}" in
            claude)
                if [[ "${CLAUDE_EFFORT_EXPLICIT}" -eq 0 ]]; then
                    CLAUDE_EFFORT="${META_effort_override}"
                fi
                ;;
            codex)
                if [[ "${CODEX_REASONING_EFFORT_EXPLICIT}" -eq 0 ]]; then
                    CODEX_REASONING_EFFORT="${META_effort_override}"
                fi
                ;;
        esac
    fi

    if [[ -n "${cadence_seconds}" && -z "${WORKER_REVIEW_INTERVAL}" ]]; then
        WORKER_REVIEW_INTERVAL="${cadence_seconds}"
    fi
    if [[ "${WORKER_REVIEW_TIMEOUT}" == "${DEFAULT_WORKER_REVIEW_TIMEOUT_SECONDS}" ]]; then
        WORKER_REVIEW_TIMEOUT="${review_timeout_seconds}"
    fi
}

worker_apply_defaults() {
    [[ "${AGENT_ROLE}" == "worker" ]] || return 0
    worker_apply_meta_defaults || return 1

    local defaults_hook=""
    defaults_hook="$(worker_resolve_hook_name apply_defaults || true)"
    [[ -z "${defaults_hook}" ]] || "${defaults_hook}"
}

worker_select_instruction_templates() {
    INSTRUCT_TEMPLATE="${CORTEX_DIR}/roles/worker.instruct"
    local template_hook=""
    template_hook="$(worker_resolve_hook_name select_instruction_templates || true)"
    [[ -z "${template_hook}" ]] || "${template_hook}"
    # Convention: when no hook picked a team template, a bundle may ship a
    # category-level addendum at roles/<META_category>/<META_category>.instruct.
    if [[ -z "${INSTRUCT_TEAM_TEMPLATE:-}" ]] && worker_load_meta && [[ -n "${META_category:-}" ]]; then
        local category_template="${CORTEX_DIR}/roles/${META_category}/${META_category}.instruct"
        [[ -f "${category_template}" ]] && INSTRUCT_TEAM_TEMPLATE="${category_template}"
    fi
    INSTRUCT_OVERRIDE_TEMPLATE="$(resolve_worker_override_template "${AGENT_ID}" || true)"
    SELFCHECK_INTERVAL="${SELFCHECK_INTERVAL:-0}"
    STATUSREPORT_INTERVAL="${STATUSREPORT_INTERVAL:-0}"
}

worker_prepare_command_scope() {
    local scope_hook=""
    scope_hook="$(worker_resolve_hook_name prepare_command_scope || true)"
    if [[ -n "${scope_hook}" ]]; then
        "${scope_hook}" "$@"
        return $?
    fi
    worker_prepare_command_scope_default
}

worker_reset_command_scope() {
    local reset_hook=""
    reset_hook="$(worker_resolve_hook_name reset_scope || true)"
    if [[ -n "${reset_hook}" ]]; then
        "${reset_hook}"
        return $?
    fi
    worker_reset_command_scope_default
}

worker_should_drain_inbox_before_periodic() {
    local drain_hook=""
    drain_hook="$(worker_resolve_hook_name should_drain_inbox_before_periodic || true)"
    if [[ -n "${drain_hook}" ]]; then
        "${drain_hook}"
        return $?
    fi
    return 1
}

worker_writable_paths() {
    local cortex_real="$1"
    local rw_paths_ref="$2"
    named_array_clear "${rw_paths_ref}"

    local agent_real
    agent_real="$(realpath_m_compat "${AGENT_DIR}")"
    mkdir -p "${agent_real}"
    named_array_append "${rw_paths_ref}" "${agent_real}"

    local rw_hook=""
    rw_hook="$(worker_resolve_hook_name append_rw_paths || true)"
    if [[ -n "${rw_hook}" ]]; then
        if ! "${rw_hook}" "${cortex_real}" "${rw_paths_ref}"; then
            return 1
        fi
    fi

    if worker_should_append_shared_rw_spec; then
        local -a extra_rw_paths=()
        if ! append_rw_paths_from_spec "${CORTEX_WORKER_BWRAP_RW:-}" extra_rw_paths; then
            return 1
        fi
        local extra_rw_path
        for extra_rw_path in "${extra_rw_paths[@]}"; do
            append_unique_path "${extra_rw_path}" "${rw_paths_ref}"
        done
    fi

    [[ -n "${cortex_real}" ]]
}

worker_should_append_shared_rw_spec() {
    local spec_hook=""
    spec_hook="$(worker_resolve_hook_name use_shared_rw_spec || true)"
    if [[ -n "${spec_hook}" ]]; then
        "${spec_hook}"
        return $?
    fi
    return 0
}

worker_bwrap_rw_binds() {
    local cortex_real="$1"
    local rw_binds_ref="$2"
    named_array_clear "${rw_binds_ref}"

    local -a rw_paths=()
    if ! worker_writable_paths "${cortex_real}" rw_paths; then
        return 1
    fi

    local rw_path
    for rw_path in "${rw_paths[@]}"; do
        named_array_append "${rw_binds_ref}" --bind "${rw_path}" "${rw_path}"
    done

    [[ -n "${cortex_real}" ]]
}

worker_post_rw_ro_binds() {
    local ro_binds_ref="$1"
    named_array_clear "${ro_binds_ref}"

    local ro_hook=""
    ro_hook="$(worker_resolve_hook_name append_ro_binds || true)"
    [[ -z "${ro_hook}" ]] || "${ro_hook}" "${ro_binds_ref}"
}

# Pre-RW read-only base: APPENDS to the early ro-bind array (does not clear it),
# so a role can contribute broad standing read-only roots that sit beneath the
# RW binds in mount order. RW children (agent dir, project tree) applied later
# therefore override these base roots and stay writable.
worker_pre_rw_ro_base() {
    local ro_binds_ref="$1"
    local base_hook=""
    base_hook="$(worker_resolve_hook_name append_ro_base || true)"
    if [[ -n "${base_hook}" ]]; then
        "${base_hook}" "${ro_binds_ref}"
        return $?
    fi
    return 0
}

# Secret/credential mask binds, applied LAST among the read binds so a broad
# read base cannot leave secrets readable. A role contributes these via an
# append_ro_masks hook; empty when no hook is defined.
worker_ro_masks() {
    local mask_ref="$1"
    named_array_clear "${mask_ref}"

    local mask_hook=""
    mask_hook="$(worker_resolve_hook_name append_ro_masks || true)"
    if [[ -n "${mask_hook}" ]]; then
        "${mask_hook}" "${mask_ref}"
        return $?
    fi
    return 0
}

worker_append_ssh_binds() {
    local ssh_binds_ref="$1"
    local ssh_hook=""
    ssh_hook="$(worker_resolve_hook_name append_ssh_binds || true)"
    if [[ -n "${ssh_hook}" ]]; then
        "${ssh_hook}" "${ssh_binds_ref}"
        return $?
    fi
    worker_append_ssh_binds_default "${ssh_binds_ref}"
}

worker_bwrap_pid_args() {
    local pid_args_ref="$1"
    named_array_clear "${pid_args_ref}"

    local pid_hook=""
    pid_hook="$(worker_resolve_hook_name append_bwrap_pid_args || true)"
    if [[ -n "${pid_hook}" ]]; then
        "${pid_hook}" "${pid_args_ref}"
        return $?
    fi

    named_array_append "${pid_args_ref}" --unshare-pid
}

worker_bwrap_device_args() {
    local device_args_ref="$1"
    security_bwrap_device_args "${device_args_ref}"

    local device_hook=""
    device_hook="$(worker_resolve_hook_name append_bwrap_device_args || true)"
    [[ -z "${device_hook}" ]] || "${device_hook}" "${device_args_ref}"
}

worker_prepare_registration() {
    if [[ "${AGENT_RUN_MODE}" == "persistent" && ! -e "${WORKER_LOGBOOK}" ]]; then
        write_msg "${WORKER_LOGBOOK}" <<'EOF'
# Persistent worker logbook

Local durable notes for this stable worker. Use the same terse
`## [ISO_TIMESTAMP] — topic` plus bullets style as the other Cortex
logbooks. Routine activity belongs in `agents/{id}/log.md`, not here.
EOF
    fi

    local registration_hook=""
    registration_hook="$(worker_resolve_hook_name prepare_registration || true)"
    if [[ -n "${registration_hook}" ]]; then
        "${registration_hook}"
        return $?
    fi
    worker_prepare_registration_default
}

worker_resolve_state_dir() {
    local state_hook=""
    state_hook="$(worker_resolve_hook_name resolve_state_dir || true)"
    if [[ -n "${state_hook}" ]]; then
        "${state_hook}"
        return $?
    fi
    worker_resolve_state_dir_default
}

worker_run_provider_cli() {
    local prompt="$1" working_file="$2" tmp_out="$3" tmp_last="$4" timeout_ref="$5"

    if [[ "${WORKER_SANDBOX_BACKEND:-bwrap}" == "macos-direct" ]]; then
        case "${AGENT_PROVIDER}" in
            claude)
                worker_launch_claude_direct "${prompt}" "${working_file}" "${tmp_out}" "${timeout_ref}"
                return $?
                ;;
            codex)
                worker_launch_codex_direct "${prompt}" "${working_file}" "${tmp_out}" "${tmp_last}" "${timeout_ref}"
                return $?
                ;;
        esac
    fi

    case "${AGENT_PROVIDER}" in
        claude)
            local claude_hook=""
            claude_hook="$(worker_resolve_hook_name launch_claude || true)"
            if [[ -n "${claude_hook}" ]]; then
                "${claude_hook}" "${prompt}" "${working_file}" "${tmp_out}" "${timeout_ref}"
            else
                worker_launch_claude_generic "${prompt}" "${working_file}" "${tmp_out}" "${timeout_ref}"
            fi
            return $?
            ;;
        codex)
            local codex_hook=""
            codex_hook="$(worker_resolve_hook_name launch_codex || true)"
            if [[ -n "${codex_hook}" ]]; then
                "${codex_hook}" "${prompt}" "${working_file}" "${tmp_out}" "${tmp_last}" "${timeout_ref}"
            else
                worker_launch_codex_generic "${prompt}" "${working_file}" "${tmp_out}" "${tmp_last}" "${timeout_ref}"
            fi
            return $?
            ;;
    esac

    printf '[cortex] unsupported provider for worker role: %s' "${AGENT_PROVIDER}"
    return 1
}

worker_check_fingerprint() {
    local notify_state="$1" body="$2"
    {
        printf 'state=%s\n' "${notify_state}"
        printf '%s\n' "${body}"
    } | sed -E \
        -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.+-]+(<|>|Z|[[:space:]])/<iso-ts>\1/g' \
        -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2}([[:space:]][A-Z]+)?/<clock-ts>/g' \
        -e 's/[0-9]{10,}/<epoch>/g' \
        | hash_text
}

worker_notify_state_field() {
    local key="$1"
    [[ -f "${WORKER_REVIEW_NOTIFY_STATE}" ]] || return 0
    awk -F= -v key="${key}" '$1 == key { print substr($0, length(key) + 2); exit }' \
        "${WORKER_REVIEW_NOTIFY_STATE}" 2>/dev/null
}

should_forward_worker_check() {
    local notify_state="$1" body="$2"
    local now fp prev_state prev_fp prev_ts
    now="$(date -u +%s)"
    fp="$(worker_check_fingerprint "${notify_state}" "${body}")"
    prev_state="$(worker_notify_state_field state)"
    prev_fp="$(worker_notify_state_field fingerprint)"
    prev_ts="$(worker_notify_state_field sent_ts)"
    prev_ts="${prev_ts:-0}"

    [[ "${notify_state}" != "${prev_state}" ]] && return 0
    [[ "${fp}" != "${prev_fp}" ]] && return 0
    (( now - prev_ts >= 86400 )) && return 0
    return 1
}

record_worker_check_forwarded() {
    local notify_state="$1" body="$2"
    local now fp tmp
    now="$(date -u +%s)"
    fp="$(worker_check_fingerprint "${notify_state}" "${body}")"
    tmp="${WORKER_REVIEW_NOTIFY_STATE}.tmp"
    {
        printf 'state=%s\n' "${notify_state}"
        printf 'fingerprint=%s\n' "${fp}"
        printf 'sent_ts=%s\n' "${now}"
    } > "${tmp}"
    mv "${tmp}" "${WORKER_REVIEW_NOTIFY_STATE}"
}

forward_worker_check_if_due() {
    local notify_state="$1" status="$2" body="$3" sent_log="$4" suppressed_log="$5"
    if should_forward_worker_check "${notify_state}" "${body}"; then
        send_to_conductor "worker_periodic_check" "none" "${status}" "${body}"
        record_worker_check_forwarded "${notify_state}" "${body}"
        log "${sent_log}"
    else
        log "${suppressed_log}"
    fi
}

worker_next_wake_enabled() {
    case "${WORKER_NEXT_WAKE_ENABLED:-0}" in
        1|yes|true)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

worker_next_wake_bounds() {
    local min_s="${WORKER_NEXT_WAKE_MIN_SECONDS:-600}"
    local max_s="${WORKER_NEXT_WAKE_MAX_SECONDS:-43200}"

    [[ "${min_s}" =~ ^[0-9]+$ ]] || min_s=600
    [[ "${max_s}" =~ ^[0-9]+$ ]] || max_s=43200
    if (( min_s <= 0 )); then
        min_s=600
    fi
    if (( max_s < min_s )); then
        max_s="${min_s}"
    fi

    printf '%s %s\n' "${min_s}" "${max_s}"
}

worker_clear_next_wake_state() {
    rm -f "${WORKER_NEXT_WAKE_AT_FILE:-}" "${WORKER_NEXT_WAKE_REASON_FILE:-}" 2>/dev/null || true
}

worker_apply_next_wake_from_result() {
    local source="$1"
    local result="$2"
    local now_epoch="${3:-$(date -u +%s)}"
    local next_wake_at=""
    local next_wake_seconds=""
    local next_wake_reason=""
    local requested_epoch=""
    local effective_epoch=""
    local effective_delta=""
    local min_s=""
    local max_s=""

    WORKER_NEXT_WAKE_DIRECTIVE_PRESENT=0
    WORKER_NEXT_WAKE_DIRECTIVE_APPLIED=0

    worker_next_wake_enabled || return 0

    next_wake_at="$(extract_result_field "NEXT_WAKE_AT" "${result}")"
    next_wake_seconds="$(extract_result_field "NEXT_WAKE_SECONDS" "${result}")"
    next_wake_reason="$(extract_result_field "NEXT_WAKE_REASON" "${result}")"

    if [[ -z "${next_wake_at}" && -z "${next_wake_seconds}" ]]; then
        return 0
    fi

    WORKER_NEXT_WAKE_DIRECTIVE_PRESENT=1
    read -r min_s max_s <<< "$(worker_next_wake_bounds)"

    if [[ -n "${next_wake_at}" ]]; then
        if [[ ! "${next_wake_at}" =~ ^[0-9]+$ ]]; then
            log "worker next wake: ignored invalid NEXT_WAKE_AT from ${source}: ${next_wake_at}"
            return 0
        fi
        requested_epoch="${next_wake_at}"
    else
        if [[ ! "${next_wake_seconds}" =~ ^[0-9]+$ ]]; then
            log "worker next wake: ignored invalid NEXT_WAKE_SECONDS from ${source}: ${next_wake_seconds}"
            return 0
        fi
        requested_epoch=$(( now_epoch + next_wake_seconds ))
    fi

    effective_delta=$(( requested_epoch - now_epoch ))
    if (( effective_delta < min_s )); then
        effective_delta="${min_s}"
    elif (( effective_delta > max_s )); then
        effective_delta="${max_s}"
    fi
    effective_epoch=$(( now_epoch + effective_delta ))

    if ! write_epoch_file_atomic "${WORKER_NEXT_WAKE_AT_FILE}" "${effective_epoch}"; then
        log "worker next wake: failed to persist next wake epoch for ${source}"
        return 0
    fi

    if [[ -n "${next_wake_reason}" ]]; then
        write_text_file_atomic "${WORKER_NEXT_WAKE_REASON_FILE}" "${next_wake_reason}" || true
    else
        rm -f "${WORKER_NEXT_WAKE_REASON_FILE}" 2>/dev/null || true
    fi

    WORKER_NEXT_WAKE_DIRECTIVE_APPLIED=1
    log "worker next wake: scheduled by ${source} in ${effective_delta}s at epoch ${effective_epoch}${next_wake_reason:+ (${next_wake_reason})}"
    return 0
}

worker_record_command_next_wake() {
    local result="$1"
    local now_epoch

    [[ "${AGENT_ROLE}" == "worker" ]] || return 0

    now_epoch="$(date -u +%s)"
    worker_apply_next_wake_from_result "command" "${result}" "${now_epoch}"
    if [[ "${WORKER_NEXT_WAKE_DIRECTIVE_APPLIED:-0}" -eq 1 ]]; then
        write_epoch_file_atomic "${WORKER_REVIEW_LAST_FILE}" "${now_epoch}" || true
    fi
}

run_worker_check() {
    local check_body prompt result check_state check_summary legacy_review_state periodic_status status_field="done"
    local hard_deadline_s=${WORKER_REVIEW_TIMEOUT}
    local soft_deadline_s=$(( WORKER_REVIEW_TIMEOUT * 4 / 5 ))
    local hard_deadline_min=$(( hard_deadline_s / 60 ))
    local soft_deadline_min=$(( soft_deadline_s / 60 ))
    local notify_body

    printf -v check_body '%s\n' \
        "Run your periodic check for this worker's standing responsibility." \
        "" \
        "TIME BUDGET - read this first:" \
        "" \
        "- Hard deadline: this process is hard-killed by the launcher after" \
        "  ${hard_deadline_s}s (${hard_deadline_min} min). At that moment SIGTERM is" \
        "  sent, then SIGKILL 30s later; any unfinished response is discarded and you" \
        "  will have produced nothing this cycle." \
        "- Your soft deadline: return your final response within" \
        "  ${soft_deadline_s}s (${soft_deadline_min} min). Stop investigating once" \
        "  that deadline is close and write up whatever you have." \
        "- Partial findings delivered on time are strictly better than complete" \
        "  findings that get truncated. Ship what you know; flag what you did not get" \
        "  to under REQUEST_ALLOWANCE or a similar channel in your role instruct." \
        "" \
        "- Use your worker instructions, including any worker-specific override, to decide what to inspect." \
        "- Prefer bounded, high-signal checks over broad dumps." \
        "- Append any durable findings to your own local memory exactly as instructed for this worker." \
        "- If additional metrics, instrumentation, or structured statistics would materially help, do not implement them unasked; request allowance with the exact proposed additions." \
        "- If there is nothing materially new, say so briefly."

    set_status "busy"
    log "worker check: starting periodic check"
    prompt="$(build_prompt "${check_body}" "PERIODIC CHECK")"
    record_prompt_context_snapshot "periodic_check" "${prompt}" || true
    result="$(run_agent_cli "${prompt}" "${WORKER_REVIEW_TIMEOUT}")" || status_field="warning"
    worker_apply_next_wake_from_result "periodic_check" "${result}"
    if [[ "${WORKER_NEXT_WAKE_DIRECTIVE_PRESENT:-0}" -eq 0 ]] \
       || [[ "${WORKER_NEXT_WAKE_DIRECTIVE_APPLIED:-0}" -eq 0 ]]; then
        worker_clear_next_wake_state
    fi
    check_state="$(extract_result_field "CHECK" "${result}")"
    if [[ -z "${check_state}" ]]; then
        legacy_review_state="$(extract_result_field "REVIEW" "${result}")"
        check_state="${legacy_review_state}"
    fi
    if [[ -z "${check_state}" ]]; then
        periodic_status="$(extract_result_field "STATUS" "${result}")"
        case "${periodic_status}" in
            done) check_state="ok" ;;
            warning) check_state="suggest" ;;
        esac
    fi
    check_summary="$(extract_result_field "SUMMARY" "${result}")"

    if [[ "${status_field}" != "done" ]]; then
        notify_body="$(printf "STATE: error\n%s" "${result}")"
        forward_worker_check_if_due \
            "error" "warning" "${notify_body}" \
            "worker check: provider failure sent to conductor" \
            "worker check: duplicate provider failure suppressed"
    elif [[ "${check_state}" == "suggest" ]]; then
        forward_worker_check_if_due \
            "suggest" "done" "${result}" \
            "worker check: suggestion sent to conductor (${check_summary:-no summary})" \
            "worker check: duplicate suggestion suppressed (${check_summary:-no summary})"
    elif [[ "${check_state}" == "ok" ]]; then
        if [[ -f "${WORKER_REVIEW_NOTIFY_STATE}" ]] \
           && [[ "$(worker_notify_state_field state)" != "ok" ]]; then
            record_worker_check_forwarded "ok" "${result}"
            log "worker check: recovery ok recorded locally (${check_summary:-no summary})"
        else
            log "worker check: ok (${check_summary:-no summary})"
        fi
    else
        notify_body="$(printf "STATE: unparseable\n%s" "${result}")"
        forward_worker_check_if_due \
            "unparseable" "warning" "${notify_body}" \
            "worker check: unparseable result sent to conductor" \
            "worker check: duplicate unparseable result suppressed"
    fi

    set_status "idle"
}

worker_maybe_run_periodic_review() {
    if [[ "${AGENT_RUN_MODE}" != "persistent" ]]; then
        return 0
    fi

    local _wr_now _wr_last _wr_status _next_wake_at="" due_now=0
    _wr_now=$(date -u +%s)
    _wr_last="$(read_epoch_file_or_default "${WORKER_REVIEW_LAST_FILE}" 0)"
    _wr_status="$(read_agent_status)"

    if worker_next_wake_enabled; then
        _next_wake_at="$(read_epoch_file_or_default "${WORKER_NEXT_WAKE_AT_FILE}" 0)"
        if (( _next_wake_at > 0 )); then
            if (( _wr_now >= _next_wake_at )); then
                due_now=1
            fi
        fi
    fi

    if [[ -z "${_next_wake_at}" || "${_next_wake_at}" == "0" ]] \
       && (( due_now == 0 )) && (( WORKER_REVIEW_INTERVAL > 0 )) \
       && (( _wr_now - _wr_last >= WORKER_REVIEW_INTERVAL )); then
        due_now=1
    fi

    if [[ "${_wr_status}" == "idle" ]] && (( due_now == 1 )); then
        run_worker_check
        write_epoch_file_atomic "${WORKER_REVIEW_LAST_FILE}" "${_wr_now}" || true
    fi
}
