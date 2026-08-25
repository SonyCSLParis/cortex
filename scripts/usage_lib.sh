#!/usr/bin/env bash

# Shared provider-usage accounting helpers.
#
# The ledger is user-owned because provider usage spends the current user's
# budget, even when the call came from watch, a worker, or a node.

cortex_usage_user_home() {
    local cortex_dir="${CORTEX_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
    if [[ -z "${CORTEX_USER_HOME:-}" ]]; then
        if declare -F cortex_user_load >/dev/null 2>&1; then
            cortex_user_load "${cortex_dir}" >/dev/null 2>&1 || true
        elif [[ -f "${cortex_dir}/scripts/user_context.sh" ]]; then
            # shellcheck disable=SC1091
            source "${cortex_dir}/scripts/user_context.sh"
            cortex_user_load "${cortex_dir}" >/dev/null 2>&1 || true
        fi
    fi
    printf '%s\n' "${CORTEX_USER_HOME:-${cortex_dir}/users/unknown}"
}

cortex_usage_ledger_path() {
    if [[ -n "${CORTEX_USAGE_LEDGER:-}" ]]; then
        printf '%s\n' "${CORTEX_USAGE_LEDGER}"
        return 0
    fi
    printf '%s/usage/usage.tsv\n' "$(cortex_usage_user_home)"
}

cortex_usage_header() {
    printf '%s\n' \
        "timestamp_local	timestamp_utc	epoch	agent	role	run_kind	provider	model	input_tokens	cached_input_tokens	output_tokens	total_tokens	estimated_usd	estimate_note	source"
}

cortex_usage_clean_number() {
    printf '%s' "${1:-}" | tr -cd '0-9'
}

# Plausibility ceiling for any single per-call token field scraped from a
# transcript. Largest deployed Claude/Codex context windows are around 1M
# tokens; a hard cap of 100M (CORTEX_USAGE_MAX_TOKENS_PER_CALL) leaves two
# orders of magnitude of headroom for future models while still rejecting
# the kind of 5.8e20-token poison that the model can quote back into its
# own transcript and have the scraper pick up. Override the env var to
# loosen or tighten the bound for tests.
cortex_usage_token_plausible() {
    local value="${1:-}"
    [[ "${value}" =~ ^[0-9]+$ ]] || return 1
    local cap="${CORTEX_USAGE_MAX_TOKENS_PER_CALL:-100000000}"
    [[ "${cap}" =~ ^[0-9]+$ ]] || cap=100000000
    # Bash arithmetic handles up to 64-bit signed; well above 10^9.
    (( value <= cap ))
}

cortex_usage_price_pair() {
    local provider="$1" model="$2" key
    key="$(printf '%s:%s' "${provider}" "${model}" | tr '[:upper:]' '[:lower:]')"
    case "${key}" in
        codex:gpt-5.6|openai:gpt-5.6|codex:gpt-5.6-sol|openai:gpt-5.6-sol) printf '4 20' ;;
        codex:gpt-5.6-terra|openai:gpt-5.6-terra) printf '2 12' ;;
        codex:gpt-5.6-luna|openai:gpt-5.6-luna) printf '0.2 1.2' ;;
        codex:gpt-5.5|openai:gpt-5.5) printf '5 30' ;;
        codex:gpt-5.5-pro|openai:gpt-5.5-pro) printf '30 180' ;;
        codex:gpt-5.4|openai:gpt-5.4) printf '2.5 15' ;;
        codex:gpt-5.4-mini|openai:gpt-5.4-mini) printf '0.75 4.5' ;;
        codex:gpt-5|openai:gpt-5) printf '1.25 10' ;;
        codex:gpt-5-mini|openai:gpt-5-mini) printf '0.25 2' ;;
        codex:gpt-5-nano|openai:gpt-5-nano) printf '0.05 0.4' ;;
        claude:claude-fable-5|anthropic:claude-fable-5) printf '10 50' ;;
        claude:claude-opus-4-8*|anthropic:claude-opus-4-8*) printf '5 25' ;;
        claude:claude-opus-4-7|anthropic:claude-opus-4-7) printf '5 25' ;;
        claude:claude-opus-4-6|anthropic:claude-opus-4-6) printf '5 25' ;;
        claude:claude-opus-4-5|anthropic:claude-opus-4-5) printf '5 25' ;;
        claude:claude-sonnet-4-6|anthropic:claude-sonnet-4-6) printf '3 15' ;;
        claude:claude-sonnet-5|anthropic:claude-sonnet-5) printf '3 15' ;;
        claude:claude-sonnet-4-5|anthropic:claude-sonnet-4-5) printf '3 15' ;;
        claude:claude-haiku-4-5|anthropic:claude-haiku-4-5) printf '1 5' ;;
        *) return 1 ;;
    esac
}

