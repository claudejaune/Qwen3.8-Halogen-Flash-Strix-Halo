# Qwen3.8-Flash-Next on AMD Strix Halo (Halogen Flash Server)

Run Qwen3.8-Flash-Next on a single Strix Halo machine using [Halogen Flash Server](https://github.com/peonist-ai/halogen-flash-server).

No prior experience with running local AI models needed. The scripts guide you through every step.

## Quick start

### Prerequisites

- AMD Strix Halo with 128 GiB RAM
- 130 GiB free disk minimum
- Kernel 7.0 or newer
- `podman`:
  - Fedora 42+: `sudo dnf install -y podman`
  - Ubuntu 24.04/26.04: `sudo apt update && sudo apt install -y podman`
  - Arch: `sudo pacman -S --needed podman`

### Set up and run

Clone the repo and run the setup

```bash
git clone https://github.com/claudejaune/Qwen3.8-Halogen-Flash-Strix-Halo
cd Qwen3.8-Halogen-Flash-Strix-Halo
./setup.sh
```

The setup script will ask you questions and configure your system accordingly. Once configured, just run the server:

```bash
./run.sh
```

This will download the weights on first start (~122 GiB; resumes if interrupted)

To stop the server, press Ctrl-c from the same terminal, or run `./stop.sh`.

## What setup.sh asks you

1. Network binding: `localhost` (default) or LAN — **the engine has no
   authentication**, so a LAN server is open to your whole network. API key support is coming soon.
2. The port to run it on. Non-root ports only (1024-65535)
3. Kernel boot params: prints exact commands if yours need changing (reboot required)
4. Vision on/off
5. Parallel slots (maximum allowed concurrent requests)
6. Weights directory (default `~/models/halogen-models`, preserved across re-runs)

### Updating

From inside the repo, run:

```bash
git pull
./refresh.sh
```

## Documentation

- [docs/how-it-works.md](docs/how-it-works.md) — what run.sh passes to the
  engine, the kernel params, and why there is no API key
- [docs/troubleshooting.md](docs/troubleshooting.md) — out of memory at
  startup, slow long prompts, kernel version, and other problems

## Credits

- Engine and deployment tree:
  [peonist-ai/halogen-flash-server](https://github.com/peonist-ai/halogen-flash-server)

## License

MIT — see [LICENSE](LICENSE). The engine itself is closed source and is not
part of this repo; this tree only deploys it.
