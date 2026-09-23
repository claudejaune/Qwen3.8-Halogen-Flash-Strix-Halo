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
    HF_TOKEN
)

# The engine image. HALOGEN_RECOMMENDED_IMAGE is the single source of truth
# for the version this repo ships: setup.sh writes it into a new config.env,
# and refresh.sh offers it to an existing one.
HALOGEN_IMAGE_REPO="ghcr.io/peonist-ai/halogen-flash-server"
HALOGEN_RECOMMENDED_IMAGE="$HALOGEN_IMAGE_REPO:0.13.5"

# The Hugging Face repo the engine's checkpoint ships in. The tree API lists
# every file with its sha256 (the LFS "oid"), which is what
# hf_remote_sha256() reads.
HF_REPO_ID="peonist-ai/halogen-qwen3.8-flash-next"
HF_TREE_API="https://huggingface.co/api/models/$HF_REPO_ID/tree/main"
HF_RESOLVE_URL="https://huggingface.co/$HF_REPO_ID/resolve/main"

# The weights the server needs, by name. The engine downloads the WHOLE repo
# (HALOGEN_DOWNLOAD); these are the files this repo checks and reports on.
# Sizes and sha256s come live from the tree API, so a file the creators
# replace under the same name is still checked against what is current.
HF_CHECKPOINT_FILE="qwen38-flash-next-w4b.hgn"
HF_OVERLAY_FILE="qwen38-flash-next-w4b.overlay.hgn"
HF_VISION_FILE="qwen38-flash-next-vision.hgn"
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

# normalize_image <value>
# Turns what a user types into a full image reference. A bare tag (0.13.5,
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

# ── Hugging Face helpers ─────────────────────────────────────────────────────

# sha256 of a file; prints nothing when the file cannot be hashed.
file_sha256() {
    sha256sum "$1" 2>/dev/null | cut -d' ' -f1
}

