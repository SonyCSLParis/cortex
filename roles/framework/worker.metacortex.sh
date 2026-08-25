#!/usr/bin/env bash

worker_metacortex_apply_defaults() {
    apply_model_tier strong
    [[ -n "${WORKER_REVIEW_INTERVAL}" ]] || WORKER_REVIEW_INTERVAL="${DEFAULT_WORKER_REVIEW_INTERVAL_DAILY}"
    if [[ "${WORKER_REVIEW_TIMEOUT}" == "${DEFAULT_WORKER_REVIEW_TIMEOUT_SECONDS}" ]]; then
        WORKER_REVIEW_TIMEOUT="${DEFAULT_WORKER_REVIEW_TIMEOUT_LONG_SECONDS}"
    fi
}
