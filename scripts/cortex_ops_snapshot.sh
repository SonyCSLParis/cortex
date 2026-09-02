#!/usr/bin/env bash
# =============================================================================
# cortex_ops_snapshot.sh — human-readable Cortex operator view
#
# Read-only; safe to run anywhere, anytime. Prints one compact view organized by
# operator decision:
#   - Critical: broken automation or checks that need prompt action
#   - Warnings: stale or advisory states worth scheduling
#   - Active: live work that is not inherently bad
#   - Quiet: important checks that are currently clear
#
# Usage:
#   bash scripts/cortex_ops_snapshot.sh
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CORTEX_DIR="${CORTEX_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd -P)}"
source "${CORTEX_DIR}/config/cortex_defaults.sh"
source "${CORTEX_DIR}/scripts/session_backend.sh"
cd "${CORTEX_DIR}" 2>/dev/null || { echo "cortex dir not found: ${CORTEX_DIR}" >&2; exit 1; }

now=$(date -u +%s)
CONDUCTOR_INBOX="agents/conductor/inbox"
CONDUCTOR_ACTIVE_SESSIONS_FILE="agents/conductor/active_sessions.tsv"
WATCH_FILE="agents/watch/watch.txt"
BACKUP_FRESH_SECONDS="${CORTEX_OPS_BACKUP_FRESH_SECONDS:-93600}"
PERIODICS_TIMEOUT_SECONDS="${CORTEX_OPS_PERIODICS_TIMEOUT_SECONDS:-25}"
SELFCHECK_FRESH_SECONDS="${CORTEX_OPS_SELFCHECK_FRESH_SECONDS:-$(( CORTEX_DEFAULT_SELFCHECK_INTERVAL_SECONDS * 2 ))}"

CRITICAL=()
WARNINGS=()
ACTIVE=()
QUIET=()

add_critical() { CRITICAL+=("$1"); }
add_warning() { WARNINGS+=("$1"); }
add_active() { ACTIVE+=("$1"); }
add_quiet() { QUIET+=("$1"); }

array_len() {
    local name="$1" len restore_u=0
    [[ $- == *u* ]] && restore_u=1
    set +u
    eval "len=\${#${name}[@]}"
    (( restore_u )) && set -u
    printf '%s' "${len:-0}"
}

array_join() {
    local sep="$1" name="$2" item first=1 restore_u=0
    (( $(array_len "${name}") > 0 )) || return 1
    [[ $- == *u* ]] && restore_u=1
    set +u
    eval 'for item in "${'"${name}"'[@]}"; do
        if (( first )); then
            printf "%s" "${item}"
            first=0
        else
            printf "%s%s" "'"${sep}"'" "${item}"
        fi
    done'
    (( restore_u )) && set -u
}

print_section_array() {
    local title="$1" name="$2" item restore_u=0
    (( $(array_len "${name}") > 0 )) || return 0

    printf '\n%s\n' "${title}"
    [[ $- == *u* ]] && restore_u=1
    set +u
    eval 'for item in "${'"${name}"'[@]}"; do printf "%s\n" "${item}"; done' | sed 's/^/- /'
    (( restore_u )) && set -u
}

run_with_timeout() {
    local seconds="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "${seconds}" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout "${seconds}" "$@"
    else
        "$@"
    fi
}

file_mtime_epoch() {
    local path="$1"
    if stat -c %Y "${path}" >/dev/null 2>&1; then
        stat -c %Y "${path}"
    elif stat -f %m "${path}" >/dev/null 2>&1; then
        stat -f %m "${path}"
    else
        printf '0\n'
    fi
}

iso8601_to_epoch_utc() {
    local iso="$1" normalized
    if date -u -d "${iso}" +%s >/dev/null 2>&1; then
        date -u -d "${iso}" +%s
        return 0
    fi

    normalized="$(printf '%s' "${iso}" | sed -E 's/Z$/+0000/; s/([+-][0-9]{2}):([0-9]{2})$/\1\2/')"
    if date -j -u -f '%Y-%m-%dT%H:%M:%S%z' "${normalized}" +%s >/dev/null 2>&1; then
        date -j -u -f '%Y-%m-%dT%H:%M:%S%z' "${normalized}" +%s
        return 0
    fi

    printf '0\n'
}

plural() {
    local n="$1" singular="$2" plural_form="${3:-${2}s}"
    if (( n == 1 )); then
        printf '%s' "${singular}"
    else
        printf '%s' "${plural_form}"
    fi
}

