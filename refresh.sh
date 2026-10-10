#!/usr/bin/env bash
# refresh.sh — After git pull: refresh the container image, check the weights,
# verify the checkpoint's integrity, and optionally update the pinned image
# tag in config.env.
#
# Usage: ./refresh.sh [--image <tag|reference>] [--verify]
#   --image   set the engine version in config.env without prompting
#   --verify  hash the local checkpoint against the repo (a few minutes)
#
# There is no build tooling in this repo, so this script is
# small by design: pull the image, verify the weights, and rewrite
# HALOGEN_IMAGE if you want a different tag.
#
# A volume still running the deprecated w4b quant gets one prompt to move to
# v2: stop the server, delete the w4b files, download v2 in their place.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"
CONTAINER_NAME="halogen-flash"
DEFAULT_MODELS_DIR="$HOME/models/halogen-models"
VISION_FILE="qwen38-flash-next-vision.hgn"
HASH_FILE="checkpoint.sha256"

# The engine release that made v2 the default checkpoint. An older pinned
# image cannot run v2, so the switch is not offered below it.
V2_MIN_IMAGE="0.15.0"

# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_not_root

# ── Flags ────────────────────────────────────────────────────────────────────
IMAGE_OVERRIDE=""
VERIFY=false
while (( $# )); do
    case "$1" in
        --image)
            if [[ -z "${2:-}" ]]; then
                err "--image needs a value: a tag such as 0.17.4, or a full image reference."
            fi
            IMAGE_OVERRIDE="$2"
            shift 2
            ;;
        --verify)
            VERIFY=true
            shift
            ;;
        *)
            echo "Error: unknown option: $1 (usage: ./refresh.sh [--image <tag>] [--verify])" >&2
            exit 1
            ;;
    esac
done

if [[ ! -f "$CONFIG_FILE" ]]; then
    err "config.env not found. Run ./setup.sh first, then ./refresh.sh after git pull."
fi

load_config "$CONFIG_FILE"
MODELS_DIR="${MODELS_DIR:-$DEFAULT_MODELS_DIR}"
VISION_FLAG=0
if [[ "${HALOGEN_VISION_TOWER:-}" == "1" ]]; then
    VISION_FLAG=1
fi

echo ""
echo "============================================"
echo " halogen-flash-server — refresh"
echo "============================================"
echo ""
echo "  Run this after:  git pull"
echo ""

if [[ -z "${HALOGEN_IMAGE:-}" ]]; then
    err "HALOGEN_IMAGE not set in config.env. Re-run ./setup.sh."
fi

# ── Stop the running server ──────────────────────────────────────────────────
# A running container keeps whatever image, checkpoint and key it started
# with, so refresh stops it first. Everything below then lands on a stopped
# server, and nothing has to work out what is still live.
if have podman && podman_container_running "$CONTAINER_NAME"; then
    if ! ask_yes_no "  A Halogen Server instance is currently running. Stop it? (Required for updating)" y; then
        echo ""
        echo "  Refresh needs the server stopped. Run ./stop.sh, then ./refresh.sh again."
        exit 1
    fi
    bash "$SCRIPT_DIR/stop.sh" || err "Could not stop the server. Nothing was changed."
fi
echo ""

# The checkpoint this deployment runs, as a base name. Unset
# HALOGEN_CHECKPOINT means v2. Everything below that touches the weights
# follows this value, and the quant switch updates it in place.
CK_BASE="$(selected_checkpoint)"
CK_PATH="$MODELS_DIR/$CK_BASE"

# ── Shared helpers ───────────────────────────────────────────────────────────

# quant_files_on_disk <base-name> — the files that quant owns which are
# actually present, as host paths, one per line.
quant_files_on_disk() {
    local ck="$1" f
    while read -r f; do
        if [[ -f "$MODELS_DIR/$f" ]]; then
            printf '%s\n' "$MODELS_DIR/$f"
        fi
    done < <(quant_files "$ck")
}

