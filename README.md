# Moderne Audit Log SIEM Export

Pulls audit log events from the Moderne Platform on a recurring schedule and uploads the CSV to an S3 bucket for ingestion into a SIEM system or data lake.

## How it works

```
┌──────────────┐   GraphQL API   ┌──────────────┐  CSV files  ┌──────────────┐
│   Moderne    │ ──────────────► │  sync-audit  │ ──────────► │     S3       │
│   Platform   │   (CSV export)  │  -logs.sh    │  (output/)  │    Bucket    │
└──────────────┘                 └──────────────┘             └──────────────┘
                                                                     ▲
                                                                     │
                                                              push-to-s3.sh
```

1. **`sync-audit-logs.sh`** calls the Moderne GraphQL API to export audit logs as CSV for the time window since the last successful sync. The CSV file is written to `output/`.
2. **`push-to-s3.sh`** uploads each CSV file to the configured S3 bucket. Successfully uploaded files are moved to `archive/`.

State is tracked in `state/last_run` so that each run only fetches new events.

## CSV format

The Moderne Platform produces CSV files with the following columns:

| Column        | Description                                                    | Example                                        |
|---------------|----------------------------------------------------------------|------------------------------------------------|
| `User`        | Email or identifier of the user that triggered the event       | `user@example.com`                             |
| `Target`      | The resource category the event applies to                     | `recipes`, `recipe.runs`, `artifact.storage`   |
| `Action type` | CRUD classification of the action                              | `Read`, `Create`, `Update`, `Delete`           |
| `Action`      | Specific action name                                           | `GET_RECIPE`, `RUN_RECIPE`                     |
| `Description` | Human-readable description of what happened                    | `Get a specific recipe and its details.`       |
| `Time`        | ISO 8601 timestamp of the event                                | `2026-02-16T12:00:00.123456Z`                  |
| `Outcome`     | Result of the action                                           | `Success`, `Failed`                            |

## Prerequisites

- A **Moderne Personal Access Token** (PAT) with admin scope. Create one at `https://<TENANT>.moderne.io/settings/access-token` or via the CLI using `mod config moderne login` (it will be stored in `~/.moderne/cli/moderne.yml`)
- An **S3 bucket** with write access (either via IAM role or AWS credentials).
- **Docker** (for containerized deployment) or **bash**, **curl**, **jq**, and **aws-cli** (for running locally).

## Quick start (local)

```bash
cp .env.example .env
# Edit .env with your Moderne tenant URL, PAT, and S3 bucket

# Source the environment
set -a; source .env; set +a

# Run once (pulls since last run, or last 24 hours on first run)
./sync-audit-logs.sh
./push-to-s3.sh

# Pull a specific time range (does not update saved state)
# Dates can be short (2026-01-01) or full RFC3339 (2026-01-01T00:00:00+00:00)
./sync-audit-logs.sh --since 2026-01-01 --until 2026-02-01
./push-to-s3.sh

# Large backfill with extended timeout (default is 120 seconds)
./sync-audit-logs.sh --since 2026-01-01 --until 2026-02-01 --timeout 600
./push-to-s3.sh
```

## Docker

### Build

```bash
docker build -t moderne-audit-export .
```

### Run with cron (default -- every 15 minutes)

```bash
docker run -d \
  --name moderne-audit-export \
  --env-file .env \
  -v audit-state:/app/state \
  -v audit-output:/app/output \
  -v audit-archive:/app/archive \
  moderne-audit-export
```

When running on EC2 or ECS, attach an IAM role with `s3:PutObject` permission on the target bucket instead of passing AWS credentials via environment variables.

### Run once (for Kubernetes CronJobs or testing)

```bash
docker run --rm \
  --env-file .env \
  moderne-audit-export once
```

### Override the sync interval

```bash
docker run -d \
  --env-file .env \
  -e SYNC_INTERVAL_MINUTES=5 \
  moderne-audit-export
```

## Backfill

To ingest historical audit logs, use `backfill-audit-logs.sh`. It batches requests into daily chunks (configurable) and tracks progress so it can be interrupted and resumed.

```bash
# Backfill from January 1, 2025 to now (1-day chunks, default)
./backfill-audit-logs.sh --since 2025-01-01

# Backfill and push each chunk to S3 as it completes
./backfill-audit-logs.sh --since 2025-01-01 --push

# Backfill a specific range in 7-day chunks
./backfill-audit-logs.sh --since 2025-01-01 --until 2025-06-01 --chunk-days 7

# Resume an interrupted backfill (just re-run the same command)
./backfill-audit-logs.sh --since 2025-01-01 --push

# Start over from scratch
./backfill-audit-logs.sh --reset --since 2025-01-01
```

| Option              | Default | Description                                   |
|---------------------|---------|-----------------------------------------------|
| `--since <date>`    | --      | Start date for backfill (required)            |
| `--until <date>`    | now     | End date for backfill                         |
| `--chunk-days <N>`  | `1`     | Days per batch                                |
| `--timeout <secs>`  | `600`   | Per-chunk download timeout                    |
| `--push`            | off     | Run `push-to-s3.sh` after each chunk          |
| `--reset`           | off     | Clear progress and start over                 |

CSV files are named with epoch timestamps for the date range: `audit-events-<since>-<until>.csv`. Re-running the same range produces the same filename.

## Configuration

| Variable                 | Required | Default        | Description                                                          |
|--------------------------|----------|----------------|----------------------------------------------------------------------|
| `MODERNE_TENANT_API_URL` | Yes      | --             | Moderne tenant URL (e.g., `https://api.mycompany.moderne.io`)        |
| `MODERNE_PAT`            | Yes      | --             | Moderne Personal Access Token (admin scope)                          |
| `S3_BUCKET`              | Yes      | --             | S3 bucket, optionally with key prefix (e.g., `my-bucket/audit-logs`) |
| `SYNC_INTERVAL_MINUTES`  | No       | `15`           | Minutes between cron runs                                            |
| `POLL_INTERVAL`          | No       | `5`            | Seconds between download-status poll requests                        |
| `POLL_TIMEOUT`           | No       | `120`          | Max seconds to wait for download completion                          |
| `OUTPUT_DIR`             | No       | `/app/output`  | Directory for CSV output files                                       |
| `STATE_DIR`              | No       | `/app/state`   | Directory for sync state (`last_run` timestamp)                      |
| `ARCHIVE_DIR`            | No       | `/app/archive` | Directory for successfully uploaded files                            |

## Moderne audit log API reference

The Moderne Platform exposes audit logs via GraphQL at `https://api.<TENANT>.moderne.io/graphql`:

- **Initiate download**: `mutation { downloadAuditLogs(format: CSV, since: "...", until: "...") { id state url } }`
- **Poll status**: `query { auditLogsDownload(id: "...") { id state url } }`
- **Download the file**: `curl -H "Authorization: Bearer $PAT" "<url>"`

The script appends `/graphql` to `MODERNE_TENANT_API_URL` to form the endpoint.

See the [Moderne reporting documentation](https://docs.moderne.io/administrator-documentation/moderne-platform/references/reporting) for more details.
