#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# sync-audit-logs.sh
#
# Pulls audit log events from the Moderne Platform as CSV and writes the file
# to the output directory.  A downstream script (push-to-s3.sh) is responsible
# for uploading the CSV to an S3 bucket for ingestion into a SIEM or data
# lake.
#
# The CSV is produced by the Moderne Platform with the following columns:
#   User, Target, Action type, Action, Description, Time, Outcome
#
# Required environment variables:
#   MODERNE_TENANT_API_URL  – the api. host, e.g. https://api.<tenant>.moderne.io
#   MODERNE_PAT         – a Moderne Personal Access Token with admin scope
#
# Optional arguments:
#   --since <ISO8601>    – start of the time range (overrides saved state)
#   --until <ISO8601>    – end of the time range (default: now)
#   --timeout <seconds>  – max seconds to wait for download (default: 120)
#
# Optional environment variables:
#   OUTPUT_DIR           – directory to write CSV files (default: ./output)
#   STATE_DIR            – directory for run state (default: ./state)
#   POLL_INTERVAL        – seconds between download-status checks (default: 5)
#   POLL_TIMEOUT         – maximum seconds to wait for download (default: 120)
#
# Examples:
#   ./sync-audit-logs.sh
#   ./sync-audit-logs.sh --since 2026-01-01
#   ./sync-audit-logs.sh --since 2026-01-01 --until 2026-02-01
#   ./sync-audit-logs.sh --since 2026-01-01T12:00:00Z --until 2026-01-01T18:00:00Z
#   ./sync-audit-logs.sh --since 2026-01-01 --until 2026-02-01 --timeout 600
# ──────────────────────────────────────────────────────────────────────────────

# ── Helpers ──────────────────────────────────────────────────────────────────

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }

# Normalize a date string to full RFC3339 (required by the Moderne API).
# Accepts:  2026-01-01  |  2026-01-01T12:00  |  2026-01-01T12:00:00
#           2026-01-01T12:00:00Z  |  2026-01-01T12:00:00+00:00  (pass-through)
to_rfc3339() {
  local d="$1"
  case "$d" in
    # Already has a timezone offset (+HH:MM or -HH:MM)
    *+[0-9][0-9]:[0-9][0-9]) echo "$d" ;;
    *-[0-9][0-9]:[0-9][0-9]) echo "$d" ;;
    # Trailing Z → replace with +00:00
    *Z) echo "${d%Z}+00:00" ;;
    # Date only: 2026-01-01
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
      echo "${d}T00:00:00+00:00" ;;
    # Date + hours:minutes: 2026-01-01T12:00
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9])
      echo "${d}:00+00:00" ;;
    # Date + full time, no tz: 2026-01-01T12:00:00
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]*)
      echo "${d}+00:00" ;;
    *)
      echo "ERROR: Unrecognized date format: $d" >&2
      echo "       Expected ISO 8601, e.g. 2026-01-01 or 2026-01-01T12:00:00+00:00" >&2
      exit 1
      ;;
  esac
}

# Convert an RFC3339 date string to epoch seconds (portable).
to_epoch() {
  local d="$1"
  if date -u -d "$d" '+%s' 2>/dev/null; then
    return  # GNU / BusyBox
  fi
  # BSD/macOS: strip timezone suffix and parse as UTC
  local stripped="${d%%[+-][0-9][0-9]:[0-9][0-9]}"
  stripped="${stripped%Z}"
  TZ=UTC date -jf '%Y-%m-%dT%H:%M:%S' "$stripped" '+%s' 2>/dev/null && return
  echo "ERROR: Failed to parse date: $d" >&2
  exit 1
}

# The X-Moderne-Platform-Version: v2 header routes the request to the v2 platform
# on tenants mid-migration, where api.<tenant>.moderne.io still resolves to the v1
# front door. It's required to authenticate with a v2 token and is a harmless
# no-op on tenants that are fully on v1 or fully cut over to v2.
graphql() {
  local query="$1"
  curl -sf \
    -H "Authorization: Bearer ${MODERNE_PAT}" \
    -H "Content-Type: application/json" \
    -H "X-Moderne-Platform-Version: v2" \
    -d "$query" \
    "$GRAPHQL_URL"
}

# ── Parse arguments ──────────────────────────────────────────────────────────

