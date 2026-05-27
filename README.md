# saas-templates

A collection of standalone, copy-and-adapt examples for automating common
operational tasks against a Moderne SaaS tenant. Each subdirectory is a
self-contained template with its own README, scripts, and configuration.

## Templates

| Template | What it does |
| -------- | ------------ |
| [`audit-logs/`](audit-logs/) | Pulls audit log events from the Moderne Platform on a schedule and uploads them as CSV to an S3 bucket for ingestion into a SIEM or data lake. Includes a backfill tool and a Docker image for scheduled runs. |
| [`auto-redeploy-recipes/`](auto-redeploy-recipes/) | Re-installs every recipe bundle registered in a tenant's universal marketplace so that bundles pinned to a moving version (`LATEST`, `latest.release`) pick up newly published artifact versions. Designed to run on a nightly cron. |

## Using a template

Each template is independent. Pick the directory you need, read its README,
and copy the scripts into your own automation environment. There is no shared
build or dependency step at the repository root.

## Adding a new template

Create a new top-level directory containing the template's scripts plus a
`README.md` that documents prerequisites, configuration (environment
variables), and how to run it. Add a row to the table above.
