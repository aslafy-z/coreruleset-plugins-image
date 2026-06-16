# crs-plugins

A single OCI image bundling [OWASP CRS](https://coreruleset.org) plugins for
mounting into Envoy (or any ModSecurity/Coraza runtime) as a Kubernetes image
volume. Plugins are delivered as files; the WAF filter activates only the ones
it references by `Include` directive.

## What this is

- A `FROM scratch` image whose root contains `<plugin-dir>/<files>` plus
  `manifest.json`.
- Published to GHCR as `ghcr.io/<owner>/crs-plugins:YYYY.MM.N` and `:latest`.
- A matching GitHub Release attaches `manifest.json` and a `tar.gz` of the same
  payload for registry-free consumption.

The plugin set is curated in `plugins.yaml` and kept in sync with the official
[CRS plugin registry](https://github.com/coreruleset/plugin-registry) through
reviewed pull requests. Nothing reaches `:latest` without human review.

## Mounting into Envoy Gateway

The image is mounted as a Kubernetes image volume; the WAF filter references
plugin files by filesystem path. Image volumes require the `ImageVolume`
feature gate (alpha in v1.31–1.32, beta off-by-default in v1.33–1.34, on by
default in v1.35, stable in v1.36) and a runtime that supports them
(containerd 2.0+, CRI-O 1.31+).

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
        reference: ghcr.io/<owner>/crs-plugins:latest   # or :2026.06.0
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

Plugin ordering is load-bearing: `-config` and `-before` files must load before
`@owasp_crs/*.conf`, and `-after` files after it. A single `*/*.conf` glob would
break this, so the includes are split around the core rules.

## Versioning

Tags use CalVer `YYYY.MM.N`. `N` is an unbounded per-month counter starting at
`0`. Renovate's default `docker` versioning parses and orders these with no
extra config.

## Bundled plugins

<!-- BEGIN BUNDLED PLUGINS -->
<!-- END BUNDLED PLUGINS -->