join_by() {
    local sep="$1"; shift
    local first=1 item
    for item in "$@"; do
        if (( first )); then
            printf '%s' "${item}"
            first=0
        else
            printf '%s%s' "${sep}" "${item}"
        fi
    done
}

compact_age() {
    local age="$1"
    if (( age < 0 )); then
        printf '0s'
    elif (( age < 60 )); then
        printf '%ss' "${age}"
    elif (( age < 3600 )); then
        printf '%sm' "$((age / 60))"
    elif (( age < 86400 )); then
        printf '%sh' "$((age / 3600))"
    else
        printf '%sd' "$((age / 86400))"
    fi
}

count_task_status() {
    local status="$1" file="$2"
    awk -v marker="- [${status}]" 'index($0, marker) == 1 { c++ } END { print c + 0 }' \
        "${file}" 2>/dev/null
}

format_agent_status() {
    local status_file="$1" raw
    [[ -f "${status_file}" ]] || { printf '?'; return 0; }
    raw="$(tr -d '\r\n' < "${status_file}" 2>/dev/null || true)"
    case "${raw}" in
        idle|busy|working|selfcheck|error|offline) printf '%s' "${raw}" ;;
        "") printf 'invalid(empty)' ;;
        *) printf 'invalid(%s)' "${raw}" ;;
    esac
}

state_file_value() {
    local file="$1" key="$2"
    awk -F= -v key="${key}" '$1 == key {
        sub(/^[^=]*=/, "")
        gsub(/^"/, "")
        gsub(/"$/, "")
        print
        exit
    }' "${file}" 2>/dev/null
}

provider_cooldown_summary() {
    local agent_id="$1"
    local state_file="agents/${agent_id}/provider_failure_state"
    local until_epoch provider reason retry_hint until_iso remaining

    [[ -f "${state_file}" ]] || return 1
    until_epoch="$(state_file_value "${state_file}" until_epoch)"
    [[ "${until_epoch}" =~ ^[0-9]+$ ]] || return 1
    (( until_epoch > now )) || return 1

    provider="$(state_file_value "${state_file}" provider)"
    reason="$(state_file_value "${state_file}" reason)"
    retry_hint="$(state_file_value "${state_file}" retry_hint)"
    until_iso="$(state_file_value "${state_file}" until_iso)"
    remaining="$(compact_age "$(( until_epoch - now ))")"

    printf '%s %s cooldown for %s, retry hint: %s' \
        "${provider:-provider}" "${reason:-unknown}" "${remaining}" "${retry_hint:-none}"
    [[ -n "${until_iso}" ]] && printf ' (until %s)' "${until_iso}"
}

snapshot_worker_id() {
    local meta_path meta_name worker_id
    while IFS= read -r meta_path; do
        grep -Eq '^META_domain="snapshot creation' "${meta_path}" || continue
        meta_name="$(basename "${meta_path}")"
        worker_id="${meta_name#worker.}"
        worker_id="${worker_id%.meta}"
        printf '%s\n' "${worker_id}"
        return 0
    done < <(find roles -type f -name 'worker.*.meta' 2>/dev/null | LC_ALL=C sort)
    return 1
}

last_snapshot_success_iso() {
    local worker_id worker_log
    worker_id="$(snapshot_worker_id || true)"
    [[ -n "${worker_id}" ]] || return 0
    worker_log="agents/${worker_id}/log.md"

    # Match both canonical success forms emitted by the snapshot worker:
    #   `[TS] <id> | SNAPSHOT: periodic check completed successfully`
    #   `[TS] <id> | PERIODIC CHECK: snapshot completed cleanly`
    # The `snapshot` token appears in either case (SNAPSHOT marker or
    # lowercase narrative), so match it case-insensitively while keeping
    # the worker id plus success wording so failure lines are never accepted.
    awk -v agent_id="${worker_id}" '/^\[/ && index($0, agent_id " |") && tolower($0) ~ /snapshot/ \
         && /(completed|cleanly| ok|snapshot ok)/ { line = $0 }
         END {
             if (line != "") {
                 sub(/^\[/, "", line)
                 sub(/\].*/, "", line)
                 print line
             }
         }' "${worker_log}" 2>/dev/null
}

message_field() {
    local file="$1" key="$2"
    awk -F: -v key="${key}" '$1 == key { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }' \
        "${file}" 2>/dev/null
}

message_preview() {
    local file="$1"
    awk '/^---$/ { found=1; next } found && NF { print; exit }' "${file}" 2>/dev/null \
        | tr '\r\n\t' '   ' \
        | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//; s/^(.{90}).*/\1.../'
}

inbox_message_class() {
    local file="$1" type status
    type="$(message_field "${file}" TYPE)"
    status="$(message_field "${file}" STATUS)"
    case "${type}" in
        worker_periodic_check)
            case "${status}" in
                warning|error|blocked) printf 'attention' ;;
                *) printf 'suggestion' ;;
            esac
            ;;
        *)
            printf 'attention'
            ;;
    esac
}

