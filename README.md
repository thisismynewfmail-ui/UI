# Bonsai 27B "CRACK" — Prism llama.cpp build & server scripts

Helper scripts to **build** and **serve** the custom
[Prism ML fork of llama.cpp](https://github.com/PrismML-Eng/llama.cpp) with the
native low‑bit (Q1_0 ternary) **Bonsai 27B CRACK** vision‑language GGUF model.

There are two targets:

| Target | Build script | Start script |
|---|---|---|
| Linux Mint / Ubuntu **MATE, x86‑64 PC** | `build_pc.sh` | `start_server_cpu.sh` |
| **8 GB, 64‑bit Raspberry Pi** (aarch64) | `build_pi.sh` | `start_server_pi.sh` |

Both start scripts launch the **OpenAI‑compatible `llama-server`**, bind it to
the **LAN**, stream tokens, forward the model's **embedded GGUF chat template**,
and show an **interactive menu** to enable image/vision support.

---

## 1. Prerequisites (install these first)

The scripts compile a C/C++ project, so you need the standard build tools. The
build scripts will detect what is missing and can install it for you with
`--install-deps`, or you can install it by hand.

### Linux Mint / Ubuntu MATE (PC)

```bash
sudo apt-get update
sudo apt-get install -y build-essential cmake git pkg-config libcurl4-openssl-dev
```

### Raspberry Pi OS (64‑bit) / Ubuntu on Pi

```bash
sudo apt-get update
sudo apt-get install -y build-essential cmake git pkg-config libcurl4-openssl-dev
```

> **A 64‑bit OS is required.** Check with `uname -m` — it must report
> `x86_64` (PC) or `aarch64` (Pi). 32‑bit `armv7l` will not work.

`libcurl4-openssl-dev` is optional (it lets `llama-server` download models by
URL). If you skip it, build with `--no-curl`.

### The model files

The scripts expect the GGUF files in the **`vision_model/`** folder next to the
scripts. Download the language model and (for images) the projector into it:

```
vision_model/
├── Bonsai-27b-1bit-CRACK-Q1_0.gguf          # language model  (default)
└── mmproj-Bonsai-27b-1bit-CRACK-F16.gguf     # vision projector (default, optional)
```

Both filenames are just defaults — override them with `--model` / `--mmproj`
(see below) if your files are named differently (e.g. the `Q2_0` ternary build).

---

## 2. Build

### PC (x86‑64)

```bash
./build_pc.sh                 # auto-detects cores, builds a Release CPU binary
./build_pc.sh --install-deps  # also apt-install any missing build tools
```

### Raspberry Pi (8 GB)

```bash
./build_pi.sh                 # RAM-aware job count so the compile doesn't OOM
./build_pi.sh --install-deps
```

Both scripts clone the Prism fork into `./llama.cpp`, configure a CPU‑only
Release build (`-DGGML_NATIVE=ON` for this CPU's SIMD kernels), compile
`llama-server`, and verify the binary landed at
`llama.cpp/build/bin/llama-server`.

Handy build flags (either script): `--dir <path>`, `--repo <url>`,
`--branch <name>`, `--jobs <N>`, `--update` (git pull first),
`--clean` (fresh build), `--no-curl`. Run with `--help` for the full list.

> **Pi tip:** compiling llama.cpp is memory‑hungry. `build_pi.sh` picks a safe
> job count from your RAM and prints swap‑file instructions if you have little
> swap. If a build is *Killed*, re‑run with `./build_pi.sh --jobs 1`.

---

## 3. Start the server

### PC

```bash
./start_server_cpu.sh
```

### Raspberry Pi

```bash
./start_server_pi.sh
./start_server_pi.sh --low-mem     # ctx 2048 + quantised KV cache, for tight RAM
```

On startup you get a **menu**:

```
Bonsai 27B — select server mode
  1) Text only            — chat / completions, streaming
  2) Text + Image/Vision  — also loads the mmproj projector

Enter choice [1-2] (default 1):
```

Choosing **2** loads `mmproj-Bonsai-27b-1bit-CRACK-F16.gguf` so the model can
see images. To skip the menu, pass `--image` / `--no-image` (or `-y`).

The banner then prints the exact configuration and the URLs to use, e.g.:

```
==> Starting Prism llama.cpp server (CPU)
    Mode        : Text + Image/Vision
    Model       : .../vision_model/Bonsai-27b-1bit-CRACK-Q1_0.gguf
    Projector   : .../vision_model/mmproj-Bonsai-27b-1bit-CRACK-F16.gguf
    Bind        : 0.0.0.0:8080  (open to LAN)
    Context     : 8192 tokens   Threads: 8   Slots: 1
    Sampling    : temp 0.7  top-p 0.95  top-k 20
    Template    : embedded GGUF (jinja)

    Web UI / API : http://192.168.1.50:8080
    OpenAI API   : POST http://192.168.1.50:8080/v1/chat/completions  (set "stream": true ...)
    Health/stats : /health  /props  /metrics
```

While running, `llama-server` shows a live **status display**: model **load
progress** while the weights map in, then **per‑request timing** each time a
call arrives (prompt tokens, generated tokens, and **tokens/second**). Machine
stats are also exposed at **`/metrics`** (Prometheus) and **`/props`**.

---

## 4. Editable server parameters

Every parameter can be set three ways — **edit the defaults at the top of the
script**, **export an environment variable**, or **pass a flag** (flag wins):

```bash
# examples
PORT=9000 ./start_server_cpu.sh
./start_server_cpu.sh --port 9000 --ctx 16384 --threads 6
./start_server_cpu.sh --local                 # bind 127.0.0.1 only (not LAN)
./start_server_cpu.sh --model My-Model.gguf --model-dir /data/models
```

| Setting | Flag | Env var | Default |
|---|---|---|---|
| Model folder | `--model-dir` | `MODEL_DIR` | `./vision_model` |
| Model file | `--model` | `MODEL_FILE` | `Bonsai-27b-1bit-CRACK-Q1_0.gguf` |
| Vision projector | `--mmproj` | `MMPROJ_FILE` | `mmproj-Bonsai-27b-1bit-CRACK-F16.gguf` |
| Open to LAN | `--lan` / `--local` | `OPEN_TO_LAN` | `1` (LAN, binds `0.0.0.0`) |
| Bind address | `--host` | `HOST` | derived from `OPEN_TO_LAN` |
| Port | `--port` | `PORT` | `8080` |
| Context length | `--ctx` | `CTX_SIZE` | `8192` PC / `4096` Pi |
| CPU threads | `--threads` | `THREADS` | all cores |
| GPU layers | `--ngl` | `NGL` | `0` (CPU build) |
| Batch size | `--batch` | `BATCH` | `2048` PC / `512` Pi |
| Parallel slots | `--parallel` | `PARALLEL` | `1` |
| Temperature | `--temp` | `TEMP` | `0.7` |
| Top‑p | `--top-p` | `TOP_P` | `0.95` |
| Top‑k | `--top-k` | `TOP_K` | `20` |
| Reasoning mode | `--reasoning` | `REASONING` | `off` |
| Chat template | `--chat-template` / `--no-jinja` | `USE_JINJA` | embedded GGUF via `--jinja` |
| Image support | `--image` / `--no-image` | `IMAGE_SUPPORT` | ask via menu |
| Extra args | `--extra "<args>"` | `EXTRA_ARGS` | — |

Pi‑only memory flags: `--low-mem`, `--kv-type q8_0`, `--mlock`, `--no-mmap`.

> **Reasoning flag:** the Bonsai model card disables reasoning in every example,
> so the scripts pass `--reasoning off` by default. If your fork build does not
> accept that flag, omit it with `--reasoning ""` (or set `REASONING=""`).

> **Chat template:** by default the scripts pass `--jinja`, which tells
> `llama-server` to use the **chat template embedded in the GGUF** — this is
> what produces the correct role/formatting (and tool‑call handling) over the
> `/v1/chat/completions` endpoint. Override with `--chat-template file.jinja`
> only if you need a custom template.

---

## 5. Testing it

### Web UI

Open the printed URL (e.g. `http://192.168.1.50:8080`) in a browser on any LAN
device.

### Streaming text (OpenAI‑compatible, SSE)

```bash
curl -N http://192.168.1.50:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "bonsai",
    "stream": true,
    "messages": [{"role":"user","content":"Explain quantum computing in simple terms."}]
  }'
```

`-N` disables curl buffering so you see tokens arrive live as `data:` events.

### Image / vision request (server started in mode 2)

```bash
IMG=$(base64 -w0 image.jpg)
curl -N http://192.168.1.50:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "bonsai",
    "stream": true,
    "messages": [{"role":"user","content":[
      {"type":"text","text":"Describe the image precisely."},
      {"type":"image_url","image_url":{"url":"data:image/jpeg;base64,'"$IMG"'"}}
    ]}]
  }'
```

### Health & stats

```bash
curl http://192.168.1.50:8080/health     # {"status":"ok"}
curl http://192.168.1.50:8080/metrics    # Prometheus counters (tokens, timings)
curl http://192.168.1.50:8080/props      # loaded model + chat template info
```

---

## 6. Troubleshooting

| Symptom | Fix |
|---|---|
| `llama-server not found` | Run `./build_pc.sh` (or `./build_pi.sh`) first, or pass `--server-bin <path>`. |
| `Model not found: .../vision_model/...` | Put the `.gguf` in `vision_model/`, or point at it with `--model-dir` / `--model`. |
| Build *Killed* on the Pi | Add swap and retry: `./build_pi.sh --jobs 1` (see the swap hint the script prints). |
| Server errors on `--reasoning off` | `./start_server_*.sh --reasoning ""` to drop the flag. |
| Out of memory loading model on Pi | `./start_server_pi.sh --low-mem` (smaller context + quantised KV cache). |
| Can't reach it from another device | Make sure you're in LAN mode (default), and open the port in the firewall: `sudo ufw allow 8080/tcp`. |
| Portable binary for older/other CPUs | Rebuild with `./build_pc.sh --no-native`. |

---

## Files in this repo

```
build_pc.sh              # build the fork on an x86-64 PC (Mint/Ubuntu MATE)
start_server_cpu.sh      # run the LAN server on the PC
build_pi.sh              # build the fork on an 8 GB 64-bit Raspberry Pi
start_server_pi.sh       # run the LAN server on the Pi
vision_model/            # put the .gguf model + projector here (+ preprocessing configs)
README.md                # this file
README_Huggingface_Model_Card*.md   # upstream model cards (reference)
```
