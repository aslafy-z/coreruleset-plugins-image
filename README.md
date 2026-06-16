# coreruleset-plugins

[![build-publish](https://github.com/aslafy-z/coreruleset-plugins-image/actions/workflows/build-publish.yml/badge.svg)](https://github.com/aslafy-z/coreruleset-plugins-image/actions/workflows/build-publish.yml)
[![sync-plugins](https://github.com/aslafy-z/coreruleset-plugins-image/actions/workflows/sync-plugins.yml/badge.svg)](https://github.com/aslafy-z/coreruleset-plugins-image/actions/workflows/sync-plugins.yml)
[![GHCR](https://img.shields.io/badge/ghcr.io-aslafy--z%2Fcoreruleset--plugins-blue?logo=docker)](https://github.com/aslafy-z/coreruleset-plugins-image/pkgs/container/coreruleset-plugins)
[![Release](https://img.shields.io/github/v/release/aslafy-z/coreruleset-plugins-image?sort=semver)](https://github.com/aslafy-z/coreruleset-plugins-image/releases/latest)
[![CRS](https://img.shields.io/badge/CRS-4.x-005571)](https://coreruleset.org)
[![Signed](https://img.shields.io/badge/cosign-signed-brightgreen?logo=sigstore)](https://www.sigstore.dev)

A single, minimal OCI image that bundles [OWASP Core Rule Set](https://coreruleset.org)
plugins for delivery to a Web Application Firewall as a Kubernetes
[image volume](https://kubernetes.io/docs/concepts/storage/volumes/#image). The
image carries plugin files only; the WAF runtime activates the ones it references
by `Include` directive. Delivery is bundled, activation is on demand.

It pairs naturally with the
[`coraza-envoy-go-filter`](https://github.com/united-security-providers/coraza-envoy-go-filter)
("Coraza Web Application Firewall implemented as Envoy Go Filter"), which embeds
CRS in the compiled filter and loads additional plugin rules from the filesystem.
Mount this image, point the filter's directives at the mount path, and the plugins
are available without rebuilding the filter.

## Highlights

- **Minimal.** A `FROM scratch` image; its root is `<plugin>/<files>` plus a
  machine-readable `manifest.json`. No shell, no base layer, no attack surface.
- **Curated and reviewed.** The plugin set lives in `plugins.yaml` and tracks the
  official [CRS plugin registry](https://github.com/coreruleset/plugin-registry).
  A nightly job proposes registry and version changes as pull requests; nothing
  reaches `:latest` without human review.
- **Reproducible inputs.** Every plugin is pinned to a commit SHA. The build
  records each archive's SHA-256 and a digest over all build inputs, republishing
  only when those inputs actually change.
- **Supply-chain ready.** Images are signed with [cosign](https://www.sigstore.dev)
  (keyless OIDC) and carry a [SLSA](https://slsa.dev) build-provenance attestation.
- **Two delivery paths.** Pull from GHCR, or fetch the `manifest.json` and
  `tar.gz` attached to each GitHub Release when a registry is not reachable.

## Quick start

The image is consumed as a Kubernetes image volume. The example below mounts it
into an Envoy pod running the Coraza filter and wires the plugin files into the
WAF directive chain.

```yaml
# Pod spec: image volume + the container's mount
spec:
  containers:
    - name: envoy
      volumeMounts:
        - name: crs-plugins
          mountPath: /etc/crs/plugins
  volumes:
    - name: crs-plugins
      image:
        reference: ghcr.io/aslafy-z/coreruleset-plugins:latest   # or pin :2026.06.0
```

```yaml
# Coraza filter directives (Envoy plugin_config TypedStruct)
plugin_config:
  "@type": type.googleapis.com/xds.type.v3.TypedStruct
  value:
    directives:
      waf1:
        simple_directives:
          - "Include @coraza-setup"
          - "SecRuleEngine On"
          - "Include @crs-setup"
          # Plugin config + before-rules from the mounted volume, BEFORE core rules:
          - "Include /etc/crs/plugins/*/*-config.conf"
          - "Include /etc/crs/plugins/*/*-before.conf"
          - "Include @owasp_crs/*.conf"
          # Plugin after-rules, AFTER core rules:
          - "Include /etc/crs/plugins/*/*-after.conf"
    default_directive: "waf1"
```

> **Ordering is load-bearing.** `-config` and `-before` files must load *before*
> `@owasp_crs/*.conf`, and `-after` files *after* it. A single `*/*.conf` glob
> breaks this, so the includes are split around the core rules. The `@` prefix
> marks resources embedded in the filter; plain filesystem paths reference the
> mounted volume.

### Requirements

Kubernetes image volumes require the `ImageVolume` feature and a supporting
runtime:

| Kubernetes | `ImageVolume` state | Action |
| --- | --- | --- |
| v1.31 – v1.32 | Alpha (off) | Enable the feature gate |
| v1.33 – v1.34 | Beta (off by default) | Enable the feature gate |
| v1.35 | Beta (on by default) | None |
| v1.36+ | Stable | None |

Container runtime: containerd 2.0+ or CRI-O 1.31+.

## Image layout

```
/                              # image root (mount target)
├── manifest.json              # generated build record
├── nextcloud/                 # one directory per plugin
│   ├── nextcloud-config.conf
│   └── nextcloud-before.conf
├── wordpress/
│   └── ...
└── ...
```

Each plugin's files live under a dedicated directory, so filenames never collide.
The directory name defaults to the repository basename with the `-plugin` and
`-rule-exclusions` suffixes stripped (overridable per entry). Mounting the root
at `/etc/crs/plugins` exposes `/etc/crs/plugins/<plugin>/<files>` with no doubled
path segment.

## Verifying provenance

```bash
IMAGE=ghcr.io/aslafy-z/coreruleset-plugins:latest

# Verify the cosign keyless signature
cosign verify "$IMAGE" \
  --certificate-identity-regexp "https://github.com/aslafy-z/coreruleset-plugins-image/.*" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com"

# Verify the SLSA build-provenance attestation
cosign verify-attestation "$IMAGE" \
  --type slsaprovenance \
  --certificate-identity-regexp "https://github.com/aslafy-z/coreruleset-plugins-image/.*" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com"
```

## Versioning

Tags use CalVer `YYYY.MM.N`, where `N` is an unbounded per-month counter starting
at `0` and incrementing on every published change. The three numeric segments are
parsed and ordered out of the box by Renovate's default `docker` versioning, so
consumers pinning a tag get correct update PRs with no extra configuration. The
exact commit and timestamp are recorded in `manifest.json`.

## How it works

| Stage | Trigger | Outcome |
| --- | --- | --- |
| **Sync** | Nightly / manual | Reconciles `plugins.yaml` against the CRS registry, resolves each plugin to a commit SHA, opens a reviewed PR. Never publishes. |
| **Build** | Push to `main` | Downloads each pinned plugin, stages its files, generates `manifest.json`, and computes a build-input digest. Fails closed on any missing or empty plugin. |
| **Publish** | Push to `main` | Gates on the digest (publish / no-op / repair), allocates the next CalVer tag, pushes to GHCR, signs, attests, renders docs, and creates a GitHub Release. |

`plugins.yaml` is the single source of truth on disk. `manifest.json` is generated
at build time, embedded in the image, and is the canonical record from which the
plugin table below and the release notes are derived.

## Local development

This project uses [mise](https://mise.jdx.dev) for tooling and tasks:

```bash
mise install        # install pinned tools (yq, jq, shellcheck, cosign, crane)
mise run sync       # reconcile registry and resolve versions into plugins.yaml
mise run build      # stage plugins and build manifest.json
mise run docs       # render the plugin table and release notes
mise run artifact   # pack the release tarball and checksums
mise run all        # sync -> build -> docs -> artifact (stamps a dev version)
mise run lint       # shellcheck all scripts
mise run clean      # remove generated build artifacts
```

## Bundled plugins

<!-- BEGIN BUNDLED PLUGINS -->
<!-- END BUNDLED PLUGINS -->