# legacy_files_on_disk — the w4b-family files present, including the speed
# overlay. The overlay belongs to w4b and is read by nothing else, so a
# volume leaving w4b has no further use for it.
legacy_files_on_disk() {
    local f
    for f in "$HF_LEGACY_CHECKPOINT_FILE" "$HF_LEGACY_OVERLAY_FILE" "$HF_SPEED_OVERLAY_FILE"; do
        if [[ -f "$MODELS_DIR/$f" ]]; then
            printf '%s\n' "$MODELS_DIR/$f"
        fi
    done
}

# stop_and_delete <file>... — stop the server if it runs, then delete the
# named files. Prompts first; returns 1 (deleting nothing) if the answer is
# no. A failed stop exits rather than deleting under a live server.
stop_and_delete() {
    local f
    if podman_container_running "$CONTAINER_NAME"; then
        info "Stopping the server..."
        bash "$SCRIPT_DIR/stop.sh" || err "Could not stop the server. Nothing was deleted."
    fi
    for f in "$@"; do
        if [[ -f "$f" ]]; then
            info "Deleting $(basename "$f") ($(du -sh "$f" | cut -f1))"
            rm -f "$f"
        fi
    done
    return 0
}

# ── Image ────────────────────────────────────────────────────────────────────
# Nothing is asked when config.env already pins the recommended version.
# Otherwise one yes/no prompt either takes it or stays put. Any other
# version is set with --image, which expands a bare tag such as 0.17.4 or
# :latest to a full reference.
info "=== Image ==="

if [[ -n "$IMAGE_OVERRIDE" ]]; then
    NEW_IMAGE="$(normalize_image "$IMAGE_OVERRIDE")"
    if [[ "$NEW_IMAGE" == "$HALOGEN_IMAGE" ]]; then
        ok "config.env already pins $HALOGEN_IMAGE."
    else
        backup_path="$(rewrite_config_key HALOGEN_IMAGE "$NEW_IMAGE")"
        HALOGEN_IMAGE="$NEW_IMAGE"
        ok "config.env updated to $HALOGEN_IMAGE."
        ok "Backup saved as: $backup_path"
    fi
elif [[ "$HALOGEN_IMAGE" == "$HALOGEN_RECOMMENDED_IMAGE" ]]; then
    ok "config.env is on the recommended version: $(version_label "$HALOGEN_IMAGE")."
else
    echo "  config.env pins:      $HALOGEN_IMAGE"
    echo "  This repo recommends: $HALOGEN_RECOMMENDED_IMAGE"
    echo ""
    if ask_yes_no_strict "  Upgrade to $(version_label "$HALOGEN_RECOMMENDED_IMAGE")?" y; then
        NEW_IMAGE="$HALOGEN_RECOMMENDED_IMAGE"
        backup_path="$(rewrite_config_key HALOGEN_IMAGE "$NEW_IMAGE")"
        HALOGEN_IMAGE="$NEW_IMAGE"
        ok "config.env updated to $HALOGEN_IMAGE."
        ok "Backup saved as: $backup_path"
    else
        ok "Staying on $HALOGEN_IMAGE."
    fi
fi

# A pinned version tag is immutable, so a present image is current. `latest`
# can move, so it is always offered.
echo ""
if ! have podman; then
    warn "podman not installed — skipping image refresh."
elif podman image exists "$HALOGEN_IMAGE" 2>/dev/null && [[ "$HALOGEN_IMAGE" != *:latest ]]; then
    ok "Image present: $(version_label "$HALOGEN_IMAGE")"
elif ask_yes_no "  Pull the $(version_label "$HALOGEN_IMAGE") image now?" y; then
    if podman pull "$HALOGEN_IMAGE"; then
        ok "Image refreshed."
    else
        warn "Pull failed. The old image (if any) is still available."
    fi
fi
echo ""

