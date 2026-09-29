#!/usr/bin/env bash
# setup.sh — Interactive onboarding for Qwen3.8-Flash-Next via halogen-flash-server
# on AMD Strix Halo.
# Writes config.env (plain KEY=value data) which run.sh reads. Re-running
# setup.sh overwrites config.env with no backup.
# The engine is halogen-flash-server: a prebuilt container image. No local
# builds. Weights (~122 GiB) are fetched by the container on first start
# (HALOGEN_DOWNLOAD); setup offers the same transfer itself, so a completed
# setup usually means ./run.sh starts a server rather than a download.
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

# The version this repo ships. The single source of truth is in lib/common.sh.
DEFAULT_IMAGE="$HALOGEN_RECOMMENDED_IMAGE"
MODELS_DIR="$HOME/models/halogen-models"
CHECKPOINT_FILE="qwen38-flash-next-w4b.hgn"
VISION_FILE="qwen38-flash-next-vision.hgn"
DISK_MIN_GIB=130

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

# ── Package installs ─────────────────────────────────────────────────────────
# The packages this setup needs carry the same name on all three distros, with
# one exception: Arch names its Python package 'python' (it provides the
# python3 command), where Fedora and Debian/Ubuntu name it 'python3'.
pkg_for_distro() {
    if [[ "$1" == "python3" && "$OS_ID" == "arch" ]]; then
        printf 'python'
    else
        printf '%s' "$1"
    fi
}

pkg_install() {
    case "$OS_ID" in
        fedora)
            sudo dnf install -y "$@" ;;
        ubuntu|debian)
            sudo apt update && sudo apt install -y "$@" ;;
        arch)
            sudo pacman -S --needed "$@" ;;
        *)
            return 1 ;;
    esac
}

# The same command as the user would type it, shown before asking.
pkg_install_display() {
    case "$OS_ID" in
        fedora)
            printf 'sudo dnf install -y %s' "$*" ;;
        ubuntu|debian)
            printf 'sudo apt update && sudo apt install -y %s' "$*" ;;
        arch)
            printf 'sudo pacman -S --needed %s' "$*" ;;
        *)
            printf '(no automatic install for %s)' "$OS_ID" ;;
    esac
}

# sudo is a prerequisite, never something this script configures. Who holds
# privilege, and under what policy, belongs to the owner of the machine.
require_sudo() {
    have sudo && return 0
    echo ""
    warn "'sudo' is not installed, and setup.sh needs it to install packages."
    echo ""
    echo "  Set it up yourself, then re-run ./setup.sh. On Arch, as root:"
    echo ""
    echo "      pacman -S --needed sudo"
    echo "      usermod -aG wheel $TARGET_USER"
    echo "      visudo -f /etc/sudoers.d/wheel      # and add this one line:"
    echo "          %wheel ALL=(ALL:ALL) ALL"
    echo ""
    echo "  Then log out, log back in as $TARGET_USER, and run ./setup.sh again."
    exit 1
}

# Everything setup.sh installs, checked the same way on every distro.
# Format: "<command>:<package>:<what it is for>". The command is what gets
# tested — tuned installs tuned-adm, and tuned-adm is what setup calls.
# pkg_for_distro() translates the package name when the distros differ.
REQUIRED_TOOLS=(
    "git:git:cloning this repo and running ./refresh.sh after a git pull"
    "curl:curl:reading the model repo's sha256 list, and the fallback downloader"
    "python3:python3:reading the model repo's sha256 and size list"
    "podman:podman:running the engine container"
    "tuned-adm:tuned:applying the accelerator-performance profile"
)

echo ""
info "=== Required tools (detected: $OS_LABEL) ==="

TARGET_USER="$(id -un)"
require_sudo

# Set by the GPU group step and the kernel step; read by the reboot gate below.
NEEDS_RELOGIN=false
NEEDS_REBOOT_NOW=false

missing_pkgs=()
for entry in "${REQUIRED_TOOLS[@]}"; do
    cmd="${entry%%:*}"
    rest="${entry#*:}"
    pkg="${rest%%:*}"
    why="${rest#*:}"
    if have "$cmd"; then
        ok "$pkg present"
    else
        printf '  %-8s missing — %s\n' "$pkg" "$why"
        missing_pkgs+=("$(pkg_for_distro "$pkg")")
    fi
done

