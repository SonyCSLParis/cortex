#!/usr/bin/env bash
# Re-price ledger rows that were recorded while their model had no entry in
# cortex_usage_price_pair. Model ids move faster than the price table, so rows
# land with estimate_note=unknown_price and an empty estimated_usd; once the
# table learns the model, this recomputes those rows from the tokens already
# captured. Only unknown_price rows are touched — no_usage_found rows have no
# tokens to price, and rejected/voided rows are excluded from totals by design.
#
#   bash scripts/usage_backfill_prices.sh [--apply] [ledger.tsv]
#
# Dry-run by default: prints what would change and leaves the ledger alone.
set -euo pipefail

CORTEX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${CORTEX_DIR}/scripts/usage_lib.sh"

apply=0
ledger=""
for arg in "$@"; do
    case "${arg}" in
        --apply) apply=1 ;;
        -*) echo "unknown flag: ${arg}" >&2; exit 2 ;;
        *) ledger="${arg}" ;;
    esac
done
[[ -n "${ledger}" ]] || ledger="$(cortex_usage_ledger_path)"
[[ -f "${ledger}" ]] || { echo "no ledger at ${ledger}" >&2; exit 1; }

tmp="${ledger}.backfill.$$"
changed=0
scanned=0

# Use the same persistent sidecar lock as all ledger appenders. Acquire it
# before opening the ledger, and hold it through the atomic replacement.
exec 9>>"${ledger}.lock"
cortex_usage_lock_ledger || exit 1

# Tab is IFS whitespace, so `read` would collapse empty token columns.
# Parameter expansion preserves them on Bash 3.2 as well as newer shells.
{
    IFS= read -r header
    printf '%s\n' "${header}"
    while IFS= read -r line; do
        f=()
        remainder="${line}"$'\t'
        field_index=0
        while [[ "${remainder}" == *$'\t'* ]]; do
            f[field_index]="${remainder%%$'\t'*}"
            remainder="${remainder#*$'\t'}"
            field_index=$((field_index + 1))
        done
        ts_local="${f[0]:-}"; ts_utc="${f[1]:-}"; epoch="${f[2]:-}"
        agent="${f[3]:-}"; role="${f[4]:-}"; run_kind="${f[5]:-}"
        provider="${f[6]:-}"; model="${f[7]:-}"
        input_tok="${f[8]:-}"; cached_tok="${f[9]:-}"; output_tok="${f[10]:-}"
        total_tok="${f[11]:-}"; usd="${f[12]:-}"; note="${f[13]:-}"; source="${f[14]:-}"
        if [[ "${note}" == "unknown_price" && -z "${usd}" ]]; then
            scanned=$((scanned + 1))
            if estimate="$(cortex_usage_estimate "${provider}" "${model}" \
                "${input_tok}" "${cached_tok}" "${output_tok}" "${total_tok}" 2>/dev/null)"; then
                new_usd="${estimate%%$'\t'*}"
                new_note="${estimate#*$'\t'}_price_backfill"
                echo "re-priced ${ts_local} ${agent} ${provider}/${model} ${total_tok} tok -> \$${new_usd} (${new_note})" >&2
                usd="${new_usd}"
                note="${new_note}"
                changed=$((changed + 1))
            fi
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "${ts_local}" "${ts_utc}" "${epoch}" "${agent}" "${role}" "${run_kind}" \
            "${provider}" "${model}" "${input_tok}" "${cached_tok}" "${output_tok}" \
            "${total_tok}" "${usd}" "${note}" "${source}"
    done
} < "${ledger}" > "${tmp}"

echo "unknown_price rows: ${scanned}; re-priced: ${changed}" >&2
if (( apply == 1 )); then
    mv "${tmp}" "${ledger}"
    echo "ledger updated: ${ledger}" >&2
else
    rm -f "${tmp}"
    echo "dry run — rerun with --apply to write" >&2
fi
