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
DEFAULT_MODELS_DIR="$HOME/models/halogen-models"
CHECKPOINT="qwen38-flash-next-w4b.hgn"
VISION_FILE="qwen38-flash-next-vision.hgn"
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
CK_OVERLAY="$CK_PATH.overlay.hgn"
VISION_PATH="$MODELS_DIR/$VISION_FILE"

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
        return 0
    fi
    warn "CHECKSUM MISMATCH: expected $expected"
    warn "                          got $actual"
    return 1
}

# rewrite_config_key <KEY> <value> — back up config.env, replace KEY= (or
# append it), keep everything else byte-for-byte.
rewrite_config_key() {
    local key="$1" value="$2" backup_path tmp seen=0
    mkdir -p "$SCRIPT_DIR/backups"
    local ts
    ts="$(date +%Y-%m-%d-%H-%M)"
    backup_path="$SCRIPT_DIR/backups/config.env-$ts"
    if [[ -e "$backup_path" ]]; then
        backup_path="$SCRIPT_DIR/backups/config.env-$ts-$(date +%S)"
    fi
    cp -a "$CONFIG_FILE" "$backup_path"
    tmp="$(mktemp "$SCRIPT_DIR/.config.env.tmp.XXXXXX")"
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            "$key="*) seen=1; printf '%s=%s\n' "$key" "$value" ;;
            *)        printf '%s\n' "$line" ;;
        esac
    done < "$CONFIG_FILE" > "$tmp"
    (( seen )) || printf '%s=%s\n' "$key" "$value" >> "$tmp"
    mv -f "$tmp" "$CONFIG_FILE"
    printf '%s\n' "$backup_path"
}

# offer_update_flow — the upstream checkpoint changed and the local file does
# not match it. Stop the server, delete exactly this version's files, and let
# ./run.sh re-download. Nothing else on disk is touched.
offer_update_flow() {
    local new_sha="$1"
    echo "  To update: the server is stopped, ONLY these files are deleted —"
    echo "    $CK_PATH"
    echo "    $CK_OVERLAY"
    echo "    $VISION_PATH (if present)"
    echo "  — and ./run.sh re-downloads (~118 GiB, resumable). Other files"
    echo "  (tokenizer, any other models) are left alone."
    if ! ask_yes_no "  Stop the server and delete them now?" n; then
        echo "  Kept. Nothing deleted. Re-run ./refresh.sh when ready, or delete by hand."
        return 0
    fi
    if podman_container_running "$CONTAINER_NAME"; then
        bash "$SCRIPT_DIR/stop.sh" || err "Could not stop the server. Nothing was deleted."
    fi
    local f
    for f in "$CK_PATH" "$CK_OVERLAY" "$VISION_PATH"; do
        if [[ -f "$f" ]]; then
            info "Deleting $(basename "$f") ($(du -sh "$f" | cut -f1))"
            rm -f "$f"
        fi
    done
    ok "Old weights removed."
    local backup_path
    backup_path="$(rewrite_config_key CHECKPOINT_SHA256 "$new_sha")"
    ok "config.env pinned to the new sha256 (backup: $backup_path)"
    if [[ -n "${VISION_SHA256:-}" ]]; then
        if V="$(hf_remote_sha256 "$VISION_FILE")"; then
            rewrite_config_key VISION_SHA256 "$V" >/dev/null
        else
            warn "Could not fetch the new vision sidecar's sha256."
        fi
    fi
    echo ""
    echo "  Now run ./run.sh — it downloads the new version (~118 GiB)."
}

info "Checking the HF repo for the checkpoint's current sha256..."
REMOTE_CK=""
if ! REMOTE_CK="$(hf_remote_sha256 "$CHECKPOINT")"; then
    REMOTE_CK=""
fi

if [[ -n "$REMOTE_CK" ]]; then
    ok "Repo reachable (checkpoint sha256 ${REMOTE_CK:0:12}...)."

    if [[ -n "${CHECKPOINT_SHA256:-}" && "$CHECKPOINT_SHA256" != "$REMOTE_CK" ]]; then
        # config pins an older hash. Either the disk was never updated, or
        # it already holds the new version and only config is stale.
        warn "The repo's checkpoint differs from the one pinned in config.env."
        echo "    pinned:  $CHECKPOINT_SHA256"
        echo "    current: $REMOTE_CK"
        if file_usable "$CK_PATH" && ask_yes_no "  Hash your local file first to see which state it is in (a few minutes)?" n; then
            if LOCAL="$(hash_checkpoint)"; then
                if [[ "$LOCAL" == "$REMOTE_CK" ]]; then
                    ok "Local file IS the new version — only config.env was stale."
                    rewrite_config_key CHECKPOINT_SHA256 "$REMOTE_CK" >/dev/null
                    ok "config.env updated to the current sha256."
                else
                    warn "Local file matches NEITHER the pinned nor the current hash."
                    offer_update_flow "$REMOTE_CK"
                fi
            else
                warn "sha256sum failed — skipping verification."
            fi
        else
            offer_update_flow "$REMOTE_CK"
        fi
    elif file_usable "$CK_PATH"; then
        ok "Checkpoint present and config.env matches the repo."
        CK_GIB=$(( $(stat -c '%s' "$CK_PATH") / 1073741824 ))
        if (( CK_GIB < 110 )); then
            warn "The checkpoint is only ${CK_GIB} GiB (expect ~115 GiB) —"
            warn "almost certainly incomplete. Re-download it."
        elif ask_yes_no "  Verify the local checkpoint against the repo (a few minutes)?" n; then
            if verify_checkpoint "$REMOTE_CK"; then
                if [[ -z "${CHECKPOINT_SHA256:-}" ]]; then
                    rewrite_config_key CHECKPOINT_SHA256 "$REMOTE_CK" >/dev/null
                    ok "config.env now pins the verified sha256."
                fi
            else
                warn "Re-download: delete $CK_PATH and run ./run.sh (resumes from HF)."
            fi
        fi
    else
        warn "Checkpoint not found: $CK_PATH"
        echo "  First ./run.sh downloads it (~118 GiB, resumes if interrupted)."
    fi