if ((${#missing_pkgs[@]} > 0)); then
    echo ""
    echo "  Will run: $(pkg_install_display "${missing_pkgs[@]}")"
    if ask_yes_no "  Install these now?" y; then
        pkg_install "${missing_pkgs[@]}" || warn "The package manager reported a failure."
        hash -r 2>/dev/null || true
    fi
fi

# Required means required: re-check rather than trust the install exit code.
still_missing=()
for entry in "${REQUIRED_TOOLS[@]}"; do
    cmd="${entry%%:*}"
    rest="${entry#*:}"
    pkg="${rest%%:*}"
    if ! have "$cmd"; then
        still_missing+=("$pkg")
    fi
done
if ((${#still_missing[@]} > 0)); then
    err "Still missing: ${still_missing[*]}.
setup.sh needs all of them. Install them and re-run ./setup.sh."
fi
ok "All required tools are in place."

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

# ── GPU device access ────────────────────────────────────────────────────────
# The engine opens /dev/kfd and a /dev/dri/render* node. On Fedora and Arch the
# udev default makes those nodes world-readable/writable; on Ubuntu they are
# 0660 root:render, so group membership is the gate. Test actual access rather
# than group membership — it is correct on every distro. AMD's documented fix
# (add both groups) is the remedy, not the test.
info "=== GPU access ==="
RENDER_NODE="$(compgen -G '/dev/dri/renderD*' 2>/dev/null | head -n1 || true)"
GPU_ACCESS_REASON=""
if [[ ! -e /dev/kfd ]]; then
    GPU_ACCESS_REASON="/dev/kfd is missing — the amdgpu/KFD driver isn't loaded."
elif [[ ! -r /dev/kfd || ! -w /dev/kfd ]]; then
    GPU_ACCESS_REASON="/dev/kfd is not readable/writable by your user."
elif [[ -z "$RENDER_NODE" || ! -r "$RENDER_NODE" ]]; then
    GPU_ACCESS_REASON="the GPU render node (/dev/dri/renderD*) is missing or not readable."
fi

if [[ -z "$GPU_ACCESS_REASON" ]]; then
    ok "Your user can access the GPU devices."
else
    warn "GPU access check failed: $GPU_ACCESS_REASON"
    echo "  The engine cannot start without GPU access. The usual cause is group"
    echo "  membership; AMD's documented fix adds both groups (the -a keeps your"
    echo "  existing ones):"
    echo ""
    echo "    sudo usermod -aG render,video $TARGET_USER"
    echo ""
    if have sudo && ask_yes_no "  Run that now?" y; then
        if sudo usermod -aG render,video "$TARGET_USER"; then
            ok "Membership updated — it takes effect in a new session."
            NEEDS_RELOGIN=true
        else
            err "usermod failed. Run it yourself, then re-run ./setup.sh."
        fi
    else
        err "GPU access is required. Add the groups yourself, then re-run ./setup.sh."
    fi
fi
echo ""

CMDLINE=$(cat /proc/cmdline 2>/dev/null || echo "")
cmdline_has() {
    # Substring match, no pipe — no pipefail/SIGPIPE edge cases.
    [[ "$CMDLINE" == *" $1 "* || "$CMDLINE" == "$1 *" || "$CMDLINE" == *" $1" || "$CMDLINE" == "$1" ]]
}

# The kernel command line this repo recommends (validated on a 128 GiB
# Strix Halo). ttm.pages_limit and amdgpu.gttsize are a matched pair —
# pages_limit x 4 KiB = gtts size (120 GiB).
EXPECTED_PARAMS=(
    "amd_iommu=off"
    "ttm.pages_limit=31457280"
    "amdgpu.gttsize=122880"
)
MISSING_PARAMS=()
for p in "${EXPECTED_PARAMS[@]}"; do
    if ! cmdline_has "$p"; then
        MISSING_PARAMS+=("$p")
    fi
done

# The commands that add the missing params, plus the caution that goes with
# touching the bootloader. Built here so the exact commands sit beside the check
# that found the problem, in the reboot gate, and in the final summary.
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
        # The rebuild command and the grub.cfg path differ by family.
        # Debian/Ubuntu: update-grub (from grub2-common), config at
        # /boot/grub/grub.cfg. RPM distros: grub2-mkconfig, config at
        # /boot/grub2/grub.cfg. grubby normally catches the RPM family
        # above; this is the path when it is not installed.
        case "$OS_ID" in
            ubuntu|debian|arch)
                # Arch and Debian/Ubuntu share the grub-mkconfig name and the
                # /boot/grub/grub.cfg location.
                if have update-grub; then
                    GRUB_REBUILD="sudo update-grub"
                else
                    GRUB_REBUILD="sudo grub-mkconfig -o /boot/grub/grub.cfg"
                fi
                ;;
            fedora|rhel|centos|rocky|almalinux)
                GRUB_REBUILD="sudo grub2-mkconfig -o /boot/grub2/grub.cfg"
                ;;
            *)
                if have update-grub; then
                    GRUB_REBUILD="sudo update-grub"
                elif have grub2-mkconfig; then
                    GRUB_REBUILD="sudo grub2-mkconfig -o /boot/grub2/grub.cfg"
                else
                    GRUB_REBUILD="sudo grub-mkconfig -o /boot/grub/grub.cfg"
                fi
                ;;
        esac
        BOOT_INSTRUCTIONS="  # GRUB (/etc/default/grub): one command appends the missing params and
  # rebuilds grub.cfg (it appends — run it once):
  sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"$/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 $KERNEL_ARGS\"/' /etc/default/grub && $GRUB_REBUILD
  sudo reboot"
    else
        BOOT_INSTRUCTIONS="  # Add these kernel boot params (method depends on your distro):
  #   $KERNEL_ARGS
  sudo reboot"
    fi
fi

# The caution belongs with the commands, wherever they are shown.
print_boot_instructions() {
    warn "These commands modify your bootloader options, which is a persistent"
    warn "change that applies at every boot. Consult your distro's documentation"
    warn "if you are unsure."
    echo ""
    echo "$BOOT_INSTRUCTIONS"
}

info "Kernel params: $(( ${#EXPECTED_PARAMS[@]} - ${#MISSING_PARAMS[@]} ))/${#EXPECTED_PARAMS[@]} of the recommended set are active"
if ((${#MISSING_PARAMS[@]} > 0)); then
    warn "Missing from your boot command line: ${MISSING_PARAMS[*]}"
    echo ""
    print_boot_instructions
fi
echo ""
# ── Kernel version ───────────────────────────────────────────────────────────
# Checked after the GPU groups so that one reboot can fix both. Ubuntu gets an
# offer to install the HWE kernel; other distros are told, not installed for.
KERNEL_RELEASE="$(uname -r)"
KERNEL_MAJOR="${KERNEL_RELEASE%%.*}"
KERNEL_TOO_OLD=false
if ! [[ "$KERNEL_MAJOR" =~ ^[0-9]+$ ]] || (( KERNEL_MAJOR < 7 )); then
    KERNEL_TOO_OLD=true
fi

if [[ "$KERNEL_TOO_OLD" == "true" && "$OS_ID" == "ubuntu" ]]; then
    echo ""
    warn "Kernel $KERNEL_RELEASE is too old — the engine needs 7.0 or newer"
    warn "(the read-only GPU registration of the checkpoint is refused on 6.x)."
    echo ""
    echo "  Ubuntu ships 7.0 in the HWE kernel."
    echo "  Will run: sudo apt update && sudo apt install -y linux-generic-hwe-24.04"
    echo ""
    if ask_yes_no "  Install it now?" y; then
        if sudo apt update && sudo apt install -y linux-generic-hwe-24.04; then
            ok "HWE kernel installed."
            NEEDS_REBOOT_NOW=true
        else
            err "The HWE kernel did not install. Install a 7.0+ kernel yourself,
then re-run ./setup.sh."
        fi
    else
        err "Setup cannot continue on kernel $KERNEL_RELEASE. Install a 7.0+
kernel (sudo apt install -y linux-generic-hwe-24.04), reboot into it, then
re-run ./setup.sh."
    fi
elif [[ "$KERNEL_TOO_OLD" == "true" ]]; then
    err "Kernel $KERNEL_RELEASE is too old. halogen-flash-server needs kernel
7.0 or newer (the read-only GPU registration of the checkpoint is refused on
6.x). Boot a newer kernel and re-run ./setup.sh."
else
    ok "Kernel $KERNEL_RELEASE (7.0+ required)."
fi

# ── One reboot covers everything that needs one ──────────────────────────────
# A new kernel and new group membership both land at the same boot, and nothing
# is configured until both are in effect.
if [[ "${NEEDS_REBOOT_NOW}" == "true" || "${NEEDS_RELOGIN}" == "true" ]]; then
    echo ""
    echo "============================================"
    warn "REBOOT REQUIRED — SETUP PAUSED BEFORE ANY CHANGES"
    echo "============================================"
    echo ""
    if [[ "${NEEDS_REBOOT_NOW}" == "true" ]]; then
        echo "  Reboot into the new kernel."
    fi
    if [[ "${NEEDS_RELOGIN}" == "true" ]]; then
        echo "  The render and video groups were added to $TARGET_USER; a reboot"
        echo "  starts a new session where they are in effect."
    fi
    if ((${#MISSING_PARAMS[@]} > 0)); then
        echo ""
        echo "  Also missing from your boot command line:"
        echo "      ${MISSING_PARAMS[*]}"
        echo ""
        echo "  Add them before you reboot:"
        echo ""
        print_boot_instructions
    fi
    echo ""
    echo "  Reboot now, then run ./setup.sh again to finish setup."
    echo ""
    exit 0
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
    ask_number PORT "Port" "8731"
    if (( 10#$PORT >= 1024 && 10#$PORT <= 65535 )); then
        break
    fi
    echo "  Ports 1-1023 are root ports — this server never uses them." >&2
    echo "  Choose a port between 1024 and 65535." >&2
done
echo ""

# Switch to the tuned profile. The package itself is already installed (checked
# up front); this only selects the profile, which takes effect immediately.
CURRENT_PROFILE=$(tuned-adm active 2>/dev/null | grep -oP 'Current active profile: \K.*' || echo "unknown")
if [[ "$CURRENT_PROFILE" != "accelerator-performance" ]]; then
    if ask_yes_no 'Set tuned profile to "accelerator-performance"? (Boosts performance)' y; then
        if sudo tuned-adm profile accelerator-performance 2>/dev/null; then
            ok "tuned profile set (no reboot needed)."
        else
            warn "Failed to set tuned profile. Check 'systemctl status tuned'."
        fi
    fi
else
    ok "tuned profile already accelerator-performance."
fi
echo ""

# ── Step 2: Vision (multimodal) ──────────────────────────────────────────────
info "=== Step 2: Vision (multimodal) ==="
echo "  The model reads images when the vision sidecar (0.84 GiB, fetched"
echo "  beside the weights) is loaded."
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

# ── Step 3: Concurrency ──────────────────────────────────────────────────────
info "=== Step 3: Concurrency ==="
echo "  Maximum simultaneous conversations. 4-8 recommended"
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

# ── Step 4: Weights location ─────────────────────────────────────────────────
info "=== Step 4: Weights ==="
# The fallback default used when the user asks to choose a different
# directory after the current one turned out not to exist.
DEFAULT_MODELS_DIR="$HOME/models/halogen-models"
FALLBACK_DEFAULT=false
DIR_ATTEMPTS=0
while true; do
    if [[ "$FALLBACK_DEFAULT" == "true" ]]; then
        THIS_DEFAULT="$DEFAULT_MODELS_DIR"
    else
        THIS_DEFAULT="$MODELS_DIR"
    fi
    echo "  Directory the weights (~122 GiB) are downloaded into on first"
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

# Query the repo's CURRENT sha256 for the checkpoint FIRST — it decides
# whether an existing checkpoint is usable as-is (no download, so no
# disk-space requirement). Written into config.env so refresh.sh can tell
# "damaged file" from "upstream shipped a new version". Best effort: an
# offline setup leaves it unset (commented) and everything still works.
info "Checking the HF repo for the checkpoint's current sha256..."
REMOTE_CK_SHA=""
if REMOTE_CK_SHA="$(hf_remote_sha256 "$CHECKPOINT_FILE")"; then
    ok "Repo lists the checkpoint (sha256 ${REMOTE_CK_SHA:0:12}...)."
else
    # Exit 2 means curl or python3 is missing, not that the repo is offline.
    case "$?" in
        2) warn "Reading the repo's file list needs python3. Install it and re-run ./setup.sh to pin the checkpoint's sha256." ;;
        *) warn "Could not fetch the repo's sha256 (offline?). Skipping integrity pinning." ;;
    esac
    REMOTE_CK_SHA=""
fi
if [[ "$HALOGEN_VISION_TOWER" == "1" ]]; then
    REMOTE_VISION_SHA=""
    if REMOTE_VISION_SHA="$(hf_remote_sha256 "$VISION_FILE")"; then
        ok "Repo lists the vision sidecar (sha256 ${REMOTE_VISION_SHA:0:12}...)."
    else
        case "$?" in
            2) warn "Reading the repo's file list needs python3. The sidecar is checked at download time." ;;
            *) warn "Could not fetch the vision sidecar's sha256. It will be checked at download time." ;;
        esac
        REMOTE_VISION_SHA=""
    fi
fi
echo ""

# ── Existing checkpoint check ────────────────────────────────────────────────
# A verified-complete checkpoint means ./run.sh downloads nothing, so the
# ~130 GiB free-disk requirement does not apply.
CK_PATH="$MODELS_DIR/$CHECKPOINT_FILE"
CK_NEEDS_DOWNLOAD=true
size_gib() {
    stat -c '%s' "$1" 2>/dev/null | awk '{printf "%.0f", $1 / 1073741824}'
}

if [[ -f "$CK_PATH" ]]; then
    echo "  A checkpoint already exists: $CK_PATH ($(du -sh "$CK_PATH" | cut -f1))"
    if [[ -n "$REMOTE_CK_SHA" ]]; then
        if ask_yes_no "  Verify it against the repo's sha256 (a few minutes)?" y; then
            info "Computing sha256 (a few minutes on NVMe)..."
            LOCAL_SHA="$(sha256sum "$CK_PATH" 2>/dev/null | cut -d' ' -f1)" || LOCAL_SHA=""
            if [[ "$LOCAL_SHA" == "$REMOTE_CK_SHA" ]]; then
                ok "The checkpoint on disk IS the current repo version."
                CK_NEEDS_DOWNLOAD=false
            else
                warn "The file on disk does not match the repo (expected $REMOTE_CK_SHA,"
                warn "got ${LOCAL_SHA:-<hash failed>})."
            fi
        else
            warn "Verification skipped — judging completeness by size alone."
        fi
    fi
    if [[ "$CK_NEEDS_DOWNLOAD" == "true" ]]; then
        CK_GIB="$(size_gib "$CK_PATH")"
        if (( CK_GIB >= 110 )); then
            info "The file is ~${CK_GIB} GiB — treated as complete (unverified)."
            CK_NEEDS_DOWNLOAD=false
        else
            warn "The file is only ~${CK_GIB} GiB (expect ~115) — incomplete."
        fi
    fi
else
    info "No checkpoint on disk yet."
fi
echo ""

# ── Disk-space gate (only when a download is actually needed) ────────────────
if [[ "$CK_NEEDS_DOWNLOAD" == "true" ]]; then
    avail="$(disk_avail_gib "$MODELS_DIR" 2>/dev/null)" || avail=""
    if [[ -z "$avail" ]]; then
        warn "Could not check free disk space for $MODELS_DIR."
    elif (( avail < DISK_MIN_GIB )); then
        err "Only ${avail} GiB free on the disk that holds $MODELS_DIR. The first
./run.sh downloads the weights and sidecars (~122 GiB in all); setup needs at
least ${DISK_MIN_GIB} GiB free. Free some space and re-run ./setup.sh."
    fi
else
    ok "Checkpoint already in place — no download needed, disk-space check skipped."
fi

# ── Write config ─────────────────────────────────────────────────────────────
info "=== Writing config ==="

# config.env is the one file here that can hold a secret (HF_TOKEN), so create
# it owner-only. The appends below keep the mode.
(
umask 077
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
# Reasoning effort for requests that send none. Unset = the model's own
# default (xhigh, recommended by the model card). Uncomment to change:
# HALOGEN_REASONING_EFFORT=medium
CONFIG_EOF
)

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

# ── Fetch phase: image, weights, vision sidecar ──────────────────────────────
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

# setup used to leave the ~122 GiB to the container's first start. It now
# offers the transfer here, with the SAME command the engine runs for
# HALOGEN_DOWNLOAD (hf download <repo> --local-dir), so a tree fetched here is
# exactly the tree the container would have fetched. It resumes if
# interrupted and needs no GPU, so it can run before the kernel-param reboot.
VISION_FLAG=0
if [[ "$HALOGEN_VISION_TOWER" == "1" ]]; then
    VISION_FLAG=1
fi
WEIGHTS_READY=false

info "=== Fetch phase: weights ==="
WEIGHTS_RC=0
WEIGHTS_STATUS="$(weights_check "$MODELS_DIR" "$VISION_FLAG" remote 2>/dev/null)" || WEIGHTS_RC=$?
if (( WEIGHTS_RC == 0 )); then
    WEIGHTS_READY=true
    ok "Weights present and the expected size in $MODELS_DIR."
else
    echo "  The weights are not all in place:"
    while read -r st file detail; do
        case "$st" in
            missing)    echo "    missing:    $file" ;;
            incomplete) echo "    incomplete: $file ($detail)" ;;
        esac
    done <<<"$WEIGHTS_STATUS"
    echo ""
    if [[ "$VISION_FLAG" != "1" ]]; then
        echo "  Vision is off, so its sidecar (0.84 GiB) and the unused speed"
        echo "  overlay and MTP head (~4 GiB) are skipped. Re-run setup with"
        echo "  vision on to fetch the sidecar."
        echo ""
    fi
    if ask_yes_no "  Download the weights now (~122 GiB)?" y; then
        # Re-check space: the gate above ran before the image pull.
        avail="$(disk_avail_gib "$MODELS_DIR" 2>/dev/null)" || avail=""
        if [[ -n "$avail" ]] && (( avail < DISK_MIN_GIB )); then
            warn "Only ${avail} GiB free on the disk that holds $MODELS_DIR."
            warn "Skipping the download. Free space and re-run ./setup.sh."
        elif hf_download_models "$MODELS_DIR" "$DEFAULT_IMAGE" "$VISION_FLAG"; then
            ok "Download finished."
            WEIGHTS_RC=0
            WEIGHTS_STATUS="$(weights_check "$MODELS_DIR" "$VISION_FLAG" remote 2>/dev/null)" || WEIGHTS_RC=$?
            if (( WEIGHTS_RC == 0 )); then
                WEIGHTS_READY=true
                ok "Weights verified: every file is present at the expected size."
                if [[ -n "$REMOTE_CK_SHA" ]] && ask_yes_no "  Compute the checkpoint's sha256 to verify it fully (a few minutes)?" n; then
                    info "Computing sha256 (a few minutes on NVMe)..."
                    LOCAL_SHA="$(file_sha256 "$CK_PATH")"
                    if [[ "$LOCAL_SHA" == "$REMOTE_CK_SHA" ]]; then
                        ok "Checkpoint integrity verified."
                    else
                        warn "CHECKSUM MISMATCH: expected $REMOTE_CK_SHA"
                        warn "                  got ${LOCAL_SHA:-<hash failed>}"
                        warn "Delete $CK_PATH and re-run ./setup.sh to re-download."
                    fi
                fi
            else
                warn "Some files are still missing or the wrong size:"
                while read -r st file detail; do
                    case "$st" in
                        missing)    echo "    missing:    $file" ;;
                        incomplete) echo "    incomplete: $file ($detail)" ;;
                    esac
                done <<<"$WEIGHTS_STATUS"
                warn "Re-run ./setup.sh or ./run.sh — the transfer resumes."
            fi
        else
            warn "The weights download did not finish."
            warn "Re-run ./setup.sh or ./run.sh — the transfer resumes."
        fi
    else
        warn "Skipped. ./run.sh downloads the weights on first start."
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
if [[ "$WEIGHTS_READY" == "true" ]]; then
echo "  Weights:    $MODELS_DIR (ready)"
else
echo "  Weights:    $MODELS_DIR (downloaded on first run, ~122 GiB)"
fi
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
if [[ "$WEIGHTS_READY" == "true" ]]; then
echo "  The weights are in place; ./run.sh loads them (minutes on the first"
echo "  start). Watch its output for progress."
else
echo "  First start downloads the weights (~122 GiB, resumes if interrupted)"
echo "  and then takes minutes to load them. Watch ./run.sh's output."
fi
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
    print_boot_instructions
    echo ""
    echo "  After reboot, verify with:"
    printf '%s\n' "    cat /proc/cmdline | tr ' ' '\\n' | grep -E 'iommu|ttm|amdgpu'"
    echo ""
fi
