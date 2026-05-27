#!/usr/bin/env bash
#
# Re-install every recipe bundle currently registered in the universal
# marketplace of a Moderne SaaS tenant so that bundles requested with a
# moving version (`LATEST`, or for Maven the Maven resolver's own
# `latest.release` / `latest.integration`) pick up newly published
# artifact versions.
#
# Intended to run on a nightly cron. Universal scope only; organization
# and user marketplaces are intentionally not touched.
#
# Required environment variables:
#   MODERNE_TENANT_URL   Tenant API gateway URL, e.g. https://api.<tenant>.moderne.io
#                        (the api. host, not the web UI host)
#   MODERNE_API_TOKEN    Personal access token (admin role required).
#
# Optional environment variables:
#   POLL_TIMEOUT_S       Per-install timeout, seconds (default: 600)
#   POLL_INTERVAL_S      Seconds between status polls (default: 5)
#   DRY_RUN              "1" to list bundles and exit without mutating
#
# Dependencies: bash 4+, curl, jq.
# Exit codes: 0 = all bundles finished, 1 = one or more failed, 2 = misconfig.

set -euo pipefail

: "${MODERNE_TENANT_URL:?missing required env var MODERNE_TENANT_URL}"
: "${MODERNE_API_TOKEN:?missing required env var MODERNE_API_TOKEN}"
POLL_TIMEOUT_S="${POLL_TIMEOUT_S:-600}"
POLL_INTERVAL_S="${POLL_INTERVAL_S:-5}"
DRY_RUN="${DRY_RUN:-0}"

for cmd in curl jq; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "error: $cmd not found on PATH" >&2; exit 2; }
done

ENDPOINT="${MODERNE_TENANT_URL%/}/graphql"

# graphql QUERY VARIABLES_JSON -> prints .data; non-zero on errors.
graphql() {
    local query="$1" variables="$2" payload resp
    payload=$(jq -n --arg q "$query" --argjson v "$variables" '{query: $q, variables: $v}')
    resp=$(curl -sS --fail-with-body -X POST "$ENDPOINT" \
        -H "Authorization: Bearer ${MODERNE_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        --data "$payload") || {
        echo "HTTP error from $ENDPOINT: $resp" >&2
        return 1
    }
    if ! printf '%s' "$resp" | jq empty >/dev/null 2>&1; then
        echo "error: $ENDPOINT did not return JSON. Make sure MODERNE_TENANT_URL points at" >&2
        echo "       the API gateway (e.g. https://api.<tenant>.moderne.io), not the web UI." >&2
        return 1
    fi
    if echo "$resp" | jq -e '.errors' >/dev/null; then
        echo "GraphQL errors: $(echo "$resp" | jq -c '.errors')" >&2
        return 1
    fi
    echo "$resp" | jq '.data'
}

# Marketplace lookups go through Organization.marketplace; "ALL" is the
# root org id (RecipeMarketplaceDataFetcher.java uses it as the universal
# entry point). The resolver merges universal + org-chain + user installs
# into one list with each edge tagged by scope, so we filter to
# UniversalInstallScope client-side.
LIST_INSTALLATIONS_QUERY='query ListInstallations($first: Int!, $after: String) {
  organization(id: "ALL") {
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
  organization(id: "ALL") {
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

# Page through installations, keep only universal-scoped edges, and emit
# one bundle JSON object per line. YAML bundles are skipped: the install
# input requires a base64 yaml blob, not a coordinate that can be
# "refreshed" from an upstream artifact repository.
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

start_install() {
    local bundle_input="$1" data vars
    vars=$(jq -n --argjson b "$bundle_input" '{bundle: $b}')
    data=$(graphql "$INSTALL_MUTATION" "$vars") || return 1
    echo "$data" | jq -r '.installRecipesUniversal.id'
}

# poll_install INSTALL_ID -> exits 0 on FINISHED, 1 on ERROR/TIMEOUT/MISSING.
poll_install() {
    local install_id="$1" deadline state msg data
    deadline=$(( $(date +%s) + POLL_TIMEOUT_S ))
    while :; do
        data=$(graphql "$POLL_INSTALLATION_QUERY" \
            "$(jq -n --arg id "$install_id" '{id: $id}')") || return 1
        state=$(echo "$data" | jq -r '.organization.marketplace.installations.edges[0].node.__typename // "MISSING"')
        case "$state" in
            RecipeInstallationFinished) return 0 ;;
            RecipeInstallationError)
                msg=$(echo "$data" | jq -r '.organization.marketplace.installations.edges[0].node.message // ""')
                echo "    error: $msg" >&2; return 1 ;;
            MISSING)
                echo "    error: install $install_id disappeared" >&2; return 1 ;;
        esac
        if (( $(date +%s) >= deadline )); then
            echo "    error: still $state after ${POLL_TIMEOUT_S}s" >&2; return 1
        fi
        sleep "$POLL_INTERVAL_S"
    done
}

echo "Fetching universal-scoped installations from $ENDPOINT..."
# Portable array population (mapfile/readarray is bash 4+; macOS ships bash 3.2).
BUNDLES=()
while IFS= read -r line; do
    [[ -n "$line" ]] && BUNDLES+=("$line")
done < <(collect_bundles)
if [[ ${#BUNDLES[@]} -eq 0 ]]; then
    echo "No universal bundles found. Nothing to do."
    exit 0
fi
echo "Found ${#BUNDLES[@]} bundle(s) to redeploy:"
for b in "${BUNDLES[@]}"; do
    echo "  - $(echo "$b" | jq -r '"[\(.ecosystem)] \(.packageName) @ \(.version // "<unspecified>")"')"
done

if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY_RUN=1, skipping mutations."
    exit 0
fi

failures=0
for b in "${BUNDLES[@]}"; do
    label=$(echo "$b" | jq -r '"[\(.ecosystem)] \(.packageName) @ \(.version // "<unspecified>")"')
    bundle_input=$(echo "$b" | jq -c '.input')
    if ! install_id=$(start_install "$bundle_input"); then
        echo "  FAIL  $label"
        failures=$((failures + 1))
        continue
    fi
    if poll_install "$install_id"; then
        echo "  OK    $label"
    else
        echo "  FAIL  $label"
        failures=$((failures + 1))
    fi
done

total=${#BUNDLES[@]}
echo
echo "Done. $((total - failures))/${total} succeeded."
if (( failures > 0 )); then
    exit 1
fi
