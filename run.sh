#!/usr/bin/env bash
# run.sh — Start Qwen3.8-Flash-Next via halogen-flash-server using config.env.
# Runs in the foreground. Use stop.sh from another terminal to stop it.
#
# Usage: ./run.sh [--log]
#   --log   also save everything the engine prints to logs/run-<timestamp>.log
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"
CONTAINER_NAME="halogen-flash"
DOWNLOAD_REPO="peonist-ai/halogen-qwen3.8-flash-next"
DEFAULT_MODELS_DIR="$HOME/models/halogen-models"

# ── Flags ────────────────────────────────────────────────────────────────────
# --log duplicates everything the engine prints into logs/. Off by default:
# engine output is large and a normal start needs no record of it.
LOG=false
for arg in "$@"; do
    case "$arg" in
        --log) LOG=true ;;
        *)
            echo "Error: unknown option: $arg (usage: ./run.sh [--log])" >&2
            exit 1
            ;;
    esac
done

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: config.env not found. Run ./setup.sh first." >&2
    exit 1
fi

# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
require_not_root
load_config "$CONFIG_FILE"
MODELS_DIR="${MODELS_DIR:-$DEFAULT_MODELS_DIR}"

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

# Value ranges — same rules setup.sh enforces, for a hand-edited config
if (( 10#$PORT < 1024 || 10#$PORT > 65535 )); then
    echo "Error: PORT must be between 1024 and 65535 (root ports 1-1023 are never used), got '$PORT' in config.env." >&2
    exit 1
fi
if [[ -n "${HALOGEN_KV_SLOTS:-}" ]] && (( 10#$HALOGEN_KV_SLOTS < 1 || 10#$HALOGEN_KV_SLOTS > 64 )); then
    echo "Error: HALOGEN_KV_SLOTS must be between 1 and 64, got '$HALOGEN_KV_SLOTS' in config.env." >&2
    exit 1
fi
if [[ -n "${HALOGEN_KV_SLOTS:-}" ]] && (( 10#$HALOGEN_KV_SLOTS > 8 )); then
    warn "More than 8 slots: past 8 total throughput stops growing — each stream gets slower."
fi
if [[ -n "${HALOGEN_KV_POOL_POSITIONS:-}" ]] && (( 10#$HALOGEN_KV_POOL_POSITIONS < 1 )); then
    echo "Error: HALOGEN_KV_POOL_POSITIONS must be at least 1, got '$HALOGEN_KV_POOL_POSITIONS' in config.env." >&2
    exit 1
fi

if [[ ! -d "$MODELS_DIR" ]]; then
    echo "Error: weights directory not found: $MODELS_DIR" >&2
    echo "Re-run ./setup.sh to create it." >&2
    exit 1
fi

# ── Weights pre-flight ───────────────────────────────────────────────────────
# The container's HALOGEN_DOWNLOAD only fires when the checkpoint is ABSENT —
# a truncated or corrupt file on disk is never re-fetched by the engine, and a
# missing vision sidecar is never fetched at all. This check covers both:
# missing files (offer the download the container would have done anyway) and
# present-but-wrong files (which only this check repairs). It never blocks:
# declining leaves the container to do exactly what it did before.
VISION_FLAG=0
if [[ "${HALOGEN_VISION_TOWER:-}" == "1" ]]; then
    VISION_FLAG=1
fi
WEIGHTS_RC=0
WEIGHTS_STATUS="$(weights_check "$MODELS_DIR" "$VISION_FLAG" 2>/dev/null)" || WEIGHTS_RC=$?
if (( WEIGHTS_RC != 0 )); then
    warn "The weights in $MODELS_DIR are not all in place:"
    while read -r st file detail; do
        case "$st" in
            missing)    echo "    missing:    $file" ;;
            incomplete) echo "    incomplete: $file ($detail)" ;;
        esac
    done <<<"$WEIGHTS_STATUS"
    echo ""
    echo "  A download resumes from what is already on disk. The engine's own"
    echo "  HALOGEN_DOWNLOAD fetches a MISSING checkpoint on start, but it"
    echo "  never repairs a file that is present and the wrong size."
    echo ""
    if ask_yes_no "  Download / repair the weights now (~122 GiB)?" y; then
        if have podman && ! podman image exists "$HALOGEN_IMAGE" 2>/dev/null; then
            info "Pulling the image first (its own 'hf' does the download)..."
            podman pull "$HALOGEN_IMAGE" || warn "Image pull failed."
        fi
        if hf_download_models "$MODELS_DIR" "$HALOGEN_IMAGE" "$VISION_FLAG"; then
            WEIGHTS_RC=0
            WEIGHTS_STATUS="$(weights_check "$MODELS_DIR" "$VISION_FLAG" 2>/dev/null)" || WEIGHTS_RC=$?
            if (( WEIGHTS_RC == 0 )); then
                ok "Weights ready."
                if [[ -n "${CHECKPOINT_SHA256:-}" ]] && ask_yes_no "  Compute the checkpoint's sha256 to verify it fully (a few minutes)?" n; then
                    info "Computing sha256 (a few minutes on NVMe)..."
                    LOCAL_SHA="$(file_sha256 "$MODELS_DIR/$HF_CHECKPOINT_FILE")"
                    if [[ "$LOCAL_SHA" == "$CHECKPOINT_SHA256" ]]; then
                        ok "Checkpoint integrity verified."
                    else
                        warn "CHECKSUM MISMATCH: expected $CHECKPOINT_SHA256"
                        warn "                  got ${LOCAL_SHA:-<hash failed>}"
                        warn "Delete $MODELS_DIR/$HF_CHECKPOINT_FILE and re-run ./run.sh."
                    fi
                fi
            else
                warn "The download finished but the check still reports a problem."
                warn "The engine may fail; re-run ./run.sh to resume, or ./refresh.sh."
            fi
        else
            warn "The download did not finish — continuing; the engine may fail."
        fi
    else
        warn "Continuing without downloading. The engine fetches a missing"
        warn "checkpoint itself (HALOGEN_DOWNLOAD); a corrupt one will fail."
    fi
    echo ""
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

# Reasoning effort for requests that send none (requests that name their
# own effort win). Unset = the engine's default, the chat template's xhigh.
if [[ -n "${HALOGEN_REASONING_EFFORT:-}" ]]; then
    CMD+=(-e "HALOGEN_REASONING_EFFORT=$HALOGEN_REASONING_EFFORT")
fi

# Optional HF token: the engine's own HALOGEN_DOWNLOAD uses it for higher
# rate limits. Read from the environment or config.env; never written by
# setup.
if [[ -n "${HF_TOKEN:-}" ]]; then
    CMD+=(-e "HF_TOKEN=$HF_TOKEN")
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
if (( WEIGHTS_RC == 0 )); then
echo "  The weights are in place; loading them takes minutes on a cold start."
echo "  The download is skipped whenever the files are complete."
else
echo "  The weights are not complete: this start downloads them (~122 GiB,"
echo "  resumes if interrupted) and then loads them for minutes."
fi
echo ""
echo "============================================"
echo ""

# Run in foreground. With --log, everything the engine prints is also kept in
# a file — the whole story for anyone debugging a bad start.
if [[ "$LOG" == "true" ]]; then
    mkdir -p "$SCRIPT_DIR/logs"
    LOG_FILE="$SCRIPT_DIR/logs/run-$(date +%Y-%m-%d-%H-%M-%S).log"
    info "Also writing output to: $LOG_FILE"
    status=0
    "${CMD[@]}" 2>&1 | tee "$LOG_FILE" || status=$?
    echo ""
    info "Log saved: $LOG_FILE"
    exit "$status"
fi

exec "${CMD[@]}"
