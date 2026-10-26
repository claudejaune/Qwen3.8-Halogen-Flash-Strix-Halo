# Changelog

All notable changes to this project will be documented in this file.

## 1.3.0 - 2026-10-26

- `refresh.sh` offers to delete older Halogen Flash versions and says how much space they'll free up
- If nothing changed after a refresh, the script ends with "Refresh finished: No changes"
- Removed redundant `"Pull the <version number> image now?"` confirmation when refreshing to a new Halogen Flash version

## 1.2.2 - 2026-10-26

- Pin the default Halogen Flash version to 0.18.16 in `setup.sh` and `refresh.sh`
- Running `refresh.sh --image latest` specifies the exact version pulled instead of just "latest"
- `refresh.sh --image <older version>` now asks for confirmation

## 1.2.1 - 2026-10-15

- Pin the default Halogen Flash version to 0.18.5 in `setup.sh` and `refresh.sh`

## 1.2.0-rc.1 - 2026-10-13

- `setup.sh`, `refresh.sh`, and `run.sh` use the Qwen 3.8 Flash v2 checkpoint by default and ship the Halogen engine through 0.17.4
- `setup.sh` and `refresh.sh` can migrate an existing w4b installation to v2 with confirmation and a resumable download; they leave w4b alone when both quant versions are present unless you choose to delete it
- The scripts detect missing, incomplete, or damaged model files and offer to download or resume the correct files instead of leaving the deployment apparently ready
- `setup.sh` and `refresh.sh` can configure an API key, preserve an existing key across setup reruns, and pass it through to Halogen Server
- `setup.sh` backs up the existing `config.env` before rewriting it, and refresh configuration updates create backups
- Model selection, integrity pins, and downloads follow the checkpoint selected in `config.env`, so older installations and v2 installations are checked against the correct files
- The update flow stops Halogen Flash before removing model files and reports whether the deployment is ready after refresh

## 1.1.0-rc.4 - 2026-09-29

- `setup.sh` and `run.sh` no longer hash the checkpoint: a download is covered by the exact-size check and the downloader's own verification, and `./refresh.sh --verify` hashes an existing file on request
- `file_sha256` returns an empty string when a file cannot be hashed instead of aborting its caller under `set -o pipefail`, which made setup exit silently mid-run
- the kernel-param prompt shows only the bootloader command, says setup does not reboot for you, and drops "run it once"; the manual path adds the reboot

## 1.1.0-rc.3 - 2026-09-29

- `setup.sh` shows the kernel-param commands beside the check that finds them, in the reboot gate, and in the closing summary, so one reboot covers the kernel, the groups, and the params
- `setup.sh` offers to add the missing params itself (grubby, systemd-boot, or GRUB), backing up the bootloader file and confirming the params landed before reporting success
- `setup.sh` treats a computed checkpoint hash mismatch as conclusive: the size check cannot clear it, and the download replaces the file instead of resuming over it
- a `sha256sum` failure falls back to the size check instead of being reported as a mismatch
- the checkpoint check no longer claims the weights download happens on first `./run.sh`
- the weights report gives sizes in GiB instead of raw bytes

## 1.1.0-rc.2 - 2026-09-29

- `setup.sh` adds `python3` to the tools it checks and installs on every distro; it reads the weights repo's sha256 and size list (Arch's package is `python`)
- `config.env` is written owner-only (0600) because it can hold `HF_TOKEN`

## 1.1.0-rc.1 - 2026-09-28

Major additions. The scripts are now tuned so that a user with a fresh Ubuntu 24.04, Fedora 44, or Arch install can run `setup.sh` and get *everything* they need to run Qwen 3.8 Flash through Halogen Server

- `setup.sh` checks `git`, `curl`, `podman`, and `tuned` on every distro and installs any that are missing in one step
- A missing `sudo` stops setup and hands over the exact commands to set it up
- On Ubuntu, setup offers to install the HWE kernel to reach kernel 7.0
- A new kernel and new GPU group memberships now need one reboot instead of two
- Downloads fall back to `uvx hf` when the host has no `hf` CLI

## 1.0.0-rc.4 - 2026-09-24

- `refresh.sh` asks nothing when everything is up to date
- `--image` sets a version and `--verify` runs a check

## 1.0.0-rc.3 - 2026-09-23

- Cleaned up `refresh.sh` phrasing
- Removed the superfluous confirmation prompt in `refresh.sh`

## 1.0.0-rc.2 - 2026-09-23

- Bumped Halogen version to 0.13.5
- `refresh.sh` updates `config.env` to the recommended engine version, with a backup

## 1.0.0-rc.1 - 2026-09-23

Ready to release in the wild