cortex_usage_extract_first_match() {
    local file="$1" kind="$2"
    awk -v kind="${kind}" '
        BEGIN { IGNORECASE = 1 }
        {
            line = tolower($0)
            if (kind == "input") {
                if (line ~ /cached/) next
                if (match(line, /(input|prompt)[ _-]*tokens[^0-9]*[0-9][0-9,]*/)) {
                    s = substr(line, RSTART, RLENGTH)
                    gsub(/[^0-9]/, "", s)
                    print s
                    exit
                }
            } else if (kind == "cached") {
                if (match(line, /(cached input|cache hit|cache read)[ _-]*tokens[^0-9]*[0-9][0-9,]*/)) {
                    s = substr(line, RSTART, RLENGTH)
                    gsub(/[^0-9]/, "", s)
                    print s
                    exit
                }
            } else if (kind == "output") {
                if (match(line, /(output|completion)[ _-]*tokens[^0-9]*[0-9][0-9,]*/)) {
                    s = substr(line, RSTART, RLENGTH)
                    gsub(/[^0-9]/, "", s)
                    print s
                    exit
                }
            } else if (kind == "total") {
                if (line ~ /tokens used/) {
                    if (getline nextline > 0) {
                        gsub(/[^0-9]/, "", nextline)
                        if (nextline != "") {
                            print nextline
                            exit
                        }
                    }
                }
                if (match(line, /(total|used)[ _-]*tokens[^0-9]*[0-9][0-9,]*/)) {
                    s = substr(line, RSTART, RLENGTH)
                    gsub(/[^0-9]/, "", s)
                    print s
                    exit
                }
            }
        }
    ' "${file}" 2>/dev/null | head -n 1
}

cortex_usage_estimate() {
    local provider="$1" model="$2" input_tokens="$3" cached_tokens="$4" output_tokens="$5" total_tokens="$6"
    local prices input_price output_price
    prices="$(cortex_usage_price_pair "${provider}" "${model}" 2>/dev/null || true)"
    [[ -n "${prices}" ]] || return 1
    read -r input_price output_price <<< "${prices}"
    awk \
        -v in_tok="${input_tokens:-}" \
        -v cached_tok="${cached_tokens:-}" \
        -v out_tok="${output_tokens:-}" \
        -v total_tok="${total_tokens:-}" \
        -v in_price="${input_price}" \
        -v out_price="${output_price}" '
        BEGIN {
            has_split = (in_tok ~ /^[0-9]+$/) || (cached_tok ~ /^[0-9]+$/) || (out_tok ~ /^[0-9]+$/)
            if (has_split) {
                in_n = (in_tok ~ /^[0-9]+$/) ? in_tok : 0
                cached_n = (cached_tok ~ /^[0-9]+$/) ? cached_tok : 0
                out_n = (out_tok ~ /^[0-9]+$/) ? out_tok : 0
                cost = ((in_n * in_price) + (cached_n * in_price * 0.1) + (out_n * out_price)) / 1000000
                printf "%.6f\texact_or_split", cost
                exit
            }
            if (total_tok ~ /^[0-9]+$/) {
                # Most agent calls are prompt-heavy. Use a transparent default
                # only when the provider exposes total tokens but not the split.
                cost = ((total_tok * 0.8 * in_price) + (total_tok * 0.2 * out_price)) / 1000000
                printf "%.6f\testimated_80_20_from_total", cost
                exit
            }
            exit 1
        }'
}

cortex_usage_codex_rollout_root() {
    # Rollout-based usage attribution requires an explicit per-invocation Codex
    # home (the staged home the caller created for this one run). We deliberately
    # do NOT fall back to the shared ${CODEX_HOME:-~/.codex}: that home is also
    # written by concurrent interactive Codex sessions sharing the same cwd, and
    # the matcher selects rollouts by cwd + time-window overlap with no
    # per-invocation provenance. Falling back there let a worker wake whose own
    # staged home is empty (every --ephemeral worker, plus any run that reset
    # CORTEX_USAGE_CODEX_HOME) steal a foreign session's millions of tokens.
    # When no isolated home is set we return failure so the caller falls back
    # to the stdout text-scrape, which can only see this run's own output.
    local codex_home="${CORTEX_USAGE_CODEX_HOME:-}"
    [[ -n "${codex_home}" ]] || return 1
    printf '%s/sessions\n' "${codex_home}"
}

