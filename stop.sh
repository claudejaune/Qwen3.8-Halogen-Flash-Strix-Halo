#!/usr/bin/env bash
# stop.sh — Stop the running halogen-flash container.
#
# Plain podman stop with a grace period: the engine finishes writing the last
# turn's KV rows to the disk tier on SIGTERM (usually well under a second;
# give it a minute rather than lose that turn). A container either exists or
# it does not — there is no host-wide process fallback, and no other
# llama-server on this machine can be confused with this one.
set -euo pipefail

CONTAINER_NAME="halogen-flash"
GRACE=60

have() { command -v "$1" &>/dev/null; }

if ! have podman; then
    echo "Error: podman not found." >&2
    exit 1
fi

if ! podman container exists "$CONTAINER_NAME" 2>/dev/null; then
    echo "No halogen container found (name: $CONTAINER_NAME)."
    exit 0
fi

if ! podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
    echo "Container '$CONTAINER_NAME' exists but is not running."
    exit 0
fi

echo "Stopping '$CONTAINER_NAME' (grace period ${GRACE}s for the disk cache flush) ..."
podman stop -t "$GRACE" "$CONTAINER_NAME"
echo "Stopped."
