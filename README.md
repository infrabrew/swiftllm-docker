# SwiftLLM — Docker (Ubuntu & RHEL, NVIDIA GPU, Air-Gap)

Containerized SwiftLLM with **NVIDIA GPU** support, on both **Ubuntu** and
**RHEL/UBI9** bases, designed to be **easy to update** and shippable to
**air-gapped** hosts.

Everything is driven by one wrapper — `swiftllmctl` — plus a `.env` file, so a
release bump is a one-liner and there are no Dockerfiles to hand-edit.

```
docker/
├── Dockerfile.ubuntu          # Ubuntu 22.04 + CUDA 12.4  (builder→runtime→devel)
├── Dockerfile.rhel            # UBI9 (RHEL 9) + CUDA 12.4  (builder→runtime→devel)
├── docker-entrypoint.sh       # env → `swiftllm serve` flags; `rebuild` verb
├── docker-compose.yml         # production GPU service
├── docker-compose.dev.yml     # dynamic dev overlay (bind-mount + fast rebuilds)
├── docker-compose.cpu.yml     # CPU-only overlay (no GPU required)
├── swiftllmctl                # build / up / update / uninstall — the golden path
├── .env.example               # all configuration knobs
└── airgap/
    ├── build-airgap.sh        # make an offline image bundle (connected host)
    └── load-airgap.sh         # install offline (air-gapped host)
```

---

