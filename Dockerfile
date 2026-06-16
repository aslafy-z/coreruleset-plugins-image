# syntax=docker/dockerfile:1
FROM scratch

# staging/ holds <dir>/<files> trees plus manifest.json, produced by
# scripts/build-plugins.sh. Copying staging/ to / yields <dir>/<files> and
# /manifest.json at the image root. Mounting at /etc/crs/plugins exposes
# /etc/crs/plugins/<dir>/<files> with no doubled "plugins/" segment.
COPY staging/ /
