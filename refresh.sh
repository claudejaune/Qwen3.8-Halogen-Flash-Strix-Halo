#!/usr/bin/env bash
# refresh.sh — After git pull: refresh the container image, check the weights,
# verify the checkpoint's integrity, and optionally update the pinned image
# tag in config.env.
#
# There are no toolboxes and no quant catalog in this repo, so this script is
# small by design: pull the image, verify the weights, and rewrite
# HALOGEN_IMAGE if you want a different tag.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"
CONTAINER_NAME="halogen-flash"
DEFAULT_MODELS_DIR="$HOME/halogen-models"
CHECKPOINT="qwen38-flash-next-w4b.hgn"
HASH_FILE="checkpoint.sha256"

# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_not_root

if [[ ! -f "$CONFIG_FILE" ]]; then
    err "config.env not found. Run ./setup.sh first, then ./refresh.sh after git pull."
fi

load_config "$CONFIG_FILE"
MODELS_DIR="${MODELS_DIR:-$DEFAULT_MODELS_DIR}"

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
CK_PATH="$MODELS_DIR/$CHECKPOINT"

# sha256 of a ~115 GiB file takes a few minutes on NVMe; every prompt asks
# before running one.
hash_checkpoint() {
    info "Computing sha256 of $CHECKPOINT (a few minutes on NVMe)..."
    local h
    h="$(sha256sum "$CK_PATH")" || return 1
    printf '%s\n' "${h%% *}"
}

verify_checkpoint() {
    local expected="$1" actual
    actual="$(hash_checkpoint)" || { warn "sha256sum failed — nothing verified."; return 1; }
    if [[ "$actual" == "$expected" ]]; then
        ok "Checkpoint integrity verified."
    else
        warn "CHECKSUM MISMATCH: expected $expected"
        warn "                          got $actual"
        warn "The checkpoint is damaged or not the file the hash was taken from."
        warn "Re-download: delete $CK_PATH and run ./run.sh (resumes from HF)."
        return 1
    fi
}

if file_usable "$CK_PATH"; then
    ok "Checkpoint present: $CK_PATH ($(du -sh "$CK_PATH" | cut -f1))"
    CK_GIB=$(( $(stat -c '%s' "$CK_PATH") / 1073741824 ))
    if (( CK_GIB < 110 )); then
        warn "The checkpoint is only ${CK_GIB} GiB (expect ~115 GiB) —"
        warn "almost certainly incomplete. Re-download it."
    fi
    if [[ -n "${CHECKPOINT_SHA256:-}" ]]; then
        echo "  CHECKPOINT_SHA256 is set in config.env — verify against it?"
        if ask_yes_no "  Compute sha256 now (a few minutes)?" n; then
            verify_checkpoint "$CHECKPOINT_SHA256" || true
        fi
    elif [[ -f "$MODELS_DIR/$HASH_FILE" ]]; then
        RECORDED="$(cut -d' ' -f1 "$MODELS_DIR/$HASH_FILE")"
        echo "  A recorded hash exists ($MODELS_DIR/$HASH_FILE) — verify against it?"
        if ask_yes_no "  Compute sha256 now (a few minutes)?" n; then
            verify_checkpoint "$RECORDED" || true
        fi
    else
        echo "  No checksum is recorded yet. Recording one now lets later"
        echo "  refreshes detect drift or corruption (upstream publishes none)."
        if ask_yes_no "  Record this checkpoint's sha256 now (a few minutes)?" n; then
            if H="$(hash_checkpoint)"; then
                printf '%s  %s\n' "$H" "$CHECKPOINT" > "$MODELS_DIR/$HASH_FILE"
                ok "Hash recorded: $MODELS_DIR/$HASH_FILE"
            else
                warn "sha256sum failed — nothing recorded."
            fi
        fi
    fi
else
    warn "Checkpoint not found: $CK_PATH"
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
