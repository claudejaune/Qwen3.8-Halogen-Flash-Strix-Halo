# Troubleshooting

Quick fixes first:

- **Do not use sudo** — `./setup.sh`, `./refresh.sh`, and `./run.sh` must run as your normal user. Rootless podman owns the container; root would write models to `/root/models`.
- **Container name in use** — a previous `./run.sh` left a stopped `halogen-flash` container: `./stop.sh` removes it, then `./run.sh` again.
- **Port in use** — change `PORT` in config.env or stop whatever holds it.
- **Kernel too old** — the engine needs kernel 7.0+. `./setup.sh` refuses to continue on an older running kernel; boot a newer one first.
- **WSL2 is not a supported host.** The engine runs on the amdgpu/KFD stack; the GPU registration is refused there. Boot native Linux on the same hardware.

## Out of memory at startup

A start that ends in

```
dmalloc: FAILED requesting 0.750 GiB after 39.703 GiB in 647 allocations (out of memory)
HIP ... out of memory
```

means the KV pool did not fit. **`HALOGEN_KV_SLOTS` will not fix it** — the
slots share one pool and each costs only ~115 MB. The knob is the pool:

```bash
# In config.env:
HALOGEN_KV_POOL_POSITIONS=262144
```

That is the small layout and still serves four conversations. If it still
will not start, add `HALOGEN_MAX_TOK=16384` to `HALOGEN_EXTRA_ENV` in
config.env (gives back ~8.8 GiB for ~9% of prefill speed):

```bash
HALOGEN_EXTRA_ENV=HALOGEN_MAX_TOK=16384
```

By default the server measures the device budget at startup and lowers the
pool itself, printing what it chose — read that line before tuning anything.

## Server starts but crawls on long prompts

Short prompts fine, long prompts collapse to a few tokens per second with
the disk busy: the host is short of file cache, not memory. The model's
47.7 GiB lookup table is read through the page cache and never held in RAM,
so RAM the KV pool takes is RAM that table loses. The levers:

```bash
# In config.env — a smaller pool leaves more file cache:
HALOGEN_KV_POOL_POSITIONS=262144

# Or let the server choose a smaller pool itself:
HALOGEN_EXTRA_ENV=HALOGEN_HOST_RESERVE_GIB=32
```

The log line `lookup table: ... took N s` reports any slow read. If it still
reads tens of seconds, the drive is the limit — make sure the weights are on
a fast NVMe SSD.

## Minutes-long stalls that look like a hang (no crash)

This server holds most of a 128 GB host: weights locked (~68 GiB) plus the
KV pool. If another large process competes for the remainder, allocations
stop to compact memory and everything can freeze for minutes at 100% of one
core with no disk activity. It is not a crash and needs no restart.

- Read the startup line `host memory left for everything else` — and believe
  it over `free`, which overstates free memory by ~68 GiB.
- Give the machine other workloads sparingly, or lower
  `HALOGEN_KV_POOL_POSITIONS`.

## Kernel params not applied

They are read once at boot. After following setup.sh's printed commands and
rebooting, verify:

```bash
cat /proc/cmdline | tr ' ' '\n' | grep -E 'iommu|ttm|amdgpu'
```

`amd_iommu=off` disables the NPU and DMA isolation machine-wide — expected
on a dedicated inference box, a real posture change otherwise.

## GPU not reachable in the container

- Check the host: `ls /dev/kfd /dev/dri` (created by the amdgpu driver).
- Check your groups: `groups` must include `render` and/or `video` (podman's
  `--group-add keep-groups` forwards them into the container).
- If startup dies early with a GPU runtime error, the usual cause is a
  missing `--ipc=host`; `run.sh` always sets it, so this points at a driver
  or permissions problem on the host.

## Vision questions

- **Images are refused with a 400 naming the flag** — `HALOGEN_VISION_TOWER`
  is not set. Re-run `./setup.sh` and enable vision, or add
  `HALOGEN_VISION_TOWER=1` to config.env by hand.
- **An `http(s)` image URL is refused by design** — send `data:` URLs or
  bare base64.
- **Check what the running build accepts**: `GET /health` reports whether
  images are accepted and why not.

## Weights download problems

- First start fetches ~118 GiB into `~/halogen-models`. Interrupted
  transfers resume on the next `./run.sh`.
- A truncated tree fails inside the container before the engine loads —
  delete the incomplete files and run again.
- The 115 GiB checkpoint is never re-fetched for a new image tag; only the
  2.4 GiB sidecar can refresh.
- To fetch the weights yourself instead (container stays offline):
  `hf download peonist-ai/halogen-qwen3.8-flash-next --local-dir ~/halogen-models`

## Slow image processing

One image costs ~5.5 s at 1280x800, ~12 s at 1080p, ~25 s at 1440p. 4K reads
no better than 1440p; the engine downscales to fit. Dense pages are harder
than sparse ones at the same text size — crop if you can.
