# How it works

Details for people who want to know what's actually going on. For the short
version, see the [main README](../README.md).

## The engine

[halogen-flash-server](https://github.com/peonist-ai/halogen-flash-server)
ships as a single prebuilt image,
`ghcr.io/peonist-ai/halogen-flash-server:<version>`. Everything it does is
configured by environment variables read once at startup; the full list with
defaults is its [docs/FLAGS.md](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/FLAGS.md).

One image serves one checkpoint: `qwen38-flash-next-w4b.hgn` (~115 GiB) plus
a 2.4 GiB quality sidecar and a tokenizer, fetched from Hugging Face on the
container's first start (`HALOGEN_DOWNLOAD=peonist-ai/halogen-qwen3.8-flash-next`).
With that variable set and the volume writable, later starts re-fetch nothing
except a stale sidecar; unset, the container opens no outbound connections.

This repo keeps that as the only weight path — there is no GGUF option here.

## What setup.sh does

1. **Podman check** — detects your distro and offers to install `podman` if missing
2. **Kernel check** — the engine needs **kernel 7.0+** (the read-only
   registration of the checkpoint is refused on 6.x); setup refuses to
   continue on an older running kernel
3. **Kernel params** — checks the boot command line against the set halogen
   was measured on and prints grubby/grub/systemd-boot commands if something
   is missing; never modifies the bootloader itself
4. **Questions** — network binding, port, vision, slots
5. **Disk check** — the weights are ~118 GiB and download on first `run.sh`;
   the fetch refuses nothing itself, so setup warns under 130 GiB free and
   stops under 120 GiB
6. **Write config.env** — before anything is downloaded
7. **Image pull** — offers to `podman pull` now, or leaves it to `run.sh`

**Ctrl-C is safe**: setup.sh traps it and says where things stand. Before the
config is written, nothing has changed — run `./setup.sh` again to complete
setup. After it is written, the message says the config was saved and a
re-run of `./setup.sh` is still needed for a complete setup (the fetch
phase's questions are all answered before any download starts).

## config.env reference

`config.env` is a plain `KEY=value` data file that `run.sh` reads. Values are
**data, not code** — they are never evaluated, so a config file can't inject
commands. The loader (`lib/common.sh`) only accepts the keys listed in
`CONFIG_ALLOWED_KEYS` and refuses anything else. Full-line `#` comments and
blank lines are allowed.

**Precedence: environment beats the config file.** Any key that is set in
the shell's environment when a script runs keeps its value instead of what
the config file says — so a one-off start needs no edit:

```bash
HALOGEN_REASONING_EFFORT=medium ./run.sh
```

```bash
# Server
BIND_HOST=127.0.0.1
PORT=8731

# Weights
MODELS_DIR=/home/you/models/halogen-models

# Engine
HALOGEN_IMAGE=ghcr.io/peonist-ai/halogen-flash-server:0.11.5
HALOGEN_KV_SLOTS=4
HALOGEN_VISION_TOWER=1
```

| Variable | Default | Meaning |
|---|---|---|
| `BIND_HOST` | `127.0.0.1` | `127.0.0.1` publishes the API on host loopback only; `0.0.0.0` publishes on all interfaces. **No API key exists in this engine** — a LAN server is unauthenticated. |
| `PORT` | `8731` | Host port; mapped to the container's fixed API port 8731 (`-p 127.0.0.1:$PORT:8731`). The default matches the image's own API port, so host and container agree on one number. |
| `MODELS_DIR` | `~/models/halogen-models` | Where the weights (~118 GiB) live and download into; mounted at `/models` in the container. setup.sh preserves it across re-runs. |
| `CHECKPOINT_SHA256` | *(written by setup)* | The sha256 the HF repo currently lists for the checkpoint, queried live at every setup run. refresh.sh re-queries and compares — a difference means upstream shipped a new version (or your file is damaged). Offline setups leave it commented. |
| `VISION_SHA256` | *(written by setup, vision only)* | Same idea for the vision sidecar. |
| `HALOGEN_IMAGE` | set by setup | The image (and tag) run.sh starts. One pinned tag; change it via `./refresh.sh`. |
| `HALOGEN_KV_SLOTS` | `4` | Conversations generating at once. Each stream runs at its own speed; past 8 total throughput stops growing. |
| `HALOGEN_VISION_TOWER` | *(unset = off)* | `1` loads the vision sidecar beside the checkpoint and enables image input on `/v1/chat/completions` and `/v1/responses`. |
| `HALOGEN_REASONING_EFFORT` | *(unset = the model's own `xhigh`, recommended by the model card)* | Reasoning effort for a request that names none: `minimal`, `low`, `medium`, `high` or `xhigh`. setup.sh leaves it commented in config.env; uncomment it (e.g. `medium` to think less) or override per start (`HALOGEN_REASONING_EFFORT=medium ./run.sh`). A request that sends `reasoning_effort` wins; `/health` reports the effective default. |
| `HALOGEN_CTX` | *(unset = 262144)* | Advanced: the most context ONE request may use. The native context is the default; there is normally no reason to set this. |
| `HALOGEN_MODEL_ID` | *(unset)* | Advanced: the model id at `/v1/models`. A label; useful to run two stacks on one host. |
| `HALOGEN_EXTRA_ENV` | *(unset)* | Advanced: space-separated `KEY=value` pairs passed as extra `-e` arguments, for any `HALOGEN_*` variable this repo does not name (e.g. `HALOGEN_TEMPERATURE=1.0 HALOGEN_TOP_P=0.95 HALOGEN_TOP_K=20` for the model card's sampling settings, or `HALOGEN_KV_POOL_POSITIONS=262144` to shrink the KV pool). |

## What run.sh starts

The assembled command, with defaults filled in:

```bash
podman run --rm --name halogen-flash \
  --device /dev/kfd --device /dev/dri \
  --group-add keep-groups \
  --ipc=host \
  --ulimit memlock=-1:-1 \
  -p 127.0.0.1:8731:8731 \
  -e HALOGEN_DOWNLOAD=peonist-ai/halogen-qwen3.8-flash-next \
  -e HALOGEN_KV_SLOTS=4 \
  [-e HALOGEN_VISION_TOWER=1] \
  [-e HALOGEN_REASONING_EFFORT=...] \
  -v ~/models/halogen-models:/models \
  ghcr.io/peonist-ai/halogen-flash-server:0.11.5
```

- **`--ipc=host` is load-bearing**: without it the GPU runtime dies during
  startup, and no `shm_size` substitutes. This is measured, not folklore —
  see the image's `docker-compose.yml` comments.
- `--group-add keep-groups` is the podman form of being in the `video` and
  `render` groups.
- The engine's own port (8730) is **never published**: its protocol has no
  authentication. Only the API (8731, mapped to `$PORT`) is reachable.
- The models volume is read-**write**: first start downloads into it, and a
  later start re-fetches a stale quality sidecar if it is writable.
- `--name halogen-flash` makes the container findable by `stop.sh` and
  refuses a second run while the first one exists.

## Kernel params

The engine runs on the amdgpu/KFD stack and its memory design depends on it:
the checkpoint is mapped and registered with the GPU in place, never copied.
The command line it was measured and shipped on (128 GB machine):

| Parameter | What it does |
|---|---|
| `amd_iommu=off` | Disables AMD IOMMU. Worth 13-16% of prefill. **Breaks NPU and DMA isolation.** |
| `ttm.pages_limit=32505856` | Max 4 KiB pages the GPU can pin — the ~124 GiB GTT ceiling. **A size, not a constant; tuned to a 128 GB machine.** |
| `amdgpu.gttsize=126976` | GTT size in MiB (~124 GiB), set to match the pages_limit ceiling. |
| `amdgpu.vm_update_mode=0` | All GPU page-table updates in the kernel. |
| `amdgpu.noretry=0` | Retry on page faults (the engine's memory model relies on it). |
| `amdgpu.sg_display=0` | Disables scatter-gather display. |

All of these **require a reboot** — they're read once at boot. `setup.sh`
checks your values and prints the commands to run; it does not modify your
bootloader. Verify after reboot:

```bash
cat /proc/cmdline | tr ' ' '\n' | grep -E 'iommu|ttm|amdgpu'
```

Two more things the engine asks of the host:

- **BIOS UMA carve-out: set it to Auto (its minimum).** A fixed block for the
  iGPU is taken before the kernel boots and never shows up as missing — the
  machine just reports itself smaller. This server does not need it; it
  drives the GPU through GTT.
- **`tuned` profile `accelerator-performance`** (runtime, no reboot) for
  maximum throughput.

## The memory model

Once loaded, this server holds most of a 128 GB host:

- The weights (~68 GiB) are **locked into RAM** and cannot be reclaimed.
- The KV pool is reserved up front (the image default is ~35 GiB).
- The 47.7 GiB lookup table is read through the file cache and never held in
  RAM — which is why `free` and `MemAvailable` **overstate free memory by
  about 68 GiB**, and why a KV pool that leaves under ~10 GiB turns into
  minutes-long stalls that look like a hang.

The startup line `host memory left for everything else` is the truth. The
levers, in order: a smaller KV pool (pass
`HALOGEN_KV_POOL_POSITIONS=262144` through `HALOGEN_EXTRA_ENV`), fewer
slots, or a machine of its own. `HALOGEN_FLASH_PIN_TRUNK=0` gives
memory back and costs several times the decode speed — a last resort.

## What happened to the llama.cpp options

This repo replaces an older llama.cpp setup; the flags that governed it have
either moved into the engine or stopped being choices:

| Old flag/question | What happens now |
|---|---|
| Model choice / quant catalog | One engine, one checkpoint. No choice. |
| Context 128k / 180k / 262k | `HALOGEN_CTX` defaults to the full native 262144; the KV pool, not the context, bounds allocation. |
| PLE table: SSD streaming vs resident | Gone. The lookup table is streamed from disk through the page cache automatically (`HALOGEN_NGRAM_GATHER_THREADS`, `HALOGEN_HOST_RESERVE_GIB` are the levers). |
| MTP speculative decoding on/off + draft model file | The MTP drafter is always on by default (`HALOGEN_DRAFTER_DEFAULT=1`); the draft head ships with the checkpoint. |
| Flash attention / GPU layers / load mode / KV cache quant | No equivalents; the engine manages its own kernels and memory. |
| `--api-key` for LAN access | **No authentication exists in this engine.** Bind to loopback, or protect a LAN server with a firewall/proxy. |

## Weights integrity

The checkpoint is ~115 GiB and the single most expensive thing on disk, so
every layer of this repo checks it:

1. **Live remote hash** (setup and refresh): the repo's tree API
   (`huggingface.co/api/models/…/tree/main`) lists the sha256 of every LFS
   file. `setup.sh` writes the *current* checkpoint hash into config.env as
   `CHECKPOINT_SHA256` — re-running setup always re-queries, so the pin never
   goes stale when the creators ship a new version. `refresh.sh` re-queries
   and compares three ways:
   - **remote ≠ config's pin** → upstream shipped a new version. Hashing the
     local file (a few minutes) tells a stale pin from a stale disk: if the
     local file *is* the new version, config.env is re-pinned and nothing is
     downloaded; if it is not, refresh.sh offers to stop the server and
     delete **only** the checkpoint, its quality overlay, and the vision
     sidecar — `./run.sh` then re-downloads (resumable).
   - **remote ≠ local file** → the file is damaged; delete and re-download.
   - **everything matches** → optionally verify the local file against the
     live hash.
2. **Size sanity check** (always, in `run.sh` and `refresh.sh`): a checkpoint
   far below its ~115 GiB is almost certainly incomplete — flagged without
   any hashing.
3. **Offline fallback**: with the repo unreachable, refresh.sh falls back to
   config's pinned hash, or a hash it recorded once into
   `<MODELS_DIR>/checkpoint.sha256`, or the size check alone.

`VISION_SHA256` works the same way for the vision sidecar (0.84 GiB), which
the engine **never downloads itself** — the container's entrypoint refuses
to start with `HALOGEN_VISION_TOWER=1` and no sidecar file beside the
checkpoint. setup.sh offers to fetch and verify it when you enable vision;
refresh.sh repairs or updates it if it goes missing or stale.

All network steps are best-effort: offline never blocks setup or refresh,
and a sha256 of the big checkpoint is only ever computed after an explicit
yes.

## Container updates

After `git pull`, `./refresh.sh`:

1. Offers to change the pinned image tag in `config.env` (backed up to
   `backups/` first)
2. Offers to `podman pull` the image
3. Checks the checkpoint is where first run expects it

Engine updates are just a new tag: `./stop.sh && ./run.sh` picks the image
up. Weights are never re-fetched for a new tag.
