#!/usr/bin/env bash

worker_cleanup_apply_defaults() {
    worker_set_codex_defaults weak "${DEFAULT_WORKER_REVIEW_INTERVAL_DAILY}" "${DEFAULT_WORKER_REVIEW_TIMEOUT_SHORT_SECONDS}"
}
