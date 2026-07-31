# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# VDO.Ninja - self-hosted static client
#
# The app is pure static HTML/JS/CSS with no build step, so this image is just
# the repo plus an nginx tuned for it. Signalling still uses the public
# handshake server at wss://vdo.ninja by default; see DOCKER.md to change it.
# ---------------------------------------------------------------------------

# --- Stage 1: precompress text assets --------------------------------------
# lib.js is 2.2 MB and rawdoc.md is 1.3 MB. Shipping .gz siblings lets nginx
# serve them via gzip_static with zero per-request CPU, which matters on the
# low-power boxes these usually run on.
#
# Pinned to BUILDPLATFORM: gzip output is byte-identical regardless of
# architecture, so this stage runs natively even when building for arm64. The
# runtime stage below has no RUN steps, which means a multi-arch build needs no
# QEMU emulation at all.
FROM --platform=$BUILDPLATFORM alpine:3.24 AS assets

RUN apk add --no-cache gzip findutils

WORKDIR /site
COPY . .

# Build-only files that slipped through .dockerignore (docker/ has to stay in
# the context so the config COPY below can reach it).
RUN rm -rf docker

RUN set -eux; \
    find . -type f \( \
           -name '*.html' -o -name '*.js'   -o -name '*.mjs' \
        -o -name '*.css'  -o -name '*.json' -o -name '*.svg' \
        -o -name '*.md'   -o -name '*.xml'  -o -name '*.txt' \
    \) -size +1k -print0 \
    | xargs -0 -r -P 4 -n 16 gzip -9 -k -f

# --- Stage 2: runtime ------------------------------------------------------
# nginx-unprivileged runs as uid 101 on port 8080 out of the box, so no
# capability juggling is needed to drop root.
FROM nginxinc/nginx-unprivileged:1.31-alpine AS runtime

LABEL org.opencontainers.image.title="VDO.Ninja" \
      org.opencontainers.image.description="Self-hosted VDO.Ninja web client" \
      org.opencontainers.image.source="https://github.com/dyay108/vdo.ninja" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later"

# Listening port, overridable at run time with -e VDO_PORT=9090. The config is
# shipped as a template and rendered by the base image's entrypoint on start.
# Must stay above 1024: this image runs as UID 101 and cannot bind a
# privileged port. 10-check-vdo-port.sh enforces that with a clear message.
ENV VDO_PORT=8080

# Restrict envsubst to our own variables so nginx's $uri, $request_uri, $1 and
# friends survive templating untouched.
ENV NGINX_ENVSUBST_FILTER=^VDO_

COPY docker/default.conf.template /etc/nginx/templates/default.conf.template

# --chmod is required, not cosmetic: the base entrypoint silently skips any
# script in /docker-entrypoint.d that lacks the exec bit. Using COPY --chmod
# rather than a RUN keeps this stage free of executable steps, so multi-arch
# builds need no QEMU emulation.
COPY --chmod=0755 docker/docker-entrypoint.d/10-check-vdo-port.sh \
     /docker-entrypoint.d/10-check-vdo-port.sh

COPY --from=assets /site /usr/share/nginx/html

# Build-time metadata only; reflects the default. Docker cannot re-evaluate
# this when VDO_PORT is overridden at run time, so publish with an explicit
# -p mapping rather than relying on EXPOSE.
EXPOSE 8080

# Shell form on purpose: ${VDO_PORT} has to expand at run time, not build time.
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD wget -qO /dev/null "http://127.0.0.1:${VDO_PORT}/healthz" || exit 1
