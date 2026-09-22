# Troubleshooting

Quick fixes first:

- **Do not use sudo** — `./setup.sh`, `./refresh.sh`, and `./run.sh` must run as your normal user. Rootless podman owns the container; root would write models to `/root/models`.
- **Container name in use** — a previous `./run.sh` left a stopped `halogen-flash` container: `./stop.sh` removes it, then `./run.sh` again.
- **Port in use** — change `PORT` in config.env or stop whatever holds it.
- **Kernel too old** — the engine needs kernel 7.0+. `./setup.sh` refuses to continue on an older running kernel; boot a newer one first.
- **WSL2 is not a supported host.** The engine runs on the amdgpu/KFD stack; the GPU registration is refused there. Boot native Linux on the same hardware.

## GPU not reachable in the container

- Check the host: `ls /dev/kfd /dev/dri` (created by the amdgpu driver).
- Check access, not just groups: your user must be able to open `/dev/kfd`
  read-write and `/dev/dri/render*`. `setup.sh` checks this and offers the fix;
  by hand it is `sudo usermod -aG render,video $USER`, then **reboot** (or log
  out and back in) — group membership is fixed when the session starts, so it
  does not apply to the current terminal (`newgrp` only patches one shell).
  On Fedora and Arch the nodes are world-readable/writable by default, so this
  is usually only an issue on Ubuntu; podman's `--group-add keep-groups`
  forwards your groups into the container.
- If startup dies early with a GPU runtime error, the usual cause is a
  missing `--ipc=host`; `run.sh` always sets it, so this points at a driver
  or permissions problem on the host.

## Vision

- **Images are refused with a 400 naming the flag** — `HALOGEN_VISION_TOWER`
  is not set. Re-run `./setup.sh` and enable vision, or add
  `HALOGEN_VISION_TOWER=1` to config.env by hand.
- **The container exits at startup** — vision is on but
  `qwen38-flash-next-vision.hgn` is missing beside the checkpoint; the engine
  never downloads it. Fixes, in order:
  - `./refresh.sh` — offers to download it (0.84 GiB, sha256-verified against
    the repo's live hash).
  - Re-run `./setup.sh` — it offers the same fetch.
  - By hand: `hf download peonist-ai/halogen-qwen3.8-flash-next qwen38-flash-next-vision.hgn --local-dir ~/models/halogen-models`
- **An `http(s)` image URL is refused by design** — send `data:` URLs or
  bare base64.
- **Check what the running build accepts**: `GET /health` reports whether
  images are accepted and why not.