# Aggregate per-turn Codex usage from the rollout JSONL started by the
# current CLI invocation. We prefer a same-cwd rollout whose
# `session_meta` timestamp is close to the invocation start; only if no
# such rollout exists do we fall back to the older overlap-by-window
# heuristic. Sums `last_token_usage` deltas per turn attributed to the
# active `turn_context.model`. Emits one TSV line per model:
#   model<TAB>input<TAB>cached<TAB>output<TAB>n_turns
#
# Codex's input_tokens already includes the cached portion; cached is the
# subset billed at the cache-read discount.
cortex_usage_codex_rollout_match() {
    local start_epoch="$1" end_epoch="$2" cwd_path="$3"
    local root
    root="$(cortex_usage_codex_rollout_root 2>/dev/null || true)"
    [[ -n "${root}" && -d "${root}" ]] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    [[ "${start_epoch}" =~ ^[0-9]+$ && "${end_epoch}" =~ ^[0-9]+$ ]] || return 1
    [[ -n "${cwd_path}" ]] || return 1
    CORTEX_CODEX_ROOT="${root}" \
    CORTEX_CODEX_START="${start_epoch}" \
    CORTEX_CODEX_END="${end_epoch}" \
    CORTEX_CODEX_START_MATCH_SECONDS="${CORTEX_USAGE_CODEX_START_MATCH_SECONDS:-300}" \
    CORTEX_CODEX_CWD="${cwd_path}" \
    python3 - <<'PY'
import json, os, glob, datetime
root = os.environ["CORTEX_CODEX_ROOT"]
start_epoch = int(os.environ["CORTEX_CODEX_START"])
end_epoch = int(os.environ["CORTEX_CODEX_END"])
start = start_epoch - 30
end = end_epoch + 30
start_match_seconds = int(os.environ.get("CORTEX_CODEX_START_MATCH_SECONDS", "300"))
want_cwd = os.environ["CORTEX_CODEX_CWD"]
def parse_ts(s):
    if not isinstance(s, str): return None
    try:
        t = s
        if t.endswith("Z"):
            t = t[:-1] + "+00:00"
        if "." in t:
            head, rest = t.split(".", 1)
            frac = ""
            i = 0
            while i < len(rest) and rest[i].isdigit():
                frac += rest[i]; i += 1
            tail = rest[i:]
            frac = (frac + "000000")[:6]
            t = f"{head}.{frac}{tail}"
        dt = datetime.datetime.fromisoformat(t)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=datetime.timezone.utc)
        return dt.timestamp()
    except Exception:
        return None
rollouts = []
for path in sorted(glob.glob(os.path.join(root, "*", "*", "*", "rollout-*.jsonl"))):
    try:
        st = os.stat(path)
    except OSError:
        continue
    if st.st_mtime + 60 < start:
        continue
    cwd = None
    session_ts = None
    first_ts = None
    last_ts = None
    cur_model = None
    file_per_model = {}
    try:
        with open(path, "r", errors="replace") as f:
            for line in f:
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                ts = parse_ts(d.get("timestamp"))
                if ts is not None:
                    if first_ts is None: first_ts = ts
                    last_ts = ts
                t = d.get("type")
                payload = d.get("payload") if isinstance(d.get("payload"), dict) else None
                if t == "session_meta" and payload:
                    cwd = payload.get("cwd")
                    session_ts = parse_ts(payload.get("timestamp")) or ts
                elif t == "turn_context" and payload:
                    m = payload.get("model")
                    if m: cur_model = m
                elif t == "event_msg" and payload and payload.get("type") == "token_count":
                    info = payload.get("info")
                    if not isinstance(info, dict): continue
                    last_use = info.get("last_token_usage")
                    if not isinstance(last_use, dict): continue
                    in_n = int(last_use.get("input_tokens") or 0)
                    cached_n = int(last_use.get("cached_input_tokens") or 0)
                    out_n = int(last_use.get("output_tokens") or 0)
                    if (in_n + out_n) == 0: continue
                    mkey = cur_model or "unknown"
                    agg = file_per_model.setdefault(mkey, [0, 0, 0, 0])
                    agg[0] += in_n
                    agg[1] += cached_n
                    agg[2] += out_n
                    agg[3] += 1
    except OSError:
        continue
    if cwd != want_cwd: continue
    if first_ts is None or last_ts is None: continue
    rollouts.append({
        "path": path,
        "session_ts": session_ts,
        "first_ts": first_ts,
        "last_ts": last_ts,
        "per_model": file_per_model,
    })