else
    # Offline (or no python3/curl): fall back to what we know locally.
    warn "HF repo unreachable — using the pinned/recorded hash only."
    if file_usable "$CK_PATH"; then
        ok "Checkpoint present: $CK_PATH ($(du -sh "$CK_PATH" | cut -f1))"
        CK_GIB=$(( $(stat -c '%s' "$CK_PATH") / 1073741824 ))
        if (( CK_GIB < 110 )); then
            warn "The checkpoint is only ${CK_GIB} GiB (expect ~115 GiB) —"
            warn "almost certainly incomplete. Re-download it."
        fi
        if [[ -n "${CHECKPOINT_SHA256:-}" ]]; then
            echo "  config.env has a CHECKPOINT_SHA256 — verify against it?"
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
            echo "  No checksum recorded. One lets later refreshes detect corruption."
            if ask_yes_no "  Record this checkpoint's sha256 now (a few minutes)?" n; then
                if H="$(hash_checkpoint)"; then
                    printf '%s  %s\n' "$H" "$CHECKPOINT" > "$MODELS_DIR/$HASH_FILE"
                    ok "Hash recorded: $MODELS_DIR/$HASH_FILE"
                fi
            fi
        fi
    else
        warn "Checkpoint not found: $CK_PATH"
        echo "  First ./run.sh downloads it (~118 GiB, resumes if interrupted)."
    fi
fi
echo ""

# ── Vision sidecar ───────────────────────────────────────────────────────────
# The engine never fetches it; without it (and HALOGEN_VISION_TOWER=1) the
# server refuses to start. Keep it present, current, and verified.
if [[ "${HALOGEN_VISION_TOWER:-}" == "1" ]]; then
    info "=== Vision sidecar ==="
    REMOTE_VISION=""
    if ! REMOTE_VISION="$(hf_remote_sha256 "$VISION_FILE")"; then
        REMOTE_VISION=""
    fi
    if [[ ! -f "$VISION_PATH" ]]; then
        if [[ -n "$REMOTE_VISION" ]]; then
            if ask_yes_no "  Vision sidecar is missing. Download it now (0.84 GiB, verified)?" y; then
                hf_fetch_file "$VISION_FILE" "$REMOTE_VISION" "$MODELS_DIR" || true
            else
                warn "Skipped. The server will refuse to start with images enabled until it exists."
            fi
        else
            warn "Vision sidecar missing and the repo unreachable. The server will"
            warn "refuse to start with images enabled. Fetch it later:"
            echo "  hf download $HF_REPO_ID $VISION_FILE --local-dir $MODELS_DIR"
        fi
    elif [[ -n "$REMOTE_VISION" ]]; then
        LOCAL_VISION="$(sha256sum "$VISION_PATH" 2>/dev/null | cut -d' ' -f1)"
        if [[ "$LOCAL_VISION" != "$REMOTE_VISION" ]]; then
            warn "Vision sidecar differs from the repo's current sha256."
            if ask_yes_no "  Re-download it (0.84 GiB)?" y; then
                hf_fetch_file "$VISION_FILE" "$REMOTE_VISION" "$MODELS_DIR" || true
            fi
        elif [[ -n "${VISION_SHA256:-}" && "$VISION_SHA256" != "$REMOTE_VISION" ]]; then
            rewrite_config_key VISION_SHA256 "$REMOTE_VISION" >/dev/null
            ok "Vision sidecar current; config.env's VISION_SHA256 refreshed."
        else
            ok "Vision sidecar present and current."
        fi
    else
        ok "Vision sidecar present (repo unreachable, hash unchecked)."
    fi
    echo ""
fi

# ── Running server ───────────────────────────────────────────────────────────
if have podman && podman_container_running "$CONTAINER_NAME"; then
    echo "  The server is running. To use the new image:"
    echo "    ./stop.sh && ./run.sh"
fi
echo ""
echo "============================================"
echo " Refresh finished."
echo "============================================"
