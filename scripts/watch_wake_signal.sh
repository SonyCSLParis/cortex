#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CORTEX_DIR="${CORTEX_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd -P)}"
source "${CORTEX_DIR}/config/cortex_defaults.sh"
source "${CORTEX_DIR}/scripts/bash_compat.sh"
WATCH_FILE_PATH="${WATCH_FILE:-${CORTEX_DIR}/agents/watch/watch.txt}"
SIGNAL_SECRETS_FILE="${SIGNAL_SECRETS_FILE:-${CORTEX_DEFAULT_SIGNAL_SECRETS_FILE}}"
SIGNAL_ACCOUNT="${SIGNAL_ACCOUNT:-}"
SIGNAL_RECIPIENT="${SIGNAL_RECIPIENT:-}"
SIGNAL_RELAY_HOST="${SIGNAL_RELAY_HOST:-${CORTEX_DEFAULT_SIGNAL_RELAY_HOST}}"

if [[ -r "${SIGNAL_SECRETS_FILE}" ]]; then
    set -a
    # shellcheck disable=SC1090
    . "${SIGNAL_SECRETS_FILE}"
    set +a
fi
SIGNAL_RELAY_HOST="${SIGNAL_RELAY_HOST:-${CORTEX_DEFAULT_SIGNAL_RELAY_HOST}}"

if [[ -z "${SIGNAL_ACCOUNT:-}" ]]; then
    echo "SIGNAL_ACCOUNT not set; define it in ${SIGNAL_SECRETS_FILE} or the environment" >&2
    exit 2
fi
if [[ -z "${SIGNAL_RELAY_HOST:-}" ]]; then
    echo "SIGNAL_RELAY_HOST not set; define it in ${SIGNAL_SECRETS_FILE} or the environment" >&2
    exit 2
fi
if [[ -z "${SIGNAL_RECIPIENT:-}" ]]; then
    SIGNAL_RECIPIENT="${SIGNAL_ACCOUNT}"
fi

if [[ ! -f "${WATCH_FILE_PATH}" ]]; then
    exit 0
fi

watch_text="$(tr '[:upper:]' '[:lower:]' < "${WATCH_FILE_PATH}")"
if [[ ! "${watch_text}" =~ (signal|send).*(every|each).*(wake) ]] && [[ ! "${watch_text}" =~ (every|each).*(wake).*(signal|send) ]]; then
    exit 0
fi

sentences=(
    "Quiet progress is still progress."
    "Even a calm night is doing its work."
    "Patience is also a form of motion."
    "What is steady does not need to be loud."
    "A small wake can still carry a good thought."
    "Not every silent interval is empty."
    "The work keeps moving, even when it looks still."
    "A gentle reminder: enough can happen one wake at a time."
)

index="${WATCH_WAKE_INDEX:-${STANDBY_WAKE_INDEX:-1}}"
count="$(bash_array_len sentences)"
sentence="${sentences[$(( (index - 1) % count ))]}"

if command -v signal-cli &>/dev/null; then
    signal-cli -a "${SIGNAL_ACCOUNT}" send -m "${sentence}" "${SIGNAL_RECIPIENT}"
else
    escaped="$(printf '%s' "${sentence}" | sed "s/'/'\"'\"'/g")"
    ssh "${SIGNAL_RELAY_HOST}" "signal-cli -a '${SIGNAL_ACCOUNT}' send -m '${escaped}' '${SIGNAL_RECIPIENT}'"
fi

printf '[hook] wake %s signal sent: %s\n' "${index}" "${sentence}"
