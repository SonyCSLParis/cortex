#!/usr/bin/env bash

worker_privacy_apply_defaults() {
    worker_set_codex_defaults medium "${DEFAULT_WORKER_REVIEW_INTERVAL_DAILY}" "${DEFAULT_WORKER_REVIEW_TIMEOUT_LONG_SECONDS}"
}
