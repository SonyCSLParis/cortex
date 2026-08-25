#!/usr/bin/env bash
# research_dashboard.sh — deterministic status board for the research cluster.
#
# Reads only on-disk state (no LLM, no agent calls):
#   - liveness:        configured session `worker_<name>` / process presence
#   - state:           agents/<name>/status  + agents/<name>/heartbeat (epoch)
#   - currently doing: last timestamped header line in the agent state
#                      dir's log.md (`agents/<name>/` by default, or
#                      `TARGET_FOLDER/<name>/` for redirected research runs)
#   - lead logbook:    most recent research-lead logbook section from the
#                      resolved state dir
#   - working on:      CYCLE_ID + objective from the most recent COMMAND the
#                      agent received (agents/<name>/{inbox,archive}/*.msg)
#   - communication:   FROM/TO/TYPE/TIME/ROLE_RESULT parsed from every research
#                      agent's inbox+archive envelopes, newest last
#
# Usage:
#   scripts/research_dashboard.sh              # one-shot snapshot
#   scripts/research_dashboard.sh --watch [N]  # refresh every N seconds (default 60)
# Read-only display: never abort on a benign grep/ls miss, so no `set -e`.
set -uo pipefail

CORTEX_DIR="${CORTEX_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "${CORTEX_DIR}"
if [[ -r "${CORTEX_DIR}/config/cortex_defaults.sh" ]]; then
    source "${CORTEX_DIR}/config/cortex_defaults.sh"
fi
if [[ -r "${CORTEX_DIR}/scripts/session_backend.sh" ]]; then
    source "${CORTEX_DIR}/scripts/session_backend.sh"
fi
SESSION_BACKEND="${CORTEX_SESSION_BACKEND:-${CORTEX_DEFAULT_SESSION_BACKEND:-screen}}"

dashboard_session_exists() {
    local session="$1"
    if declare -F cortex_session_backend_resolve >/dev/null 2>&1; then
        local backend
        backend="$(cortex_session_backend_resolve "${SESSION_BACKEND}")" || return 1
        cortex_session_backend_available "${backend}" \
            && cortex_session_exists "${backend}" "${session}"
        return
    fi
    [[ "${SESSION_BACKEND}" == "screen" ]] || return 1
    screen -ls 2>/dev/null | grep -qE "\.${session}\b"
}

WATCH=0
INTERVAL=60
if [[ "${1:-}" == "--watch" ]]; then
    WATCH=1
    [[ -n "${2:-}" ]] && INTERVAL="$2"
fi

# Order: lead first, then specialists alphabetically.
research_agents() {
    local d name
    [[ -d agents/research-lead ]] && echo research-lead
    for d in agents/research-*; do
        name="$(basename "$d")"
        [[ "$name" == "research-lead" ]] && continue
        echo "$name"
    done
}

