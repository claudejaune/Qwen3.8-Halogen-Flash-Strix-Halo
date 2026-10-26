#!/usr/bin/env bash
# lib/common.sh — shared helpers sourced by setup.sh, run.sh, stop.sh and
# refresh.sh.

# Keys that may appear in config.env. load_config refuses anything else, so a
# hand-edited config can never overwrite shell-critical variables (PATH, HOME,
# ...) or trip over readonly ones (UID, ...).
# shellcheck disable=SC2034  # consumed via nameref in _key_in_list
CONFIG_ALLOWED_KEYS=(
    BIND_HOST PORT
    MODELS_DIR
    CHECKPOINT_SHA256 VISION_SHA256
    HALOGEN_IMAGE HALOGEN_MODEL_ID HALOGEN_CHECKPOINT
    HALOGEN_API_KEY
    HALOGEN_CTX HALOGEN_KV_SLOTS HALOGEN_KV_POOL_POSITIONS
    HALOGEN_VISION_TOWER
    HALOGEN_REASONING_EFFORT
    HALOGEN_EXTRA_ENV
    HF_TOKEN
)

# The engine image. HALOGEN_RECOMMENDED_IMAGE is the single source of truth
# for the version this repo ships: setup.sh writes it into a new config.env,
# and refresh.sh offers it to an existing one.
HALOGEN_IMAGE_REPO="ghcr.io/peonist-ai/halogen-flash-server"
HALOGEN_RECOMMENDED_IMAGE="$HALOGEN_IMAGE_REPO:0.18.5"

# The Hugging Face repo the engine's checkpoint ships in. The tree API lists
# every file with its sha256 (the LFS "oid"), which is what
# hf_remote_sha256() reads.
HF_REPO_ID="peonist-ai/halogen-qwen3.8-flash-next"
HF_TREE_API="https://huggingface.co/api/models/$HF_REPO_ID/tree/main"
HF_RESOLVE_URL="https://huggingface.co/$HF_REPO_ID/resolve/main"

# The weights the server needs, by name. Sizes and sha256s come live from
# the tree API, so a file the creators replace under the same name is still
# checked against what is current.
#
# Two quant generations exist in the weights repo, and a deployment runs one
# of them. HALOGEN_CHECKPOINT names which; unset means v2, the engine's own
# default since 0.15.0.
#
# v2 is the current quant: one checkpoint file with no sidecar, plus its
# lookup table beside it (~110 GiB together).
HF_CHECKPOINT_FILE="qwen38-flash-next-v2.hgn"
HF_NGRAM_FILE="qwen38-flash-next-ngram.hgn"
# w4b is the 0.14 quant: the checkpoint plus its quality sidecar. Deprecated
# upstream since 0.16.2 and outside its release testing, though it still
# loads in current Halogen Flash releases. refresh.sh offers to replace it with v2 on a volume that
# still holds it.
HF_LEGACY_CHECKPOINT_FILE="qwen38-flash-next-w4b.hgn"
HF_LEGACY_OVERLAY_FILE="qwen38-flash-next-w4b.overlay.hgn"
# The vision sidecar is shared by both quants.
HF_VISION_FILE="qwen38-flash-next-vision.hgn"
# Never needed by this repo: the speed overlay is read only by
# HALOGEN_CK_OVERLAY, and the MTP head only a GGUF trunk reads — the .hgn
# checkpoints carry their own head.
HF_SPEED_OVERLAY_FILE="qwen38-flash-next-w4b.overlay-speed.hgn"
HF_MTP_FILE="qwen38-flash-next-mtp.hgn"

# The tokenizer is not LFS, so the tree API above does not list it. These
# names are used only by the last-resort curl fetch; the server cannot start
# without the first two.
HF_TOKENIZER_FILES=(
    tokenizer/chat_template.jinja
    tokenizer/generation_config.json
    tokenizer/merges.txt
    tokenizer/tokenizer.json
    tokenizer/tokenizer_config.json
    tokenizer/vocab.json
)
HF_TOKENIZER_REQUIRED=(
    tokenizer/tokenizer.json
    tokenizer/tokenizer_config.json
)

# Keys that may appear in run.sh's generated HALOGEN_* -e list. HALOGEN_EXTRA_ENV
# is passed through verbatim as extra `-e KEY=value` arguments, so the keys
# above plus this list describe everything config.env can reach.
config_key_allowed() {
    _key_in_list "$1" CONFIG_ALLOWED_KEYS
}

_key_in_list() {
    local needle="$1"
    local -n _keys="$2"
    local key
    for key in "${_keys[@]}"; do
        if [[ "$key" == "$needle" ]]; then
            return 0
        fi
    done
    return 1
}

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
err()   { echo -e "\033[1;31m[ERR ]\033[0m  $*" >&2; exit 1; }

have() { command -v "$1" &>/dev/null; }

# Regular user only — podman runs rootless, and the models directory and
# config.env must be owned by the user who runs the server.
require_not_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        err "Don't run this as root (sudo). Run as your normal user."
    fi
}

