#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CORTEX_DIR="${CORTEX_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd -P)}"

COLOR_MODE="auto"
ALIVE_HOURS=24
SHOW_ALL=0

usage() {
    cat <<'EOF'
Usage:
  bash scripts/living_agent_roster.sh [--alive-hours N] [--all] [--color|--no-color]

Show a richer roster for agents with recent heartbeats. By default, only
agents whose heartbeat is no older than 24 hours are shown.

Examples:
  bash scripts/living_agent_roster.sh
  bash scripts/living_agent_roster.sh --alive-hours 6
  bash scripts/living_agent_roster.sh --all
  watch -c 'bash scripts/living_agent_roster.sh --color --alive-hours 24'
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --color)
            COLOR_MODE="always"
            shift
            ;;
        --no-color)
            COLOR_MODE="never"
            shift
            ;;
        --alive-hours)
            [[ $# -ge 2 ]] || { echo "Missing value for --alive-hours" >&2; exit 2; }
            [[ "$2" =~ ^[0-9]+$ ]] || { echo "--alive-hours expects a non-negative integer" >&2; exit 2; }
            ALIVE_HOURS="$2"
            shift 2
            ;;
        --all)
            SHOW_ALL=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

source "${CORTEX_DIR}/config/cortex_defaults.sh"
source "${CORTEX_DIR}/scripts/bash_compat.sh"

if [[ "${COLOR_MODE}" == "always" ]] || { [[ "${COLOR_MODE}" == "auto" ]] && [[ -t 1 ]]; }; then
    GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; GREY='\033[0;90m'
    BOLD='\033[1m'; RESET='\033[0m'
else
    GREEN=''; YELLOW=''; RED=''; GREY=''
    BOLD=''; RESET=''
fi

ALIVE_SECONDS=$(( ALIVE_HOURS * 3600 ))
SCREEN_SESSION_LISTING="$(screen -ls 2>/dev/null || true)"
NOW_EPOCH="$(date -u +%s)"

compact_age() {
    local age="${1:-0}"
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

trunc() {
    local text="$1" max_len="$2"
    if (( ${#text} > max_len )); then
        printf '%s...' "${text:0:$((max_len - 3))}"
    else
        printf '%s' "${text}"
    fi
}

agent_status_value() {
    local status_file="$1" raw
    [[ -f "${status_file}" ]] || { printf '?'; return 0; }
    raw="$(tr -d '\r\n' < "${status_file}" 2>/dev/null || true)"
    case "${raw}" in
        idle|busy|working|selfcheck|error|offline) printf '%s' "${raw}" ;;
        "") printf 'invalid(empty)' ;;
        *) printf 'invalid(%s)' "${raw}" ;;
    esac
}

screen_session_exists() {
    local session="$1"
    printf '%s\n' "${SCREEN_SESSION_LISTING}" | awk -v session="${session}" '
        $1 ~ /^[0-9]+\./ {
            sub(/^[0-9]+\./, "", $1)
            if ($1 == session) found = 1
        }
        END { exit found ? 0 : 1 }
    '
}

agent_info_field() {
    local info_file="$1" key="$2"
    awk -F: -v key="${key}" '$1 == key { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }' \
        "${info_file}" 2>/dev/null
}

agent_screen_name() {
    local role="$1" agent_id="$2"
    case "${role}" in
        worker) printf 'worker_%s' "${agent_id}" ;;
        node) printf 'node_%s' "${agent_id}" ;;
        watch) printf 'watch' ;;
        *) return 1 ;;
    esac
}

agent_host_label() {
    local info_file="$1" host ip
    host="$(trim_whitespace "$(agent_info_field "${info_file}" HOST)")"
    [[ -n "${host}" ]] && { printf '%s' "${host}"; return 0; }
    ip="$(trim_whitespace "$(agent_info_field "${info_file}" IP)")"
    [[ -n "${ip}" ]] && { printf '%s' "${ip}"; return 0; }
    printf '—'
}

