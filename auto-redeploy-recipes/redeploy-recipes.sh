#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# redeploy-recipes.sh
#
# Re-installs every recipe bundle currently registered in the universal
# marketplace of a Moderne SaaS tenant so that bundles requested with a moving
# version (LATEST, or for Maven the Maven resolver's own latest.release /
# latest.integration) pick up newly published artifact versions.
#
# Intended to run on a nightly cron.  Universal scope only; organization and
# user marketplaces are intentionally not touched.
#
# Required environment variables:
#   MODERNE_TENANT_API_URL  – e.g. https://api.app.moderne.io  (the api. host,
#                             not the web UI host)
#   MODERNE_PAT             – a Moderne Personal Access Token with admin scope
#
# Optional environment variables:
#   POLL_INTERVAL           – seconds between install-status checks (default: 5)
#   POLL_TIMEOUT            – maximum seconds to wait per install (default: 600)
#   DRY_RUN                 – "1" to list bundles and exit without mutating
#
# Examples:
#   ./redeploy-recipes.sh
#   DRY_RUN=1 ./redeploy-recipes.sh
#
# Dependencies: bash, curl, jq.
# Exit codes: 0 = all bundles finished, 1 = one or more failed, 2 = misconfig.
# ──────────────────────────────────────────────────────────────────────────────

# ── Helpers ──────────────────────────────────────────────────────────────────

# Logs go to stderr so that they never contaminate the stdout of functions whose
# output is captured with $() (graphql's .data, collect_bundles' bundle list,
# start_install's id).  Cron redirects (>> log 2>&1) still capture them.
log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" >&2; }

# Send a GraphQL operation (query string + variables JSON) and print .data.
# Returns non-zero on transport errors, non-JSON responses, or GraphQL errors.
#
# The X-Moderne-Platform-Version: v2 header routes the request to the v2 platform
# on tenants mid-migration, where api.<tenant>.moderne.io still resolves to the v1
# front door. It's required to authenticate with a v2 token and is a harmless
# no-op on tenants that are fully on v1 or fully cut over to v2.
graphql() {
  local query="$1" variables="$2" payload resp
  payload=$(jq -n --arg q "$query" --argjson v "$variables" '{query: $q, variables: $v}')
  resp=$(curl -sS --fail-with-body -X POST "$GRAPHQL_URL" \
    -H "Authorization: Bearer ${MODERNE_PAT}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -H "X-Moderne-Platform-Version: v2" \
    -d "$payload") || {
    log "ERROR: HTTP error from ${GRAPHQL_URL}: ${resp}"
    return 1
  }
  if ! printf '%s' "$resp" | jq empty >/dev/null 2>&1; then
    log "ERROR: ${GRAPHQL_URL} did not return JSON. Set MODERNE_TENANT_API_URL to the"
    log "       API gateway (e.g. https://api.<tenant>.moderne.io), not the web UI."
    return 1
  fi
  if echo "$resp" | jq -e '.errors' >/dev/null; then
    log "ERROR: GraphQL errors: $(echo "$resp" | jq -c '.errors')"
    return 1
  fi
  echo "$resp" | jq '.data'
}

# ── Configuration ────────────────────────────────────────────────────────────

: "${MODERNE_TENANT_API_URL:?Set MODERNE_TENANT_API_URL (e.g. https://api.app.moderne.io)}"
: "${MODERNE_PAT:?Set MODERNE_PAT to a Moderne Personal Access Token}"

POLL_INTERVAL="${POLL_INTERVAL:-5}"
POLL_TIMEOUT="${POLL_TIMEOUT:-600}"
DRY_RUN="${DRY_RUN:-0}"
GRAPHQL_URL="${MODERNE_TENANT_API_URL%/}/graphql"

for cmd in curl jq; do
  command -v "$cmd" >/dev/null 2>&1 || { log "ERROR: ${cmd} not found on PATH"; exit 2; }
done

# ── GraphQL operations ───────────────────────────────────────────────────────
#
# Marketplace lookups go through Organization.marketplace; "ε" (epsilon) is the
# synthetic global-root org id used by the UI's GLOBAL_ORGANIZATION_ID, present
# on every tenant regardless of how the customer's org tree is configured.  The
# resolver merges universal + org-chain + user installs into one list with each
# edge tagged by scope, so we filter to UniversalInstallScope client-side.

