#!/usr/bin/env bash
# Print the image's org.opencontainers.image.* metadata, one key=value per line.
set -euo pipefail

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null || die "jq not found"

MANIFEST="${1:-manifest.json}"
REPO_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-aslafy-z/coreruleset-plugins-image}"
VENDOR="${GITHUB_REPOSITORY_OWNER:-aslafy-z}"

[ -f "$MANIFEST" ] || die "${MANIFEST} not found; run build-plugins first"

jq -er --arg url "$REPO_URL" --arg vendor "$VENDOR" '
  if (.version // "") == "" then
    error("manifest has no version; publish fills it before building")
  else . end
  | {
      title: "coreruleset-plugins",
      description: "OWASP CRS plugins as a minimal, signed OCI image for Coraza/Envoy WAFs.",
      vendor: $vendor,
      url: $url,
      source: $url,
      documentation: "\($url)#readme",
      version: .version,
      revision: .commit,
      created: .generated
    }
  | to_entries[]
  | "org.opencontainers.image.\(.key)=\(.value)"
' "$MANIFEST"