mission_target_folder() {
    local target target_path target_real cortex_real
    target="$(awk '
        BEGIN { in_block=0 }
        /^TARGET_FOLDER:[[:space:]]*$/ { in_block=1; next }
        in_block && /^[A-Z][A-Z0-9_ ]*:[[:space:]]*$/ { exit }
        in_block {
            line=$0
            sub(/^[[:space:]]*-[[:space:]]*/, "", line)
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (line != "" && line !~ /^#/) { print line; exit }
        }
    ' agents/research-lead/mission.txt 2>/dev/null)"
    [[ -n "$target" ]] || return 1
    if [[ "$target" == /* ]]; then
        target_path="$target"
    else
        target_path="${CORTEX_DIR}/${target}"
    fi
    [[ -d "$target_path" ]] || return 1
    target_real="$(realpath "$target_path" 2>/dev/null || printf '%s' "$target_path")"
    cortex_real="$(realpath "$CORTEX_DIR" 2>/dev/null || printf '%s' "$CORTEX_DIR")"
    [[ "$target_real" == "$cortex_real" || "$target_real" == "$cortex_real/"* ]] || return 1
    printf '%s\n' "$target_real"
}

agent_state_dir() {
    local name="$1" target
    target="$(mission_target_folder || true)"
    if [[ -n "$target" ]]; then
        printf '%s/%s\n' "$target" "$name"
    else
        printf 'agents/%s\n' "$name"
    fi
}

# Extract a header value (e.g. FROM/TO/TYPE/TIME) from a .msg envelope (above ---).
msg_header() { sed -n "s/^$2:[[:space:]]*//p" "$1" 2>/dev/null | head -n1; }

# First meaningful body line after a labelled field (e.g. SUMMARY/OBJECTIVE).
msg_field_first() {
    awk -v key="$2" '
        $0 ~ "^"key":" {grab=1; next}
        grab==1 {
            line=$0; sub(/^[[:space:]]*-?[[:space:]]*/,"",line)
            if (line!="") {print line; exit}
        }' "$1" 2>/dev/null | head -n1
}

trunc() { local s="$1" n="$2"; if [[ ${#s} -gt $n ]]; then printf '%s…' "${s:0:$((n-1))}"; else printf '%s' "$s"; fi; }

# Last timestamped header line of a log.md (lines beginning with "[").
last_log_activity() {
    local f line
    f="$(agent_state_dir "$1")/log.md"
    [[ -f "$f" ]] || { echo "—"; return; }
    line="$(grep -E '^\[' "$f" | tail -n1)"
    # Strip leading "[timestamp] name | " or "[timestamp] name: " prefix.
    line="$(printf '%s' "$line" | sed -E 's/^\[[^]]*\][[:space:]]*[^|:]*[|:][[:space:]]*//')"
    printf '%s' "${line:-—}"
}

last_logbook_entry() {
    local name="$1" f entry title="" detail="" line
    f="$(agent_state_dir "$name")/logbook.md"
    [[ -f "$f" ]] || { echo "—"; return; }

    entry="$(awk '
        /^## \[/ { block=$0 ORS; capture=1; next }
        capture { block=block $0 ORS }
        END { printf "%s", block }
    ' "$f" 2>/dev/null)"
    [[ -n "$entry" ]] || { echo "—"; return; }

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        if [[ -z "$title" ]]; then
            title="${line#\#\# }"
            continue
        fi
        detail="${line#- }"
        break
    done <<< "$(printf '%s\n' "$entry" | sed '/^[[:space:]]*$/d')"

    if [[ -n "$detail" ]]; then
        printf '%s | %s' "$title" "$detail"
    else
        printf '%s' "${title:-—}"
    fi
}

# Most recent COMMAND received by an agent → "CYCLE | objective".
current_task() {
    local name="$1" newest="" t best_t=0 f to typ tm
    for f in agents/"$name"/archive/*.msg agents/"$name"/inbox/*.msg; do
        [[ -e "$f" ]] || continue
        to="$(msg_header "$f" TO)"; typ="$(msg_header "$f" TYPE)"
        [[ "$to" == "$name" && "$typ" == "COMMAND" ]] || continue
        tm="$(msg_header "$f" TIME)"; [[ "$tm" =~ ^[0-9]+$ ]] || tm=0
        if (( tm >= best_t )); then best_t=$tm; newest="$f"; fi
    done
    [[ -n "$newest" ]] || { echo "—"; return; }
    local cyc obj
    cyc="$(grep -aoE 'C[0-9]{8}-[0-9]+' "$newest" | head -n1)"
    obj="$(msg_field_first "$newest" OBJECTIVE)"
    [[ -n "$obj" ]] || obj="$(msg_field_first "$newest" SUMMARY)"
    printf '%s | %s' "${cyc:-?}" "$(trunc "${obj:-—}" 60)"
}

now="$(date +%s)"

render() {
    now="$(date +%s)"
    local cyc mission lead_status lead_state_dir
    lead_state_dir="$(agent_state_dir research-lead)"
    cyc="$(sed -n 's/^- cycle_id:[[:space:]]*//p' "${lead_state_dir}/cluster_state.md" 2>/dev/null | head -n1)"
    mission="$(sed -n 's/^- mission:[[:space:]]*//p' "${lead_state_dir}/cluster_state.md" 2>/dev/null | head -n1)"
    lead_status="$(sed -n 's/^- status:[[:space:]]*//p' "${lead_state_dir}/cluster_state.md" 2>/dev/null | head -n1)"

    printf '╔══════════════════════════════════════════════════════════════════════════════════════╗\n'
    printf '║ RESEARCH CLUSTER DASHBOARD   %-57s ║\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf '╚══════════════════════════════════════════════════════════════════════════════════════╝\n'
    printf 'Active cycle : %s\n' "${cyc:-—}"
    printf 'Mission      : %s\n' "$(trunc "${mission:-—}" 86)"
    printf 'Lead status  : %s\n' "$(trunc "${lead_status:-—}" 86)"
    printf 'Lead logbook : %s\n\n' "$(trunc "$(last_logbook_entry research-lead)" 86)"

    # ── Worker table ──────────────────────────────────────────────────────────
    {
        printf 'WORKER|PROC|STATE|HB|INBOX|CURRENTLY DOING\n'
        printf '%s\n' '------|----|-----|--|-----|---------------'
        local name proc st hb age ib
        while read -r name; do
            if pgrep -f "scripts/start_agent.sh --role worker --name ${name}\b" >/dev/null 2>&1 \
               || dashboard_session_exists "worker_${name}"; then
                proc="up"
            else
                proc="DOWN"
            fi
            st="$(cat "agents/$name/status" 2>/dev/null || echo '?')"
            hb="$(cat "agents/$name/heartbeat" 2>/dev/null || echo '')"
            if [[ "$hb" =~ ^[0-9]+$ ]]; then age="$(( now - hb ))s"; else age="—"; fi
            ib="$(ls agents/"$name"/inbox/*.msg 2>/dev/null | wc -l | tr -d ' ')"
            printf '%s|%s|%s|%s|%s|%s\n' \
                "$name" "$proc" "$st" "$age" "$ib" "$(trunc "$(last_log_activity "$name")" 52)"
        done < <(research_agents)
    } | column -t -s '|'

    # ── Task focus ────────────────────────────────────────────────────────────
    printf '\nWORKING ON (most recent COMMAND received)\n'
    {
        printf 'WORKER|CYCLE | OBJECTIVE\n'
        printf '%s\n' '------|---------------'
        local name
        while read -r name; do
            printf '%s|%s\n' "$name" "$(current_task "$name")"
        done < <(research_agents)
    } | column -t -s '|'

    # ── Communication graph ──────────────────────────────────────────────────
    printf '\nRECENT COMMUNICATION (newest last)\n'
    {
        printf 'TIME|FROM → TO|TYPE|RESULT|SUMMARY\n'
        printf '%s\n' '----|--------|----|------|-------'
        local f frm to typ tm res sm line
        for f in agents/research-*/archive/*.msg agents/research-*/inbox/*.msg; do
            [[ -e "$f" ]] || continue
            tm="$(msg_header "$f" TIME)"; [[ "$tm" =~ ^[0-9]+$ ]] || continue
            frm="$(msg_header "$f" FROM)"; to="$(msg_header "$f" TO)"; typ="$(msg_header "$f" TYPE)"
            res="$(sed -n 's/^ROLE_RESULT:[[:space:]]*//p' "$f" 2>/dev/null | head -n1)"
            sm="$(msg_field_first "$f" SUMMARY)"; [[ -n "$sm" ]] || sm="$(msg_field_first "$f" OBJECTIVE)"
            printf '%s\t%s\t%s → %s\t%s\t%s\t%s\n' \
                "$tm" "$(date -d "@$tm" '+%H:%M:%S' 2>/dev/null)" "$frm" "$to" "$typ" "${res:--}" "$(trunc "${sm:-—}" 46)"
        done | sort -t$'\t' -k1,1n -u | tail -n 14 | cut -f2- \
            | while IFS=$'\t' read -r t route typ res sm; do printf '%s|%s|%s|%s|%s\n' "$t" "$route" "$typ" "$res" "$sm"; done
    } | column -t -s '|'
}

if [[ "$WATCH" -eq 1 ]]; then
    while true; do
        clear
        render
        printf '\n(refreshing every %ss — Ctrl-C to stop)\n' "$INTERVAL"
        sleep "$INTERVAL"
    done
else
    render
fi