# True if path exists, is a regular file, and is not empty.
file_usable() {
    [[ -f "$1" && -s "$1" ]]
}

# All prompts tolerate EOF (Ctrl-D): read fails, the default is used instead
# of the script dying with a cryptic set -e failure.
ask() {
    local varname="$1" prompt="$2" default="$3" val
    read -rp "$prompt [$default]: " val || val=""
    val="${val:-$default}"
    printf -v "$varname" '%s' "$val"
}

ask_number() {
    local varname="$1" prompt="$2" default="$3" val
    while true; do
        read -rp "$prompt [$default]: " val || val=""
        val="${val:-$default}"
        if [[ "$val" =~ ^[0-9]+$ ]]; then break; fi
        echo "  Please enter a number." >&2
    done
    printf -v "$varname" '%s' "$val"
}

# ask_yes_no <prompt> [y|n] — returns 0 on yes
ask_yes_no() {
    local prompt="$1" default="${2:-y}" reply
    if [[ "$default" == "y" ]]; then
        read -rp "$prompt [Y/n]: " reply || reply=""
        [[ ! "$reply" =~ ^[Nn] ]]
    else
        read -rp "$prompt [y/N]: " reply || reply=""
        [[ "$reply" =~ ^[Yy] ]]
    fi
}

# ask_yes_no_strict <prompt> [y|n] — returns 0 on yes
# A yes/no prompt that accepts nothing else. ask_yes_no reads any answer
# that is not "n" as yes, which is fine for a casual prompt and wrong for
# the engine upgrade: a user who types a version number there means
# something this script will not do, and silently getting the recommended
# version reads as consent to their own input. Anything that is not a
# clear yes or no is rejected and asked again. End of input falls back to
# the default, so a piped or closed stdin cannot hang the script.
ask_yes_no_strict() {
    local prompt="$1" default="${2:-y}" reply
    while true; do
        if ! read -rp "$prompt [Y/n]: " reply; then
            if [[ "$default" == "n" ]]; then return 1; else return 0; fi
        fi
        case "${reply//[[:space:]]/}" in
            ""|[Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo])        return 1 ;;
            *) echo "  Please enter y/n" >&2 ;;
        esac
    done
}

