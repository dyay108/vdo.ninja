#!/bin/sh
# Validate VDO_PORT before 20-envsubst-on-templates.sh renders it into the
# nginx config. Runs as part of the base image's entrypoint chain.
#
# Without this, a bad value produces one of two confusing failures: a
# privileged port fails with a bare "bind() ... Permission denied" (this image
# runs as UID 101, which cannot bind below 1024), and a non-numeric value
# produces an nginx syntax error pointing at a generated file the user never
# wrote.

set -e

ME=$(basename "$0")
port="${VDO_PORT:-8080}"

case "$port" in
    ''|*[!0-9]*)
        echo "$ME: ERROR: VDO_PORT must be a number, got '$port'" >&2
        exit 1
        ;;
esac

if [ "$port" -lt 1025 ] || [ "$port" -gt 65535 ]; then
    echo "$ME: ERROR: VDO_PORT must be between 1025 and 65535, got '$port'" >&2
    echo "$ME: nginx runs as an unprivileged user here and cannot bind a" >&2
    echo "$ME: privileged port. Map port 80/443 on the host side instead," >&2
    echo "$ME: e.g. ports: [\"80:8080\"]." >&2
    exit 1
fi

# The envsubst step silently does nothing if this is not writable, which would
# leave nginx with no server block at all. Fail loudly instead.
if [ ! -w /etc/nginx/conf.d ]; then
    echo "$ME: ERROR: /etc/nginx/conf.d is not writable, so the config" >&2
    echo "$ME: template cannot be rendered. If you run with a read-only" >&2
    echo "$ME: root filesystem, add a tmpfs for /etc/nginx/conf.d." >&2
    exit 1
fi

if [ -z "${NGINX_ENTRYPOINT_QUIET_LOGS:-}" ]; then
    echo "$ME: VDO.Ninja will listen on port $port"
fi
