# auto-redeploy-saas-recipes

A small Bash script that re-installs every recipe bundle currently registered
in a Moderne SaaS tenant's **universal marketplace**. Run it on a nightly
cron and any bundle that was originally installed with a moving version
selector will pick up the newest artifact version published to your internal
artifact repository. Pinned versions are also re-resolved, which is a cheap
no-op.

Organization and user marketplaces are intentionally not touched.

## How it works

1. Calls `query { organization(id: "ALL") { marketplace { installations(...) } } }`
   on the tenant's GraphQL API (`/graphql`) and pages through the results.
2. Filters edges to `UniversalInstallScope` only.
3. For each bundle, fires `installRecipesUniversal(bundle: ...)` using the
   bundle's originally `requestedVersion`, then polls the install until it
   reaches `FINISHED` or `ERROR`.
4. Exits non-zero if any install failed or timed out, so the cron host can
   surface failures.

YAML bundles are skipped because they have no upstream artifact to refresh.

## Moving version selectors

The `requestedVersion` recorded at install time is what gets re-sent. To get
the "pick up the newest version" behavior, install your bundles with a
moving version selector in the first place:

| Ecosystem        | Use                                       |
| ---------------- | ----------------------------------------- |
| Maven            | `latest.release` or `latest.integration`  |
| Pip / Go         | `LATEST` (case-insensitive)               |
| NPM / NuGet      | a concrete version is required at install |

A bundle pinned to a concrete version will just be re-resolved to the same
version each night - harmless but a no-op.

## Requirements

- Bash 4+
- `curl` and `jq` on `PATH`
- A Moderne personal access token with the `admin` role

## Configuration

All configuration is via environment variables.

| Variable             | Required | Default | Notes                                                                 |
| -------------------- | -------- | ------- | --------------------------------------------------------------------- |
| `MODERNE_TENANT_URL` | yes      |         | Base URL of the tenant, e.g. `https://app.moderne.io`.                |
| `MODERNE_API_TOKEN`  | yes      |         | Personal access token (`mat-...`) with admin role.                    |
| `POLL_TIMEOUT_S`     | no       | `600`   | Per-install timeout, in seconds.                                      |
| `POLL_INTERVAL_S`    | no       | `5`     | Seconds between status polls.                                         |
| `DRY_RUN`            | no       | unset   | When `1`, prints what would be redeployed and exits without mutating. |

## Quick start

```sh
export MODERNE_TENANT_URL=https://app.moderne.io
export MODERNE_API_TOKEN=mat-...
./redeploy_recipes.sh
```

Dry run first to see the bundles that would be touched:

```sh
DRY_RUN=1 ./redeploy_recipes.sh
```

## Scheduling nightly

### cron

```cron
# Re-resolve universal recipe bundles every night at 02:30
30 2 * * *  MODERNE_TENANT_URL=https://app.moderne.io MODERNE_API_TOKEN=mat-... /opt/moderne/redeploy_recipes.sh >> /var/log/moderne-redeploy.log 2>&1
```

### GitHub Actions

```yaml
name: nightly-recipe-redeploy
on:
  schedule:
    - cron: '30 2 * * *'
  workflow_dispatch: {}

jobs:
  redeploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: ./redeploy_recipes.sh
        env:
          MODERNE_TENANT_URL: https://app.moderne.io
          MODERNE_API_TOKEN: ${{ secrets.MODERNE_API_TOKEN }}
```

## Exit codes

- `0` - every bundle finished installing.
- `1` - at least one bundle errored or timed out.
- `2` - misconfiguration (missing env vars, or `curl`/`jq` not on `PATH`).
