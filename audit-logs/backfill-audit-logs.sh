#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# backfill-audit-logs.sh
#
# Backfills historical audit logs by batching requests into daily (or
# configurable) time-window chunks.  Each chunk delegates to
# sync-audit-logs.sh and optionally pushes to S3 after each chunk.
#
# Progress is tracked in a local state file so the backfill can be
# interrupted and resumed.
#
# Required arguments:
#   --since <ISO8601>    – start date for the backfill
#
# Optional arguments:
#   --until <ISO8601>    – end date (default: now)
#   --chunk-days <N>     – days per batch (default: 1)
#   --timeout <seconds>  – per-chunk download timeout (default: 600)
#   --push               – run push-to-s3.sh after each chunk
#   --reset              – clear backfill progress and start over
#   --help               – show usage
#
# Required environment variables:
#   MODERNE_TENANT_API_URL  – e.g. https://api.app.moderne.io
#   MODERNE_PAT             – a Moderne Personal Access Token with admin scope
#
# Examples:
#   ./backfill-audit-logs.sh --since 2025-01-01
#   ./backfill-audit-logs.sh --since 2025-01-01 --until 2025-06-01 --chunk-days 7
#   ./backfill-audit-logs.sh --since 2025-01-01 --push
#   ./backfill-audit-logs.sh --reset --since 2025-01-01
# ──────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="${STATE_DIR:-./state}"
PROGRESS_FILE="${STATE_DIR}/backfill_progress"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }

# Reuse to_rfc3339 from sync-audit-logs.sh
to_rfc3339() {
  local d="$1"
  case "$d" in
    *+[0-9][0-9]:[0-9][0-9]) echo "$d" ;;
    *-[0-9][0-9]:[0-9][0-9]) echo "$d" ;;
    *Z) echo "${d%Z}+00:00" ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
      echo "${d}T00:00:00+00:00" ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9])
      echo "${d}:00+00:00" ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]*)
      echo "${d}+00:00" ;;
    *)
      echo "ERROR: Unrecognized date format: $d" >&2
      exit 1
      ;;
  esac
}

to_epoch() {
  local d="$1"
  if date -u -d "$d" '+%s' 2>/dev/null; then
    return
  fi
  local stripped="${d%%[+-][0-9][0-9]:[0-9][0-9]}"
  stripped="${stripped%Z}"
  TZ=UTC date -jf '%Y-%m-%dT%H:%M:%S' "$stripped" '+%s' 2>/dev/null && return
  echo "ERROR: Failed to parse date: $d" >&2
  exit 1
}

from_epoch() {
  local e="$1"
  if date -u -d "@${e}" '+%Y-%m-%dT%H:%M:%S+00:00' 2>/dev/null; then
    return
  fi
  date -u -r "${e}" '+%Y-%m-%dT%H:%M:%S+00:00'
}

# ── Parse arguments ──────────────────────────────────────────────────────────

ARG_SINCE=""
ARG_UNTIL=""
CHUNK_DAYS=1
TIMEOUT=600
PUSH=false
RESET=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)      ARG_SINCE="$2";  shift 2 ;;
    --until)      ARG_UNTIL="$2";  shift 2 ;;
    --chunk-days) CHUNK_DAYS="$2"; shift 2 ;;
    --timeout)    TIMEOUT="$2";    shift 2 ;;
    --push)       PUSH=true;       shift   ;;
    --reset)      RESET=true;      shift   ;;
    --help|-h)
      echo "Usage: backfill-audit-logs.sh --since <date> [options]"
      echo ""
      echo "Required:"
      echo "  --since <date>        Start date for backfill"
      echo ""
      echo "Options:"
      echo "  --until <date>        End date (default: now)"
      echo "  --chunk-days <N>      Days per batch (default: 1)"
      echo "  --timeout <seconds>   Per-chunk download timeout (default: 600)"
      echo "  --push                Run push-to-s3.sh after each chunk"
      echo "  --reset               Clear backfill progress and start over"
      echo "  --help                Show usage"
      exit 0
      ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      echo "Usage: backfill-audit-logs.sh --since <date> [options]" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$ARG_SINCE" ]]; then
  echo "ERROR: --since is required." >&2
  echo "Usage: backfill-audit-logs.sh --since <date> [options]" >&2
  exit 1
