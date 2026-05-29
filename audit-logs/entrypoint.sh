#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# entrypoint.sh
#
# Docker entrypoint that supports two modes:
#
#   1. "cron"  – (default) Installs a cron job that runs the sync every
#                SYNC_INTERVAL_MINUTES (default: 15) and keeps the container
#                alive.
#   2. "once"  – Runs the sync + push once and exits.  Useful for Kubernetes
#                CronJobs or one-off testing.
# ──────────────────────────────────────────────────────────────────────────────

MODE="${1:-cron}"
SYNC_INTERVAL_MINUTES="${SYNC_INTERVAL_MINUTES:-15}"

run_sync() {
  echo "========================================="
  echo " Starting audit log sync at $(date -u)"
  echo "========================================="
  /app/sync-audit-logs.sh && /app/push-to-s3.sh
  echo ""
}

case "$MODE" in
  once)
    run_sync
    ;;
  cron)
    # Run once immediately on startup
    run_sync || true

    echo "Setting up cron: every ${SYNC_INTERVAL_MINUTES} minutes"

    # Build the cron expression
    CRON_EXPR="*/${SYNC_INTERVAL_MINUTES} * * * *"

    # Write environment to a file so the cron job inherits it
    env | grep -E '^(MODERNE_|OUTPUT_|STATE_|ARCHIVE_|POLL_|S3_|AWS_)' \
      > /app/env.sh 2>/dev/null || true
    sed -i 's/^/export /' /app/env.sh 2>/dev/null || true

    # Install the cron job
    echo "${CRON_EXPR} . /app/env.sh && /app/sync-audit-logs.sh && /app/push-to-s3.sh >> /proc/1/fd/1 2>&1" \
      | crontab -

    echo "Cron installed. Waiting…"
    exec crond -f -l 2
    ;;
  *)
    echo "Usage: entrypoint.sh [once|cron]"
    exit 1
    ;;
esac