# ── Quant: move a w4b volume to v2 ───────────────────────────────────────────
# The engine changed its default checkpoint at 0.15.0 and deprecated w4b at
# 0.16.2. A volume that still holds w4b keeps serving it — the engine
# auto-detects and downloads nothing — but it is outside upstream release
# testing. This is the one prompt that moves it.
#
# The config is rewritten BEFORE anything is deleted. If the transfer is
# interrupted, the config already points at v2, so every repair path in
# run.sh and refresh.sh leads forward to completing the download instead of
# back to a half-deleted w4b.
offer_quant_switch() {
    local new_sha="$1"
    local -a doomed=()
    local f total_gib

    while read -r f; do
        if [[ -n "$f" ]]; then
            doomed+=("$f")
        fi
    done < <(legacy_files_on_disk)

    total_gib="$(du -c "${doomed[@]}" 2>/dev/null | awk 'END { printf "%.0f", $1/1048576 }')"
    local size_note=""
    if [[ -n "$total_gib" && "$total_gib" != "0" ]]; then
        size_note=" (~${total_gib} GiB)"
    fi

    echo ""
    warn "This volume runs the deprecated w4b quant."
    echo "  w4b was deprecated upstream at engine 0.16.2 and has been outside"
    echo "  their release testing since 0.16.1. v2 is the current checkpoint:"
    echo "  one file plus its lookup table, about 110 GiB together."
    echo ""
    echo "  Switching to v2:"
    echo "    stops the server"
    echo "    deletes the w4b files${size_note}:"
    for f in "${doomed[@]}"; do
        echo "      $f"
    done
    echo "    downloads v2 and its lookup table (~110 GiB, resumable)"
    echo ""
    echo "  The vision sidecar and the tokenizer are kept — both quants use"
    echo "  them. Nothing else on disk is touched."
    echo ""
    if ! ask_yes_no "  Switch this volume to v2 now? (RECOMMENDED; deletes older quant and downloads new version ~110 GiB)" n; then
        echo "  Stayed on w4b. Nothing was deleted or downloaded."
        echo "  Run this again when ready, or switch by hand:"
        echo "    hf download $HF_REPO_ID $HF_CHECKPOINT_FILE $HF_NGRAM_FILE --local-dir $MODELS_DIR"
        return 0
    fi

    # Config first — see the note above. The shell variable is updated with
    # the file: load_config read the old value at start, and the weights
    # section below would otherwise report a mismatch against the w4b hash
    # we just replaced and offer to delete the v2 files it just arrived.
    local backup_path
    backup_path="$(rewrite_config_key HALOGEN_CHECKPOINT "/models/$HF_CHECKPOINT_FILE" "" HALOGEN_IMAGE)"
    HALOGEN_CHECKPOINT="/models/$HF_CHECKPOINT_FILE"
    ok "config.env now selects v2 (backup: $backup_path)"
    rewrite_config_key CHECKPOINT_SHA256 "$new_sha" >/dev/null
    CHECKPOINT_SHA256="$new_sha"
    ok "config.env pinned to v2's sha256 (${new_sha:0:12}...)."

    stop_and_delete "${doomed[@]}"
    ok "Old quant removed."

    CK_BASE="$HF_CHECKPOINT_FILE"
    CK_PATH="$MODELS_DIR/$CK_BASE"

    echo ""
    info "Downloading v2 and its lookup table (~110 GiB, resumable)..."
    if hf_download_models "$MODELS_DIR" "$HALOGEN_IMAGE" "$VISION_FLAG" "$CK_BASE"; then
        local rc=0
        weights_check "$MODELS_DIR" "$VISION_FLAG" remote "$CK_BASE" >/dev/null 2>&1 || rc=$?
        if (( rc == 0 )); then
            ok "v2 is in place and verified at the expected size."
            echo ""
            echo "  Start it with ./run.sh"
        else
            warn "The download finished but the size check still reports a problem."
            warn "Re-run ./refresh.sh or ./run.sh — the transfer resumes."
        fi
    else
        warn "The download did not finish."
        warn "The w4b files are already gone: re-run ./refresh.sh or ./run.sh"
        warn "to resume the v2 transfer. The config already points at v2."
    fi
    echo ""
}

