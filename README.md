# coreruleset-plugins

[![build-publish](https://github.com/aslafy-z/coreruleset-plugins-image/actions/workflows/build-publish.yml/badge.svg)](https://github.com/aslafy-z/coreruleset-plugins-image/actions/workflows/build-publish.yml)
[![sync-plugins](https://github.com/aslafy-z/coreruleset-plugins-image/actions/workflows/sync-plugins.yml/badge.svg)](https://github.com/aslafy-z/coreruleset-plugins-image/actions/workflows/sync-plugins.yml)
[![GHCR](https://img.shields.io/badge/ghcr.io-aslafy--z%2Fcoreruleset--plugins-blue?logo=docker)](https://github.com/aslafy-z/coreruleset-plugins-image/pkgs/container/coreruleset-plugins)
[![Release](https://img.shields.io/github/v/release/aslafy-z/coreruleset-plugins-image?sort=semver)](https://github.com/aslafy-z/coreruleset-plugins-image/releases/latest)
[![CRS](https://img.shields.io/badge/CRS-4.x-005571)](https://coreruleset.org)
[![Signed](https://img.shields.io/badge/cosign-signed-brightgreen?logo=sigstore)](https://www.sigstore.dev)

A single, minimal OCI image that bundles [OWASP Core Rule Set](https://coreruleset.org)
plugins as plain files, ready to deliver to a Web Application Firewall. The image
carries plugin files only; the WAF runtime activates the ones it references by
`Include` directive. Delivery is bundled, activation is on demand.

The same payload reaches the WAF through whichever path fits your platform:

- **Kubernetes image volume**: mount the image directly, no copy step.
- **Custom WAF image**: bake the files into your Envoy/Coraza image at build time
  with a multi-stage `COPY --from`.

A `manifest.json` and a `tar.gz` of the same payload are also attached to every
GitHub Release for registry-free consumption.

It pairs naturally with the
[`coraza-envoy-go-filter`](https://github.com/united-security-providers/coraza-envoy-go-filter)
("Coraza Web Application Firewall implemented as Envoy Go Filter"), which embeds
CRS in the compiled filter and loads additional plugin rules from the filesystem.
Point the filter's directives at wherever the files land, and the plugins are
available without rebuilding the filter.

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
- **Flexible delivery.** Mount as a Kubernetes image volume, or bake into your own
  WAF image with `COPY --from`. A `manifest.json` and `tar.gz` are also attached to
  each GitHub Release for registry-free consumption.

## Getting the files onto the WAF

Pick the delivery method that fits your platform. All three land the same
`<plugin>/<files>` tree at a path the filter can `Include`.

### Option A: Kubernetes image volume

Mounts the image directly. Requires the `ImageVolume` feature (see
[Requirements](#requirements)).

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

### Option B: Custom WAF image

Bake the plugins into your own Envoy/Coraza image at build time. Because this image
is `FROM scratch`, `COPY --from` pulls its entire root with no shell or copy tooling
involved, and the plugins ship inside your image with nothing to mount at runtime.

```dockerfile
# Pin a specific version for reproducible builds.
FROM ghcr.io/aslafy-z/coreruleset-plugins:2026.06.0 AS plugins

FROM your-registry/envoy-coraza:latest
COPY --from=plugins / /etc/crs/plugins/
```

Pinning to a tag (rather than `:latest`) keeps the build reproducible; Renovate's
default `docker` versioning will open update PRs as new versions publish.

## Wiring the plugins into the filter

Once the files are at the mount path, reference them from the filter's directives.
This example targets the Coraza Envoy filter.

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
          # Activate only the plugins you need, by name, BEFORE core rules:
          - "Include /etc/crs/plugins/wordpress/*-config.conf"
          - "Include /etc/crs/plugins/wordpress/*-before.conf"
          - "Include /etc/crs/plugins/nextcloud/*-config.conf"
          - "Include /etc/crs/plugins/nextcloud/*-before.conf"
          - "Include @owasp_crs/*.conf"
          # The same plugins' after-rules, AFTER core rules:
          - "Include /etc/crs/plugins/wordpress/*-after.conf"
          - "Include /etc/crs/plugins/nextcloud/*-after.conf"
    default_directive: "waf1"
```

> **Activation is per plugin.** The volume delivers every bundled plugin, but the
> filter loads only the directories you reference, so include the specific plugins
> you want rather than a `*/*` glob over all of them.
>
> **Ordering is load-bearing.** A plugin's `-config` and `-before` files must load
> *before* `@owasp_crs/*.conf`, and its `-after` files *after* it, so the includes
> are split around the core rules. The `@` prefix marks resources embedded in the
> filter; plain filesystem paths reference the mounted volume.

### Requirements

Kubernetes image volumes require the `ImageVolume` feature and a supporting
runtime:

| Kubernetes | `ImageVolume` state | Action |
| --- | --- | --- |
| v1.31 to v1.32 | Alpha (off) | Enable the feature gate |
| v1.33 to v1.34 | Beta (off by default) | Enable the feature gate |
| v1.35 | Beta (on by default) | None |
| v1.36+ | Stable | None |

Container runtime: containerd 2.0+ or CRI-O 1.31+.

## Image layout

```
/                              # image root / tarball root
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
`-rule-exclusions` suffixes stripped (overridable per entry). Placing the root at
`/etc/crs/plugins` (by mount or extraction) exposes
`/etc/crs/plugins/<plugin>/<files>` with no doubled path segment.

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
| Plugin | Version | Origin | Commit |
| --- | --- | --- | --- |
| [EsadCetiner/iredadmin-rule-exclusions-plugin](https://github.com/EsadCetiner/iredadmin-rule-exclusions-plugin) | 1.0.1 | registry | `d8a982f` |
| [EsadCetiner/plausible-rule-exclusions-plugin](https://github.com/EsadCetiner/plausible-rule-exclusions-plugin) | 1.0.0 | registry | `67d5d64` |
| [EsadCetiner/roundcube-rule-exclusions-plugin](https://github.com/EsadCetiner/roundcube-rule-exclusions-plugin) | 1.0.4 | registry | `ed73635` |
| [EsadCetiner/sogo-rule-exclusions-plugin](https://github.com/EsadCetiner/sogo-rule-exclusions-plugin) | 1.0.4 | registry | `4d0f073` |
| [coreruleset/antivirus-plugin](https://github.com/coreruleset/antivirus-plugin) | e6b53a7 | registry | `e6b53a7` |
| [coreruleset/auto-decoding-plugin](https://github.com/coreruleset/auto-decoding-plugin) | 5d096ad | registry | `5d096ad` |
| [coreruleset/body-decompress-plugin](https://github.com/coreruleset/body-decompress-plugin) | 80e7d9b | registry | `80e7d9b` |
| [coreruleset/cpanel-rule-exclusions-plugin](https://github.com/coreruleset/cpanel-rule-exclusions-plugin) | 1.0.0 | registry | `2fd1cab` |
| [coreruleset/database-logging-plugin](https://github.com/coreruleset/database-logging-plugin) | 1f6ea17 | registry | `1f6ea17` |
| [coreruleset/dokuwiki-rule-exclusions-plugin](https://github.com/coreruleset/dokuwiki-rule-exclusions-plugin) | 1.0.0 | registry | `0099676` |
| [coreruleset/dos-protection-plugin-modsecurity](https://github.com/coreruleset/dos-protection-plugin-modsecurity) | 98962f1 | registry | `98962f1` |
| [coreruleset/drupal-rule-exclusions-plugin](https://github.com/coreruleset/drupal-rule-exclusions-plugin) | 1.0.0 | registry | `6771319` |
| [coreruleset/fake-bot-plugin](https://github.com/coreruleset/fake-bot-plugin) | 1.1.0 | registry | `e7c675e` |
| [coreruleset/false-positive-report-plugin](https://github.com/coreruleset/false-positive-report-plugin) | b33cfa3 | registry | `b33cfa3` |
| [coreruleset/google-oauth2-plugin](https://github.com/coreruleset/google-oauth2-plugin) | 1.0.0 | registry | `4434424` |
| [coreruleset/incubator-plugin](https://github.com/coreruleset/incubator-plugin) | b87b1d2 | registry | `b87b1d2` |
| [coreruleset/nextcloud-rule-exclusions-plugin](https://github.com/coreruleset/nextcloud-rule-exclusions-plugin) | 1.6.0 | registry | `83ab69f` |
| [coreruleset/phpbb-rule-exclusions-plugin](https://github.com/coreruleset/phpbb-rule-exclusions-plugin) | 1.0.0 | registry | `5f1e034` |
| [coreruleset/phpmyadmin-rule-exclusions-plugin](https://github.com/coreruleset/phpmyadmin-rule-exclusions-plugin) | 1.1.0 | registry | `6629e88` |
| [coreruleset/referer-hardening-plugin](https://github.com/coreruleset/referer-hardening-plugin) | f3220b2 | registry | `f3220b2` |
| [coreruleset/template-plugin](https://github.com/coreruleset/template-plugin) | 79a4ec5 | registry | `79a4ec5` |
| [coreruleset/traffic-observation-plugin](https://github.com/coreruleset/traffic-observation-plugin) | 2cde930 | registry | `2cde930` |
| [coreruleset/wordpress-rule-exclusions-plugin](https://github.com/coreruleset/wordpress-rule-exclusions-plugin) | 1.2.0 | registry | `161bb90` |
| [coreruleset/xenforo-rule-exclusions-plugin](https://github.com/coreruleset/xenforo-rule-exclusions-plugin) | 1.0.0 | registry | `193288a` |
| [eilandert/wordpress-hardening-plugin](https://github.com/eilandert/wordpress-hardening-plugin) | 1.1.2 | registry | `2e2c2a5` |
| [netnea/netnea-crs-upgrading-plugin](https://github.com/netnea/netnea-crs-upgrading-plugin) | 665bb12 | registry | `665bb12` |
<!-- END BUNDLED PLUGINS -->
