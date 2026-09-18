#!/usr/bin/env bash
# refresh.sh — After git pull: refresh the container image, check the weights,
# and optionally update the pinned image tag in config.env.
#
# There are no toolboxes and no quant catalog in this repo, so this script is
# small by design: pull the image, verify the weights are where first run
# expects them, and rewrite HALOGEN_IMAGE if you want a different tag.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"
CONTAINER_NAME="halogen-flash"
MODELS_DIR="$HOME/models/halogen"
CHECKPOINT="qwen38-flash-next-w4b.hgn"

# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_not_root

if [[ ! -f "$CONFIG_FILE" ]]; then
    err "config.env not found. Run ./setup.sh first, then ./refresh.sh after git pull."
fi

load_config "$CONFIG_FILE"

echo ""
echo "============================================"
echo " halogen-flash-server — refresh"
echo "============================================"
echo ""
echo "  Run this after:  git pull"
echo "  You can answer No to any step."
echo ""

if [[ -z "${HALOGEN_IMAGE:-}" ]]; then
    err "HALOGEN_IMAGE not set in config.env. Re-run ./setup.sh."
fi

# ── Image tag ────────────────────────────────────────────────────────────────
info "=== Image ==="
echo "  Current tag: $HALOGEN_IMAGE"
echo "  If this repo's docs now recommend a newer version, enter it here."
echo "  Press Enter to keep the current tag."
ask NEW_TAG "New image tag (empty = keep $HALOGEN_IMAGE)" ""
if [[ -n "$NEW_TAG" ]] && [[ "$NEW_TAG" != "$HALOGEN_IMAGE" ]]; then
    if ! ask_yes_no "  Point config.env at $NEW_TAG?" n; then
        echo "  Kept $HALOGEN_IMAGE."
    else
        backup_config() {
            mkdir -p "$SCRIPT_DIR/backups"
            local ts dest
            ts="$(date +%Y-%m-%d-%H-%M)"
            dest="$SCRIPT_DIR/backups/config.env-$ts"
            if [[ -e "$dest" ]]; then
                dest="$SCRIPT_DIR/backups/config.env-$ts-$(date +%S)"
            fi
            cp -a "$CONFIG_FILE" "$dest"
            printf '%s\n' "$dest"
        }
        backup_path="$(backup_config)"
        tmp="$(mktemp "$SCRIPT_DIR/.config.env.tmp.XXXXXX")"
        seen=0
        while IFS= read -r line || [[ -n "$line" ]]; do
            case "$line" in
                HALOGEN_IMAGE=*) seen=1; printf 'HALOGEN_IMAGE=%s\n' "$NEW_TAG" ;;
                *)               printf '%s\n' "$line" ;;
            esac
        done < "$CONFIG_FILE" > "$tmp"
        (( seen )) || printf 'HALOGEN_IMAGE=%s\n' "$NEW_TAG" >> "$tmp"
        mv -f "$tmp" "$CONFIG_FILE"
        HALOGEN_IMAGE="$NEW_TAG"
        ok "config.env updated to $HALOGEN_IMAGE."
        ok "Backup saved as: $backup_path"
    fi
fi

if have podman; then
    if ask_yes_no "  Pull $HALOGEN_IMAGE now?" n; then
        if podman pull "$HALOGEN_IMAGE"; then
            ok "Image refreshed."
        else
            warn "Pull failed. The old image (if any) is still available."
        fi
    else
        echo "  Skipped. run.sh pulls automatically if the image is missing."
    fi
else
    warn "podman not installed — skipping image refresh."
fi
echo ""

# ── Weights ──────────────────────────────────────────────────────────────────
info "=== Weights ==="
if file_usable "$MODELS_DIR/$CHECKPOINT"; then
    ok "Checkpoint present: $MODELS_DIR/$CHECKPOINT ($(du -sh "$MODELS_DIR/$CHECKPOINT" | cut -f1))"
else
    warn "Checkpoint not found: $MODELS_DIR/$CHECKPOINT"
    echo "  First ./run.sh downloads it (~118 GiB, resumes if interrupted)."
fi
echo ""

# ── Running server ───────────────────────────────────────────────────────────
if have podman && podman_container_running "$CONTAINER_NAME"; then
    echo "  The server is running. To use the new image:"
    echo "    ./stop.sh && ./run.sh"
fi
echo ""
echo "============================================"
echo " Refresh finished."
echo "============================================"
