# Changelog

All notable changes to this project will be documented in this file.

## 1.1.0-rc.3 - 2026-09-29

- `setup.sh` shows the kernel-param commands beside the check that finds them, in the reboot gate, and in the closing summary, so one reboot covers the kernel, the groups, and the params
- `setup.sh` offers to add the missing params itself (grubby, systemd-boot, or GRUB), backing up the bootloader file and confirming the params landed before reporting success
- `setup.sh` treats a computed checkpoint hash mismatch as conclusive: the size check cannot clear it, and the download replaces the file instead of resuming over it
- a `sha256sum` failure falls back to the size check instead of being reported as a mismatch
- the checkpoint check no longer claims the weights download happens on first `./run.sh`

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