# offer_v2_repoint <new-sha-or-empty>
# The volume holds both quants and config.env still selects w4b. v2 is
# already on disk, so this is a config-only change: no stop, no delete, no
# download. Keeping both weights around is a legitimate choice, and the
# script must never delete a file the user still has a use for just because
# a newer one arrived.
offer_v2_repoint() {
    local new_sha="$1"
    local kept
    kept="$(legacy_files_on_disk | tr '\n' ' ')"

    echo ""
    warn "This volume holds both quants, and config.env still selects w4b."
    echo "  v2 is already downloaded, so nothing needs to be fetched."
    echo "  Keeping w4b is fine — it simply sits unused while the server runs v2."
    echo ""
    echo "  Left on disk: $kept"
    echo ""
    if ask_yes_no "  Point the config at v2 and keep w4b on disk?" y; then
        local backup_path
        backup_path="$(rewrite_config_key HALOGEN_CHECKPOINT "/models/$HF_CHECKPOINT_FILE" "" HALOGEN_IMAGE)"
        HALOGEN_CHECKPOINT="/models/$HF_CHECKPOINT_FILE"
        ok "config.env now selects v2 (backup: $backup_path)"
        if [[ -n "$new_sha" ]]; then
            rewrite_config_key CHECKPOINT_SHA256 "$new_sha" >/dev/null
            CHECKPOINT_SHA256="$new_sha"
            ok "config.env pinned to v2's sha256 (${new_sha:0:12}...)."
        else
            # w4b's hash must not stay pinned against a v2 file: the weights
            # check would report a mismatch on a perfectly good file. Clearing
            # it means "unverified", and the Weights section re-pins it as
            # soon as the repo is reachable.
            rewrite_config_key CHECKPOINT_SHA256 "" >/dev/null
            CHECKPOINT_SHA256=""
            warn "Repo unreachable, so the sha256 pin is cleared rather than"
            warn "left pointing at w4b. ./refresh.sh re-pins it when online."
        fi
        CK_BASE="$HF_CHECKPOINT_FILE"
        CK_PATH="$MODELS_DIR/$CK_BASE"
        echo ""
        echo "  Nothing was deleted and nothing was downloaded."
        echo "  Start it with ./run.sh"
    else
        echo "  Staying on w4b. ./refresh.sh asks again next time."
    fi
    echo ""
}

info "=== Quant ==="
if ! image_tag_ge "$HALOGEN_IMAGE" "$V2_MIN_IMAGE"; then
    ok "Pinned engine $HALOGEN_IMAGE predates the v2 checkpoint; staying on w4b."
elif [[ ! -f "$MODELS_DIR/$HF_LEGACY_CHECKPOINT_FILE" ]]; then
    ok "No legacy w4b checkpoint in $MODELS_DIR."
elif v2_installed "$MODELS_DIR"; then
    # Both quants are on this volume. Nothing here deletes or downloads.
    if [[ "$CK_BASE" == "$HF_CHECKPOINT_FILE" ]]; then
        ok "Running v2. The w4b files beside it are left alone."
    else
        # Best effort: the repoint works offline, it just cannot pin the hash.
        BOTH_REMOTE_SHA=""
        BOTH_REMOTE_SHA="$(hf_remote_sha256 "$HF_CHECKPOINT_FILE" 2>/dev/null)" || BOTH_REMOTE_SHA=""
        offer_v2_repoint "$BOTH_REMOTE_SHA"
    fi
else
    # Need v2's live hash before touching anything: the switch pins it, and
    # starting the deletion without it would leave config unverifiable.
    V2_REMOTE_SHA=""
    V2_SHA_RC=0
    V2_REMOTE_SHA="$(hf_remote_sha256 "$HF_CHECKPOINT_FILE" 2>/dev/null)" || V2_SHA_RC=$?
    if [[ -z "$V2_REMOTE_SHA" ]]; then
        if (( V2_SHA_RC == 2 )); then
            warn "Reading the repo's file list needs python3 — cannot switch to v2."
        else
            warn "The weights repo is unreachable — cannot switch to v2."
        fi
        warn "Nothing was deleted. Re-run ./refresh.sh when you are online."
    else
        offer_quant_switch "$V2_REMOTE_SHA"
    fi
fi
echo ""