ARG_SINCE=""
ARG_UNTIL=""
ARG_TIMEOUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)   ARG_SINCE="$2";   shift 2 ;;
    --until)   ARG_UNTIL="$2";   shift 2 ;;
    --timeout) ARG_TIMEOUT="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: sync-audit-logs.sh [--since <date>] [--until <date>] [--timeout <seconds>]"
      echo "  Dates can be: 2026-01-01, 2026-01-01T12:00, 2026-01-01T12:00:00Z, etc."
      echo "  --timeout  Max seconds to wait for download (default: 120, or POLL_TIMEOUT env var)"
      exit 0
      ;;
    *)
      echo "Usage: sync-audit-logs.sh [--since <ISO8601>] [--until <ISO8601>] [--timeout <seconds>]"
      exit 1
      ;;
  esac
done

# Normalize dates to RFC3339 before anything else uses them
[[ -n "$ARG_SINCE" ]] && ARG_SINCE=$(to_rfc3339 "$ARG_SINCE")
[[ -n "$ARG_UNTIL" ]] && ARG_UNTIL=$(to_rfc3339 "$ARG_UNTIL")

: "${MODERNE_TENANT_API_URL:?Set MODERNE_TENANT_API_URL (e.g. https://api.app.moderne.io)}"
: "${MODERNE_PAT:?Set MODERNE_PAT to a Moderne Personal Access Token}"

OUTPUT_DIR="${OUTPUT_DIR:-./output}"
STATE_DIR="${STATE_DIR:-./state}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"
POLL_TIMEOUT="${ARG_TIMEOUT:-${POLL_TIMEOUT:-120}}"
GRAPHQL_URL="${MODERNE_TENANT_API_URL%/}/graphql"

mkdir -p "$OUTPUT_DIR" "$STATE_DIR"

# ── 1. Determine time window ────────────────────────────────────────────────

LAST_RUN_FILE="${STATE_DIR}/last_run"
NOW_ISO=$(date -u '+%Y-%m-%dT%H:%M:%S+00:00')

# --until overrides the default (now)
UNTIL_ISO="${ARG_UNTIL:-$NOW_ISO}"

# --since overrides saved state and the 24-hour default
if [[ -n "$ARG_SINCE" ]]; then
  SINCE_ISO="$ARG_SINCE"
  log "Fetching audit logs from ${SINCE_ISO} to ${UNTIL_ISO} (explicit range)"
elif [[ -f "$LAST_RUN_FILE" ]]; then
  SINCE_ISO=$(cat "$LAST_RUN_FILE")
  log "Fetching audit logs since ${SINCE_ISO}"
else
  # First run – pull last 24 hours.  Works on GNU, BSD, and BusyBox date.
  SINCE_EPOCH=$(( $(date +%s) - 86400 ))
  if date -u -d "@${SINCE_EPOCH}" '+%Y' >/dev/null 2>&1; then
    # GNU / BusyBox
    SINCE_ISO=$(date -u -d "@${SINCE_EPOCH}" '+%Y-%m-%dT%H:%M:%S+00:00')
  else
    # BSD/macOS
    SINCE_ISO=$(date -u -r "${SINCE_EPOCH}" '+%Y-%m-%dT%H:%M:%S+00:00')
  fi
  log "First run – fetching audit logs since ${SINCE_ISO}"
fi

# ── 2. Initiate CSV download ────────────────────────────────────────────────

log "Requesting audit log CSV export…"

# downloadAuditLogs returns the AuditLogsDownload interface; the concrete state is
# carried in __typename (Processing → Finished → Error). The mutation may return
# Finished immediately when a matching closed-window export already exists.
INITIATE_PAYLOAD=$(jq -n \
  --arg since "$SINCE_ISO" \
  --arg until "$UNTIL_ISO" \
  '{
    query: "mutation ($since: DateTime, $until: DateTime) { downloadAuditLogs(format: CSV, since: $since, until: $until) { __typename id ... on AuditLogsDownloadFinished { downloadUrl } ... on AuditLogsDownloadError { message } } }",
    variables: { since: $since, until: $until }
  }')