## Contents
1. [Prerequisites](#1-prerequisites)
2. [Install](#2-install)
3. [Ubuntu vs RHEL](#3-ubuntu-vs-rhel)
4. [Update — the "dynamic" part](#4-update--the-dynamic-part)
5. [Uninstall](#5-uninstall)
6. [Air-gapped install / update / uninstall](#6-air-gapped-install--update--uninstall)
7. [Configuration reference](#7-configuration-reference)
8. [Using plain docker compose (no wrapper)](#8-using-plain-docker-compose-no-wrapper)
9. [Training & dataset jobs](#9-training--dataset-jobs-trainer-service)
10. [GPU / CPU notes](#10-gpu--cpu-notes)
11. [Security notes](#11-security-notes)
12. [Troubleshooting](#12-troubleshooting)

---

## 1. Prerequisites

**Build/run host**
- Docker Engine 24+ and **Docker Compose v2** (`docker compose version`).
- For GPU: an NVIDIA driver + the **NVIDIA Container Toolkit**
  (`nvidia-ctk`). Quick check: `docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi`.
- Disk: a GPU build pulls CUDA images + PyTorch (~8–12 GB) and the final image
  is several GB. The first build compiles Rust + CUDA kernels + (optionally)
  `llama-cpp-python` and can take **15–40 minutes**. Subsequent builds are cached.

> No GPU? Use `--cpu` everywhere (smaller, faster build, no driver needed).

---

## 2. Install

```bash
cd docker
cp .env.example .env
# edit .env — at minimum set SWIFTLLM_MODEL (and HF_TOKEN for gated models)

./swiftllmctl build          # build the Ubuntu GPU image (default)
./swiftllmctl up             # start the OpenAI-compatible server (detached)
./swiftllmctl logs -f        # watch it load the model
```

Verify:

```bash
curl http://localhost:8000/health
# {"status":"healthy"}

curl http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"swiftllm","messages":[{"role":"user","content":"Hello!"}]}'
```

One-shot commands (no long-running server) work too:

```bash
./swiftllmctl download -m "Qwen/Qwen2.5-0.5B-Instruct-GGUF:qwen2.5-0.5b-instruct-q4_k_m.gguf"
./swiftllmctl chat     -m "Qwen/Qwen2.5-0.5B-Instruct-GGUF:qwen2.5-0.5b-instruct-q4_k_m.gguf"
./swiftllmctl generate -m <model> -p "Write a haiku about GPUs"
```

Models are stored in the persistent Docker volume **`swiftllm-models`**, so they
survive restarts, updates, and image rebuilds.

---

## 3. Ubuntu vs RHEL

Pick the base with a global flag; everything else is identical.

```bash
./swiftllmctl --ubuntu build && ./swiftllmctl --ubuntu up   # Ubuntu 22.04 (default)
./swiftllmctl --rhel   build && ./swiftllmctl --rhel   up   # RHEL 9 (UBI9)
```

- **Ubuntu** → `nvidia/cuda:12.4.1-*-ubuntu22.04`, Python 3.10.
- **RHEL** → `nvidia/cuda:12.4.1-*-ubi9` (Red Hat UBI9, binary-compatible with
  RHEL 9, freely redistributable, no subscription), Python 3.11.

To make one of them your default without typing the flag, set `SWIFTLLM_OS` in
`.env`. You can run both side by side (they use distinct image tags).

> Building on **entitled RHEL** instead of UBI9? Edit the two `FROM` lines in
> `Dockerfile.rhel` to point at your CUDA-on-RHEL images; nothing else changes.

---

## 4. Update — the "dynamic" part

There are three update paths. Pick the one that matches how you work.

### A) Track the latest source and rebuild (default)
For when this repo is your working copy and you want the newest code.

```bash
./swiftllmctl update
# = git pull (this checkout) → rebuild image → recreate container
```

### B) Pin a published release
Reproducible build straight from GitHub at a tag/branch/commit.

```bash
./swiftllmctl update --ref v2.0.1
# clones infrabrew/swiftllm @ v2.0.1 inside the build and rebuilds
```

You can also set this permanently in `.env` and just `build`:
```ini
SWIFTLLM_GIT_URL=https://github.com/infrabrew/swiftllm
SWIFTLLM_GIT_REF=v2.0.1
```

### C) Dynamic dev loop — edit locally, rebuild in seconds
Bind-mounts your source into the container and caches the Rust/Cargo build, so
you don't rebuild the whole image for a code change.

```bash
./swiftllmctl --dev up                 # start with source bind-mounted
# ...edit any .rs / .py in this repo...
./swiftllmctl --dev rebuild            # maturin rebuild in-place + restart (fast)
```

> **Why it's "dynamic":** the image is fully parameterized (CUDA/Python/torch
> versions, GPU archs, source ref are all build args), and updates never require
> editing a Dockerfile — change `.env` or pass a flag and rebuild. Mode (C)
> additionally skips the image rebuild entirely for day-to-day code changes.

After any update, confirm the version:
```bash
./swiftllmctl version
```

---

## 5. Uninstall

```bash
./swiftllmctl uninstall            # stop + remove container and images
                                   # (KEEPS the swiftllm-models volume)

./swiftllmctl uninstall --purge    # also delete volumes, INCLUDING downloaded models
```

What `--purge` removes: `swiftllm-models`, `swiftllm-target`,
`swiftllm-cargo-registry`, `swiftllm-cargo-git`. Without `--purge`, your models
are preserved so a later reinstall is instant.

Manual equivalent:
```bash
cd docker
docker compose down --remove-orphans
docker image rm -f swiftllm:ubuntu-2.0.0 swiftllm:rhel-2.0.0 swiftllm:dev
docker volume rm swiftllm-models      # only if you want models gone
```

---

## 6. Air-gapped install / update / uninstall

This bundle ships a **fully built image** — nothing is compiled or downloaded on
the target. (That's different from the repo's source-level `airgap-bundle.sh`,
which ships wheels + Rust for an on-host build.)

### Build the bundle (on a connected machine)
```bash
cd docker
./swiftllmctl airgap-save                       # Ubuntu GPU image → tar.gz
./swiftllmctl --rhel airgap-save                # RHEL image
./swiftllmctl --cpu  airgap-save                # CPU-only image
# bundle a model so the target needs nothing else:
./airgap/build-airgap.sh -m "Qwen/Qwen2.5-0.5B-Instruct-GGUF:qwen2.5-0.5b-instruct-q4_k_m.gguf"
```
Produces `swiftllm-docker-airgap-<os>-<arch>.tar.gz` (image + compose + a pinned
`.env` + optional models + an offline installer).

### Install (on the air-gapped host)
```bash
tar xzf swiftllm-docker-airgap-ubuntu-x86_64.tar.gz
cd swiftllm-docker-airgap
./load-airgap.sh                 # docker load + restore models into the volume

cd compose
$EDITOR .env                     # set SWIFTLLM_MODEL if not bundled
./swiftllmctl up                 # starts from the loaded image (never builds/pulls)
curl http://localhost:8000/health
```

### Update (air-gapped)
Updating offline = ship a **new** bundle built on the connected machine, then on
the target:
```bash
./load-airgap.sh                 # loads the newer image (new tag)
cd compose && ./swiftllmctl up   # recreate with the new image
```

### Uninstall (air-gapped)
```bash
cd compose
./swiftllmctl uninstall          # or --purge to drop the model volume too
```

> GPU air-gapped hosts must already have the **NVIDIA Container Toolkit**
> installed offline (vendor RPM/DEB). The CUDA runtime itself is inside the image.

---

## 7. Configuration reference

Set these in `docker/.env`. The entrypoint maps them to the exact `swiftllm
serve` flags; the server reads secrets straight from the environment.

| Variable | Default | Purpose |
|---|---|---|
| `SWIFTLLM_OS` | `ubuntu` | Default base (`ubuntu`/`rhel`) |
| `SWIFTLLM_MODEL` | _(unset)_ | **Required.** HF id, `repo:file.gguf`, or path under `/models` |
| `SWIFTLLM_HOST_PORT` | `8000` | Host port published on the machine |
| `SWIFTLLM_PORT` | `8000` | In-container server port |
| `SWIFTLLM_MODEL_DIR` | `/models` | Model cache (persistent volume) |
| `SWIFTLLM_API_KEY` | _(unset)_ | If set, bearer token required on the API |
| `HF_TOKEN` | _(unset)_ | HuggingFace token for gated/private models |
| `SWIFTLLM_TENSOR_PARALLEL_SIZE` | _(unset)_ | Multi-GPU tensor parallelism |
| `SWIFTLLM_GPU_MEMORY_UTILIZATION` | _(unset)_ | e.g. `0.90` |
| `SWIFTLLM_MAX_MODEL_LEN` | _(unset)_ | Context length cap |
| `SWIFTLLM_QUANTIZATION` | _(unset)_ | e.g. `awq`, `gptq` |
| `SWIFTLLM_DTYPE` | _(unset)_ | e.g. `float16`, `bfloat16` |
| `SWIFTLLM_TRUST_REMOTE_CODE` | _(unset)_ | `1` to allow custom model code |
| `SWIFTLLM_ENABLE_PREFIX_CACHING` | _(unset)_ | `1` to enable |
| `SWIFTLLM_SERVE_ARGS` | _(unset)_ | Raw extra flags appended to `serve` |
| `NVIDIA_VISIBLE_DEVICES` | `all` | GPUs visible to the container (`all` or `0,1`) |

**Build-time** (rebuild to apply): `CUDA_VERSION`, `UBUNTU_VERSION`,
`UBI_VERSION`, `PYTHON_VERSION`, `SWIFTLLM_FEATURES` (`cuda`/`cpu`),
`CUDA_ARCHITECTURES`, `BUILD_LLAMA`, `RUST_VERSION`, `TORCH_INDEX_URL`,
`TORCH_SPEC`, `SWIFTLLM_UID`/`SWIFTLLM_GID`, `SWIFTLLM_GIT_URL`/`SWIFTLLM_GIT_REF`.

The full `SWIFTLLM_*` runtime surface (LoRA, speculative decoding, schedulers,
RLM/Dense-Verification, SSL, CORS, …) is documented in the main project README;
add any of them to the `environment:` block or pass via `SWIFTLLM_SERVE_ARGS`.

---

## 8. Using plain docker compose (no wrapper)

`swiftllmctl` just orchestrates these:

```bash
cd docker
# Ubuntu GPU
docker compose up -d --build
# RHEL
SWIFTLLM_DOCKERFILE=docker/Dockerfile.rhel SWIFTLLM_IMAGE=swiftllm:rhel-2.0.0 \
  PYTHON_VERSION=3.11 docker compose up -d --build
# CPU
docker compose -f docker-compose.yml -f docker-compose.cpu.yml up -d --build
# Dynamic dev
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build
docker compose -f docker-compose.yml -f docker-compose.dev.yml exec swiftllm rebuild
```

---

## 9. Training & dataset jobs (`trainer` service)

> ⚠️ **swiftllm's training backend is currently a simulated stub.** The
> `train` / `finetune` / `grpo` commands run the CLI, config, logging and
> checkpoint plumbing but do **not** load weights or compute gradients
> (`Trainer.train()` is marked `[SIMULATED]` in
> [`python/swiftllm/training.py`](../python/swiftllm/training.py)). Dataset
> **ingestion** (`swiftllm dataset …`) is real. The rest of this section is the
> Docker mechanics for running these jobs.

Training is a **one-shot job**, not the long-running server, so the tool is
`docker compose run` (which overrides the service's default `serve` command).

**A. Quick — reuse the existing `swiftllm` service**
```bash
cd docker
# datasets in ./data ; write checkpoints to /models (persistent volume)
docker compose run --rm -v "$PWD/data:/data" swiftllm \
  swiftllm train -m <model> --train-data /data/train.jsonl -o /models/runs/exp1
```
`run` replaces `serve` with your command and reuses the image, env, GPU and the
`swiftllm-models` volume; `--rm` removes the one-off container on exit.

**B. Repeatable — the dedicated `trainer` service** (behind the `train` profile,
so a plain `docker compose up` never starts it):
```bash
cd docker
# datasets go in ./data  (or set SWIFTLLM_DATA_HOST=/abs/path in .env)
docker compose run --rm trainer \
  swiftllm train -m <model> --train-data /data/train.jsonl -o /models/runs/exp1
docker compose run --rm trainer swiftllm dataset --help      # ingestion (real)
```
…or via the wrapper, which targets the same service:
```bash
./swiftllmctl train   -m <model> --train-data /data/train.jsonl -o /models/runs/exp1
./swiftllmctl dataset --help
```

**Notes**
- **Build the image first** (`./swiftllmctl build` or `docker compose up -d --build`) —
  the `trainer` service reuses that image; it has no build block of its own.
- **GPU on `run`:** current Docker Compose attaches the service's reserved GPUs to
  `run` containers. If `nvidia-smi` shows nothing inside, add `--gpus all`
  (e.g. `docker compose run --rm --gpus all trainer …`).
- **Where to write output:** the container runs as a non-root user (uid 1000) that
  owns `/models`, so write checkpoints under `/models/...`. `/data` is your host
  dir — to write there too, make it writable by uid 1000 (or set
  `SWIFTLLM_UID`/`SWIFTLLM_GID` at build time to match your host user).
- **Multi-GPU:** pass `-tp <N>` or set `SWIFTLLM_TENSOR_PARALLEL_SIZE`.

---

## 10. GPU / CPU notes

- **GPU is the default.** `docker-compose.yml` reserves all NVIDIA GPUs and the
  CUDA runtime ships inside the image. Limit GPUs with
  `NVIDIA_VISIBLE_DEVICES=0,1` in `.env`.
- **GPU architectures** built for the GGUF/CUDA backend: `80;86;89;90`
  (A100, RTX 30xx, RTX 40xx/L4, H100). **Blackwell / RTX 50 (sm_120)** needs
  CUDA 13+ (and a `cudarc` bump in the Rust crate), so it is intentionally not
  built here. To try it: set `CUDA_VERSION=13.x.x` and
  `CUDA_ARCHITECTURES=80;86;89;90;120`, then rebuild.
- **CPU mode** (`--cpu`) builds with `SWIFTLLM_FEATURES=cpu` and CPU PyTorch, and
  drops the GPU reservation — runs anywhere, no driver needed.

---

## 11. Security notes

- The image runs as a **non-root** user (`swiftllm`, uid/gid `1000` — override
  with `SWIFTLLM_UID`/`SWIFTLLM_GID` to match a bind-mount owner).
- If you expose the port beyond localhost, **set `SWIFTLLM_API_KEY`**. The server
  then requires `Authorization: Bearer <key>`. The key is passed via environment,
  never on the command line (so it won't show up in `ps`).
- `SWIFTLLM_HOST` defaults to `0.0.0.0` *inside* the container; control real
  exposure with the host port mapping (`SWIFTLLM_HOST_PORT`) and your firewall.
- Secrets (`.env`, `*.key`, `*.pem`) are excluded from the build context by
  `.dockerignore`.

---

## 12. Troubleshooting

| Symptom | Fix |
|---|---|
| `could not select device driver "nvidia"` | Install the NVIDIA Container Toolkit; or run with `--cpu`. |
| `no model specified` on startup | Set `SWIFTLLM_MODEL` in `.env` (or `serve -m <model>`). |
| Health check stuck `starting` | Large models take a while to load — the check has a 180s grace; watch `logs -f`. |
| Gated model 401/403 | Set `HF_TOKEN` in `.env`. |
| Slow first build | Expected (Rust + CUDA + torch). Set `BUILD_LLAMA=0` to skip the GGUF CUDA compile, or `--cpu` for a fast build. |
| Bind-mount permission denied (dev) | Set `SWIFTLLM_UID`/`SWIFTLLM_GID` to your `id -u`/`id -g` and rebuild. |
| Out of GPU memory | Lower `SWIFTLLM_GPU_MEMORY_UTILIZATION` (e.g. `0.80`) or `SWIFTLLM_MAX_MODEL_LEN`. |

---

*Apache-2.0 · part of [infrabrew/swiftllm](https://github.com/infrabrew/swiftllm)*