agent_model_label() {
    local info_file="$1" provider model fallback
    provider="$(trim_whitespace "$(agent_info_field "${info_file}" PROVIDER)")"
    model=""
    fallback=""
    case "${provider}" in
        codex) model="$(trim_whitespace "$(agent_info_field "${info_file}" CODEX_MODEL)")" ;;
        claude) model="$(trim_whitespace "$(agent_info_field "${info_file}" CLAUDE_MODEL)")" ;;
    esac
    fallback="$(trim_whitespace "$(agent_info_field "${info_file}" FALLBACK_PROVIDER)")"

    if [[ -n "${provider}" && -n "${model}" ]]; then
        printf '%s/%s' "${provider}" "${model}"
    elif [[ -n "${provider}" ]]; then
        printf '%s' "${provider}"
    elif [[ -n "${model}" ]]; then
        printf '%s' "${model}"
    else
        printf '—'
    fi

    if [[ -n "${fallback}" ]]; then
        printf ' (fb:%s)' "${fallback}"
    fi
}

msg_header() {
    sed -n "s/^$2:[[:space:]]*//p" "$1" 2>/dev/null | head -n1
}

msg_field_first() {
    awk -v key="$2" '
        $0 ~ "^" key ":" { grab=1; next }
        grab == 1 {
            line=$0
            sub(/^[[:space:]]*-?[[:space:]]*/, "", line)
            if (line != "") { print line; exit }
        }
    ' "$1" 2>/dev/null | head -n1
}

msg_body_first() {
    awk '
        body == 1 {
            line=$0
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (line != "") { print line; exit }
        }
        /^---$/ { body=1 }
    ' "$1" 2>/dev/null | head -n1
}

latest_command_record() {
    local agent_id="$1" best_ts=0 newest="" f to typ ts from cyc summary
    for f in "${CORTEX_DIR}/agents/${agent_id}"/archive/*.msg "${CORTEX_DIR}/agents/${agent_id}"/inbox/*.msg; do
        [[ -e "${f}" ]] || continue
        to="$(trim_whitespace "$(msg_header "${f}" TO)")"
        typ="$(trim_whitespace "$(msg_header "${f}" TYPE)")"
        [[ "${to}" == "${agent_id}" && "${typ}" == "COMMAND" ]] || continue
        ts="$(trim_whitespace "$(msg_header "${f}" TIME)")"
        [[ "${ts}" =~ ^[0-9]+$ ]] || ts=0
        if (( ts >= best_ts )); then
            best_ts="${ts}"
            newest="${f}"
        fi
    done

    [[ -n "${newest}" ]] || return 1

    from="$(trim_whitespace "$(msg_header "${newest}" FROM)")"
    cyc="$(grep -aoE 'C[0-9]{8}-[0-9]+' "${newest}" | head -n1)"
    summary="$(trim_whitespace "$(msg_field_first "${newest}" OBJECTIVE)")"
    [[ -n "${summary}" ]] || summary="$(trim_whitespace "$(msg_field_first "${newest}" SUMMARY)")"
    [[ -n "${summary}" ]] || summary="$(trim_whitespace "$(msg_body_first "${newest}")")"
    if [[ -n "${cyc}" ]]; then
        summary="${cyc} | ${summary}"
    fi
    printf '%s\t%s\t%s\n' "${best_ts}" "${from:-unknown}" "${summary:-—}"
}

last_log_record() {
    local agent_dir="$1" log_file line ts summary
    log_file="${agent_dir}/log.md"
    [[ -f "${log_file}" ]] || return 1
    line="$(awk '/^\[/ { last=$0 } END { print last }' "${log_file}" 2>/dev/null)"
    [[ -n "${line}" ]] || return 1
    ts="${line%%]*}"
    ts="${ts#[}"
    summary="$(printf '%s' "${line}" | sed -E 's/^\[[^]]*\][[:space:]]*[^|:]*[|:][[:space:]]*//')"
    summary="$(trim_whitespace "${summary}")"
    printf '%s\t%s\n' "${ts}" "${summary:-—}"
}

