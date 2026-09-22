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
    HALOGEN_IMAGE HALOGEN_MODEL_ID
    HALOGEN_CTX HALOGEN_KV_SLOTS HALOGEN_KV_POOL_POSITIONS
    HALOGEN_VISION_TOWER
    HALOGEN_REASONING_EFFORT
    HALOGEN_EXTRA_ENV
)

# The Hugging Face repo the engine's checkpoint ships in. The tree API lists
# every file with its sha256 (the LFS "oid"), which is what
# hf_remote_sha256() reads.
HF_REPO_ID="peonist-ai/halogen-qwen3.8-flash-next"
HF_TREE_API="https://huggingface.co/api/models/$HF_REPO_ID/tree/main"
HF_RESOLVE_URL="https://huggingface.co/$HF_REPO_ID/resolve/main"

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
        echo "Error: config file not found or unreadable: $file" >&2
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
            echo "Error: $file:$lineno — unknown config key: $key" >&2
            echo "Allowed keys are listed in CONFIG_ALLOWED_KEYS in lib/common.sh." >&2
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

# ── Hugging Face helpers ─────────────────────────────────────────────────────

# hf_remote_sha256 <filename>
# Prints the sha256 the HF repo currently lists for the file (the LFS "oid"
# in the tree API). Returns 1 when offline, when curl/python3 are missing,
# or when the file is not in the repo. Never cached — every call is the
# repo's current state.
hf_remote_sha256() {
    local file="$1" json
    if ! have curl; then
        echo "hf_remote_sha256: curl not found" >&2
        return 1
    fi
    if ! have python3; then
        echo "hf_remote_sha256: python3 not found" >&2
        return 1
    fi
    if ! json="$(curl -fsSL --max-time 30 "$HF_TREE_API" 2>/dev/null)"; then
        echo "hf_remote_sha256: could not reach the HF API (offline?)" >&2
        return 1
    fi
    local oid
    oid="$(python3 -c '
import json, sys
tree = json.load(sys.stdin)
for entry in tree:
    if entry.get("path") == sys.argv[1] and "lfs" in entry:
        print(entry["lfs"]["oid"])
        break
' "$1" <<<"$json")"
    if [[ ! "$oid" =~ ^[0-9a-f]{64}$ ]]; then
        echo "hf_remote_sha256: $1 not found in $HF_REPO_ID (or the API response changed)" >&2
        return 1
    fi
    printf '%s\n' "$oid"
}

# hf_fetch_file <filename> <expected-sha256> <dest-dir>
# Downloads one small file from the weights repo and verifies its sha256.
# Uses `hf download` when the CLI is present; otherwise curl with resume
# (-C -). Only for small files (sidecars) — the ~122 GiB weights tree is
# fetched by the container itself.
hf_fetch_file() {
    local file="$1" expected="$2" dir="$3"
    local fpath="$dir/$file" actual

    file_sha256() {
        sha256sum "$1" 2>/dev/null | cut -d' ' -f1
    }

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
    elif have curl; then
        echo "  Downloading $file (hf CLI not found; resumable curl) ..."
        if ! curl -fL -C - --retry 3 -o "$fpath" "$HF_RESOLVE_URL/$file"; then
            warn "Download failed: $file"
            return 1
        fi
    else
        warn "Neither 'hf' nor 'curl' found — cannot download $file."
        return 1
    fi
    actual="$(file_sha256 "$fpath")"
    if [[ "$actual" != "$expected" ]]; then
        warn "CHECKSUM MISMATCH for $file: got $actual, expected $expected"
        return 1
    fi
    ok "Downloaded and verified: $file"
}
