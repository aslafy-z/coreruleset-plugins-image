#!/usr/bin/env bash
set -euo pipefail

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*" >&2; }

for c in yq jq curl tar sha256sum; do
  command -v "$c" >/dev/null || die "$c not found"
done

PLUGINS_FILE="${PLUGINS_FILE:-plugins.yaml}"
STAGING="${STAGING:-staging}"
MANIFEST="${MANIFEST:-manifest.json}"
GITHUB_API="${GITHUB_API:-https://api.github.com}"

CRS_COMPAT="$(yq '.crs_compatibility' "$PLUGINS_FILE")"
COMMIT="${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"
GENERATED="${GENERATED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

rm -rf "$STAGING"; mkdir -p "$STAGING"
records="[]"; total_files=0

# Iterate non-disabled entries as compact JSON lines.
while IFS= read -r entry; do
  [ -z "$entry" ] && continue
  repo="$(jq -r .repo <<<"$entry")"
  dir_override="$(jq -r '.dir // "null"' <<<"$entry")"
  sha="$(jq -r '.resolved.commit_sha // ""' <<<"$entry")"
  ver="$(jq -r '.resolved.version // ""' <<<"$entry")"
  rtype="$(jq -r '.resolved.ref_type // ""' <<<"$entry")"
  origin="$(jq -r '.origin // "registry"' <<<"$entry")"

  [ -n "$sha" ] || die "entry ${repo} has no resolved commit_sha (fail closed)"

  if [ "$dir_override" != "null" ] && [ -n "$dir_override" ]; then
    dir="$dir_override"
  else
    base="${repo##*/}"; dir="${base%-plugin}"
  fi
  dest="${STAGING}/${dir}"
  [ -d "$dest" ] && die "duplicate staging dir: ${dir} (set a dir override)"

  tar_tmp="$(mktemp)"
  curl -fsSL ${GITHUB_TOKEN:+-H "Authorization: Bearer ${GITHUB_TOKEN}"} \
    "https://api.github.com/repos/${repo}/tarball/${sha}" -o "$tar_tmp" \
    || die "download failed for ${repo}@${sha}"
  archive_sha="$(sha256sum "$tar_tmp" | cut -d' ' -f1)"

  # List once to a file: piping `tar | grep -q` lets grep close the pipe early,
  # killing tar with SIGPIPE, which pipefail then surfaces as a false failure.
  list_tmp="$(mktemp)"
  tar -tzf "$tar_tmp" >"$list_tmp"
  grep -qE '(^|/)plugins/' "$list_tmp" \
    || die "archive for ${repo} has no plugins/ directory"
  rm -f "$list_tmp"
  mkdir -p "$dest"
  tar -C "$dest" -xzf "$tar_tmp" --wildcards --strip-components=2 '*/plugins/*' 2>/dev/null
  rm -f "$tar_tmp"

  [ -n "$(find "$dest" -type f -print -quit)" ] || die "no files staged for ${dir}"
  files_json="$(cd "$dest" && find . -maxdepth 1 -type f -printf '%f\n' \
    | LC_ALL=C sort | jq -R . | jq -s -c .)"
  total_files=$((total_files + $(jq 'length' <<<"$files_json")))

  records="$(jq -n --argjson acc "$records" \
    --arg repo "$repo" --arg dir "$dir" --arg version "$ver" --arg rtype "$rtype" \
    --arg sha "$sha" --arg asha "$archive_sha" --argjson files "$files_json" --arg origin "$origin" \
    '$acc + [{repo:$repo, dir:$dir, version:$version, ref_type:$rtype,
              commit_sha:$sha, archive_sha256:$asha, files:$files, origin:$origin}]')"
done < <(yq -o=json -I=0 '.plugins[] | select(.disabled != true)' "$PLUGINS_FILE")

[ "$total_files" -gt 0 ] || die "no files staged from any plugin (refusing empty image)"

# Generate manifest (version + build_digest filled below / at publish).
jq -n --arg crs "$CRS_COMPAT" --arg commit "$COMMIT" --arg generated "$GENERATED" \
  --argjson plugins "$records" \
  '{version:"", crs_compatibility:$crs, generated:$generated, commit:$commit,
    build_digest:"", plugins:$plugins}' >"$MANIFEST"

# Build-input digest: sorted staged paths+hashes (excluding manifest.json),
# Dockerfile, payload scripts, and normalized manifest-relevant plugins.yaml.
norm="$(yq -o=json '{
  "crs_compatibility": .crs_compatibility,
  "plugins": [ .plugins[] | select(.disabled != true)
    | {"dir": .dir, "origin": .origin, "commit_sha": .resolved.commit_sha, "version": .resolved.version} ]
}' "$PLUGINS_FILE" | jq -S -c .)"

digest="$( {
  ( cd "$STAGING" && find . -type f ! -name manifest.json | LC_ALL=C sort \
    | while IFS= read -r f; do printf '%s  %s\n' "$f" "$(sha256sum "$f" | cut -d' ' -f1)"; done )
  sha256sum Dockerfile scripts/build-plugins.sh scripts/pack-artifacts.sh | cut -d' ' -f1
  printf '%s\n' "$norm"
} | sha256sum | cut -d' ' -f1 )"

tmp="$(mktemp)"
jq --arg d "sha256:${digest}" '.build_digest = $d' "$MANIFEST" >"$tmp"
mv "$tmp" "$MANIFEST"
cp "$MANIFEST" "${STAGING}/manifest.json"

log "staged ${total_files} files; build_digest sha256:${digest}"
[ "${1:-}" = "--dry-run" ] && { log "dry-run: no push"; exit 0; }
log "staging complete"