age_from_iso() {
    local iso="$1" epoch
    [[ -n "${iso}" ]] || { printf '—'; return 0; }
    epoch="$(iso8601_to_epoch_utc "${iso}" 2>/dev/null || echo 0)"
    [[ "${epoch}" =~ ^[0-9]+$ ]] || epoch=0
    (( epoch > 0 )) || { printf '—'; return 0; }
    printf '%s' "$(compact_age "$(( NOW_EPOCH - epoch ))")"
}

agent_color() {
    local status="$1" hb_age="$2" screen_state="$3"
    if [[ "${status}" == "error" || "${status}" == invalid* || "${status}" == "?" ]]; then
        printf '%s' "${RED}"
    elif [[ "${status}" == "offline" ]]; then
        printf '%s' "${GREY}"
    elif (( hb_age > ALIVE_SECONDS )) || [[ "${screen_state}" == "down" ]]; then
        printf '%s' "${YELLOW}"
    else
        printf '%s' "${GREEN}"
    fi
}

collect_rows() {
    local row_file="$1"
    local agent_dir agent_id info_file role status hb hb_age hb_age_str inbox_n screen_name screen_state host model
    local last_log_ts last_log_age last_log_summary cmd_ts cmd_age cmd_from cmd_summary cmd_record log_record color

    : > "${row_file}"

    while IFS= read -r agent_dir; do
        [[ -d "${agent_dir}" ]] || continue
        agent_id="$(basename "${agent_dir}")"
        [[ "${agent_id}" == "conductor" ]] && continue

        info_file="${agent_dir}/info"
        role="$(trim_whitespace "$(agent_info_field "${info_file}" ROLE)")"
        [[ -n "${role}" ]] || role="?"
        status="$(agent_status_value "${agent_dir}/status")"

        hb=0
        if [[ -f "${agent_dir}/heartbeat" ]]; then
            hb="$(tr -dc '0-9' < "${agent_dir}/heartbeat" 2>/dev/null || echo 0)"
        fi
        if [[ "${hb}" =~ ^[0-9]+$ ]] && (( hb > 0 )); then
            hb_age=$(( NOW_EPOCH - hb ))
            hb_age_str="$(compact_age "${hb_age}")"
        else
            hb_age=$(( ALIVE_SECONDS + 1 ))
            hb_age_str="no-hb"
        fi

        if (( SHOW_ALL == 0 && hb_age > ALIVE_SECONDS )); then
            continue
        fi

        inbox_n="$(find "${agent_dir}/inbox" -maxdepth 1 -name '*.msg' -type f 2>/dev/null | wc -l | tr -d ' ')"
        host="$(agent_host_label "${info_file}")"
        model="$(agent_model_label "${info_file}")"

        screen_name=""
        screen_state="n/a"
        if [[ "${role}" == "?" ]]; then
            if [[ "${agent_id}" == "watch" ]]; then
                role="watch"
            elif screen_session_exists "worker_${agent_id}"; then
                role="worker"
            elif screen_session_exists "node_${agent_id}"; then
                role="node"
            fi
        fi
        if screen_name="$(agent_screen_name "${role}" "${agent_id}" 2>/dev/null)"; then
            if screen_session_exists "${screen_name}"; then
                screen_state="up"
            else
                screen_state="down"
            fi
        fi

        last_log_ts=""
        last_log_age="—"
        last_log_summary="—"
        if log_record="$(last_log_record "${agent_dir}")"; then
            last_log_ts="${log_record%%$'\t'*}"
            last_log_summary="${log_record#*$'\t'}"
            last_log_age="$(age_from_iso "${last_log_ts}")"
        fi

        cmd_ts=""
        cmd_age="—"
        cmd_from="—"
        cmd_summary="—"
        if cmd_record="$(latest_command_record "${agent_id}")"; then
            cmd_ts="${cmd_record%%$'\t'*}"
            cmd_record="${cmd_record#*$'\t'}"
            cmd_from="${cmd_record%%$'\t'*}"
            cmd_summary="${cmd_record#*$'\t'}"
            if [[ "${cmd_ts}" =~ ^[0-9]+$ ]] && (( cmd_ts > 0 )); then
                cmd_age="$(compact_age "$(( NOW_EPOCH - cmd_ts ))")"
            fi
        fi

        color="$(agent_color "${status}" "${hb_age}" "${screen_state}")"

        printf '%09d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "${hb_age}" "${agent_id}" "${role}" "${screen_state}" "${status}" "${hb_age_str}" \
            "${inbox_n}" "${host}" "${model}" "${last_log_age}" "${last_log_summary}" \
            "${cmd_age}" "${cmd_from}" "${cmd_summary}" "${screen_name:-—}" "${color}" "${RESET}" \
            >> "${row_file}"
    done < <(find "${CORTEX_DIR}/agents" -mindepth 1 -maxdepth 1 -type d | sort)
}

