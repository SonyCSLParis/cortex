#!/usr/bin/env bash
# Cross-board task report: list live task rows (open / doing / blocked) from
# every standard task board with age and staleness flags.
#
# Usage:
#   bash scripts/task_board_report.sh            # all live rows, flagged or not
#   bash scripts/task_board_report.sh --stale    # only flagged rows
#   bash scripts/task_board_report.sh --count    # number of flagged rows
#
# Flags (a row may carry several, comma-separated):
#   no-until  doing row without an `until YYYY-MM-DD` expiry in its text
#   overdue   doing row whose `until` date has passed
#   stale     open/blocked row older than CORTEX_DEFAULT_TASKS_OPEN_STALE_DAYS,
#             or doing row without `until` older than
#             CORTEX_DEFAULT_TASKS_DOING_MAX_DAYS
#   due       row carrying `due YYYY-MM-DD` with the date reached (reminders)
#
# Age is derived from the TASK_ID date (TYYYYMMDD-XX). Boards are discovered
# the same way scripts/cortex_doctor.sh does: agents/*/tasks.md,
# projects/*/tasks.md, users/*/tasks.md. Output is advisory; exit is always 0.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CORTEX_DIR="${CORTEX_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd -P)}"
# shellcheck disable=SC1091
[[ -f "${CORTEX_DIR}/config/cortex_defaults.sh" ]] && source "${CORTEX_DIR}/config/cortex_defaults.sh"
OPEN_STALE_DAYS="${CORTEX_DEFAULT_TASKS_OPEN_STALE_DAYS:-14}"
DOING_MAX_DAYS="${CORTEX_DEFAULT_TASKS_DOING_MAX_DAYS:-7}"

MODE=all
BOARDS=()
while (( $# )); do
    case "$1" in
        --stale) MODE=stale ;;
        --count) MODE=count ;;
        -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) BOARDS+=("$1") ;;
    esac
    shift
done

cd "${CORTEX_DIR}"
if (( ${#BOARDS[@]} == 0 )); then
    while IFS= read -r f; do BOARDS+=("$f"); done < <(
        find agents projects users -mindepth 2 -maxdepth 2 -type f -name tasks.md 2>/dev/null | LC_ALL=C sort
    )
fi
(( ${#BOARDS[@]} )) || { echo "# no task boards found"; exit 0; }

TODAY="$(date +%Y%m%d)"

awk -v today="${TODAY}" -v open_stale="${OPEN_STALE_DAYS}" -v doing_max="${DOING_MAX_DAYS}" -v mode="${MODE}" '
    function jdn(y, m, d) {  # days since epoch-like origin; only differences matter
        a = int((14 - m) / 12); y2 = y + 4800 - a; m2 = m + 12 * a - 3
        return d + int((153 * m2 + 2) / 5) + 365 * y2 + int(y2 / 4) - int(y2 / 100) + int(y2 / 400) - 32045
    }
    function days_from(ymd) { return jdn(substr(ymd, 1, 4) + 0, substr(ymd, 5, 2) + 0, substr(ymd, 7, 2) + 0) }
    function iso_to_ymd(s) { gsub(/-/, "", s); return s }
    BEGIN { tnum = days_from(today); flagged = 0; total = 0 }
    /^- \[(open|doing|blocked)\] T[0-9]{8}-[0-9]{2} / {
        status = $0; sub(/^- \[/, "", status); sub(/\].*$/, "", status)
        id = $0; sub(/^- \[[a-z]+\] /, "", id); sub(/ .*$/, "", id)
        age = tnum - days_from(substr(id, 2, 8))
        n = split($0, f, / \| /)
        summary = (n >= 4) ? f[4] : ""
        flags = ""
        if (status == "doing") {
            if (match($0, /until [0-9]{4}-[0-9]{2}-[0-9]{2}/)) {
                until = iso_to_ymd(substr($0, RSTART + 6, 10))
                if (days_from(until) < tnum) flags = flags "overdue,"
            } else {
                flags = flags "no-until,"
                if (age > doing_max) flags = flags "stale,"
            }
        } else if (age > open_stale) {
            flags = flags "stale,"
        }
        if (match($0, /due [0-9]{4}-[0-9]{2}-[0-9]{2}/)) {
            due = iso_to_ymd(substr($0, RSTART + 4, 10))
            if (days_from(due) <= tnum) flags = flags "due,"
        }
        sub(/,$/, "", flags)
        total++
        if (flags != "") flagged++
        if (mode == "count") next
        if (mode == "stale" && flags == "") next
        if (length(summary) > 72) summary = substr(summary, 1, 69) "..."
        printf "%-18s %-8s %-13s %4dd  %-40s %s\n", (flags == "" ? "-" : flags), status, id, age, FILENAME, summary
    }
    END {
        if (mode == "count") { print flagged; exit }
        printf "# %d live row(s), %d flagged (open/blocked stale > %sd, doing needs `until`, doing max %sd without it)\n", total, flagged, open_stale, doing_max
    }
' "${BOARDS[@]}"
