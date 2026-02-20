#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# push-to-s3.sh
#
# Uploads CSV files produced by sync-audit-logs.sh to an S3 bucket for
# ingestion into a SIEM or data lake.
#
# Required environment variables:
#   S3_BUCKET     – S3 bucket name, optionally with a key prefix
#                   e.g. my-bucket  or  my-bucket/path/to/audit-logs
#
# Optional environment variables:
#   S3_PROFILE    – AWS CLI named profile to use (default: none)
#   OUTPUT_DIR    – directory containing CSV files to upload (default: ./output)
#   ARCHIVE_DIR   – directory for successfully uploaded files (default: ./archive)
#
# Authentication:
#   Uses the standard AWS credential chain.  When running on EC2/ECS, attach
#   an IAM role with s3:PutObject permission on the target bucket.  When
#   running locally, configure credentials via environment variables or
#   ~/.aws/credentials.
# ──────────────────────────────────────────────────────────────────────────────

: "${S3_BUCKET:?Set S3_BUCKET to the target S3 bucket name}"

# If S3_BUCKET contains a /, split into bucket + prefix
if [[ "$S3_BUCKET" == */* ]]; then
  S3_PREFIX="${S3_BUCKET#*/}"
  S3_BUCKET="${S3_BUCKET%%/*}"
else
  S3_PREFIX=""
fi
S3_PROFILE="${S3_PROFILE:-}"
OUTPUT_DIR="${OUTPUT_DIR:-./output}"
ARCHIVE_DIR="${ARCHIVE_DIR:-./archive}"

AWS_PROFILE_FLAG=()
[[ -n "$S3_PROFILE" ]] && AWS_PROFILE_FLAG=(--profile "$S3_PROFILE")

mkdir -p "$ARCHIVE_DIR"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }

# ── Upload each CSV file ────────────────────────────────────────────────────

UPLOADED=0
FAILED=0

for csv_file in "$OUTPUT_DIR"/audit-events-*.csv; do
  [[ -f "$csv_file" ]] || continue

  FILENAME=$(basename "$csv_file")
  S3_KEY="${S3_PREFIX:+${S3_PREFIX}/}${FILENAME}"
  ROW_COUNT=$(tail -n +2 "$csv_file" | grep -c '.' || true)

  log "Uploading ${FILENAME} (${ROW_COUNT} events) → s3://${S3_BUCKET}/${S3_KEY}"

  if aws s3 cp "$csv_file" "s3://${S3_BUCKET}/${S3_KEY}" "${AWS_PROFILE_FLAG[@]}" --quiet; then
    mv "$csv_file" "$ARCHIVE_DIR/"
    UPLOADED=$((UPLOADED + 1))
    log "  Uploaded successfully."
  else
    log "ERROR: Failed to upload ${FILENAME}"
    FAILED=$((FAILED + 1))
  fi
done

if (( UPLOADED == 0 && FAILED == 0 )); then
  log "No files to upload."
else
  log "Upload complete: ${UPLOADED} succeeded, ${FAILED} failed."
fi