# ── API key ──────────────────────────────────────────────────────────────────
# Only for a deployment that never got one. An existing key is left exactly
# as it is: rotating it would 401 every client and agent already configured
# with the old value, which is never something a refresh should do on its
# own.
info "=== Set API key ==="
if api_key_present "$CONFIG_FILE"; then
    ok "API key already configured. Not rotating it."
    echo "  To rotate: ./setup.sh, or edit HALOGEN_API_KEY in config.env by hand."
else
    echo "  Currently no API key is set. Any program can access Halogen without a key or password"
    if ask_yes_no "  Generate an API key? (RECOMMENDED)" y; then
        NEW_KEY="$(generate_api_key)"
        backup_path="$(rewrite_config_key HALOGEN_API_KEY "$NEW_KEY" "" HALOGEN_IMAGE)"
        HALOGEN_API_KEY="$NEW_KEY"
        ok "API key added: $NEW_KEY"
        ok "config.env updated (backup: $backup_path)"
        echo ""
        echo "  Clients send it as   Authorization: Bearer $NEW_KEY"
        echo "                   or  x-api-key: $NEW_KEY"
    else
        warn "No API key set. Anyone who can reach the port can use this server."
    fi
fi
echo ""

# ── Weights ──────────────────────────────────────────────────────────────────
info "=== Weights ==="
CK_OVERLAY="$CK_PATH.overlay.hgn"
VISION_PATH="$MODELS_DIR/$VISION_FILE"
CHECKPOINT="$CK_BASE"

# sha256 of a ~62 GiB file takes a few minutes on NVMe; every prompt asks
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

# offer_update_flow — the upstream checkpoint changed and the local file does
# not match it. Stop the server, delete exactly this version's files, and
# download the current ones. The vision sidecar is left to its own section,
# which re-fetches it only if it too went stale.
offer_update_flow() {
    local new_sha="$1"
    local -a doomed=()
    local f

    while read -r f; do
        if [[ -n "$f" ]]; then
            doomed+=("$f")
        fi
    done < <(quant_files_on_disk "$CK_BASE")

    echo "  To update: the server is stopped, ONLY these files are deleted —"
    for f in "${doomed[@]}"; do
        echo "    $f"
    done
    echo "  — and the current ones are re-downloaded (~110 GiB, resumable)."
    echo "  Other files (tokenizer, vision sidecar, any other models) are"
    echo "  left alone."
    if ! ask_yes_no "  Stop the server and delete them now?" n; then
        echo "  Kept. Nothing deleted. Re-run ./refresh.sh when ready, or delete by hand."
        return 0
    fi

    stop_and_delete "${doomed[@]}"
    ok "Old weights removed."
    local backup_path
    backup_path="$(rewrite_config_key CHECKPOINT_SHA256 "$new_sha")"
    ok "config.env pinned to the new sha256 (backup: $backup_path)"
    if [[ -n "${VISION_SHA256:-}" ]]; then
        if V="$(hf_remote_sha256 "$VISION_FILE")"; then
            rewrite_config_key VISION_SHA256 "$V" >/dev/null
            VISION_SHA256="$V"
        else
            warn "Could not fetch the new vision sidecar's sha256."
        fi
    fi
    echo ""
    echo "  Downloading the current weights (~110 GiB, resumable)..."
    if hf_download_models "$MODELS_DIR" "$HALOGEN_IMAGE" "$VISION_FLAG" "$CK_BASE"; then
        ok "Download finished."
    else
        warn "The download did not finish — re-run ./refresh.sh or ./run.sh to resume."
    fi
}

# weights_status — every file this quant needs that is not usable, one per
# line as "<name>|<detail>". Empty means the checkpoint is complete: each
# file exists and clears its size floor. A file under its floor is what a
# truncated or interrupted download looks like.
weights_status() {
    local f path size floor got
    while read -r f; do
        [[ -n "$f" ]] || continue
        path="$MODELS_DIR/$f"
        if [[ ! -f "$path" ]]; then
            printf '%s|missing\n' "$f"
            continue
        fi
        size="$(stat -c '%s' "$path" 2>/dev/null || echo 0)"
        floor="$(quant_floor_gib "$f")"
        if (( floor > 0 && size < floor * 1073741824 )); then
            got="$(awk -v b="$size" 'BEGIN { printf "%.1f", b / 1073741824 }')"
            printf '%s|only %s GiB, expect more than %s GiB\n' "$f" "$got" "$floor"
        fi
    done < <(quant_files "$CK_BASE")
}