selected = []
anchored = [
    item for item in rollouts
    if item["session_ts"] is not None
    and item["session_ts"] <= end
    and abs(item["session_ts"] - start_epoch) <= start_match_seconds
]
if anchored:
    anchored.sort(key=lambda item: (abs(item["session_ts"] - start_epoch), item["session_ts"], item["path"]))
    selected = [anchored[0]]
else:
    selected = [
        item for item in rollouts
        if not (item["last_ts"] < start or item["first_ts"] > end)
    ]

per_model = {}
for item in selected:
    for m, vals in item["per_model"].items():
        agg = per_model.setdefault(m, [0, 0, 0, 0])
        for i in range(4):
            agg[i] += vals[i]
for model, (i, cached, o, n) in per_model.items():
    if (i + o) == 0:
        continue
    print(f"{model}\t{i}\t{cached}\t{o}\t{n}")
PY
}

cortex_usage_claude_project_dir() {
    local cwd="$1"
    local home="${HOME:-}"
    [[ -n "${home}" && -n "${cwd}" ]] || return 1
    local encoded
    encoded="$(printf '%s' "${cwd}" | sed 's,/,-,g')"
    printf '%s/.claude/projects/%s\n' "${home}" "${encoded}"
}

# Aggregate per-message Claude usage from session JSONLs whose record
# timestamps overlap a window. Emits one TSV line per model:
#   model<TAB>input<TAB>cache_creation<TAB>cache_read<TAB>output<TAB>n
cortex_usage_claude_session_match() {
    local start_epoch="$1" end_epoch="$2" cwd_path="$3"
    local dir
    dir="$(cortex_usage_claude_project_dir "${cwd_path}" 2>/dev/null || true)"
    [[ -n "${dir}" && -d "${dir}" ]] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    [[ "${start_epoch}" =~ ^[0-9]+$ && "${end_epoch}" =~ ^[0-9]+$ ]] || return 1
    CORTEX_CLAUDE_DIR="${dir}" \
    CORTEX_CLAUDE_START="${start_epoch}" \
    CORTEX_CLAUDE_END="${end_epoch}" \
    python3 - <<'PY'
import json, os, glob, datetime
dir_path = os.environ["CORTEX_CLAUDE_DIR"]
start = int(os.environ["CORTEX_CLAUDE_START"]) - 30
end = int(os.environ["CORTEX_CLAUDE_END"]) + 30
def parse_ts(s):
    if not isinstance(s, str): return None
    try:
        t = s
        if t.endswith("Z"):
            t = t[:-1] + "+00:00"
        if "." in t:
            head, rest = t.split(".", 1)
            frac, sep, tail = "", "", ""
            i = 0
            while i < len(rest) and rest[i].isdigit():
                frac += rest[i]; i += 1
            tail = rest[i:]
            frac = (frac + "000000")[:6]
            t = f"{head}.{frac}{tail}"
        dt = datetime.datetime.fromisoformat(t)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=datetime.timezone.utc)
        return dt.timestamp()
    except Exception:
        return None
per_model = {}
for path in glob.glob(os.path.join(dir_path, "*.jsonl")):
    try:
        st = os.stat(path)
    except OSError:
        continue
    if st.st_mtime + 60 < start:
        continue
    seen = set()
    try:
        with open(path, "r", errors="replace") as f:
            for line in f:
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                ts = parse_ts(d.get("timestamp"))
                if ts is None or ts < start or ts > end:
                    continue
                msg = d.get("message")
                if not isinstance(msg, dict):
                    continue
                usage = msg.get("usage")
                if not isinstance(usage, dict):
                    continue
                request_id = d.get("requestId")
                message_id = msg.get("id")
                if request_id or message_id:
                    key = (request_id, message_id)
                    if key in seen:
                        continue
                    seen.add(key)
                model = msg.get("model") or "unknown"
                agg = per_model.setdefault(model, [0, 0, 0, 0, 0])
                agg[0] += int(usage.get("input_tokens") or 0)
                agg[1] += int(usage.get("cache_creation_input_tokens") or 0)
                agg[2] += int(usage.get("cache_read_input_tokens") or 0)
                agg[3] += int(usage.get("output_tokens") or 0)
                agg[4] += 1
    except OSError:
        continue
