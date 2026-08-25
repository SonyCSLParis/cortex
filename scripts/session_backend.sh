#!/usr/bin/env bash
# Explicit session backend helpers. Default callers use screen; tmux is used
# only when the selected backend is tmux.

cortex_session_backend_resolve() {
    local backend="${1:-${CORTEX_SESSION_BACKEND:-${CORTEX_DEFAULT_SESSION_BACKEND:-screen}}}"
    case "${backend}" in
        screen|tmux) printf '%s' "${backend}" ;;
        *) echo "unsupported session backend: ${backend}" >&2; return 2 ;;
    esac
}

cortex_session_backend_available() {
    local backend="$1"
    case "${backend}" in
        screen) command -v screen >/dev/null 2>&1 ;;
        tmux) command -v tmux >/dev/null 2>&1 ;;
        *) return 2 ;;
    esac
}

cortex_session_exists() {
    local backend="$1" session="$2"
    case "${backend}" in
        screen)
            screen -ls 2>/dev/null | awk -v session="${session}" '
                $1 ~ /^[0-9]+\./ {
                    sub(/^[0-9]+\./, "", $1)
                    if ($1 == session) found = 1
                }
                END { exit found ? 0 : 1 }
            '
            ;;
        tmux)
            tmux has-session -t "${session}" 2>/dev/null
            ;;
        *)
            return 2
            ;;
    esac
}

cortex_session_list() {
    local backend="$1"
    case "${backend}" in
        screen)
            screen -ls 2>/dev/null \
                | grep -E '^\s+[0-9]+\.' \
                | awk '{print $1}' \
                | sed 's/^[0-9]*\.//'
            ;;
        tmux)
            tmux list-sessions -F '#S' 2>/dev/null
            ;;
        *)
            return 2
            ;;
    esac
}

cortex_session_start() {
    local backend="$1" session="$2" cmd="$3" cwd="${4:-${CORTEX_DIR:-${PWD}}}"
    case "${backend}" in
        screen)
            screen -dmS "${session}" bash -lc "${cmd}"
            ;;
        tmux)
            tmux new-session -d -s "${session}" -c "${cwd}" "bash -lc $(printf '%q' "${cmd}")"
            ;;
        *)
            return 2
            ;;
    esac
}

cortex_session_stop() {
    local backend="$1" session="$2"
    case "${backend}" in
        screen)
            screen -S "${session}" -X quit
            ;;
        tmux)
            tmux kill-session -t "${session}"
            ;;
        *)
            return 2
            ;;
    esac
}

cortex_session_attach_hint() {
    local backend="$1" session="$2"
    case "${backend}" in
        screen) printf 'screen -r %s' "${session}" ;;
        tmux) printf 'tmux attach -t %s' "${session}" ;;
        *) return 2 ;;
    esac
}

cortex_session_start_dry_run() {
    local backend="$1" session="$2" cmd="$3" cwd="${4:-${CORTEX_DIR:-${PWD}}}"
    case "${backend}" in
        screen)
            printf 'screen -dmS %s bash -lc %q\n' "${session}" "${cmd}"
            ;;
        tmux)
            printf 'tmux new-session -d -s %s -c %q %q\n' \
                "${session}" "${cwd}" "bash -lc $(printf '%q' "${cmd}")"
            ;;
        *)
            return 2
            ;;
    esac
}