# list_weights_problem <name|detail lines> — the not-ready listing, shared
# by the download offer and the offline path so both read the same way.
list_weights_problem() {
    local name detail
    echo ""
    echo "  The checkpoint is not ready:"
    while IFS='|' read -r name detail; do
        [[ -n "$name" ]] || continue
        printf '    %-28s %s\n' "$name" "$detail"
    done <<< "$1"
}

# offer_weights_download <name|detail lines> — say what is wrong and offer
# to fetch it. Taking the offer clears any file that is present but wrong,
# downloads the set, and re-checks it. Declining leaves the deployment
# unable to run, which is said plainly. READY carries the outcome.
offer_weights_download() {
    local details="$1" name detail
    list_weights_problem "$details"
    echo ""
    if ! ask_yes_no "  Download now? (~110 GiB, resumes if interrupted)" y; then
        READY=0
        echo ""
        echo "  Halogen cannot run without the checkpoint."
        echo "  Run ./refresh.sh again and take the download."
        return 0
    fi

    # A file that is present but wrong is removed first, so the download
    # never resumes onto a bad file.
    while IFS='|' read -r name detail; do
        [[ -n "$name" && -f "$MODELS_DIR/$name" ]] && rm -f "$MODELS_DIR/$name"
    done <<< "$details"

    echo ""
    if hf_download_models "$MODELS_DIR" "$HALOGEN_IMAGE" "$VISION_FLAG" "$CK_BASE"; then
        local still_bad
        still_bad="$(weights_status)"
        if [[ -z "$still_bad" ]]; then
            ok "Checkpoint downloaded."
            READY=1
        else
            READY=0
            warn "Some files are still not right:"
            while IFS='|' read -r name detail; do
                [[ -n "$name" ]] || continue
                printf '    %-28s %s\n' "$name" "$detail"
            done <<< "$still_bad"
            echo "  Run ./refresh.sh again to resume."
        fi
    else
        READY=0
        warn "The download did not finish. Run ./refresh.sh again to resume."
    fi
}

info "Checking the HF repo for the checkpoint's current sha256..."
REMOTE_CK=""
CK_PROBE_RC=0
REMOTE_CK="$(hf_remote_sha256 "$CHECKPOINT")" || CK_PROBE_RC=$?

# What is wrong with the weight files, if anything. One check feeds every
# branch below, so the listing and the READY flag never disagree.
WSTATUS="$(weights_status)"
READY=1

if [[ -n "$REMOTE_CK" ]]; then
    ok "Repo reachable (checkpoint sha256 ${REMOTE_CK:0:12}...)."

    if [[ -n "${CHECKPOINT_SHA256:-}" && "$CHECKPOINT_SHA256" != "$REMOTE_CK" ]]; then
        # config pins an older hash. Either the disk was never updated, or
        # it already holds the new version and only config is stale.
        warn "The repo's checkpoint differs from the one pinned in config.env."
        echo "    pinned:  $CHECKPOINT_SHA256"
        echo "    current: $REMOTE_CK"
        if [[ "$VERIFY" == "true" ]] && file_usable "$CK_PATH"; then
            if LOCAL="$(hash_checkpoint)"; then
                if [[ "$LOCAL" == "$REMOTE_CK" ]]; then
                    ok "Local file IS the new version — only config.env was stale."
                    rewrite_config_key CHECKPOINT_SHA256 "$REMOTE_CK" >/dev/null
                    CHECKPOINT_SHA256="$REMOTE_CK"
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
    elif [[ -n "$WSTATUS" ]]; then
        offer_weights_download "$WSTATUS"
    else
        ok "Checkpoint present and config.env matches the repo."
        if [[ "$VERIFY" == "true" ]]; then
            if verify_checkpoint "$REMOTE_CK"; then
                if [[ -z "${CHECKPOINT_SHA256:-}" ]]; then
                    rewrite_config_key CHECKPOINT_SHA256 "$REMOTE_CK" >/dev/null
                    CHECKPOINT_SHA256="$REMOTE_CK"
                    ok "config.env now pins the verified sha256."
                fi
            else
                offer_weights_download "$CK_BASE|checksum mismatch"
            fi
        fi
    fi