collect_conductor_sessions() {
    local count=0 line session_id status age provider label details=()

    [[ -f "${CONDUCTOR_ACTIVE_SESSIONS_FILE}" ]] || return 0
    while IFS=$'\t' read -r session_id status age provider label _; do
        [[ "${session_id}" == "session_id" ]] && continue
        [[ -n "${session_id}" ]] || continue
        count=$(( count + 1 ))
        line="${session_id}"
        if [[ -n "${provider:-}" && "${provider}" != "unknown" ]]; then
            line="${line} ${provider}"
        fi
        if [[ -n "${label:-}" && "${label}" != "none" ]]; then
            line="${line}/${label}"
        fi
        line="${line} (${age}s old, status=${status:-unknown})"
        details+=("${line}")
    done < "${CONDUCTOR_ACTIVE_SESSIONS_FILE}"

    if (( count > 1 )); then
        add_warning "Multiple conductor sessions active (${count}): $(array_join '; ' details). Shared inbox/tasks/log apply."
    elif (( count == 1 )); then
        add_active "1 conductor session active: ${details[0]}."
    else
        add_quiet "No active conductor session."
    fi
}

core_worker_age() {
    local core_id="$1"
    local hb_file="agents/${core_id}/heartbeat" hb
    [[ -f "${hb_file}" ]] || { printf 'no heartbeat'; return 0; }
    hb="$(cat "${hb_file}" 2>/dev/null || echo 0)"
    [[ "${hb}" =~ ^[0-9]+$ ]] || { printf 'unreadable heartbeat'; return 0; }
    (( hb > 0 )) || { printf 'no heartbeat'; return 0; }
    compact_age "$(( now - hb ))"
}

core_worker_age_seconds() {
    local core_id="$1"
    local hb_file="agents/${core_id}/heartbeat" hb
    [[ -f "${hb_file}" ]] || return 1
    hb="$(cat "${hb_file}" 2>/dev/null || echo 0)"
    [[ "${hb}" =~ ^[0-9]+$ ]] || return 1
    (( hb > 0 )) || return 1
    printf '%s' "$(( now - hb ))"
}

agent_session_backend() {
    local session="$1"
    local backend
    backend="$(cortex_session_backend_resolve "${CORTEX_SESSION_BACKEND:-${CORTEX_DEFAULT_SESSION_BACKEND}}")" || return 1
    if cortex_session_backend_available "${backend}" && cortex_session_exists "${backend}" "${session}"; then
        printf '%s' "${backend}"
        return 0
    fi
    return 1
}

periodic_records() {
    local output rc
    [[ -x scripts/periodics_check.sh ]] || return 0
    output="$(run_with_timeout "${PERIODICS_TIMEOUT_SECONDS}" bash scripts/periodics_check.sh status 2>&1)"
    rc=$?
    if (( rc == 124 || rc == 137 )); then
        printf 'probe_error\tperiodics_check\tperiodic status collection\ttimed out after %ss\n' "${PERIODICS_TIMEOUT_SECONDS}"
        return 0
    fi
    printf '%s\n' "${output}" | awk '
        /^[[:space:]]*(ok|disabled|advisory|unreachable|probe_error|down)[[:space:]]/ {
            if (job != "") print state "\t" job "\t" desc "\t" reason
            state = $1
            job = $2
            desc = $0
            sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+/, "", desc)
            reason = ""
            next
        }
        job != "" && reason == "" && NF {
            reason = $0
            sub(/^[[:space:]]+/, "", reason)
        }
        END {
            if (job != "") print state "\t" job "\t" desc "\t" reason
        }'
}

