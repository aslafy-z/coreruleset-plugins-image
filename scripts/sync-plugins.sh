#!/usr/bin/env bash
set -euo pipefail

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*" >&2; }

PLUGINS_FILE="${PLUGINS_FILE:-plugins.yaml}"
REGISTRY_URL="${REGISTRY_URL:-https://raw.githubusercontent.com/coreruleset/plugin-registry/main/README.md}"
GITHUB_API="${GITHUB_API:-https://api.github.com}"

command -v yq >/dev/null || die "yq not found"
command -v jq >/dev/null || die "jq not found"
command -v curl >/dev/null || die "curl not found"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

CRS_COMPATIBILITY="${CRS_COMPATIBILITY:-4.x}"

# Bootstrap a minimal file if absent; reconciliation fills it from the registry.
if [ ! -f "$PLUGINS_FILE" ]; then
  log "creating ${PLUGINS_FILE} (did not exist)"
  cat >"$PLUGINS_FILE" <<EOF
# Source of truth for the bundled CRS plugins.
# Curated fields are human-edited; the \`resolved\` block is written by the
# nightly sync job via PR, so committed SHAs are always reviewed before build.
crs_compatibility: "${CRS_COMPATIBILITY}"
plugins: []
EOF
fi

gh_get() {
  curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    ${GITHUB_TOKEN:+-H "Authorization: Bearer ${GITHUB_TOKEN}"} \
    "${GITHUB_API}/$1" 2>/dev/null || true
}

# --- 1. Fetch + parse registry -------------------------------------------
log "fetching registry: ${REGISTRY_URL}"
curl -fsSL "$REGISTRY_URL" >"${tmp}/registry.md" \
  || die "registry fetch failed (no partial changes written)"

# Extract owner/repo from github links, skipping draft/private rows.
grep -viE 'draft|private' "${tmp}/registry.md" \
  | grep -oE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' \
  | sed -E 's#https://github\.com/##; s#/$##' \
  | LC_ALL=C sort -u >"${tmp}/slugs.txt"
[ -s "${tmp}/slugs.txt" ] || die "registry parse produced no slugs"

# --- 2. Reconcile registry slugs -----------------------------------------
present="$(yq -o=json -I=0 '[.plugins[].repo]' "$PLUGINS_FILE")"
managed="$(yq -o=json -I=0 \
  '[.plugins[] | select(.origin == "registry" and .disabled != true) | .repo]' \
  "$PLUGINS_FILE")"
slugs="$(jq -R -s 'split("\n") | map(select(length > 0))' "${tmp}/slugs.txt")"

# Additions: registry slugs with no entry at all.
jq -rn --argjson present "$present" --argjson slugs "$slugs" \
  '$slugs[] | select(. as $s | ($present | index($s)) | not)' \
  | while IFS= read -r slug; do
      [ -z "$slug" ] && continue
      log "adding registry plugin ${slug}"
      yq -i ".plugins += [{\"repo\": \"${slug}\", \"origin\": \"registry\", \"pin\": null, \"dir\": null, \"disabled\": false, \"resolved\": null}]" \
        "$PLUGINS_FILE"
    done

# Removals: managed registry entries no longer in the registry.
jq -rn --argjson managed "$managed" --argjson slugs "$slugs" \
  '$managed[] | select(. as $m | ($slugs | index($m)) | not)' \
  | while IFS= read -r slug; do
      [ -z "$slug" ] && continue
      log "removing dropped registry plugin ${slug}"
      yq -i "del(.plugins[] | select(.repo == \"${slug}\"))" "$PLUGINS_FILE"
    done

# --- 3. Resolve versions for every non-disabled entry --------------------
count="$(yq '.plugins | length' "$PLUGINS_FILE")"
for i in $(seq 0 $((count - 1))); do
  [ "$(yq ".plugins[$i].disabled" "$PLUGINS_FILE")" = "true" ] && continue
  repo="$(yq ".plugins[$i].repo" "$PLUGINS_FILE")"
  pin="$(yq ".plugins[$i].pin" "$PLUGINS_FILE")"

  if [ -n "$pin" ] && [ "$pin" != "null" ]; then
    ver="${pin:0:7}"; rtype="sha"; sha="$pin"
  else
    rel="$(gh_get "repos/${repo}/releases/latest")"
    tag="$(printf '%s' "$rel" | jq -r 'if .tag_name then (.tag_name | sub("^v"; "")) else "" end')"
    if [ -n "$tag" ]; then
      refj="$(gh_get "repos/${repo}/git/refs/tags/v${tag}")"
      sha="$(printf '%s' "$refj" | jq -r '.object.sha // empty')"
      [ -z "$sha" ] && {
        refj="$(gh_get "repos/${repo}/git/refs/tags/${tag}")"
        sha="$(printf '%s' "$refj" | jq -r '.object.sha // empty')"
      }
      [ -n "$sha" ] || die "could not resolve tag ${tag} for ${repo}"
      ver="$tag"; rtype="tag"
    else
      headj="$(gh_get "repos/${repo}/commits/HEAD")"
      sha="$(printf '%s' "$headj" | jq -r '.sha // empty')"
      [ -n "$sha" ] || die "could not resolve HEAD for ${repo}"
      ver="${sha:0:7}"; rtype="sha"
    fi
  fi

  log "resolved ${repo} -> ${ver} (${rtype}) ${sha}"
  yq -i ".plugins[$i].resolved = {\"version\": \"${ver}\", \"ref_type\": \"${rtype}\", \"commit_sha\": \"${sha}\"}" \
    "$PLUGINS_FILE"
done

log "sync complete; plugins.yaml updated in place"