for model, (i, cc, cr, o, n) in per_model.items():
    if (i + cc + cr + o) == 0:
        continue
    print(f"{model}\t{i}\t{cc}\t{cr}\t{o}\t{n}")
PY
}

cortex_usage_estimate_cache_split() {
    local provider="$1" model="$2" input_n="$3" cc_n="$4" cr_n="$5" out_n="$6"
    local prices input_price output_price
    prices="$(cortex_usage_price_pair "${provider}" "${model}" 2>/dev/null || true)"
    [[ -n "${prices}" ]] || return 1
    read -r input_price output_price <<< "${prices}"
    awk -v in_n="${input_n:-0}" -v cc_n="${cc_n:-0}" -v cr_n="${cr_n:-0}" \
        -v out_n="${out_n:-0}" -v in_price="${input_price}" -v out_price="${output_price}" \
        'BEGIN {
            cost = ((in_n + cc_n * 1.25 + cr_n * 0.1) * in_price + out_n * out_price) / 1000000
            printf "%.6f", cost
        }'
}

cortex_usage_record_from_file() {
    local output_file="$1" agent="$2" role="$3" run_kind="$4" provider="$5" model="$6" source="$7"
    [[ "${CORTEX_USAGE_DISABLE:-0}" != "1" ]] || return 0
    [[ -f "${output_file}" ]] || return 0

    local start_epoch="${8:-}" end_epoch="${9:-}" cwd_path="${10:-${CORTEX_DIR:-}}"
    local ledger ledger_dir lock_file input_tokens cached_tokens output_tokens total_tokens estimate estimate_usd estimate_note
    ledger="$(cortex_usage_ledger_path)"
    ledger_dir="$(dirname "${ledger}")"
    mkdir -p "${ledger_dir}" || return 0

    if [[ "${provider}" == "claude" ]]; then
        local claude_rows c_model c_input c_cc c_cr c_output c_n
        local c_input_col c_cached_col c_total_col c_estimate_usd c_estimate_note
        claude_rows="$(cortex_usage_claude_session_match "${start_epoch}" "${end_epoch}" "${cwd_path}" 2>/dev/null || true)"
        if [[ -n "${claude_rows}" ]]; then
            lock_file="${ledger}.lock"
            {
                if command -v flock >/dev/null 2>&1; then
                    flock 9 || true
                fi
                if [[ ! -s "${ledger}" ]]; then
                    cortex_usage_header > "${ledger}"
                fi
                while IFS=$'\t' read -r c_model c_input c_cc c_cr c_output c_n; do
                    [[ -n "${c_model}" ]] || continue
                    c_input_col=$(( c_input + c_cc ))
                    c_cached_col="${c_cr}"
                    c_total_col=$(( c_input + c_cc + c_cr + c_output ))
                    c_estimate_usd="$(cortex_usage_estimate_cache_split "${provider}" "${c_model}" "${c_input}" "${c_cc}" "${c_cr}" "${c_output}" 2>/dev/null || true)"
                    if [[ -n "${c_estimate_usd}" ]]; then
                        c_estimate_note="claude_session_split"
                    else
                        c_estimate_usd=""
                        c_estimate_note="unknown_price"
                    fi
                    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                        "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
                        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
                        "$(date -u +%s)" \
                        "${agent}" "${role}" "${run_kind}" "${provider}" "${c_model}" \
                        "${c_input_col}" "${c_cached_col}" "${c_output}" "${c_total_col}" \
                        "${c_estimate_usd}" "${c_estimate_note}" "${source}" >> "${ledger}"
                done <<< "${claude_rows}"
            } 9>> "${lock_file}"
            return 0
        fi
    fi
    # Prefer structured Codex rollout usage when available — the JSONL
    # rollout records are provider-owned and immune to transcript
    # self-contamination, where the model can quote a giant number back
    # into its own output and have the text scraper pick it up. We try
    # rollout first even when the text scrape would have found something;
    # only fall through to scraping when no rollout match exists.
    if [[ "${provider}" == "codex" ]]; then
        local codex_rows x_model x_input x_cached x_output x_n
        local x_input_col x_total_col x_estimate_usd x_estimate_note
        codex_rows="$(cortex_usage_codex_rollout_match "${start_epoch}" "${end_epoch}" "${cwd_path}" 2>/dev/null || true)"
        if [[ -n "${codex_rows}" ]]; then
            lock_file="${ledger}.lock"
            {
                if command -v flock >/dev/null 2>&1; then
                    flock 9 || true
                fi
                if [[ ! -s "${ledger}" ]]; then
                    cortex_usage_header > "${ledger}"
                fi
                while IFS=$'\t' read -r x_model x_input x_cached x_output x_n; do
                    [[ -n "${x_model}" ]] || continue
                    x_input_col=$(( x_input - x_cached ))
                    (( x_input_col >= 0 )) || x_input_col=0
                    x_total_col=$(( x_input + x_output ))
                    x_estimate_usd="$(cortex_usage_estimate_cache_split "${provider}" "${x_model}" "${x_input_col}" 0 "${x_cached}" "${x_output}" 2>/dev/null || true)"
                    if [[ -n "${x_estimate_usd}" ]]; then
                        x_estimate_note="codex_rollout_split"
                    else
                        x_estimate_usd=""
                        x_estimate_note="unknown_price"
                    fi
                    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                        "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
                        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
                        "$(date -u +%s)" \
                        "${agent}" "${role}" "${run_kind}" "${provider}" "${x_model}" \
                        "${x_input_col}" "${x_cached}" "${x_output}" "${x_total_col}" \
                        "${x_estimate_usd}" "${x_estimate_note}" "${source}" >> "${ledger}"
                done <<< "${codex_rows}"
            } 9>> "${lock_file}"
            return 0
        fi
    fi
    input_tokens="$(cortex_usage_clean_number "$(cortex_usage_extract_first_match "${output_file}" input)")"
    cached_tokens="$(cortex_usage_clean_number "$(cortex_usage_extract_first_match "${output_file}" cached)")"
    output_tokens="$(cortex_usage_clean_number "$(cortex_usage_extract_first_match "${output_file}" output)")"
    total_tokens="$(cortex_usage_clean_number "$(cortex_usage_extract_first_match "${output_file}" total)")"
    if [[ -z "${total_tokens}" && ( -n "${input_tokens}" || -n "${cached_tokens}" || -n "${output_tokens}" ) ]]; then
        total_tokens="$(( ${input_tokens:-0} + ${cached_tokens:-0} + ${output_tokens:-0} ))"
    fi

    # Reject implausibly large scrapes (e.g. the model quoting a giant
    # number from a past poisoned row back into its own transcript). Zero
    # the fields and mark the row so usage_report.py can skip it.
    local poisoned=0 field
    for field in "${input_tokens}" "${cached_tokens}" "${output_tokens}" "${total_tokens}"; do
        if [[ -n "${field}" ]] && ! cortex_usage_token_plausible "${field}"; then
            poisoned=1
            break
        fi
    done

    estimate=""
    if (( poisoned )); then
        input_tokens=""
        cached_tokens=""
        output_tokens=""
        total_tokens=""
        estimate_usd=""
        estimate_note="rejected_implausible"
    else
        estimate="$(cortex_usage_estimate "${provider}" "${model}" "${input_tokens}" "${cached_tokens}" "${output_tokens}" "${total_tokens}" 2>/dev/null || true)"
        estimate_usd="${estimate%%$'\t'*}"
        estimate_note="${estimate#*$'\t'}"
        if [[ -z "${estimate}" ]]; then
            estimate_usd=""
            if [[ -n "${total_tokens}${input_tokens}${cached_tokens}${output_tokens}" ]]; then
                estimate_note="unknown_price"
            else
                estimate_note="no_usage_found"
            fi
        fi
    fi

    lock_file="${ledger}.lock"
    {
        if command -v flock >/dev/null 2>&1; then
            flock 9 || true
        fi
        if [[ ! -s "${ledger}" ]]; then
            cortex_usage_header > "${ledger}"
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
            "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
            "$(date -u +%s)" \
            "${agent}" "${role}" "${run_kind}" "${provider}" "${model}" \
            "${input_tokens}" "${cached_tokens}" "${output_tokens}" "${total_tokens}" \
            "${estimate_usd}" "${estimate_note}" "${source}" >> "${ledger}"
    } 9>> "${lock_file}"
}
