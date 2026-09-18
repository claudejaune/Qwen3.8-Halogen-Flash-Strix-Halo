#!/usr/bin/env bash
# run.sh — Start Qwen3.8-Flash-Next via halogen-flash-server using config.env.
# Runs in the foreground. Use stop.sh from another terminal to stop it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"
CONTAINER_NAME="halogen-flash"
DOWNLOAD_REPO="peonist-ai/halogen-qwen3.8-flash-next"
MODELS_DIR="$HOME/models/halogen"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: config.env not found. Run ./setup.sh first." >&2
    exit 1
fi

# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
require_not_root
load_config "$CONFIG_FILE"

# Validate required vars
for var in BIND_HOST PORT HALOGEN_IMAGE; do
    if [[ -z "${!var:-}" ]]; then
        echo "Error: $var not set in config.env. Re-run ./setup.sh." >&2
        exit 1
    fi
done

# Numeric vars — a hand-edited config must not pass garbage to the engine
for var in PORT HALOGEN_KV_SLOTS HALOGEN_KV_POOL_POSITIONS HALOGEN_CTX; do
    val="${!var:-}"
    if [[ -n "$val" && ! "$val" =~ ^[0-9]+$ ]]; then
        echo "Error: $var must be a number, got '$val' in config.env." >&2
        exit 1
    fi
done

if [[ "${BIND_HOST}" != "127.0.0.1" && "${BIND_HOST}" != "0.0.0.0" ]]; then
    echo "Error: BIND_HOST must be 127.0.0.1 or 0.0.0.0, got '${BIND_HOST}' in config.env." >&2
    exit 1
fi

if [[ ! -d "$MODELS_DIR" ]]; then
    echo "Error: weights directory not found: $MODELS_DIR" >&2
    echo "Re-run ./setup.sh to create it." >&2
    exit 1
fi

# The engine port has no authentication and is never published; the API port
# is fixed at 8731 inside the container and mapped to $PORT on the host.
if [[ "$BIND_HOST" == "0.0.0.0" ]]; then
    PUBLISH=(-p "$PORT:8731")
else
    PUBLISH=(-p "127.0.0.1:$PORT:8731")
fi

# The container name must be free: podman refuses a --rm run whose name is
# already taken, stopped or running.
if podman_container_exists "$CONTAINER_NAME"; then
    echo "Error: a container named '$CONTAINER_NAME' already exists (it may be stopped)." >&2
    echo "Run ./stop.sh first, then ./run.sh again." >&2
    exit 1
fi

# Build the image args
CMD=(podman run --rm --name "$CONTAINER_NAME")
CMD+=(--device /dev/kfd --device /dev/dri)
CMD+=(--group-add keep-groups)
CMD+=(--ipc=host)
CMD+=(--ulimit memlock=-1:-1)
CMD+=("${PUBLISH[@]}")
CMD+=(-e "HALOGEN_DOWNLOAD=$DOWNLOAD_REPO")
CMD+=(-v "$MODELS_DIR:/models")

# Engine configuration from config.env (unset keys use the image's defaults)
CMD+=(-e "HALOGEN_KV_SLOTS=${HALOGEN_KV_SLOTS:-4}")
if [[ -n "${HALOGEN_KV_POOL_POSITIONS:-}" ]]; then
    CMD+=(-e "HALOGEN_KV_POOL_POSITIONS=$HALOGEN_KV_POOL_POSITIONS")
fi
if [[ -n "${HALOGEN_CTX:-}" ]]; then
    CMD+=(-e "HALOGEN_CTX=$HALOGEN_CTX")
fi
if [[ -n "${HALOGEN_MODEL_ID:-}" ]]; then
    CMD+=(-e "HALOGEN_MODEL_ID=$HALOGEN_MODEL_ID")
fi

# Vision: off unless the tower flag is set
if [[ "${HALOGEN_VISION_TOWER:-}" == "1" ]]; then
    CMD+=(-e "HALOGEN_VISION_TOWER=1")
fi

# Free-form extras: space-separated KEY=value pairs, one -e each.
# shellcheck disable=SC2086
if [[ -n "${HALOGEN_EXTRA_ENV:-}" ]]; then
    for pair in $HALOGEN_EXTRA_ENV; do
        if [[ "$pair" != *=* ]]; then
            echo "Error: HALOGEN_EXTRA_ENV entry '$pair' is not KEY=value." >&2
            exit 1
        fi
        CMD+=(-e "$pair")
    done
fi

CMD+=("$HALOGEN_IMAGE")

# Pull the image if it is not here yet
if ! podman image exists "$HALOGEN_IMAGE" 2>/dev/null; then
    info "Image not found. Pulling $HALOGEN_IMAGE ..."
    podman pull "$HALOGEN_IMAGE"
fi

# Host shown in the connection info: the LAN IP when bound to the network,
# the loopback address when bound to localhost.
DISPLAY_HOST="$BIND_HOST"
if [[ "$BIND_HOST" != "127.0.0.1" ]]; then
    DISPLAY_HOST="$(hostname -I 2>/dev/null | awk '{print $1}')"
    if [[ -z "$DISPLAY_HOST" ]]; then
        DISPLAY_HOST="$BIND_HOST"
    fi
fi

# Print connection info
echo ""
echo "============================================"
echo " Qwen3.8-Flash-Next Server (halogen-flash)"
echo "============================================"
echo ""
echo "  Image:     $HALOGEN_IMAGE"
echo "  Weights:   $MODELS_DIR"
echo "  Slots:     ${HALOGEN_KV_SLOTS:-4 (default)}"
echo "  Vision:    $([[ "${HALOGEN_VISION_TOWER:-}" == "1" ]] && echo on || echo off)"
echo ""
echo "  Endpoint:  http://$DISPLAY_HOST:$PORT/v1/chat/completions"
echo "  Health:    http://$DISPLAY_HOST:$PORT/health"
if [[ "$BIND_HOST" == "0.0.0.0" ]]; then
echo ""
echo "  NOTE: UNAUTHENTICATED. Anyone on the network can reach this server."
fi
echo ""
echo "  Stop:      ./stop.sh (from another terminal)"
echo ""
echo "  First start downloads the weights (~118 GiB, resumes if interrupted)"
echo "  and loads them for minutes. Later starts skip both."
echo ""
echo "============================================"
echo ""

# Run in foreground
exec "${CMD[@]}"
