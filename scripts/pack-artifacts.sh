#!/usr/bin/env bash
set -euo pipefail

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*" >&2; }

for c in jq tar sha256sum; do command -v "$c" >/dev/null || die "$c not found"; done

STAGING="${STAGING:-staging}"
DIST="${DIST:-dist}"
MANIFEST="${STAGING}/manifest.json"

[ -f "$MANIFEST" ] || die "manifest.json not in staging; run build-plugins first"
version="$(jq -r .version "$MANIFEST")"
if [ -z "$version" ] || [ "$version" = "null" ]; then
  die "manifest has no version; publish fills it before packing"
fi

mkdir -p "$DIST"
tarball="${DIST}/crs-plugins-${version}.tar.gz"
tar -C "$STAGING" -czf "$tarball" .
cp "$MANIFEST" "${DIST}/manifest.json"
( cd "$DIST" && sha256sum "crs-plugins-${version}.tar.gz" "manifest.json" >SHA256SUMS )

log "packed ${tarball} and SHA256SUMS"
