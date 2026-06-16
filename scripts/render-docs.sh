#!/usr/bin/env bash
set -euo pipefail

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*" >&2; }

command -v jq >/dev/null || die "jq not found"

MANIFEST="${1:-manifest.json}"
README="${README:-README.md}"
PREV_MANIFEST="${PREV_MANIFEST:-}"
RELEASE_OUT="${RELEASE_OUT:-dist/release-notes.md}"
START="<!-- BEGIN BUNDLED PLUGINS -->"
END="<!-- END BUNDLED PLUGINS -->"

render_table() {
  printf '| Plugin | Version | Origin | Commit |\n'
  printf '| --- | --- | --- | --- |\n'
  jq -r '.plugins[]
    | "| [\(.repo)](https://github.com/\(.repo)) | \(.version) | \(.origin) | `\(.commit_sha[0:7])` |"' \
    "$MANIFEST"
}

# --- README table between markers ----------------------------------------
table="$(render_table)"
tmp="$(mktemp)"
awk -v start="$START" -v end="$END" -v tbl="$table" '
  $0 == start { print; print tbl; skip=1; next }
  $0 == end   { skip=0 }
  skip != 1   { print }
' "$README" >"$tmp"
mv "$tmp" "$README"

# --- Release notes --------------------------------------------------------
mkdir -p "$(dirname "$RELEASE_OUT")"
version="$(jq -r .version "$MANIFEST")"
crs="$(jq -r .crs_compatibility "$MANIFEST")"
{
  printf '## crs-plugins %s\n\n' "$version"
  printf 'CRS compatibility: %s\n\n' "$crs"
  printf '### Changes\n\n'
  if [ -n "$PREV_MANIFEST" ] && [ -f "$PREV_MANIFEST" ]; then
    jq -rn --slurpfile cur "$MANIFEST" --slurpfile old "$PREV_MANIFEST" '
      ($cur[0].plugins) as $c | ($old[0].plugins) as $o |
      ( [ $c[] | select(.repo as $r | ($o | map(.repo) | index($r)) | not)
          | "- added \(.repo)@\(.version)" ] ) +
      ( [ $c[] as $p | ($o[] | select(.repo == $p.repo)) as $q
          | select($p.version != $q.version)
          | "- \($p.dir) \($q.version) -> \($p.version)" ] ) | .[]'
  else
    jq -r '.plugins[] | "- added \(.repo)@\(.version)"' "$MANIFEST"
  fi
  printf '\n### Bundled plugins\n\n'
  render_table
} >"$RELEASE_OUT"

log "rendered README table and ${RELEASE_OUT}"
