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

DEFAULT_IMAGE="ghcr.io/peonist-ai/halogen-flash-server:0.11.5"
MODELS_DIR="$HOME/halogen-models"
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

ask_number PORT "Port" "1235"
if (( 10#$PORT < 1 || 10#$PORT > 65535 )); then
    err "Port must be between 1 and 65535."
fi
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
        if ask_yes_no "Set tuned profile to accelerator-performance?" y; then
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
ask_number HALOGEN_KV_SLOTS "Slots" "4"
if (( 10#$HALOGEN_KV_SLOTS < 1 || 10#$HALOGEN_KV_SLOTS > 64 )); then
    err "Slots must be between 1 and 64."
fi
echo ""
echo "  The KV pool is the memory knob: positions resident across all"
echo "  conversations (~29.5 KiB each). Leave empty to use the image default"
echo "  (2x the native 262144-token context, self-sized to the machine)."
echo "  262144 is the small layout if startup ever reports out of memory."
echo ""
ask HALOGEN_KV_POOL_POSITIONS "KV pool positions (empty = default)" ""
if [[ -n "$HALOGEN_KV_POOL_POSITIONS" ]] && \
   ! [[ "$HALOGEN_KV_POOL_POSITIONS" =~ ^[0-9]+$ ]]; then
    err "KV pool positions must be a number or empty."
fi
echo ""

# ── Step 5: Weights location ─────────────────────────────────────────────────
info "=== Step 5: Weights ==="
echo "  Directory the weights (~118 GiB) are downloaded into on first"
echo "  ./run.sh. Press Enter for the default ($MODELS_DIR, the same path the"
echo "  upstream quickstart uses). It must be an absolute path."
ask MODELS_DIR "Weights directory" "$MODELS_DIR"
# Expand a leading ~ the shell does not expand on read input.
if [[ "${MODELS_DIR:0:1}" == "~" ]]; then
    MODELS_DIR="${MODELS_DIR/#\~/$HOME}"
fi
if [[ ! "$MODELS_DIR" = /* ]]; then
    err "The weights directory must be an absolute path, got '$MODELS_DIR'."
fi
if [[ ! -d "$MODELS_DIR" ]]; then
    if ask_yes_no "  Create the weights directory $MODELS_DIR?" y; then
        mkdir -p "$MODELS_DIR"
        ok "Created $MODELS_DIR"
    fi
fi

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
if [[ -n "$HALOGEN_KV_POOL_POSITIONS" ]]; then
    echo "HALOGEN_KV_POOL_POSITIONS=$HALOGEN_KV_POOL_POSITIONS" >> "$CONFIG_FILE"
fi
cat >> "$CONFIG_FILE" <<CONFIG_EOF

# Integrity (optional): sha256 of the checkpoint. Upstream publishes none;
# set it (from the HF page or your own recorded hash) and ./refresh.sh will
# offer to verify. Leave empty to have refresh.sh record one after the fact.
# CHECKPOINT_SHA256=

# Advanced (uncomment to override; see docs/how-it-works.md):
# HALOGEN_CTX=262144
# HALOGEN_MODEL_ID=halogen-qwen3.8-flash-next
# HALOGEN_EXTRA_ENV=                    # extra -e KEY=value pairs for run.sh
CONFIG_EOF

ok "Config written to: $CONFIG_FILE"
echo ""

# ── Fetch phase: container image (weights download on first run.sh) ─────────
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
