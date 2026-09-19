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
4. **Questions** — network binding, port, vision, slots, optional KV pool
5. **Disk check** — the weights are ~118 GiB and download on first `run.sh`;
   the fetch refuses nothing itself, so setup warns under 130 GiB free and
   stops under 120 GiB
6. **Write config.env** — before anything is downloaded
7. **Image pull** — offers to `podman pull` now, or leaves it to `run.sh`

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
HALOGEN_REASONING_EFFORT=low ./run.sh
```

```bash
# Server
BIND_HOST=127.0.0.1
PORT=1235

# Engine
HALOGEN_IMAGE=ghcr.io/peonist-ai/halogen-flash-server:0.11.5
HALOGEN_KV_SLOTS=4
HALOGEN_REASONING_EFFORT=medium
HALOGEN_VISION_TOWER=1
```

| Variable | Default | Meaning |
|---|---|---|
| `BIND_HOST` | `127.0.0.1` | `127.0.0.1` publishes the API on host loopback only; `0.0.0.0` publishes on all interfaces. **No API key exists in this engine** — a LAN server is unauthenticated. |
| `PORT` | `1235` | Host port; mapped to the container's fixed API port 8731 (`-p 127.0.0.1:$PORT:8731`). |
| `HALOGEN_IMAGE` | set by setup | The image (and tag) run.sh starts. One pinned tag; change it via `./refresh.sh`. |
| `HALOGEN_KV_SLOTS` | `4` | Conversations generating at once. Each stream runs at its own speed; past 8 total throughput stops growing. |
| `HALOGEN_KV_POOL_POSITIONS` | *(unset = image default)* | The memory knob: KV positions resident across all conversations (~29.5 KiB each). The image default is 2x the native context and the server lowers it itself if it will not fit. `262144` is the small layout. |
| `HALOGEN_VISION_TOWER` | *(unset = off)* | `1` loads the vision sidecar beside the checkpoint and enables image input on `/v1/chat/completions` and `/v1/responses`. |
| `HALOGEN_REASONING_EFFORT` | `medium` (set by setup) | Reasoning effort for a request that names none: `minimal`, `low`, `medium`, `high` or `xhigh`. Unset, the engine uses the chat template's own `xhigh`, which thinks for hundreds to thousands of tokens on an agentic prompt — that spend comes out of the request's token budget. A request that sends `reasoning_effort` wins; the environment overrides config.env for a single start (`HALOGEN_REASONING_EFFORT=low ./run.sh`); `/health` reports the effective default. |
| `HALOGEN_CTX` | *(unset = 262144)* | Advanced: the most context ONE request may use. The native context is the default; there is normally no reason to set this. |
| `HALOGEN_MODEL_ID` | *(unset)* | Advanced: the model id at `/v1/models`. A label; useful to run two stacks on one host. |
| `HALOGEN_EXTRA_ENV` | *(unset)* | Advanced: space-separated `KEY=value` pairs passed as extra `-e` arguments, for any `HALOGEN_*` variable this repo does not name (e.g. `HALOGEN_TEMPERATURE=1.0 HALOGEN_TOP_P=0.95 HALOGEN_TOP_K=20` for the model card's sampling settings). |

## What run.sh starts

The assembled command, with defaults filled in:

```bash
podman run --rm --name halogen-flash \
  --device /dev/kfd --device /dev/dri \
  --group-add keep-groups \
  --ipc=host \
  --ulimit memlock=-1:-1 \
  -p 127.0.0.1:1235:8731 \
  -e HALOGEN_DOWNLOAD=peonist-ai/halogen-qwen3.8-flash-next \
  -e HALOGEN_KV_SLOTS=4 \
  [-e HALOGEN_VISION_TOWER=1] \
  [-e HALOGEN_KV_POOL_POSITIONS=...] \
  -v ~/halogen-models:/models \
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
levers, in order: fewer concurrent needs (`HALOGEN_KV_POOL_POSITIONS`),
fewer slots, or a machine of its own. `HALOGEN_FLASH_PIN_TRUNK=0` gives
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

## Container updates

After `git pull`, `./refresh.sh`:

1. Offers to change the pinned image tag in `config.env` (backed up to
   `backups/` first)
2. Offers to `podman pull` the image
3. Checks the checkpoint is where first run expects it

Engine updates are just a new tag: `./stop.sh && ./run.sh` picks the image
up. Weights are never re-fetched for a new tag.
