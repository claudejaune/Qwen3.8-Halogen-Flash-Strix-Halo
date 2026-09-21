#!/usr/bin/env bash
# setup.sh — Interactive onboarding for Qwen3.8-Flash-Next via halogen-flash-server
# on AMD Strix Halo.
# Writes config.env (plain KEY=value data) which run.sh reads. Re-running
# setup.sh overwrites config.env with no backup.
# The engine is halogen-flash-server: a prebuilt container image. No local
# builds. Weights (~118 GiB) are fetched by the container itself on first
# start (HALOGEN_DOWNLOAD); this script only checks that there is room.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"

# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_not_root

# Ctrl-C: say where things stand and how to finish. The config is written
# only after every question, so the flag distinguishes "interrupted during
# questions" from "interrupted during downloads".
CONFIG_WRITTEN=false
on_interrupt() {
    echo ""
    warn "Setup interrupted (Ctrl-C)."
    if [[ "$CONFIG_WRITTEN" == "true" ]]; then
        warn "Your config was saved to: $CONFIG_FILE"
    else
        warn "config.env was NOT written — nothing has changed."
    fi
    warn "A partially answered setup cannot run the server. Run ./setup.sh again"
    warn "to complete it (you can keep answering the same answers)."
    if [[ "${MODELS_DIR_PENDING:-false}" == "true" ]]; then
        warn "Remember: the weights directory (${MODELS_DIR:-<unset>}) must exist"
        warn "before the server can run."
    fi
    exit 130
}
trap on_interrupt INT

DEFAULT_IMAGE="ghcr.io/peonist-ai/halogen-flash-server:0.11.5"
MODELS_DIR="$HOME/halogen-models"
CHECKPOINT_FILE="qwen38-flash-next-w4b.hgn"
VISION_FILE="qwen38-flash-next-vision.hgn"
DISK_MIN_GIB=120
DISK_REC_GIB=130