# Load KEY=value pairs from a data file into the environment.
#
# The file is treated as pure DATA: values are never evaluated, quoted or
# expanded — a hand-edited file cannot inject commands. Full-line comments
# (#) and blank lines are ignored; CRLF line endings are tolerated. The value
# is everything after the FIRST '=', so values may contain '=' and spaces.
#
# Strict: returns non-zero (and the caller should abort) on malformed lines.
_load_kv_file() {
    local file="$1" line key value lineno=0
    if [[ ! -r "$file" ]]; then
        echo "Error: config file not found: $file" >&2
        return 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        if [[ -z "$line" || "$line" == \#* ]]; then
            continue
        fi
        if [[ "$line" != *=* ]]; then
            echo "Error: $file:$lineno — expected KEY=value, got: $line" >&2
            return 1
        fi
        key="${line%%=*}"
        value="${line#*=}"
        if [[ ! "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
            echo "Error: $file:$lineno — invalid variable name: $key" >&2
            return 1
        fi
        if ! config_key_allowed "$key"; then
            echo "Error: unknown setting on line $lineno: $key. Remove it, or run ./setup.sh." >&2
            return 1
        fi
        # A key already set in the environment wins over the config file:
        #   HALOGEN_REASONING_EFFORT=low ./run.sh
        # overrides the value written by setup.sh for that start. (${var+x}
        # expands to "x" when set, even to the empty string.)
        if [[ -n "${!key+x}" ]]; then
            continue
        fi
        printf -v "$key" '%s' "$value"
    done < "$file"
    return 0
}

# Usage: load_config <file>
load_config() {
    _load_kv_file "$1"
}

# rewrite_config_key <KEY> <value> [config-file] [insert-after-key]
# Back up the config file, replace KEY= (or add the key), and keep
# everything else byte-for-byte. Prints the backup path. The file defaults to
# $CONFIG_FILE, which every entry script sets. Pure text rewriting plus a copy:
# the config is never executed, so this is safe from setup.sh, which reads the
# old config with grep for exactly that reason.
#
# A key the file does not have yet is appended at the end. Pass
# [insert-after-key] to land it directly below that key instead: a
# config.env written by an older setup.sh has no HALOGEN_CHECKPOINT, and
# appending it would drop it under the "# Advanced (uncomment to override)"
# header, where it reads as part of the commented-out block.
rewrite_config_key() {
    local key="$1" value="$2" file="${3:-${CONFIG_FILE:-}}" after="${4:-}"
    local backup_path tmp seen=0 inserted_after=0
    if [[ -z "$file" ]]; then
        echo "rewrite_config_key: no config file given and CONFIG_FILE is unset" >&2
        return 1
    fi
    local lib_dir backups_dir ts
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    backups_dir="$(dirname "$lib_dir")/backups"
    mkdir -p "$backups_dir"
    # Backups hold the whole config, API key included. cp -a keeps the file's
    # own 0600; the directory needs tightening too so it is not listable.
    chmod 700 "$backups_dir" 2>/dev/null || true
    ts="$(date +%Y-%m-%d-%H-%M)"
    backup_path="$backups_dir/config.env-$ts"
    if [[ -e "$backup_path" ]]; then
        backup_path="$backups_dir/config.env-$ts-$(date +%S)"
    fi
    cp -a "$file" "$backup_path"
    tmp="$(mktemp "$(dirname "$file")/.config.env.tmp.XXXXXX")"
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            "$key="*)
                seen=1
                printf '%s=%s\n' "$key" "$value"
                ;;
            *)
                printf '%s\n' "$line"
                if [[ -n "$after" && $inserted_after -eq 0 ]]; then
                    case "$line" in
                        "$after="*)
                            printf '%s=%s\n' "$key" "$value"
                            inserted_after=1
                            ;;
                    esac
                fi
                ;;
        esac
    done < "$file" > "$tmp"
    if (( seen == 0 && inserted_after == 0 )); then
        printf '%s=%s\n' "$key" "$value" >> "$tmp"
    fi
    mv -f "$tmp" "$file"
    printf '%s\n' "$backup_path"
}

# generate_api_key — a new API key in the shape this stack uses: hl-gn- plus
# 24 hex characters. od reads a fixed byte count, so no pipe is closed
# early and the function is safe under `set -o pipefail`.
generate_api_key() {
    printf 'hl-gn-%s\n' "$(od -An -N18 -tx1 /dev/urandom | tr -d ' \n' | cut -c1-24)"
}

# api_key_present <config-file> — true when the file carries a
# HALOGEN_API_KEY with a non-empty value. Read with grep, never executed:
# the config may hold a secret and must stay data. A commented
# "# HALOGEN_API_KEY=" placeholder does not count as configured.
api_key_present() {
    local file="$1" line value
    [[ -f "$file" ]] || return 1
    line="$(grep -E '^HALOGEN_API_KEY=' "$file" 2>/dev/null | tail -n1 || true)"
    [[ -n "$line" ]] || return 1
    value="${line#*=}"
    [[ -n "$value" ]]
}

# GiB free on the filesystem that contains $1 (walks up if the path does not
# exist yet). Prints an integer. Returns 1 if df fails.
disk_avail_gib() {
    local path="$1"
    local avail
    while [[ -n "$path" && "$path" != "/" && ! -e "$path" ]]; do
        path="$(dirname "$path")"
    done
    [[ -e "$path" ]] || path="/"
    avail="$(df -B1G --output=avail "$path" 2>/dev/null | awk 'NR==2 {print $1}')"
    avail="${avail%G}"
    avail="${avail%g}"
    if [[ ! "$avail" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    printf '%s\n' "$avail"
}

# True if a container with the given name exists (any state).
podman_container_exists() {
    local names
    names="$(podman ps -a --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')" || return 1
    [[ " $names " == *" $1 "* ]]
}

# True if the container with the given name is currently running.
podman_container_running() {
    local running
    running="$(podman ps --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')" || return 1
    [[ " $running " == *" $1 "* ]]
}

# normalize_image <value>
# Turns what a user types into a full image reference. A bare tag (0.18.5,
# latest), a :tag, or a complete reference all work.
normalize_image() {
    local value="$1"
    if [[ "$value" == */* ]]; then
        printf '%s\n' "$value"
    elif [[ "$value" == :* ]]; then
        printf '%s\n' "${HALOGEN_IMAGE_REPO}${value}"
    else
        printf '%s\n' "${HALOGEN_IMAGE_REPO}:${value}"
    fi
}

# image_version_local <image-ref> — the version the image on disk reports, read
# from its own org.opencontainers.image.version label. Prints nothing and
# returns 1 when podman is missing, the image is not here, or it carries no
# label.
image_version_local() {
    local ref="$1" ver
    have podman || return 1
    ver="$(podman image inspect "$ref" \
        --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' \
        2>/dev/null)" || return 1
    if [[ "$ver" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
        printf '%s\n' "$ver"
        return 0
    fi
    return 1
}

# image_version <image-ref> — the version a reference names: the tag when it is
# already a number, otherwise the version of the image on disk. Returns 1 when
# neither answers, so a caller can tell "no version" from "version 0".
image_version() {
    local tag="${1##*:}"
    if [[ "$tag" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
        printf '%s\n' "$tag"
        return 0
    fi
    image_version_local "$1"
}

# image_version_upstream <image-ref> — the version the registry reports for
# this tag, read from the image config its manifest points at. Public
# registries answer after a bearer token and say where to get one in a 401
# challenge. Needs curl and python3, the same tools the model checks use.
# Prints nothing and returns 1 when offline, a tool is missing, the tag is
# unknown, or the registry does not use this shape — the caller then keeps the
# tag it has.
image_version_upstream() {
    local ref="$1" host rest repo tag www realm service scope token digest ver
    local accept='application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json'
    have curl || return 1
    have python3 || return 1
    [[ "$ref" == */* ]] || return 1
    host="${ref%%/*}"
    [[ "$host" == *.* || "$host" == *:* ]] || return 1
    rest="${ref#*/}"
    [[ "$rest" == *:* ]] || return 1
    tag="${rest##*:}"
    repo="${rest%:*}"

    www="$(curl -sS -o /dev/null -D - --connect-timeout 5 --max-time 15 \
             -H "Accept: $accept" "https://$host/v2/$repo/manifests/$tag" 2>/dev/null \
             | tr -d '\r' \
             | awk 'tolower($1) == "www-authenticate:" { sub(/^[^ ]+ /, ""); print; exit }')" || return 1
    realm="$(sed -n 's/.*realm="\([^"]*\)".*/\1/p' <<<"$www")"
    service="$(sed -n 's/.*service="\([^"]*\)".*/\1/p' <<<"$www")"
    scope="$(sed -n 's/.*scope="\([^"]*\)".*/\1/p' <<<"$www")"
    [[ -n "$realm" ]] || realm="https://$host/token"
    [[ -n "$scope" ]] || scope="repository:$repo:pull"

    token="$(curl -fsSL --connect-timeout 5 --max-time 15 \
               "${realm}?service=${service}&scope=${scope}" 2>/dev/null \
               | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))' 2>/dev/null)" || return 1
    [[ -n "$token" ]] || return 1

    digest="$(curl -fsSL --connect-timeout 5 --max-time 15 \
                -H "Authorization: Bearer $token" -H "Accept: $accept" \
                "https://$host/v2/$repo/manifests/$tag" 2>/dev/null \
                | python3 -c 'import json,sys; print(json.load(sys.stdin).get("config",{}).get("digest",""))' 2>/dev/null)" || return 1
    [[ "$digest" == sha256:* ]] || return 1

    ver="$(curl -fsSL --connect-timeout 5 --max-time 15 \
             -H "Authorization: Bearer $token" \
             "https://$host/v2/$repo/blobs/$digest" 2>/dev/null \
             | python3 -c 'import json,sys; print((json.load(sys.stdin).get("config") or {}).get("Labels", {}).get("org.opencontainers.image.version", ""))' 2>/dev/null)" || return 1
    [[ "$ver" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 1
    printf '%s\n' "$ver"
}

# resolve_moving_tag <image-ref> — a `latest` reference with its tag replaced by
# the version the registry says `latest` is now. Everything else comes back
# unchanged, and so does `latest` when the registry cannot be reached: a
# version nobody could confirm is not worth writing down.
resolve_moving_tag() {
    local ref="$1" ver
    if [[ "${ref##*:}" == "latest" ]] && ver="$(image_version_upstream "$ref")"; then
        printf '%s\n' "${ref%:*}:$ver"
    else
        printf '%s\n' "$ref"
    fi
}

# image_display <image-ref> — a reference for a report line. A version tag is
# already the answer; a moving tag gains the version of the image on disk:
# `ghcr.io/…:latest (v0.18.16)`. Nothing is fetched to find it.
image_display() {
    local ref="$1" ver=""
    [[ "${ref##*:}" =~ ^[0-9] ]] || ver="$(image_version_local "$ref")" || ver=""
    if [[ -n "$ver" ]]; then
        printf '%s (v%s)' "$ref" "$ver"
    else
        printf '%s' "$ref"
    fi
}

# version_label <image-ref> — the tag for display, prefixed with "v" when it
# looks like a version number. `latest` and sha tags keep their own name, so
# a prompt never reads "vlatest".
version_label() {
    local tag="${1##*:}"
    if [[ "$tag" =~ ^[0-9] ]]; then
        printf 'v%s' "$tag"
    else
        printf '%s' "$tag"
    fi
}

# ── Quant selection ──────────────────────────────────────────────────────────
# A deployment runs one quant generation. Everything here takes the
# checkpoint's base name (as in HALOGEN_CHECKPOINT) and answers what that
# quant needs on disk.

# selected_checkpoint [config-value] [models-dir]
# The base name of the checkpoint this deployment actually runs. A set
# HALOGEN_CHECKPOINT decides it. Unset, this mirrors the engine's own
# auto-detect: a volume holding w4b and not v2 keeps serving w4b and
# downloads nothing, so w4b is the honest answer there; every other case
# runs v2, the engine's default since 0.15.0.
selected_checkpoint() {
    local cp="${1:-${HALOGEN_CHECKPOINT:-}}"
    local dir="${2:-${MODELS_DIR:-}}"
    if [[ -n "$cp" ]]; then
        printf '%s\n' "$(basename "$cp")"
        return 0
    fi
    if [[ -n "$dir" && -f "$dir/$HF_LEGACY_CHECKPOINT_FILE" \
          && ! -f "$dir/$HF_CHECKPOINT_FILE" ]]; then
        printf '%s\n' "$HF_LEGACY_CHECKPOINT_FILE"
        return 0
    fi
    printf '%s\n' "$HF_CHECKPOINT_FILE"
}

# quant_is_legacy <base-name> — true for the deprecated w4b quant.
quant_is_legacy() {
    [[ "$1" == "$HF_LEGACY_CHECKPOINT_FILE" ]]
}

# quant_files <base-name> — the .hgn files that quant needs, one per line.
# w4b is two files (the checkpoint and its quality sidecar); v2 is one file
# plus its lookup table.
quant_files() {
    if quant_is_legacy "$1"; then
        printf '%s\n' "$HF_LEGACY_CHECKPOINT_FILE" "$HF_LEGACY_OVERLAY_FILE"
    else
        printf '%s\n' "$HF_CHECKPOINT_FILE" "$HF_NGRAM_FILE"
    fi
}

# other_quant_files <base-name> — the .hgn files belonging to the quant this
# deployment does NOT run. Excluded from every download so one switch never
# pulls both generations (~170 GiB) when only ~110 GiB is wanted.
other_quant_files() {
    if quant_is_legacy "$1"; then
        printf '%s\n' "$HF_CHECKPOINT_FILE" "$HF_NGRAM_FILE"
    else
        printf '%s\n' "$HF_LEGACY_CHECKPOINT_FILE" "$HF_LEGACY_OVERLAY_FILE"
    fi
}

# quant_floor_gib <file-name> — the local size floor in GiB, used only when
# the repo's live listing is unavailable. A file under its floor is treated
# as truncated. 0 means no floor beyond the empty-file check.
quant_floor_gib() {
    case "$1" in
        "$HF_LEGACY_CHECKPOINT_FILE") printf '110\n' ;;
        "$HF_CHECKPOINT_FILE")        printf '55\n'  ;;
        "$HF_NGRAM_FILE")            printf '42\n'  ;;
        "$HF_LEGACY_OVERLAY_FILE")   printf '2\n'   ;;
        *)                           printf '0\n'   ;;
    esac
}

# v2_installed [models-dir] — true when the v2 checkpoint is on disk and
# big enough to be a real file. The floor matters: a truncated or zero-byte
# v2 is not "already downloaded", and calling it that would skip a download
# that is genuinely needed. A volume holding both quants uses this to tell
# a real v2 from a half-written one. Apparent size (stat %s), not disk
# usage, so a sparse file measures correctly.
v2_installed() {
    local dir="${1:-${MODELS_DIR:-}}"
    local file size floor
    [[ -n "$dir" && -f "$dir/$HF_CHECKPOINT_FILE" ]] || return 1
    file="$dir/$HF_CHECKPOINT_FILE"
    size="$(stat -c '%s' "$file" 2>/dev/null || echo "")"
    [[ "$size" =~ ^[0-9]+$ ]] || return 1
    floor="$(quant_floor_gib "$HF_CHECKPOINT_FILE")"
    (( size >= floor * 1073741824 ))
}

# checkpoint_host_path <container-path> <models-dir> — the host file behind
# a HALOGEN_CHECKPOINT value. The volume is mounted at /models, so the path
# maps onto MODELS_DIR. A value outside /models/ cannot be checked locally:
# the base name in <models-dir> is used and a warning says so.
checkpoint_host_path() {
    local cp="$1" dir="$2" rel
    if [[ "$cp" == /models/* && "$cp" != /models ]]; then
        rel="${cp#/models/}"
        printf '%s/%s\n' "$dir" "$rel"
        return 0
    fi
    warn "HALOGEN_CHECKPOINT is outside the model folder. Checking $(basename "$cp") in $dir instead."
    printf '%s/%s\n' "$dir" "$(basename "$cp")"
}

# image_tag_ge <image-ref> <min-version> — true when the image's tag is at
# or above <min-version>. A non-numeric tag (latest, a digest) counts as
# capable, so newer behaviour is never skipped for it.
image_tag_ge() {
    local ref="$1" min="$2" tag
    tag="${ref##*:}"
    if [[ ! "$tag" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
        return 0
    fi
    [[ "$(printf '%s\n%s\n' "$tag" "$min" | sort -V | head -n1)" == "$min" ]]
}

# ── Hugging Face helpers ─────────────────────────────────────────────────────

# sha256 of a file; prints nothing when the file cannot be hashed. The `|| true`
# keeps a failed sha256sum from aborting a caller under `set -o pipefail`.
file_sha256() {
    sha256sum "$1" 2>/dev/null | cut -d' ' -f1 || true
}

# hf_remote_table — one API call, one line per LFS file in the weights repo:
#   <path> <sha256> <size-bytes>
# Returns 1 when the repo is unreachable, and 2 when curl or python3 is
# missing — so a caller can tell "no network" from "no tooling".
# Never cached: every call is the repo's current state.
hf_remote_table() {
    local json
    if ! have curl; then
        echo "hf_remote_table: curl not found" >&2
        return 2
    fi
    if ! have python3; then
        echo "hf_remote_table: python3 not found" >&2
        return 2
    fi
    if ! json="$(curl -fsSL --connect-timeout 5 --max-time 20 "$HF_TREE_API" 2>/dev/null)"; then
        echo "hf_remote_table: could not reach the HF API (offline?)" >&2
        return 1
    fi
    python3 -c '
import json, sys
for entry in json.load(sys.stdin):
    if "lfs" in entry:
        print(entry["path"], entry["lfs"]["oid"], entry["lfs"]["size"])
' <<<"$json"
}

# hf_remote_sha256 <filename>
# Prints the sha256 the HF repo currently lists for the file (the LFS "oid"
# in the tree API). Returns 1 when offline or when the file is not in the
# repo, 2 when curl or python3 is missing.
hf_remote_sha256() {
    local file="$1" table oid rc=0
    table="$(hf_remote_table 2>/dev/null)" || rc=$?
    if (( rc == 2 )); then
        echo "hf_remote_sha256: reading the repo's file list needs python3" >&2
        return 2
    fi
    oid="$(awk -v f="$file" '$1 == f {print $2; exit}' <<<"$table")"
    if [[ ! "$oid" =~ ^[0-9a-f]{64}$ ]]; then
        echo "hf_remote_sha256: $file not found in $HF_REPO_ID (or offline)" >&2
        return 1
    fi
    printf '%s\n' "$oid"
}

# Bytes as GiB with one decimal, for the size reports. 1073741824 -> 1.0
bytes_gib() {
    awk -v b="${1:-0}" 'BEGIN { printf "%.1f", b / 1073741824 }'
}

# _weights_check_pass <models-dir> <vision> <table> [checkpoint-base-name]
# The core pass. With a non-empty <table> (from hf_remote_table) sizes are
# compared exactly; with an empty one the local floors from quant_floor_gib
# are used. The files checked are the ones the named quant needs (see
# quant_files), plus the tokenizer and, when vision is on, the sidecar.
# Prints one line per file: "<status> <file> <detail>". Status is
#   ok         present, and the size matches the repo's current listing
#   unverified present, size plausible, no listing available
#   missing    not on disk
#   incomplete present but the wrong size (truncated / partial)
# Sizes in <detail> are GiB, for display.
_weights_check_pass() {
    local dir="$1" vision="$2" table="$3" ck="${4:-$HF_CHECKPOINT_FILE}" rc=0
    local -a files=()
    local qf
    while read -r qf; do
        if [[ -n "$qf" ]]; then
            files+=("$qf")
        fi
    done < <(quant_files "$ck")
    if [[ "$vision" == "1" ]]; then
        files+=("$HF_VISION_FILE")
    fi

    local f path actual expected floor
    for f in "${files[@]}"; do
        path="$dir/$f"
        if [[ ! -f "$path" ]]; then
            printf 'missing %s -\n' "$f"
            rc=1
            continue
        fi
        actual="$(stat -c '%s' "$path" 2>/dev/null || echo "")"
        if [[ ! "$actual" =~ ^[0-9]+$ ]]; then
            printf 'missing %s -\n' "$f"
            rc=1
            continue
        fi
        expected="$(awk -v f="$f" '$1 == f {print $3; exit}' <<<"$table")"
        if [[ -n "$expected" ]]; then
            if [[ "$actual" == "$expected" ]]; then
                printf 'ok %s %s GiB\n' "$f" "$(bytes_gib "$actual")"
            else
                printf 'incomplete %s %s GiB of %s GiB\n' "$f" "$(bytes_gib "$actual")" "$(bytes_gib "$expected")"
                rc=1
            fi
        else
            floor="$(quant_floor_gib "$f")"
            if (( actual < floor * 1073741824 )); then
                # No listing: the local size floor for this file.
                printf 'incomplete %s %s GiB\n' "$f" "$(bytes_gib "$actual")"
                rc=1
            elif (( actual == 0 )); then
                printf 'incomplete %s %s GiB\n' "$f" "$(bytes_gib "$actual")"
                rc=1
            else
                printf 'unverified %s %s GiB\n' "$f" "$(bytes_gib "$actual")"
            fi
        fi
    done

    local tf
    for tf in "${HF_TOKENIZER_REQUIRED[@]}"; do
        if [[ ! -s "$dir/$tf" ]]; then
            printf 'missing %s -\n' "$tf"
            rc=1
        fi
    done
    return $rc
}

# weights_check <models-dir> [vision 0|1] [mode auto|remote|local] [checkpoint-base-name]
# One line per file this repo needs: "<status> <file> <detail>" (see
# _weights_check_pass). Returns 0 when every required file is ok or
# unverified, 1 otherwise.
#
# mode auto (default): local floors first. The repo's exact byte sizes are
#   consulted only when the local pass already found a problem, so a complete
#   tree costs no network call and an offline start is not delayed. run.sh
#   uses this.
# mode remote: always compare against the repo's live exact sizes, so a
#   truncated file is caught by size alone. setup.sh uses this.
# mode local: never touch the network.
weights_check() {
    local dir="$1" vision="${2:-0}" mode="${3:-auto}" ck
    ck="$(selected_checkpoint "${4:-}")"

    if [[ "$mode" == "local" ]]; then
        _weights_check_pass "$dir" "$vision" "" "$ck"
        return $?
    fi

    if [[ "$mode" == "auto" ]]; then
        local first
        if first="$(_weights_check_pass "$dir" "$vision" "" "$ck")"; then
            printf '%s\n' "$first"
            return 0
        fi
    fi

    local table
    table="$(hf_remote_table 2>/dev/null)" || table=""
    _weights_check_pass "$dir" "$vision" "$table" "$ck"
}

# hf_download_excludes [vision 0|1] [checkpoint-base-name]
# Prints, one per line, the weights-repo files this deployment does not need:
#   - the files of the quant generation this deployment does not run, so a
#     v2 volume never pulls w4b and its sidecar (~118 GiB) and a w4b
#     volume never pulls v2 and its lookup table (~110 GiB)
#   - the vision sidecar, unless vision is enabled (0.84 GiB)
#   - the speed overlay, which only HALOGEN_CK_OVERLAY names (2.5 GiB)
#   - the MTP head, which only a GGUF trunk reads — the .hgn checkpoint
#     carries its own head (1.5 GiB)
# Skipping them is safe: the engine's own HALOGEN_DOWNLOAD fires only when the
# checkpoint is absent, and its sidecar refresh only ever touches
# <checkpoint>.overlay.hgn, so nothing re-fetches an excluded file. Turning
# vision on and re-running setup fetches the sidecar then.
hf_download_excludes() {
    local vision="${1:-0}" ck
    ck="$(selected_checkpoint "${2:-}")"
    printf '%s\n' "$HF_SPEED_OVERLAY_FILE" "$HF_MTP_FILE"
    other_quant_files "$ck"
    if [[ "$vision" != "1" ]]; then
        printf '%s\n' "$HF_VISION_FILE"
    fi
}

# hf_download_models <dest-dir> [image] [vision 0|1] [checkpoint-base-name]
# Fetch the weights repo into <dest-dir> with the same command the engine's
# entrypoint runs for HALOGEN_DOWNLOAD:
#   HF_HUB_OFFLINE=0 hf download <repo> --local-dir <dir>
# minus the files hf_download_excludes() names, so a config pays only for the
# quant it runs and, if vision is off, not for the sidecar. Resumable.
# Preference: host `hf`, then `uvx hf` (the same CLI, no install beyond uv),
# then the engine image's own `hf` (podman; no GPU needed, so this works
# before a kernel-param reboot), then resumable curl. Returns non-zero on
# failure; whatever arrived is left in place so a re-run resumes.
hf_download_models() {
    local dir="$1" image="${2:-}" vision="${3:-0}" ck
    ck="$(selected_checkpoint "${4:-}")"
    mkdir -p "$dir"

    # Built once; both the host and the container path use it.
    local -a excludes=()
    local pat
    while read -r pat; do
        if [[ -n "$pat" ]]; then
            excludes+=(--exclude "$pat")
        fi
    done < <(hf_download_excludes "$vision" "$ck")

    if have hf; then
        info "Downloading the weights with the host 'hf' CLI (resumes if interrupted)..."
        HF_HUB_OFFLINE=0 hf download "$HF_REPO_ID" --local-dir "$dir" "${excludes[@]}"
        return $?
    fi

    # 'hf' on PyPI is the official CLI, published by Hugging Face and pinned
    # to the huggingface_hub library — the same tool the host package provides.
    # Tried before the container because it needs no image pull, but its first
    # run resolves the package from PyPI: a failure there is not a failed
    # download, so fall through instead of ending the attempt.
    if have uvx; then
        info "Downloading the weights with 'uvx hf' (resumes if interrupted)..."
        if HF_HUB_OFFLINE=0 uvx hf download "$HF_REPO_ID" --local-dir "$dir" "${excludes[@]}"; then
            return 0
        fi
        warn "'uvx hf' failed (PyPI unreachable?) — falling back to the image."
    fi

    if have podman && [[ -n "$image" ]] && podman image exists "$image" 2>/dev/null; then
        info "Downloading the weights with the engine image's own 'hf' (resumes if interrupted)..."
        local -a args=(run --rm --entrypoint /usr/local/bin/hf -e HF_HUB_OFFLINE=0)
        # Give hf a tty when we have one, so its progress bars render; without
        # one it goes quiet for the length of a 110 GiB transfer.
        if [[ -t 1 ]]; then
            args+=(-t)
        fi
        if [[ -n "${HF_TOKEN:-}" ]]; then
            args+=(-e "HF_TOKEN=$HF_TOKEN")
        fi
        args+=(-v "$dir:/models")
        args+=("$image" download "$HF_REPO_ID" --local-dir /models)
        args+=("${excludes[@]}")
        podman "${args[@]}"
        return $?
    fi

    if have curl; then
        warn "Neither 'hf' nor the engine image is usable — falling back to resumable curl."
        _hf_curl_fetch_tree "$dir" "$vision" "$ck"
        return $?
    fi

    warn "No download tool found. Install uv or curl, then try again."
    return 1
}

# _hf_curl_fetch_tree <dest-dir> [vision 0|1] [checkpoint-base-name]
# Last-resort fetch with curl: every LFS file the repo lists (or the names
# this repo knows for the selected quant, when offline), then the tokenizer.
# Single connection per file, resumable with -C -. The engine never uses this
# path; it exists so a host with neither `hf` nor a usable image can still
# get the weights.
_hf_curl_fetch_tree() {
    local dir="$1" vision="${2:-0}" ck
    ck="$(selected_checkpoint "${3:-}")"
    local rc=0 f expected actual
    local table table_rc=0
    table="$(hf_remote_table 2>/dev/null)" || table_rc=$?

    local -a excluded=()
    local x
    while read -r x; do
        if [[ -n "$x" ]]; then
            excluded+=("$x")
        fi
    done < <(hf_download_excludes "$vision" "$ck")

    local -a names=()
    if [[ -n "$table" ]]; then
        while read -r f _ _; do
            if [[ -n "$f" ]]; then
                names+=("$f")
            fi
        done <<<"$table"
    else
        if (( table_rc == 2 )); then
            warn "python3 is missing. Fetching the known files only."
        else
            warn "Offline. Fetching the known files only."
        fi
        names=()
        local qf
        while read -r qf; do
            if [[ -n "$qf" ]]; then
                names+=("$qf")
            fi
        done < <(quant_files "$ck")
        if [[ "$vision" == "1" ]]; then
            names+=("$HF_VISION_FILE")
        fi
    fi

    for f in "${names[@]}"; do
        if _key_in_list "$f" excluded; then
            info "Skipping $f (not needed by this configuration)."
            continue
        fi
        expected="$(awk -v f="$f" '$1 == f {print $3; exit}' <<<"$table")"
        actual="$(stat -c '%s' "$dir/$f" 2>/dev/null || echo 0)"
        if [[ -n "$expected" && "$actual" == "$expected" ]]; then
            ok "Already downloaded: $f"
            continue
        fi
        echo "  Downloading $f (resumable) ..."
        mkdir -p "$dir/$(dirname "$f")"
        if ! curl -fL -C - --retry 3 --retry-delay 5 -o "$dir/$f" "$HF_RESOLVE_URL/$f"; then
            warn "Download failed: $f"
            rc=1
            continue
        fi
        if [[ -n "$expected" ]]; then
            actual="$(stat -c '%s' "$dir/$f" 2>/dev/null || echo 0)"
            if [[ "$actual" != "$expected" ]]; then
                warn "Size mismatch for $f: got $actual, expected $expected"
                rc=1
            fi
        fi
    done

    for f in "${HF_TOKENIZER_FILES[@]}"; do
        if [[ -s "$dir/$f" ]]; then
            continue
        fi
        mkdir -p "$dir/$(dirname "$f")"
        echo "  Downloading $f ..."
        if ! curl -fL --retry 3 -o "$dir/$f" "$HF_RESOLVE_URL/$f"; then
            warn "Download failed: $f"
            rc=1
        fi
    done
    return $rc
}

# hf_fetch_file <filename> <expected-sha256> <dest-dir>
# Downloads one small file from the weights repo and verifies its sha256.
# Uses `hf download` when the CLI is present, then `uvx hf`, then curl with
# resume (-C -). For small files (the vision sidecar); the ~110 GiB weights
# tree goes through hf_download_models().
hf_fetch_file() {
    local file="$1" expected="$2" dir="$3"
    local fpath="$dir/$file" actual
    local fetched=false

    mkdir -p "$dir"
    # Already here and correct? Skip. Here but wrong? Delete and re-download.
    if [[ -f "$fpath" ]]; then
        actual="$(file_sha256 "$fpath")"
        if [[ "$actual" == "$expected" ]]; then
            ok "Already downloaded and verified: $file"
            return 0
        fi
        warn "Existing $file does not match the repo's sha256 — re-downloading."
        rm -f "$fpath"
    fi

    if have hf; then
        if ! hf download "$HF_REPO_ID" "$file" --local-dir "$dir"; then
            warn "Download failed: $file"
            return 1
        fi
        fetched=true
    elif have uvx; then
        # The official 'hf' CLI from PyPI. Its first run resolves the
        # package over the network, so a failure here is not a failed
        # download: fall through to curl rather than give up.
        if uvx hf download "$HF_REPO_ID" "$file" --local-dir "$dir"; then
            fetched=true
        else
            warn "'uvx hf' failed (PyPI unreachable?) — trying curl."
        fi
    fi

    if [[ "$fetched" != "true" ]]; then
        if have curl; then
            echo "  Downloading $file (no working hf CLI; resumable curl) ..."
            if ! curl -fL -C - --retry 3 -o "$fpath" "$HF_RESOLVE_URL/$file"; then
                warn "Download failed: $file"
                return 1
            fi
        else
            warn "Can't download $file. Install curl, hf, or uvx, then try again."
            return 1
        fi
    fi
    actual="$(file_sha256 "$fpath")"
    if [[ "$actual" != "$expected" ]]; then
        warn "CHECKSUM MISMATCH for $file: got $actual, expected $expected"
        return 1
    fi
    ok "Downloaded and verified: $file"
}