messenger_selfcheck_evidence() {
    local job="$1" host="" process_name="" session_name="" snapshot age mtime
    case "${job}" in
        signal_inbox_daemon)
            host="${CORTEX_DEFAULT_SIGNAL_RELAY_HOST:-}"
            process_name="signal_inbox_daemon.py"
            session_name="${CORTEX_DEFAULT_SIGNAL_INBOX_SESSION:-}"
            ;;
        telegram_inbox_daemon)
            host="${CORTEX_DEFAULT_TELEGRAM_RELAY_HOST:-}"
            process_name="telegram_inbox_daemon.py"
            session_name="${CORTEX_DEFAULT_TELEGRAM_INBOX_SESSION:-}"
            ;;
        *)
            return 1
            ;;
    esac

    [[ -n "${host}" ]] || return 1
    snapshot="${CORTEX_DIR}/agents/${host}/selfcheck_latest.snapshot"
    [[ -f "${snapshot}" ]] || return 1

    mtime="$(file_mtime_epoch "${snapshot}")"
    [[ "${mtime}" =~ ^[0-9]+$ ]] || return 1
    age=$(( now - mtime ))
    (( age >= 0 && age <= SELFCHECK_FRESH_SECONDS )) || return 1

    if grep -Fq "${process_name}" "${snapshot}" 2>/dev/null; then
        if [[ -n "${session_name}" ]] && grep -Fq ".${session_name}" "${snapshot}" 2>/dev/null; then
            printf 'fresh %s self-check (%s old) shows the daemon process and %s session alive' \
                "${host}" "$(compact_age "${age}")" "${session_name}"
        else
            printf 'fresh %s self-check (%s old) shows the daemon process alive' \
                "${host}" "$(compact_age "${age}")"
        fi
        return 0
    fi

    if [[ -n "${session_name}" ]] && grep -Fq ".${session_name}" "${snapshot}" 2>/dev/null; then
        printf 'fresh %s self-check (%s old) shows the %s session alive' \
            "${host}" "$(compact_age "${age}")" "${session_name}"
        return 0
    fi

    return 1
}