render() {
    local row_file count
    row_file="$(mktemp)"
    trap 'rm -f "${row_file}"' EXIT

    NOW_EPOCH="$(date -u +%s)"
    collect_rows "${row_file}"
    count="$(wc -l < "${row_file}" | tr -d ' ')"

    printf '%b\n' "${BOLD}LIVING AGENT ROSTER${RESET}"
    printf '  generated=%s  filter=%s  count=%s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S %Z')" \
        "$( (( SHOW_ALL )) && printf 'all agents' || printf 'heartbeat <= %sh' "${ALIVE_HOURS}" )" \
        "${count}"

    if [[ "${count}" == "0" ]]; then
        printf '  no agents matched the current filter\n'
        rm -f "${row_file}"
        trap - EXIT
        return 0
    fi

    printf '\n'
    {
        printf 'AGENT|ROLE|PROC|STATUS|HB|INBOX|HOST\n'
        printf '%s\n' '-----|----|----|------|--|-----|----'
        sort -n -k1,1 "${row_file}" | while IFS=$'\t' read -r hb_sort agent_id role screen_state status hb_age_str inbox_n host model last_log_age last_log_summary cmd_age cmd_from cmd_summary screen_name color reset; do
            printf '%b%s%b|%s|%s|%s|%s|%s|%s\n' \
                "${color}" "${agent_id}" "${RESET}" "${role}" "${screen_state}" "${status}" "${hb_age_str}" "${inbox_n}" "${host}"
        done
    } | column -t -s '|'

    printf '\n%b\n' "${BOLD}DETAILS${RESET}"
    sort -n -k1,1 "${row_file}" | while IFS=$'\t' read -r hb_sort agent_id role screen_state status hb_age_str inbox_n host model last_log_age last_log_summary cmd_age cmd_from cmd_summary screen_name color reset; do
        printf '\n%b%s%b\n' "${color}" "${agent_id}" "${RESET}"
        printf '  runtime : role=%s  screen=%s  status=%s  hb=%s  inbox=%s  host=%s\n' \
            "${role}" "${screen_state}" "${status}" "${hb_age_str}" "${inbox_n}" "${host}"
        printf '  model   : %s\n' "${model}"
        if [[ "${last_log_summary}" == "—" ]]; then
            printf '  last did: —\n'
        elif [[ "${last_log_age}" == "—" ]]; then
            printf '  last did: %s\n' "$(trunc "${last_log_summary}" 140)"
        else
            printf '  last did: %s ago — %s\n' "${last_log_age}" "$(trunc "${last_log_summary}" 140)"
        fi
        if [[ "${cmd_summary}" == "—" ]]; then
            printf '  assigned: —\n'
        elif [[ "${cmd_age}" == "—" ]]; then
            printf '  assigned: from %s — %s\n' \
                "${cmd_from}" "$(trunc "${cmd_summary}" 140)"
        else
            printf '  assigned: %s ago from %s — %s\n' \
                "${cmd_age}" "${cmd_from}" "$(trunc "${cmd_summary}" 140)"
        fi
    done

    rm -f "${row_file}"
    trap - EXIT
}

render