# hf_remote_table — one API call, one line per LFS file in the weights repo:
#   <path> <sha256> <size-bytes>
# Returns 1 when curl/python3 are missing or the repo is unreachable. Never
# cached: every call is the repo's current state.
hf_remote_table() {
    local json
    if ! have curl; then
        echo "hf_remote_table: curl not found" >&2
        return 1
    fi
    if ! have python3; then
        echo "hf_remote_table: python3 not found" >&2
        return 1
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
# in the tree API). Returns 1 when offline, when curl/python3 are missing,
# or when the file is not in the repo.
hf_remote_sha256() {
    local file="$1" table oid
    table="$(hf_remote_table 2>/dev/null)" || table=""
    oid="$(awk -v f="$file" '$1 == f {print $2; exit}' <<<"$table")"
    if [[ ! "$oid" =~ ^[0-9a-f]{64}$ ]]; then
        echo "hf_remote_sha256: $file not found in $HF_REPO_ID (or offline)" >&2
        return 1
    fi
    printf '%s\n' "$oid"
}

# _weights_check_pass <models-dir> <vision> <table>
# The core pass. With a non-empty <table> (from hf_remote_table) sizes are
# compared exactly; with an empty one the historical local floors are used.
# Prints one line per file: "<status> <file> <detail>". Status is
#   ok         present, and the size matches the repo's current listing
#   unverified present, size plausible, no listing available
#   missing    not on disk
#   incomplete present but the wrong size (truncated / partial)
_weights_check_pass() {
    local dir="$1" vision="$2" table="$3" rc=0
    local -a files=("$HF_CHECKPOINT_FILE" "$HF_OVERLAY_FILE")
    if [[ "$vision" == "1" ]]; then
        files+=("$HF_VISION_FILE")
    fi

    local f path actual expected
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
                printf 'ok %s %s\n' "$f" "$actual"
            else
                printf 'incomplete %s %s/%s\n' "$f" "$actual" "$expected"
                rc=1
            fi
        elif [[ "$f" == "$HF_CHECKPOINT_FILE" && "$actual" -lt $((110 * 1073741824)) ]]; then
            # No listing: the historical size floor. ~115 GiB expected.
            printf 'incomplete %s %s\n' "$f" "$actual"
            rc=1
        elif (( actual == 0 )); then
            printf 'incomplete %s %s\n' "$f" "$actual"
            rc=1
        else
            printf 'unverified %s %s\n' "$f" "$actual"
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

# weights_check <models-dir> [vision 0|1] [mode auto|remote|local]
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
    local dir="$1" vision="${2:-0}" mode="${3:-auto}"

    if [[ "$mode" == "local" ]]; then
        _weights_check_pass "$dir" "$vision" ""
        return $?
    fi

    if [[ "$mode" == "auto" ]]; then
        local first
        if first="$(_weights_check_pass "$dir" "$vision" "")"; then
            printf '%s\n' "$first"
            return 0
        fi
    fi

    local table
    table="$(hf_remote_table 2>/dev/null)" || table=""
    _weights_check_pass "$dir" "$vision" "$table"
}

# hf_download_excludes [vision 0|1]
# Prints, one per line, the weights-repo files this deployment does not need:
#   - the vision sidecar, unless vision is enabled (0.84 GiB)
#   - the speed overlay, which only HALOGEN_CK_OVERLAY names (2.5 GiB)
#   - the MTP head, which only a GGUF trunk reads — the .hgn checkpoint
#     carries its own head (1.5 GiB)
# Skipping them is safe: the engine's own HALOGEN_DOWNLOAD fires only when the
# checkpoint is absent, and its sidecar refresh only ever touches
# <checkpoint>.overlay.hgn, so nothing re-fetches an excluded file. Turning
# vision on and re-running setup fetches the sidecar then.
hf_download_excludes() {
    local vision="${1:-0}"
    printf '%s\n' "$HF_SPEED_OVERLAY_FILE" "$HF_MTP_FILE"
    if [[ "$vision" != "1" ]]; then
        printf '%s\n' "$HF_VISION_FILE"
    fi
}

# hf_download_models <dest-dir> [image] [vision 0|1]
# Fetch the weights repo into <dest-dir> with the same command the engine's
# entrypoint runs for HALOGEN_DOWNLOAD:
#   HF_HUB_OFFLINE=0 hf download <repo> --local-dir <dir>
# minus the files hf_download_excludes() names, so a config that does not use
# the vision sidecar does not pay for it. Resumable. Preference: host `hf`,
# then the engine image's own `hf` (podman; no GPU needed, so this works
# before a kernel-param reboot), then resumable curl. Returns non-zero on
# failure; whatever arrived is left in place so a re-run resumes.
hf_download_models() {
    local dir="$1" image="${2:-}" vision="${3:-0}"
    mkdir -p "$dir"

    # Built once; both the host and the container path use it.
    local -a excludes=()
    local pat
    while read -r pat; do
        if [[ -n "$pat" ]]; then
            excludes+=(--exclude "$pat")
        fi
    done < <(hf_download_excludes "$vision")

    if have hf; then
        info "Downloading the weights with the host 'hf' CLI (resumes if interrupted)..."
        HF_HUB_OFFLINE=0 hf download "$HF_REPO_ID" --local-dir "$dir" "${excludes[@]}"
        return $?
    fi

    if have podman && [[ -n "$image" ]] && podman image exists "$image" 2>/dev/null; then
        info "Downloading the weights with the engine image's own 'hf' (resumes if interrupted)..."
        local -a args=(run --rm --entrypoint /usr/local/bin/hf -e HF_HUB_OFFLINE=0)
        # Give hf a tty when we have one, so its progress bars render; without
        # one it goes quiet for the length of a 122 GiB transfer.
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
        _hf_curl_fetch_tree "$dir" "$vision"
        return $?
    fi

    warn "No downloader available: install 'hf', pull $image, or install curl."
    return 1
}

# Last-resort fetch with curl: every LFS file the repo lists (or the names
# this repo knows, when offline), then the tokenizer. Single connection per
# file, resumable with -C -. The engine never uses this path; it exists so a
# host with neither `hf` nor a usable image can still get the weights.
_hf_curl_fetch_tree() {
    local dir="$1" vision="${2:-0}" rc=0 f expected actual
    local table
    table="$(hf_remote_table 2>/dev/null)" || table=""

    local -a excluded=()
    local x
    while read -r x; do
        if [[ -n "$x" ]]; then
            excluded+=("$x")
        fi
    done < <(hf_download_excludes "$vision")

    local -a names=()
    if [[ -n "$table" ]]; then
        while read -r f _ _; do
            if [[ -n "$f" ]]; then
                names+=("$f")
            fi
        done <<<"$table"
    else
        warn "HF API unreachable — fetching only the files this repo knows by name."
        names=("$HF_CHECKPOINT_FILE" "$HF_OVERLAY_FILE" "$HF_VISION_FILE")
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
# Uses `hf download` when the CLI is present; otherwise curl with resume
# (-C -). For small files (the vision sidecar); the ~122 GiB weights tree
# goes through hf_download_models().
hf_fetch_file() {
    local file="$1" expected="$2" dir="$3"
    local fpath="$dir/$file" actual

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