LIST_INSTALLATIONS_QUERY='query ListInstallations($first: Int!, $after: String) {
  organization(id: "ε") {
    marketplace {
      installations(first: $first, after: $after) {
        pageInfo { hasNextPage endCursor }
        edges {
          scope { __typename }
          node {
            bundle {
              __typename
              requestedVersion
              version
              ... on MavenRecipeBundle { groupId artifactId packageName }
              ... on NpmRecipeBundle   { packageName }
              ... on NugetRecipeBundle { packageName }
              ... on PipRecipeBundle   { packageName }
              ... on GoRecipeBundle    { packageName }
            }
          }
        }
      }
    }
  }
}'

INSTALL_MUTATION='mutation Install($bundle: RecipeBundleInput!) {
  installRecipesUniversal(bundle: $bundle) { id }
}'

POLL_INSTALLATION_QUERY='query PollInstallation($id: ID!) {
  organization(id: "ε") {
    marketplace {
      installations(first: 1, where: { id: { _eq: $id } }) {
        edges {
          node {
            __typename
            ... on RecipeInstallationError { message }
          }
        }
      }
    }
  }
}'

# ── Functions ────────────────────────────────────────────────────────────────

# Page through installations, keep only universal-scoped edges, and emit one
# bundle JSON object per line.  YAML bundles are skipped: the install input
# requires a base64 yaml blob, not a coordinate that can be refreshed from an
# upstream artifact repository.
collect_bundles() {
  local cursor=null all_edges='[]' data
  while :; do
    data=$(graphql "$LIST_INSTALLATIONS_QUERY" \
      "$(jq -n --argjson c "$cursor" '{first: 100, after: $c}')")
    all_edges=$(jq -c --argjson new \
      "$(echo "$data" | jq '.organization.marketplace.installations.edges')" \
      '. + $new' <<<"$all_edges")
    local has_next end_cursor
    has_next=$(echo "$data" | jq -r '.organization.marketplace.installations.pageInfo.hasNextPage')
    end_cursor=$(echo "$data" | jq -r '.organization.marketplace.installations.pageInfo.endCursor // empty')
    [[ "$has_next" == "true" && -n "$end_cursor" ]] || break
    cursor=$(jq -n --arg c "$end_cursor" '$c')
  done

  jq -c '[ .[]
          | select(.scope.__typename == "UniversalInstallScope")
          | .node.bundle ]
         | map(
             (.requestedVersion // .version) as $v
             | if .__typename == "MavenRecipeBundle" and $v then
                 {ecosystem: "Maven", packageName: .packageName, version: $v,
                  input: {maven: {groupId: .groupId, artifactId: .artifactId, version: $v}}}
               elif .__typename == "NpmRecipeBundle" and $v then
                 {ecosystem: "NPM", packageName: .packageName, version: $v,
                  input: {npm: {packageName: .packageName, version: $v}}}
               elif .__typename == "NugetRecipeBundle" and $v then
                 {ecosystem: "Nuget", packageName: .packageName, version: $v,
                  input: {nuget: {packageName: .packageName, version: $v}}}
               elif .__typename == "PipRecipeBundle" then
                 {ecosystem: "Pip", packageName: .packageName, version: $v,
                  input: {pip: ({packageName: .packageName} + (if $v then {version: $v} else {} end))}}
               elif .__typename == "GoRecipeBundle" then
                 {ecosystem: "Go", packageName: .packageName, version: $v,
                  input: {go: ({packageName: .packageName} + (if $v then {version: $v} else {} end))}}
               else empty end
           )
         | sort_by(.ecosystem, .packageName)
         | .[]' <<<"$all_edges"
}

# start_install BUNDLE_INPUT -> 0 on success with INSTALL_ID set to the new id.
# On failure, returns 1 and sets FAIL_REASON to a human-readable explanation.
# Sets INSTALL_ID via a global rather than stdout so it isn't run in a $()
# subshell, which would discard the FAIL_REASON it sets.
start_install() {
  local bundle_input="$1" data vars
  INSTALL_ID=""
  vars=$(jq -n --argjson b "$bundle_input" '{bundle: $b}')
  if ! data=$(graphql "$INSTALL_MUTATION" "$vars"); then
    FAIL_REASON="install request was rejected (see GraphQL/HTTP error above)"
    return 1
  fi
  INSTALL_ID=$(echo "$data" | jq -r '.installRecipesUniversal.id // empty')
  if [[ -z "$INSTALL_ID" ]]; then
    FAIL_REASON="install request returned no id; response was: $(echo "$data" | jq -c .)"
    return 1
  fi
  return 0
}