else
    # Fall back to what we know locally.
    if (( CK_PROBE_RC == 2 )); then
        warn "Reading the repo's file list needs python3 — using the pinned/recorded hash only."
    else
        warn "HF repo unreachable — using the pinned/recorded hash only."
    fi
    if [[ -n "$WSTATUS" ]]; then
        READY=0
        list_weights_problem "$WSTATUS"
        echo ""
        echo "  Halogen cannot run without the checkpoint, and the repo is"
        echo "  unreachable. Reconnect and run ./refresh.sh again."
    else
        ok "Checkpoint present: $CK_PATH ($(du -sh "$CK_PATH" | cut -f1))"
        if [[ "$VERIFY" == "true" ]]; then
            if [[ -n "${CHECKPOINT_SHA256:-}" ]]; then
                verify_checkpoint "$CHECKPOINT_SHA256" || true
            elif [[ -f "$MODELS_DIR/$HASH_FILE" ]]; then
                RECORDED="$(cut -d' ' -f1 "$MODELS_DIR/$HASH_FILE")"
                verify_checkpoint "$RECORDED" || true
            else
                echo "  No checksum recorded. One lets later refreshes detect corruption."
                if H="$(hash_checkpoint)"; then
                    printf '%s  %s\n' "$H" "$CHECKPOINT" > "$MODELS_DIR/$HASH_FILE"
                    ok "Hash recorded: $MODELS_DIR/$HASH_FILE"
                fi
            fi
        fi
    fi
fi
echo ""

# ── Vision sidecar ───────────────────────────────────────────────────────────
# The engine never fetches it; without it (and HALOGEN_VISION_TOWER=1) the
# server refuses to start. Keep it present, current, and verified.
if [[ "${HALOGEN_VISION_TOWER:-}" == "1" ]]; then
    info "=== Vision sidecar ==="
    REMOTE_VISION=""
    VISION_PROBE_RC=0
    REMOTE_VISION="$(hf_remote_sha256 "$VISION_FILE")" || VISION_PROBE_RC=$?
    if (( VISION_PROBE_RC == 2 )); then
        VISION_PROBE_WHY="python3 is not installed"
    else
        VISION_PROBE_WHY="the repo is unreachable"
    fi
    if [[ ! -f "$VISION_PATH" ]]; then
        if [[ -n "$REMOTE_VISION" ]]; then
            if ask_yes_no "  Vision sidecar is missing. Download it now (0.84 GiB, verified)?" y; then
                hf_fetch_file "$VISION_FILE" "$REMOTE_VISION" "$MODELS_DIR" || true
            else
                warn "Skipped. The server will refuse to start with images enabled until it exists."
            fi
        else
            warn "Vision sidecar missing and $VISION_PROBE_WHY. The server will"
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
        elif [[ "${VISION_SHA256:-}" != "$REMOTE_VISION" ]]; then
            rewrite_config_key VISION_SHA256 "$REMOTE_VISION" >/dev/null
            VISION_SHA256="$REMOTE_VISION"
            ok "Vision sidecar current; config.env's VISION_SHA256 refreshed."
        else
            ok "Vision sidecar present and current."
        fi
    else
        ok "Vision sidecar present ($VISION_PROBE_WHY, hash unchecked)."
    fi
    echo ""
fi

echo ""
echo "============================================"
echo " Refresh finished."
echo "============================================"
echo "  Image:      $HALOGEN_IMAGE"
echo "  Checkpoint: $CK_BASE"
if [[ "${READY:-1}" == "1" ]]; then
    echo "  Ready:      yes — ./run.sh"
else
    echo "  Ready:      no — the checkpoint is not complete."
    echo "              Run ./refresh.sh again and take the download."
fi
echo "============================================"
