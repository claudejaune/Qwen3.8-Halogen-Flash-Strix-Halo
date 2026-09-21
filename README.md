# Qwen3.8-Flash-Next on AMD Strix Halo (halogen-flash-server)

Run Qwen3.8-Flash-Next (180B params, 6B active) on a single Strix Halo machine
with 128 GB unified memory, served by
[halogen-flash-server](https://github.com/peonist-ai/halogen-flash-server) —
a prebuilt OpenAI-compatible container. No local builds.

No prior experience with running local AI models needed. The scripts guide
you through every step.

## Quick start

### Prerequisites

- AMD Strix Halo with 128 GB RAM and **120 GB free disk minimum** (130 GB
  recommended) — the weights are ~118 GiB
- **Kernel 7.0 or newer** (hard requirement of the engine)
- `podman`:
  - Fedora 42+: `sudo dnf install -y podman` (preinstalled on Workstation)
  - Ubuntu 24.04/26.04: `sudo apt install -y podman`
  - Arch: `sudo pacman -S --needed podman`

### Set up and run

```bash
git clone https://github.com/claudejaune/Qwen3.8-Halogen-Flash-Strix-Halo
cd Qwen3.8-Halogen-Flash-Strix-Halo
./setup.sh
./run.sh
```

`run.sh` downloads the weights on first start (~118 GiB, resumes if
interrupted) and loads them for minutes. Later starts are quick.

To stop the server, press Ctrl-c from the same terminal, or run `./stop.sh`.

After `git pull`, update the container image:

```bash
./refresh.sh
```

It also offers a sha256 integrity check of the checkpoint against the
repo's live hash.

You can answer No to every prompt. If the image tag in `config.env` changes,
a timestamped backup is saved under `backups/`.

`refresh.sh` also talks to the HF repo: it re-checks the checkpoint's sha256
against what the repo currently lists, so if the creators ship a new version
it offers to clear the way for a re-download — and it fetches or repairs the
vision sidecar (which the engine never downloads itself).

## What setup.sh asks you

1. Network binding: `localhost` (default) or LAN — **the engine has no
   authentication**, so a LAN server is open to your whole network
2. Kernel boot params: prints exact commands if yours need changing (reboot required)
3. Vision on/off
4. Parallel slots (concurrent requests; above 8 asks for explicit confirmation)
5. Weights directory (default `~/models/halogen-models`, preserved across re-runs)

The port is always a non-root port (1024-65535) — ports 1-1023 are never
offered.

No model choice: this repo serves one engine and one checkpoint. No MTP
question: speculative decoding is always on by default. No storage question:
the 47.7 GiB lookup table is streamed from disk automatically. Reasoning
effort defaults to `medium` for requests that don't ask for a level
(the engine's own default is `xhigh`); a request that sends
`reasoning_effort` always wins, and a per-start override is
`HALOGEN_REASONING_EFFORT=low ./run.sh`.

## Documentation

- [docs/how-it-works.md](docs/how-it-works.md) — what run.sh passes to the
  engine, the kernel params, the memory model, and why there is no API key
- [docs/troubleshooting.md](docs/troubleshooting.md) — out of memory at
  startup, slow long prompts, kernel version, and other problems

## Credits

- Engine and deployment tree:
  [peonist-ai/halogen-flash-server](https://github.com/peonist-ai/halogen-flash-server)
- Script UX patterns (setup/refresh flow, data-only config parsing) from
  [claudejaune/Qwen3.8-Flash-AMD-Strix-Halo](https://github.com/claudejaune/Qwen3.8-Flash-AMD-Strix-Halo)

## License

MIT — see [LICENSE](LICENSE). The engine itself is closed source and is not
part of this repo; this tree only deploys it.