# poll_install INSTALL_ID -> 0 on FINISHED, 1 on ERROR or TIMEOUT. A transiently
# MISSING install (not yet visible in the eventually-consistent listing) is polled
# until it appears or POLL_TIMEOUT elapses, not treated as an immediate failure.
# On failure, returns 1 and sets FAIL_REASON to a human-readable explanation
# (always including the install id so the failure can be looked up in the UI).
poll_install() {
  local install_id="$1" deadline state msg data
  deadline=$(( $(date +%s) + POLL_TIMEOUT ))
  while :; do
    if ! data=$(graphql "$POLL_INSTALLATION_QUERY" \
      "$(jq -n --arg id "$install_id" '{id: $id}')"); then
      FAIL_REASON="could not query status of install ${install_id} (see error above)"
      return 1
    fi
    state=$(echo "$data" | jq -r '.organization.marketplace.installations.edges[0].node.__typename // "MISSING"')
    case "$state" in
      RecipeInstallationFinished) return 0 ;;
      RecipeInstallationError)
        msg=$(echo "$data" | jq -r '.organization.marketplace.installations.edges[0].node.message // "(no message returned)"')
        FAIL_REASON="install ${install_id} failed: ${msg}"
        log "  error: ${msg} (install ${install_id})"
        return 1 ;;
      # MISSING (no edge yet) is not terminal: the listing is eventually consistent, so a
      # just-enqueued or just-finished install can be briefly absent. Keep polling; a still
      # MISSING install is caught by the POLL_TIMEOUT branch below.
    esac
    if (( $(date +%s) >= deadline )); then
      FAIL_REASON="install ${install_id} still ${state} after ${POLL_TIMEOUT}s timeout"
      log "  error: ${FAIL_REASON}"
      return 1
    fi
    sleep "$POLL_INTERVAL"
  done
}

# ── Redeploy ─────────────────────────────────────────────────────────────────

log "Fetching universal-scoped installations from ${GRAPHQL_URL}…"

# Capture collect_bundles' output to a variable first.  A process-substitution
# `done < <(collect_bundles)` would let a fetch failure (API down, bad token,
# non-JSON response) close the pipe with no output, leaving BUNDLES empty and
# the script silently exiting 0 with "Nothing to do" — invisible to a cron.
# Assigning from $() under `set -e` propagates the failure so we can fail loud.
BUNDLES_JSON=$(collect_bundles) || {
  log "ERROR: failed to fetch installations from ${GRAPHQL_URL}"
  exit 1
}

# Portable array population (mapfile/readarray is bash 4+; macOS ships bash 3.2).
BUNDLES=()
while IFS= read -r line; do
  [[ -n "$line" ]] && BUNDLES+=("$line")
done <<<"$BUNDLES_JSON"

if [[ ${#BUNDLES[@]} -eq 0 ]]; then
  log "No universal bundles found. Nothing to do."
  exit 0
fi

log "Found ${#BUNDLES[@]} bundle(s) to redeploy:"
for b in "${BUNDLES[@]}"; do
  log "  - $(echo "$b" | jq -r '"[\(.ecosystem)] \(.packageName) @ \(.version // "<unspecified>")"')"
done

if [[ "$DRY_RUN" == "1" ]]; then
  log "DRY_RUN=1 – skipping mutations."
  exit 0
fi

# ── Process each bundle ──────────────────────────────────────────────────────

FAILED=0
FAILURES=()
for b in "${BUNDLES[@]}"; do
  LABEL=$(echo "$b" | jq -r '"[\(.ecosystem)] \(.packageName) @ \(.version // "<unspecified>")"')
  BUNDLE_INPUT=$(echo "$b" | jq -c '.input')
  FAIL_REASON=""
  INSTALL_ID=""

  if ! start_install "$BUNDLE_INPUT"; then
    log "FAIL  ${LABEL}: ${FAIL_REASON}"
    FAILURES+=("${LABEL}: ${FAIL_REASON}")
    FAILED=$(( FAILED + 1 ))
    continue
  fi

  if poll_install "$INSTALL_ID"; then
    log "OK    ${LABEL} (install ${INSTALL_ID})"
  else
    log "FAIL  ${LABEL}: ${FAIL_REASON}"
    FAILURES+=("${LABEL}: ${FAIL_REASON}")
    FAILED=$(( FAILED + 1 ))
  fi
done

TOTAL=${#BUNDLES[@]}
log "Done. $(( TOTAL - FAILED ))/${TOTAL} succeeded."
if (( FAILED > 0 )); then
  log "${FAILED} of ${TOTAL} bundle(s) failed to redeploy:"
  for f in "${FAILURES[@]}"; do
    log "  - ${f}"
  done
  exit 1
fi
