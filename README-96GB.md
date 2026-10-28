# Qwen3.8-Flash-Next on 96 GB Strix Halo

EN | [日本語](#日本語)

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
./refresh.sh --image 0.18.17
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

---

## 日本語

> この手順は 96 GB 版の Strix Halo 向けです。128 GB 版は [README.md](README.md) を参照してください。

この手順では実験用の `strix-halo-96gb` ブランチを使用します。セットアップは 96 GB のマシンを検出し、自動的に小さい方の `ht43` モデルを選択します。

## クイックスタート

### 前提条件

- AMD Strix Halo（96 GB RAM）
- 空きディスク 120 GiB 以上
- `podman`、`python3`、Kernel 7.0 以降（不足している場合はスクリプトが対処します）
- Arch Linux の場合: `sudo` がインストールされ、設定済みであること（最小構成では未インストール）

### 96 GB ブランチに切り替える

```bash
git clone https://github.com/claudejaune/Qwen3.8-Halogen-Flash-Strix-Halo
cd Qwen3.8-Halogen-Flash-Strix-Halo
git switch strix-halo-96gb
```

### セットアップと実行

```bash
./setup.sh
```

セットアップは `Machine: 96 GB Strix Halo` と `Model: 96 GB model (ht43)` を表示します。いくつかの質問をし、システムを設定し、モデル（約 102 GiB。中断しても再開できます）をダウンロードします。設定が完了したら、サーバーを起動します。

```bash
./run.sh
```

サーバーを停止するには、同じターミナルで Ctrl-C を押すか、`./stop.sh` を実行します。

### setup.sh が尋ねる内容

- ネットワークバインディング: `localhost`（既定）またはすべてのインターフェース（0.0.0.0）
- 使用するポート
- ビジョンのオン/オフ
- 並列スロット数（同時に処理できるリクエストの最大数）
- モデルの保存先ディレクトリ（既定: `~/models/halogen-models`。再実行しても保持されます）
- 最適化されたカーネル起動パラメーター: 不足している場合に追加を提案

### 更新

リポジトリ内で次を実行します。

```bash
git pull
./refresh.sh
```

サーバーを停止するかどうかを確認し、残りの手順を案内します。

#### 特定のバージョンに更新する

特定の Halogen Flash バージョンに更新する場合（ピン留めされたバージョンより新しいものを試す、またはリグレッション時に古いバージョンに戻すなど）は、次を実行します。

```bash
git pull
./refresh.sh --image 0.18.17
```

上流が提供する最新の Halogen Flash バージョンを取得することもできます。

```bash
git pull
./refresh.sh --image latest
```

### メインブランチに戻る

```bash
git switch main
```

## コーディングエージェントで使う（Pi、OpenCode など）

ハーネスに IP アドレス、ポート（既定では `http://127.0.0.1:8731/v1`）、選択した API キーを設定するか、エージェントにハーネスのモデル一覧へ追加するよう指示してください。モデル一覧に `Halogen Qwen 3.8 Flash`（名前を変えた場合はその名前）として表示されます。