fi

# ── Setup ─────────────────────────────────────────────────────────────────────

mkdir -p "$STATE_DIR"

if $RESET && [[ -f "$PROGRESS_FILE" ]]; then
  log "Clearing backfill progress."
  rm -f "$PROGRESS_FILE"
fi

SINCE_ISO=$(to_rfc3339 "$ARG_SINCE")
UNTIL_ISO="${ARG_UNTIL:+$(to_rfc3339 "$ARG_UNTIL")}"
UNTIL_ISO="${UNTIL_ISO:-$(date -u '+%Y-%m-%dT%H:%M:%S+00:00')}"

SINCE_EPOCH=$(to_epoch "$SINCE_ISO")
UNTIL_EPOCH=$(to_epoch "$UNTIL_ISO")

CHUNK_SECONDS=$(( CHUNK_DAYS * 86400 ))

# Resume from progress file if it exists
if [[ -f "$PROGRESS_FILE" ]]; then
  RESUME_EPOCH=$(cat "$PROGRESS_FILE")
  if (( RESUME_EPOCH > SINCE_EPOCH && RESUME_EPOCH < UNTIL_EPOCH )); then
    SINCE_EPOCH=$RESUME_EPOCH
    SINCE_ISO=$(from_epoch "$SINCE_EPOCH")
    log "Resuming backfill from $(from_epoch "$RESUME_EPOCH")"
  fi
fi

# Calculate total chunks
TOTAL_SECONDS=$(( UNTIL_EPOCH - SINCE_EPOCH ))
TOTAL_CHUNKS=$(( (TOTAL_SECONDS + CHUNK_SECONDS - 1) / CHUNK_SECONDS ))

if (( TOTAL_CHUNKS <= 0 )); then
  log "Nothing to backfill: --since is not before --until."
  exit 0
fi

log "Backfill: $(from_epoch "$SINCE_EPOCH") → $(from_epoch "$UNTIL_EPOCH")"
log "  ${TOTAL_CHUNKS} chunks of ${CHUNK_DAYS} day(s), timeout ${TIMEOUT}s per chunk"
if $PUSH; then
  log "  Push to S3 enabled after each chunk"
fi

# ── Process chunks ────────────────────────────────────────────────────────────

CHUNK_START=$SINCE_EPOCH
CHUNK_NUM=0
SUCCEEDED=0
FAILED=0

while (( CHUNK_START < UNTIL_EPOCH )); do
  CHUNK_END=$(( CHUNK_START + CHUNK_SECONDS ))
  # Clamp the last chunk to the until boundary
  if (( CHUNK_END > UNTIL_EPOCH )); then
    CHUNK_END=$UNTIL_EPOCH
  fi

  CHUNK_NUM=$(( CHUNK_NUM + 1 ))
  CHUNK_SINCE=$(from_epoch "$CHUNK_START")
  CHUNK_UNTIL=$(from_epoch "$CHUNK_END")

  log "Chunk ${CHUNK_NUM}/${TOTAL_CHUNKS}: ${CHUNK_SINCE} → ${CHUNK_UNTIL}"

  if "${SCRIPT_DIR}/sync-audit-logs.sh" --since "$CHUNK_SINCE" --until "$CHUNK_UNTIL" --timeout "$TIMEOUT"; then
    SUCCEEDED=$(( SUCCEEDED + 1 ))

    if $PUSH; then
      "${SCRIPT_DIR}/push-to-s3.sh" || log "WARNING: push-to-s3.sh failed for chunk ${CHUNK_NUM}"
    fi

    # Save progress after each successful chunk
    echo "$CHUNK_END" > "$PROGRESS_FILE"
  else
    FAILED=$(( FAILED + 1 ))
    log "ERROR: Chunk ${CHUNK_NUM} failed. Stopping backfill."
    log "  Resume by re-running the same command (progress saved)."
    exit 1
  fi

  CHUNK_START=$CHUNK_END
done

log "Backfill complete: ${SUCCEEDED} chunks succeeded, ${FAILED} failed."

# Clean up progress file on full completion
rm -f "$PROGRESS_FILE"
log "Progress file removed. Backfill finished."