# Preserve an existing weights location across setup runs (extracted by grep
# — we deliberately do NOT execute the old config here).
if [[ -f "$CONFIG_FILE" ]]; then
    PRESERVED_MODELS_DIR="$(grep -E '^MODELS_DIR=' "$CONFIG_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
    if [[ -n "$PRESERVED_MODELS_DIR" && "$PRESERVED_MODELS_DIR" = /* ]]; then
        MODELS_DIR="$PRESERVED_MODELS_DIR"
    fi
fi

# ── Detect OS ────────────────────────────────────────────────────────────────
OS_ID="unknown"
OS_VERSION=""
if [[ -r /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-}"
fi
case "$OS_ID" in
    fedora)        OS_LABEL="Fedora ${OS_VERSION:-}" ;;
    ubuntu|debian) OS_LABEL="${OS_ID^} ${OS_VERSION:-}" ;;
    arch)          OS_LABEL="Arch Linux" ;;
    *)             OS_LABEL="${PRETTY_NAME:-$OS_ID}" ;;
esac

# ── Container tooling (podman only — no toolbox, no local builds) ────────────
install_podman() {
    echo "  This project runs the server in a podman container."
    echo ""
    case "$OS_ID" in
        fedora)
            echo "  Will run: sudo dnf install -y podman" ;;
        ubuntu|debian)
            echo "  Will run: sudo apt update && sudo apt install -y podman" ;;
        arch)
            echo "  Will run: sudo pacman -S --needed podman" ;;
        *)
            echo "  No automatic install for '$OS_ID'. Install podman with your"
            echo "  distro's package manager, then re-run setup.sh." ;;
    esac
    if ! ask_yes_no "  Install now?" y; then
        warn "Skipped. Install podman before running run.sh."
        return 1
    fi
    case "$OS_ID" in
        fedora)
            sudo dnf install -y podman || return 1 ;;
        ubuntu|debian)
            sudo apt update && sudo apt install -y podman || return 1 ;;
        arch)
            sudo pacman -S --needed podman || return 1 ;;
        *)
            return 1 ;;
    esac
    ok "Podman installed."
}

echo ""
info "=== Container tooling (detected: $OS_LABEL) ==="
if ! have podman; then
    warn "'podman' not found."
    if install_podman; then
        hash -r 2>/dev/null || true
    fi
fi
if have podman; then
    ok "Using: podman"
else
    warn "Podman incomplete. run.sh will not work until it is installed."
fi

# ── Detect hardware / kernel ─────────────────────────────────────────────────
echo ""
echo "============================================"
echo " Qwen3.8-Flash-Next (halogen-flash-server)"
echo " Interactive Setup"
echo "============================================"
echo ""

MEM_TOTAL_GIB=$(awk '/MemTotal/ {printf "%.0f", $2/1048576}' /proc/meminfo)
MEM_AVAIL_GIB=$(awk '/MemAvailable/ {printf "%.0f", $2/1048576}' /proc/meminfo)
info "Total RAM: ${MEM_TOTAL_GIB} GiB  Available: ${MEM_AVAIL_GIB} GiB"

KERNEL_RELEASE="$(uname -r)"
KERNEL_MAJOR="${KERNEL_RELEASE%%.*}"
if ! [[ "$KERNEL_MAJOR" =~ ^[0-9]+$ ]] || (( KERNEL_MAJOR < 7 )); then
    err "Kernel $KERNEL_RELEASE is too old. halogen-flash-server needs kernel 7.0 or
newer (the read-only GPU registration of the checkpoint is refused on 6.x).
Boot a newer kernel and re-run ./setup.sh."
fi
ok "Kernel $KERNEL_RELEASE (7.0+ required)."

CMDLINE=$(cat /proc/cmdline 2>/dev/null || echo "")
cmdline_has() {
    # Substring match, no pipe — no pipefail/SIGPIPE edge cases.
    [[ "$CMDLINE" == *" $1 "* || "$CMDLINE" == "$1 *" || "$CMDLINE" == *" $1" || "$CMDLINE" == "$1" ]]
}

# The kernel command line halogen-flash-server was measured and shipped on.
# ttm.pages_limit and amdgpu.gttsize are sizes tuned to a 128 GB machine.
EXPECTED_PARAMS=(
    "amd_iommu=off"
    "ttm.pages_limit=32505856"
    "amdgpu.gttsize=126976"
    "amdgpu.vm_update_mode=0"
    "amdgpu.noretry=0"
    "amdgpu.sg_display=0"
)
MISSING_PARAMS=()
for p in "${EXPECTED_PARAMS[@]}"; do
    if ! cmdline_has "$p"; then
        MISSING_PARAMS+=("$p")
    fi
done

info "Kernel params: $(( ${#EXPECTED_PARAMS[@]} - ${#MISSING_PARAMS[@]} ))/${#EXPECTED_PARAMS[@]} of the recommended set are active"
if ((${#MISSING_PARAMS[@]} > 0)); then
    warn "Missing from your boot command line: ${MISSING_PARAMS[*]}"
fi
echo ""

# ── Step 1: Network binding ──────────────────────────────────────────────────
info "=== Step 1: Network binding ==="
echo "  1) localhost — only accessible on this machine"
echo "  2) 0.0.0.0  — accessible over the network"
echo ""
echo "  NOTE: halogen-flash-server has NO authentication — no API key exists"
echo "  in this engine. Anyone on your network can use a 0.0.0.0 server."
echo "  If you choose LAN, protect it another way (firewall rule, VPN, or a"
echo "  reverse proxy with auth in front of the published port)."
echo ""
read -rp "Choice [1]: " net_choice || net_choice=""
net_choice="${net_choice:-1}"

if [[ "$net_choice" == "2" ]]; then
    BIND_HOST="0.0.0.0"
    warn "Network access enabled. This endpoint is UNAUTHENTICATED."
else
    BIND_HOST="127.0.0.1"
    ok "Localhost only. Other machines need an SSH tunnel."
fi

while true; do
    ask_number PORT "Port" "1235"
    if (( 10#$PORT >= 1024 && 10#$PORT <= 65535 )); then
        break
    fi
    echo "  Ports 1-1023 are root ports — this server never uses them." >&2
    echo "  Choose a port between 1024 and 65535." >&2
done
echo ""

# ── Step 2: Kernel params notice ─────────────────────────────────────────────
NEEDS_REBOOT=false
BOOT_INSTRUCTIONS=""
if ((${#MISSING_PARAMS[@]} > 0)); then
    NEEDS_REBOOT=true
    KERNEL_ARGS="${MISSING_PARAMS[*]}"
    # Prefer grubby (Fedora/RHEL family): the recommended tool, works with BLS
    # entries where grub2-mkconfig alone does not propagate kernel args.
    if have grubby; then
        BOOT_INSTRUCTIONS="  # Fedora/RHEL-family: grubby updates all entries (BLS + /etc/kernel/cmdline + grub.cfg)
  sudo grubby --update-kernel=ALL --args='$KERNEL_ARGS'
  sudo reboot"
    elif [[ -d /boot/loader/entries || -f /etc/kernel/cmdline ]]; then
        BOOT_INSTRUCTIONS="  # systemd-boot: add to /etc/kernel/cmdline:
  #   $KERNEL_ARGS
  #
  # Then rebuild and reboot:
  sudo kernel-install add \"\$(uname -r)\" \"/boot/vmlinuz-\$(uname -r)\" \"/boot/initramfs-\$(uname -r).img\"
  sudo reboot"
    elif [[ -f /etc/default/grub ]]; then
        BOOT_INSTRUCTIONS="  # Add to GRUB_CMDLINE_LINUX in /etc/default/grub:
  #   $KERNEL_ARGS
  #
  # Then rebuild and reboot:
  sudo update-grub 2>/dev/null || sudo grub2-mkconfig -o /boot/grub2/grub.cfg
  sudo reboot"
    else
        BOOT_INSTRUCTIONS="  # Add these kernel boot params (method depends on your distro):
  #   $KERNEL_ARGS
  sudo reboot"
    fi
fi

# Offer tuned profile (can be changed at runtime, no reboot needed)
if have tuned-adm; then
    CURRENT_PROFILE=$(tuned-adm active 2>/dev/null | grep -oP 'Current active profile: \K.*' || echo "unknown")
    if [[ "$CURRENT_PROFILE" != "accelerator-performance" ]]; then
        if ask_yes_no 'Set tuned profile to "accelerator-performance"? (Boosts performance)' y; then
            if sudo tuned-adm profile accelerator-performance 2>/dev/null; then
                ok "tuned profile set (no reboot needed)."
            else
                warn "Failed to set tuned profile."
            fi
        fi
    else
        ok "tuned profile already accelerator-performance."
    fi
fi
echo ""

# ── Step 3: Vision (multimodal) ──────────────────────────────────────────────
info "=== Step 3: Vision (multimodal) ==="
echo "  The model reads images when the vision sidecar (0.84 GiB, fetched"
echo "  beside the weights) is loaded. An image costs ~1,000-2,500 tokens of"
echo "  context and 5-25 s of processing depending on resolution."
echo ""
echo "  1) Enable vision"
echo "  2) Disable vision — text only"
read -rp "Choice [1]: " vision_choice || vision_choice=""
vision_choice="${vision_choice:-1}"
if [[ "$vision_choice" == "1" ]]; then
    HALOGEN_VISION_TOWER="1"
    ok "Vision enabled."
else
    HALOGEN_VISION_TOWER=""
    ok "Vision disabled. Text only."
fi
echo ""

# ── Step 4: Concurrency ──────────────────────────────────────────────────────
info "=== Step 4: Concurrency ==="
echo "  Conversations generating at once. Each stream runs at its own speed;"
echo "  more streams trade per-stream speed for admitting more clients."
echo "  Past 8 slots total throughput stops growing."
echo ""
while true; do
    ask_number HALOGEN_KV_SLOTS "Slots" "4"
    if (( 10#$HALOGEN_KV_SLOTS >= 1 && 10#$HALOGEN_KV_SLOTS <= 64 )); then
        if (( 10#$HALOGEN_KV_SLOTS <= 8 )); then
            break
        fi
        echo ""
        warn "More than 8 slots is NOT recommended: past 8 a step takes two"
        warn "forwards and total throughput stops growing — every stream only"
        warn "gets slower. Nothing above 8 is faster in total."
        if ask_yes_no "  Proceed anyway (NOT recommended)?" n; then
            break
        fi
        echo "  Choose a value between 1 and 8." >&2
    else
        echo "  Please choose a number between 1 and 64 (1-8 recommended)." >&2
    fi
done
echo ""

# ── Step 5: Weights location ─────────────────────────────────────────────────
info "=== Step 5: Weights ==="
# The fallback default used when the user asks to choose a different
# directory after the current one turned out not to exist.
DEFAULT_MODELS_DIR="$HOME/halogen-models"
FALLBACK_DEFAULT=false
DIR_ATTEMPTS=0
while true; do
    if [[ "$FALLBACK_DEFAULT" == "true" ]]; then
        THIS_DEFAULT="$DEFAULT_MODELS_DIR"
    else
        THIS_DEFAULT="$MODELS_DIR"
    fi
    echo "  Directory the weights (~118 GiB) are downloaded into on first"
    echo "  ./run.sh. Press Enter for the default ($THIS_DEFAULT)."
    echo "  It must be an absolute path."
    ask MODELS_DIR "Weights directory" "$THIS_DEFAULT"
    FALLBACK_DEFAULT=false
    # Expand a leading ~ the shell does not expand on read input.
    if [[ "${MODELS_DIR:0:1}" == "~" ]]; then
        MODELS_DIR="${MODELS_DIR/#\~/$HOME}"
    fi
    if [[ ! "$MODELS_DIR" = /* ]]; then
        # Bounded retries: an exhausted stdin (Ctrl-D) would otherwise feed
        # the same invalid default forever.
        DIR_ATTEMPTS=$((DIR_ATTEMPTS + 1))
        if (( DIR_ATTEMPTS >= 5 )); then
            err "Too many invalid directory choices. Re-run ./setup.sh."
        fi
        echo "  The weights directory must be an absolute path, got '$MODELS_DIR'." >&2
        continue
    fi
    DIR_ATTEMPTS=0
    if [[ -d "$MODELS_DIR" ]]; then
        break
    fi
    MODELS_DIR_PENDING=true
    echo ""
    echo "  $MODELS_DIR needs to exist for the script to run."
    echo ""
    echo "  1) Yes, create the directory"
    echo "  2) Choose a different directory"
    echo "  3) Exit setup"
    dir_ok=false
    while true; do
        read -rp "Choice [1]: " dir_choice || dir_choice=""
        dir_choice="${dir_choice:-1}"
        case "$dir_choice" in
            1)
                if mkdir -p "$MODELS_DIR"; then
                    ok "Created $MODELS_DIR"
                    MODELS_DIR_PENDING=false
                    dir_ok=true
                else
                    warn "Could not create $MODELS_DIR."
                    warn "The weights directory must exist for the server to run."
                    err "Exiting setup. Create it yourself and re-run ./setup.sh."
                fi
                break
                ;;
            2)
                FALLBACK_DEFAULT=true
                break
                ;;
            3)
                warn "The weights directory ($MODELS_DIR) must exist for the"
                warn "server to run. Create it and re-run ./setup.sh."
                exit 130
                ;;
            *)
                echo "  Please choose 1, 2 or 3." >&2
                ;;
        esac
    done
    if [[ "$dir_ok" == "true" ]]; then
        break
    fi
done

avail="$(disk_avail_gib "$MODELS_DIR" 2>/dev/null)" || avail=""
if [[ -z "$avail" ]]; then
    warn "Could not check free disk space for $MODELS_DIR."
elif (( avail < DISK_MIN_GIB )); then
    err "Only ${avail} GiB free on the disk that holds $MODELS_DIR. The weights
are ~118 GiB and download on first ./run.sh; need at least ${DISK_MIN_GIB} GiB
(${DISK_REC_GIB} GiB recommended)."
elif (( avail < DISK_REC_GIB )); then
    warn "Only ${avail} GiB free. ${DISK_REC_GIB} GiB is recommended so the disk isn't packed full."
    if ! ask_yes_no "  Continue anyway?" n; then
        err "Stopped. config.env was not written. Free some space and re-run ./setup.sh."
    fi
fi

# Query the repo's CURRENT sha256 for the checkpoint. Written into config.env
# so refresh.sh can tell "damaged file" from "upstream shipped a new version".
# Best effort: offline setup leaves it unset (commented) and everything still
# works.
info "Checking the HF repo for the checkpoint's current sha256..."
REMOTE_CK_SHA=""
if REMOTE_CK_SHA="$(hf_remote_sha256 "$CHECKPOINT_FILE")"; then
    ok "Repo lists the checkpoint (sha256 ${REMOTE_CK_SHA:0:12}...)."
else
    warn "Could not fetch the repo's sha256 (offline?). Skipping integrity pinning."
    REMOTE_CK_SHA=""
fi
if [[ "$HALOGEN_VISION_TOWER" == "1" ]]; then
    REMOTE_VISION_SHA=""
    if REMOTE_VISION_SHA="$(hf_remote_sha256 "$VISION_FILE")"; then
        ok "Repo lists the vision sidecar (sha256 ${REMOTE_VISION_SHA:0:12}...)."
    else
        warn "Could not fetch the vision sidecar's sha256. It will be checked at download time."
        REMOTE_VISION_SHA=""
    fi
fi
echo ""

# ── Write config ─────────────────────────────────────────────────────────────
info "=== Writing config ==="

cat > "$CONFIG_FILE" <<CONFIG_EOF
# config.env — Generated by setup.sh on $(date -Iseconds)
# Plain KEY=value data — safe to edit by hand, never executed as code.
# Full-line comments only. Re-running setup.sh overwrites this file.

# Server
BIND_HOST=$BIND_HOST
PORT=$PORT

# Weights
MODELS_DIR=$MODELS_DIR

# Engine
HALOGEN_IMAGE=$DEFAULT_IMAGE
HALOGEN_KV_SLOTS=$HALOGEN_KV_SLOTS
# Reasoning effort for requests that send none (the chat template's own
# default is xhigh, which thinks for hundreds to thousands of tokens).
HALOGEN_REASONING_EFFORT=medium
CONFIG_EOF

if [[ "$HALOGEN_VISION_TOWER" == "1" ]]; then
    echo "HALOGEN_VISION_TOWER=1" >> "$CONFIG_FILE"
fi

# Integrity: the sha256 the HF repo currently lists. refresh.sh compares it
# against the repo again later — a difference means the checkpoint changed
# upstream (or your file is damaged). Unset when the API was unreachable.
if [[ -n "$REMOTE_CK_SHA" ]]; then
    echo "CHECKPOINT_SHA256=$REMOTE_CK_SHA" >> "$CONFIG_FILE"
else
    echo "# CHECKPOINT_SHA256=   # (offline during setup; ./refresh.sh can fill this in)" >> "$CONFIG_FILE"
fi
if [[ "$HALOGEN_VISION_TOWER" == "1" && -n "$REMOTE_VISION_SHA" ]]; then
    echo "VISION_SHA256=$REMOTE_VISION_SHA" >> "$CONFIG_FILE"
fi

cat >> "$CONFIG_FILE" <<CONFIG_EOF

# Advanced (uncomment to override; see docs/how-it-works.md):
# HALOGEN_CTX=262144
# HALOGEN_MODEL_ID=halogen-qwen3.8-flash-next
# HALOGEN_EXTRA_ENV=                    # extra -e KEY=value pairs for run.sh
CONFIG_EOF

ok "Config written to: $CONFIG_FILE"
CONFIG_WRITTEN=true
echo ""

# ── Fetch phase: image + vision sidecar (checkpoint downloads on first run.sh)
info "=== Fetch phase: container image ==="
if podman image exists "$DEFAULT_IMAGE" 2>/dev/null; then
    ok "Image $DEFAULT_IMAGE already present."
else
    if ask_yes_no "  Pull $DEFAULT_IMAGE now?" y; then
        if podman pull "$DEFAULT_IMAGE"; then
            ok "Image pulled."
        else
            warn "Image pull failed. run.sh will pull on first start."
        fi
    else
        echo "  Left for first ./run.sh (it pulls automatically)."
    fi
fi
echo ""

# The engine does NOT fetch the vision sidecar itself — with vision on and
# the file missing it refuses to start. Fetch it here (0.84 GiB, verified
# against the repo's current sha256).
if [[ "$HALOGEN_VISION_TOWER" == "1" ]]; then
    info "=== Fetch phase: vision sidecar ==="
    if [[ -f "$MODELS_DIR/$VISION_FILE" ]]; then
        ok "Vision sidecar already present: $MODELS_DIR/$VISION_FILE"
        if [[ -n "$REMOTE_VISION_SHA" ]]; then
            EXISTING_SHA="$(sha256sum "$MODELS_DIR/$VISION_FILE" 2>/dev/null | cut -d' ' -f1)"
            if [[ "$EXISTING_SHA" != "$REMOTE_VISION_SHA" ]]; then
                warn "The sidecar on disk does not match the repo's current sha256."
                if ask_yes_no "  Re-download it?" y; then
                    hf_fetch_file "$VISION_FILE" "$REMOTE_VISION_SHA" "$MODELS_DIR" || true
                fi
            else
                ok "Vision sidecar matches the repo."
            fi
        fi
    elif [[ -n "$REMOTE_VISION_SHA" ]]; then
        if ask_yes_no "  Download the vision sidecar now (0.84 GiB, verified)?" y; then
            hf_fetch_file "$VISION_FILE" "$REMOTE_VISION_SHA" "$MODELS_DIR" || \
                warn "Vision sidecar download failed. Re-run ./setup.sh or ./refresh.sh later."
        else
            warn "Vision is ON but the sidecar is missing — the server will refuse to start with images enabled."
        fi
    else
        warn "Vision is ON but the sidecar is not on disk and the repo was unreachable."
        echo "  Fetch it before starting: hf download $HF_REPO_ID $VISION_FILE --local-dir $MODELS_DIR"
    fi
    echo ""
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo "============================================"
echo " Setup complete!"
echo "============================================"
echo ""
echo "  Image:      $DEFAULT_IMAGE"
echo "  Weights:    $MODELS_DIR (downloaded on first run, ~118 GiB)"
echo "  Slots:      $HALOGEN_KV_SLOTS"
echo "  Vision:     $([[ "$HALOGEN_VISION_TOWER" == "1" ]] && echo on || echo off)"
echo "  Bind:       $BIND_HOST:$PORT"
if [[ "$BIND_HOST" != "127.0.0.1" ]]; then
echo ""
echo "  WARNING: no authentication. Anyone on your network can use this server."
fi
echo ""
echo "  Start:      ./run.sh"
echo "  Stop:       ./stop.sh"
echo "  Update:     ./refresh.sh   (after git pull)"
echo ""
echo "  First start downloads the weights (~118 GiB, resumes if interrupted)"
echo "  and then takes minutes to load them. Watch ./run.sh's output."
echo ""

if [[ "$NEEDS_REBOOT" == "true" ]]; then
    echo ""
    echo "============================================"
    warn "KERNEL PARAMS NOT YET APPLIED — REBOOT REQUIRED"
    echo "============================================"
    echo ""
    echo "  setup.sh does NOT modify your bootloader."
    echo "  Run these commands manually, then reboot:"
    echo ""
    echo "$BOOT_INSTRUCTIONS"
    echo ""
    echo "  After reboot, verify with:"
    printf '%s\n' "    cat /proc/cmdline | tr ' ' '\\n' | grep -E 'iommu|ttm|amdgpu'"
    echo ""
fi
