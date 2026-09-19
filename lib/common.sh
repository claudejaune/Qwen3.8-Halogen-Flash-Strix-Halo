#!/usr/bin/env bash
# lib/common.sh — shared helpers sourced by setup.sh, run.sh, stop.sh and
# refresh.sh.

# Keys that may appear in config.env. load_config refuses anything else, so a
# hand-edited config can never overwrite shell-critical variables (PATH, HOME,
# ...) or trip over readonly ones (UID, ...).
# shellcheck disable=SC2034  # consumed via nameref in _key_in_list
CONFIG_ALLOWED_KEYS=(
    BIND_HOST PORT
    HALOGEN_IMAGE HALOGEN_MODEL_ID
    HALOGEN_CTX HALOGEN_KV_SLOTS HALOGEN_KV_POOL_POSITIONS
    HALOGEN_VISION_TOWER
    HALOGEN_REASONING_EFFORT
    HALOGEN_EXTRA_ENV
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