collect_queues() {
    local inbox_n=0 bcast_n suggestion_n=0 attention_n=0 msg

    while IFS= read -r msg; do
        [[ -n "${msg}" ]] || continue
        inbox_n=$(( inbox_n + 1 ))
        case "$(inbox_message_class "${msg}")" in
            suggestion) suggestion_n=$(( suggestion_n + 1 )) ;;
            *) attention_n=$(( attention_n + 1 )) ;;
        esac
    done < <(find "${CONDUCTOR_INBOX}" -maxdepth 1 -name '*.msg' -type f 2>/dev/null)

    bcast_n=$(find broadcast -maxdepth 1 -name '*.msg' -type f 2>/dev/null | wc -l)

    if (( inbox_n > 0 )); then
        if (( attention_n > 0 )); then
            add_critical "Conductor inbox has ${inbox_n} unread $(plural "${inbox_n}" message) (${attention_n} attention-worthy, ${suggestion_n} suggestion-only)."
        else
            add_warning "Conductor inbox has ${inbox_n} unread suggestion-only worker check $(plural "${inbox_n}" message)."
        fi
        while IFS= read -r msg; do
            local from type status preview
            [[ -n "${msg}" ]] || continue
            from="$(message_field "${msg}" FROM)"
            type="$(message_field "${msg}" TYPE)"
            status="$(message_field "${msg}" STATUS)"
            preview="$(message_preview "${msg}")"
            add_active "Inbox: ${from:-unknown} ${type:-message} ${status:-unknown}: ${preview:-no preview}."
        done < <(LC_ALL=C ls -1t "${CONDUCTOR_INBOX}"/*.msg 2>/dev/null | head -3)
    else
        add_quiet "No conductor inbox messages."
    fi

    if (( bcast_n > 0 )); then
        add_warning "Broadcast queue has ${bcast_n} pending $(plural "${bcast_n}" message)."
    else
        add_quiet "No broadcast backlog."
    fi
}

collect_tasks() {
    local open_n=0 doing_n=0 block_n=0
    if [[ -f agents/conductor/tasks.md ]]; then
        open_n=$(count_task_status open agents/conductor/tasks.md)
        doing_n=$(count_task_status doing agents/conductor/tasks.md)
        block_n=$(count_task_status blocked agents/conductor/tasks.md)
    fi

    if (( block_n > 0 )); then
        add_warning "${block_n} conductor $(plural "${block_n}" task) $( (( block_n == 1 )) && printf 'is' || printf 'are' ) blocked."
    fi
    if (( open_n > 0 || doing_n > 0 )); then
        add_active "Conductor tasks: ${open_n} open, ${doing_n} doing, ${block_n} blocked."
    elif (( block_n == 0 )); then
        add_quiet "No open conductor tasks."
    fi

    local flagged_n=0
    if [[ -f scripts/task_board_report.sh ]]; then
        flagged_n="$(bash scripts/task_board_report.sh --count 2>/dev/null || printf '0')"
    fi
    if (( flagged_n > 0 )); then
        add_warning "${flagged_n} stale/overdue task $(plural "${flagged_n}" row) across all boards (bash scripts/task_board_report.sh --stale)."
    fi
}

collect_periodics() {
    local state job desc reason commits evidence

    while IFS=$'\t' read -r state job desc reason; do
        [[ -n "${job:-}" ]] || continue
        case "${state}" in
            down)
                add_critical "Periodic job ${job} is down: ${reason:-${desc}}."
                ;;
            unreachable|probe_error)
                if evidence="$(messenger_selfcheck_evidence "${job}")"; then
                    add_active "Periodic ${job} is visibility-limited: ${evidence}; direct probe said ${reason:-${desc}}."
                else
                    add_critical "Cannot verify ${job}: ${reason:-${desc}}."
                fi
                ;;
            advisory)
                if [[ "${job}" == "sync_public_drift" && "${reason}" =~ ^([0-9]+)[[:space:]]commit ]]; then
                    commits="${BASH_REMATCH[1]}"
                    add_warning "Public sync is behind: ${commits} framework $(plural "${commits}" commit) pending."
                else
                    add_warning "Periodic advisory for ${job}: ${reason:-${desc}}."
                fi
                ;;
            disabled)
                add_quiet "${job} is intentionally disabled."
                ;;
        esac
    done < <(periodic_records)
}

list_core_worker_ids() {
    local meta_path meta_name worker_id
    while IFS= read -r meta_path; do
        [[ -n "${meta_path}" ]] || continue
        grep -qx 'META_core=yes' "${meta_path}" || continue
        meta_name="$(basename "${meta_path}")"
        worker_id="${meta_name#worker.}"
        worker_id="${worker_id%.meta}"
        printf '%s\n' "${worker_id}"
    done < <(find roles -type f -name 'worker.*.meta' 2>/dev/null | LC_ALL=C sort)
}

collect_core_workers() {
    local running=() absent=() stale=() bad=() cooldowns=() visibility_limited=()
    local core_id age age_seconds status cooldown running_list absent_list stale_list bad_list cooldown_list visibility_limited_list
    local saw_core=0

    while IFS= read -r core_id; do
        [[ -n "${core_id}" ]] || continue
        saw_core=1
        [[ -d "agents/${core_id}" ]] || continue
        status="$(format_agent_status "agents/${core_id}/status")"
        age="$(core_worker_age "${core_id}")"
        cooldown="$(provider_cooldown_summary "${core_id}" || true)"
        [[ -n "${cooldown}" ]] && cooldowns+=("${core_id}: ${cooldown}")
        if [[ "${status}" == "error" ]]; then
            bad+=("${core_id} status=error")
            continue
        fi

        if ! agent_session_backend "worker_${core_id}" >/dev/null; then
            # A sandboxed snapshot run cannot see host `screen` sockets, so an
            # invisible session is not proof of absence. A fresh heartbeat means
            # the worker is alive and only the screen view is limited; treat that
            # as visibility-limited, not absent. Warn "absent" only when the
            # heartbeat is also stale/unreadable (genuinely down).
            if age_seconds="$(core_worker_age_seconds "${core_id}")" \
                && (( age_seconds <= CORTEX_DEFAULT_HEARTBEAT_STALE_SECONDS )); then
                visibility_limited+=("${core_id} (screen not visible, heartbeat ${age} old, status=${status})")
            else
                absent+=("${core_id} (screen absent, heartbeat ${age} old, status=${status})")
            fi
            continue
        fi

        if ! age_seconds="$(core_worker_age_seconds "${core_id}")"; then
            bad+=("${core_id} screen running but heartbeat unreadable")
        elif (( age_seconds > CORTEX_DEFAULT_HEARTBEAT_STALE_SECONDS )); then
            stale+=("${core_id} (screen running, heartbeat ${age} old, status=${status})")
        else
            running+=("${core_id} (${age} old, status=${status})")
        fi
    done < <(list_core_worker_ids)

    if (( saw_core == 0 )); then
        add_quiet "No core-worker metadata found under roles/."
        return 0
    fi

    if (( $(array_len bad) > 0 )); then
        bad_list="$(array_join ', ' bad)"
        add_critical "Core worker health is broken: ${bad_list}."
    fi

    if (( $(array_len stale) > 0 )); then
        stale_list="$(array_join ', ' stale)"
        add_critical "Core worker screens are running but stale: ${stale_list}."
    fi

    if (( $(array_len absent) > 0 )); then
        absent_list="$(array_join ', ' absent)"
        add_warning "Core worker screens are absent: ${absent_list}."
    fi

    if (( $(array_len visibility_limited) > 0 )); then
        visibility_limited_list="$(array_join ', ' visibility_limited)"
        add_active "Core worker screens not visible from this context but heartbeats fresh (visibility-limited, likely sandboxed): ${visibility_limited_list}."
    fi

    if (( $(array_len running) > 0 )); then
        running_list="$(array_join ', ' running)"
        add_quiet "Core worker screens are running with fresh heartbeats: ${running_list}."
    elif (( $(array_len bad) == 0 && $(array_len stale) == 0 && $(array_len absent) == 0 && $(array_len visibility_limited) == 0 )); then
        add_quiet "No core worker homes found."
    fi

    if (( $(array_len cooldowns) > 0 )); then
        cooldown_list="$(array_join '; ' cooldowns)"
        add_warning "Provider cooldowns active: ${cooldown_list}."
    fi
}

collect_snapshot_freshness() {
    local success_iso success_epoch backup_age backup_age_str
    success_iso="$(last_snapshot_success_iso)"
    if [[ -z "${success_iso}" ]]; then
        add_warning "Snapshots have no recorded successful run."
        return 0
    fi

    success_epoch="$(iso8601_to_epoch_utc "${success_iso}")"
    if (( success_epoch <= 0 )); then
        add_warning "Snapshot freshness is unreadable: last success timestamp is ${success_iso}."
        return 0
    fi

    backup_age=$(( now - success_epoch ))
    backup_age_str="$(compact_age "${backup_age}")"
    if (( backup_age > BACKUP_FRESH_SECONDS )); then
        add_warning "Snapshots are stale: last success ${success_iso}, ${backup_age_str} ago."
    else
        add_quiet "Snapshots are fresh: last success ${backup_age_str} ago."
    fi
}

collect_watch() {
    local wlines=0 wmtime=0 wage=0 wage_str="unknown"

    if [[ -f "${WATCH_FILE}" ]]; then
        wlines=$(awk 'NF { c++ } END { print c + 0 }' "${WATCH_FILE}" 2>/dev/null)
        wmtime="$(file_mtime_epoch "${WATCH_FILE}")"
        if (( wmtime > 0 )); then
            wage=$(( now - wmtime ))
            wage_str="$(compact_age "${wage}")"
        fi
    fi

    if (( wlines > 0 )); then
        add_warning "watch.txt has content to review: ${wlines} $(plural "${wlines}" line), modified ${wage_str} ago."
    else
        add_quiet "watch.txt is empty."
    fi
}

collect_usage() {
    local usage_line
    if [[ ! -x scripts/usage_report.py ]]; then
        return 0
    fi
    usage_line="$(scripts/usage_report.py --since 24h --quiet-line 2>/dev/null || true)"
    [[ -n "${usage_line}" ]] || return 0
    case "${usage_line}" in
        *"no ledger yet"*|*"no provider calls recorded"*)
            add_quiet "${usage_line}"
            ;;
        *)
            add_active "${usage_line}"
            ;;
    esac
}

collect_conductor_sessions
collect_queues
collect_tasks
collect_periodics
collect_core_workers
collect_snapshot_freshness
collect_watch
collect_usage

if (( $(array_len CRITICAL) > 0 )); then
    status="Needs attention"
elif (( $(array_len WARNINGS) > 0 )); then
    status="Warnings"
else
    status="Healthy"
fi

printf 'CORTEX OPERATOR VIEW  |  %s\n' "${status}"
printf 'Updated: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"

print_section_array "Critical" CRITICAL
print_section_array "Warnings" WARNINGS
print_section_array "Active" ACTIVE
print_section_array "Quiet" QUIET
