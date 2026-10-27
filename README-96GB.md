# Qwen3.8-Flash-Next on 96 GB Strix Halo

> These instructions apply to the 96 GB Strix Halo. For the 128 GB version, see [README.md](README.md).

These instructions use the experimental `strix-halo-96gb` branch. Setup detects the 96 GB machine and uses the smaller `ht43` model automatically.

## Quick start

### Prerequisites

- AMD Strix Halo with 96 GB RAM
- 120 GiB free disk minimum
- `podman`, `python3`, Kernel 7.0 or newer (handled by script if missing)
- Arch Linux specific: `sudo` installed and configured (missing in minimal install)

### Switch to the 96 GB branch

```bash
git clone https://github.com/claudejaune/Qwen3.8-Halogen-Flash-Strix-Halo
cd Qwen3.8-Halogen-Flash-Strix-Halo
git switch strix-halo-96gb
```

### Set up and run

```bash
./setup.sh
```

Setup prints `Machine: 96 GB Strix Halo` and `Model: 96 GB model (ht43)`. It asks you questions, configures your system accordingly, and downloads the weights (~102 GiB; resumes if interrupted). Once configured, just run the server:

```bash
./run.sh
```

To stop the server, press Ctrl-C from the same terminal, or run `./stop.sh`.

### What setup.sh asks you

- Network binding: `localhost` (default) or all interfaces (0.0.0.0)
- The port to run it on
- Vision on/off
- Parallel slots (maximum allowed concurrent requests)
- Weights directory (default `~/models/halogen-models`, preserved across re-runs)
- Optimized kernel boot params: offered when missing

### Updating

From inside the repo, run:

```bash
git pull
./refresh.sh
```

Offers to stop the server and guides you through the rest of the process.

#### Updating to a specific version

To update to a specific Halogen Flash version (e.g., to try versions newer than the pinned ones or roll back to an older version in case of a regression), run:

```bash
git pull
./refresh.sh --image 0.18.16
```

You can also pull the latest Halogen Flash version offered by upstream:

```bash
git pull
./refresh.sh --image latest
```

### To return to the main branch

```bash
git switch main
```

## Using with coding agents (Pi, OpenCode, etc)

Point your harness to the IP address, port (`http://127.0.0.1:8731/v1` by default), and API key you chose, or tell your agent to add it to your harness' models list. It should then appear as `Halogen Qwen 3.8 Flash` (or whatever you named it) in your list.