INITIATE_RESPONSE=$(graphql "$INITIATE_PAYLOAD")
NODE=$(echo "$INITIATE_RESPONSE" | jq -c '.data.downloadAuditLogs // empty')
DOWNLOAD_ID=$(echo "$NODE" | jq -r '.id // empty')
STATE=$(echo "$NODE" | jq -r '.__typename // empty')

if [[ -z "$DOWNLOAD_ID" || "$DOWNLOAD_ID" == "null" ]]; then
  log "ERROR: Failed to initiate audit log download."
  log "Response: $INITIATE_RESPONSE"
  exit 1
fi

log "Download initiated (id=${DOWNLOAD_ID}, state=${STATE})"

# ── 3. Poll until ready ─────────────────────────────────────────────────────

# Status is polled via the auditLogsDownloads connection, filtered to this id. The
# listing is eventually consistent, so a just-created download can be briefly absent
# (node = MISSING); that is treated as still-processing, not a failure.
POLL_QUERY=$(jq -n \
  --arg id "$DOWNLOAD_ID" \
  '{
    query: "query ($id: ID!) { auditLogsDownloads(first: 1, where: { id: { _eq: $id } }) { edges { node { __typename id ... on AuditLogsDownloadFinished { downloadUrl } ... on AuditLogsDownloadError { message } } } } }",
    variables: { id: $id }
  }')

ELAPSED=0

while [[ "$STATE" != "AuditLogsDownloadFinished" && "$STATE" != "AuditLogsDownloadError" ]]; do
  if (( ELAPSED >= POLL_TIMEOUT )); then
    log "ERROR: Timed out waiting for download after ${POLL_TIMEOUT}s (last state: ${STATE})"
    exit 1
  fi
  sleep "$POLL_INTERVAL"
  ELAPSED=$(( ELAPSED + POLL_INTERVAL ))
  POLL_RESPONSE=$(graphql "$POLL_QUERY")
  NODE=$(echo "$POLL_RESPONSE" | jq -c '.data.auditLogsDownloads.edges[0].node // empty')
  STATE=$(echo "$NODE" | jq -r '.__typename // "MISSING"')
  log "  … state=${STATE} (${ELAPSED}s elapsed)"
done

if [[ "$STATE" != "AuditLogsDownloadFinished" ]]; then
  STATE_MSG=$(echo "$NODE" | jq -r '.message // "unknown"')
  log "ERROR: Download failed – ${STATE_MSG}"
  exit 1
fi

# downloadUrl is a path relative to the tenant API host (e.g. /audit_logs/download/<id>).
DOWNLOAD_PATH=$(echo "$NODE" | jq -r '.downloadUrl')
DOWNLOAD_URL="${MODERNE_TENANT_API_URL%/}${DOWNLOAD_PATH}"
log "Download ready: ${DOWNLOAD_URL}"

# ── 4. Download CSV to output directory ──────────────────────────────────────

SINCE_EPOCH=$(to_epoch "$SINCE_ISO")
UNTIL_EPOCH=$(to_epoch "$UNTIL_ISO")
CSV_FILE="${OUTPUT_DIR}/audit-events-${SINCE_EPOCH}-${UNTIL_EPOCH}.csv"

curl -sf \
  -H "Authorization: Bearer ${MODERNE_PAT}" \
  -H "X-Moderne-Platform-Version: v2" \
  -o "$CSV_FILE" \
  "$DOWNLOAD_URL"

# Count non-empty lines after the header
ROW_COUNT=$(tail -n +2 "$CSV_FILE" | grep -c '.' || true)
log "Downloaded ${ROW_COUNT} audit log events → ${CSV_FILE}"

if (( ROW_COUNT == 0 )); then
  log "No new events – removing empty file."
  rm -f "$CSV_FILE"
  if [[ -z "$ARG_SINCE" ]]; then
    echo "$NOW_ISO" > "$LAST_RUN_FILE"
  fi
  exit 0
fi

# ── 5. Save state ───────────────────────────────────────────────────────────
# Skip state update when an explicit --since was provided (backfill / one-off).

if [[ -z "$ARG_SINCE" ]]; then
  echo "$NOW_ISO" > "$LAST_RUN_FILE"
  log "State saved – next run will fetch events since ${NOW_ISO}"
else
  log "Explicit range – state file not updated."
fi
log "Done. CSV ready for upload: ${CSV_FILE}"
