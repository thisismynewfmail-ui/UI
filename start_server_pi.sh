#!/usr/bin/env bash
# =============================================================================
# start_server_pi.sh
#
# Launch the Prism llama.cpp server (OpenAI-compatible) for the Bonsai 27B
# "CRACK" GGUF model on an 8 GB, 64-bit Raspberry Pi, exposed on the LAN.
# On startup it shows a small menu to choose Text-only or Text + Image
# (vision) mode.
#
# Defaults here are tuned for the Pi's limited RAM/CPU: a smaller context
# window, memory-mapped weights, and an optional low-memory profile that
# quantises the KV cache.
#
# Every parameter can be edited three ways (later wins):
#   1. Edit the defaults in this file.
#   2. Export an environment variable, e.g.  PORT=9000 ./start_server_pi.sh
#   3. Pass a command-line flag,        e.g.  ./start_server_pi.sh --port 9000
#
# Run  ./start_server_pi.sh --help  for the full option list.
# =============================================================================
set -euo pipefail

# --------------------------------------------------------------------------- #
# Editable defaults  (env vars of the same name override these)
# --------------------------------------------------------------------------- #
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Model files ----------------------------------------------------------- #
MODEL_DIR="${MODEL_DIR:-$SCRIPT_DIR/vision_model}"
MODEL_FILE="${MODEL_FILE:-Bonsai-27b-1bit-CRACK-Q1_0.gguf}"
MMPROJ_FILE="${MMPROJ_FILE:-mmproj-Bonsai-27b-1bit-CRACK-F16.gguf}"

# --- Auto-download (Hugging Face) ------------------------------------------ #
# On an 8 GB Pi the 1-bit prism-ml/Bonsai-27B-gguf build is the recommended fit
# and can be fetched automatically when selected at startup.
HF_REPO="${HF_REPO:-}"               # repo for the language model (auto-resolved if blank)
HF_MMPROJ_REPO="${HF_MMPROJ_REPO:-}" # repo for the projector (defaults to HF_REPO)
HF_ENDPOINT="${HF_ENDPOINT:-https://huggingface.co}"
AUTO_DOWNLOAD="${AUTO_DOWNLOAD:-ask}"  # ask | 1 (always) | 0 (never, error if missing)
MODEL_ID="${MODEL_ID:-}"             # preset id: 'crack' or 'onebit' (see --model-id)
MODEL_SET=0                          # 1 once a model is chosen explicitly (skips the menu)

# --- Network --------------------------------------------------------------- #
OPEN_TO_LAN="${OPEN_TO_LAN:-1}"      # 1 = bind 0.0.0.0 (whole LAN), 0 = 127.0.0.1 only
HOST="${HOST:-}"                     # explicit bind address (overrides OPEN_TO_LAN if set)
PORT="${PORT:-8080}"

# --- Inference / context (Pi-tuned, smaller than the PC defaults) ---------- #
CTX_SIZE="${CTX_SIZE:-4096}"         # context length in tokens (-c)
NGL="${NGL:-0}"                      # GPU layers; 0 for a CPU build
THREADS="${THREADS:-$(nproc 2>/dev/null || echo 4)}"
BATCH="${BATCH:-512}"                # smaller batch keeps prompt-processing RAM down
PARALLEL="${PARALLEL:-1}"

# --- Memory options -------------------------------------------------------- #
USE_MMAP="${USE_MMAP:-1}"            # 1 = mmap weights (recommended on the Pi)
USE_MLOCK="${USE_MLOCK:-0}"          # 1 = lock weights in RAM (only if you have headroom)
CACHE_TYPE_K="${CACHE_TYPE_K:-}"     # e.g. q8_0 / q4_0 to shrink the KV cache (blank = f16)
CACHE_TYPE_V="${CACHE_TYPE_V:-}"
FLASH_ATTN="${FLASH_ATTN:-0}"        # 1 = --flash-attn (needed for quantised V cache)

# --- Sampling defaults (model card: temp 0.7 / top-p 0.95 / top-k 20) ------ #
TEMP="${TEMP:-0.7}"
TOP_P="${TOP_P:-0.95}"
TOP_K="${TOP_K:-20}"

# --- Model behaviour ------------------------------------------------------- #
REASONING="${REASONING:-off}"        # set "" to omit if your fork rejects the flag
USE_JINJA="${USE_JINJA:-1}"          # 1 = --jinja (embedded GGUF chat template)
CHAT_TEMPLATE="${CHAT_TEMPLATE:-}"   # optional path to a .jinja template file

# --- Image / vision support ------------------------------------------------ #
IMAGE_SUPPORT="${IMAGE_SUPPORT:-}"   # blank = ask via menu; 1 = on; 0 = off

# --- Server binary --------------------------------------------------------- #
LLAMA_DIR="${LLAMA_DIR:-$SCRIPT_DIR/llama.cpp}"
SERVER_BIN="${SERVER_BIN:-}"

EXTRA_ARGS="${EXTRA_ARGS:-}"
ASSUME_YES=0

# --------------------------------------------------------------------------- #
# Pretty output helpers
# --------------------------------------------------------------------------- #
if [ -t 1 ]; then
  B=$(tput bold 2>/dev/null || true); N=$(tput sgr0 2>/dev/null || true)
  R=$(tput setaf 1 2>/dev/null || true); G=$(tput setaf 2 2>/dev/null || true)
  Y=$(tput setaf 3 2>/dev/null || true); C=$(tput setaf 6 2>/dev/null || true)
else
  B=""; N=""; R=""; G=""; Y=""; C=""
fi
log()  { printf '%s\n' "${C}==>${N} ${B}$*${N}"; }
ok()   { printf '%s\n' "${G}  ✓${N} $*"; }
warn() { printf '%s\n' "${Y}  ! ${N}$*" >&2; }
die()  { printf '%s\n' "${R}  ✗ ERROR:${N} $*" >&2; exit 1; }

# --------------------------------------------------------------------------- #
# Model catalog + Hugging Face auto-download
# --------------------------------------------------------------------------- #
repo_for_file() {
  case "$1" in
    # CRACK 1-bit build (the local default) — dealign.ai
    Bonsai-27b-1bit-CRACK-Q1_0.gguf|mmproj-Bonsai-27b-1bit-CRACK-F16.gguf)
      echo "dealignai/Bonsai-27b-1bit-CRACK-GGUF" ;;
    # CRACK ternary (Q2_0) build — dealign.ai
    Bonsai-27b-Ternary-CRACK-Q2_0.gguf|mmproj-Bonsai-27b-Ternary-CRACK-F16.gguf)
      echo "dealignai/Bonsai-27b-Ternary-CRACK-GGUF" ;;
    # Prism ML 1-bit build (+ dspark drafter and mmproj packs)
    Bonsai-27B-Q1_0.gguf|Bonsai-27B-F16.gguf|Bonsai-27B-dspark-*.gguf|Bonsai-27B-mmproj-*.gguf)
      echo "prism-ml/Bonsai-27B-gguf" ;;
    *) echo "" ;;
  esac
}

# Apply a named preset. Both CRACK and Prism builds auto-download when selected.
apply_model_id() {
  case "$1" in
    crack|crack-1bit|bonsai-crack)          # dealignai 1-bit CRACK (default)
      MODEL_FILE="Bonsai-27b-1bit-CRACK-Q1_0.gguf"
      MMPROJ_FILE="mmproj-Bonsai-27b-1bit-CRACK-F16.gguf"
      HF_REPO="dealignai/Bonsai-27b-1bit-CRACK-GGUF"
      HF_MMPROJ_REPO="dealignai/Bonsai-27b-1bit-CRACK-GGUF" ;;
    ternary|crack-ternary|q2)               # dealignai ternary (Q2_0) CRACK
      MODEL_FILE="Bonsai-27b-Ternary-CRACK-Q2_0.gguf"
      MMPROJ_FILE="mmproj-Bonsai-27b-Ternary-CRACK-F16.gguf"
      HF_REPO="dealignai/Bonsai-27b-Ternary-CRACK-GGUF"
      HF_MMPROJ_REPO="dealignai/Bonsai-27b-Ternary-CRACK-GGUF" ;;
    onebit|1bit|q1|bonsai-1bit)             # prism-ml 1-bit
      MODEL_FILE="Bonsai-27B-Q1_0.gguf"
      MMPROJ_FILE="Bonsai-27B-mmproj-Q8_0.gguf"
      HF_REPO="prism-ml/Bonsai-27B-gguf"
      HF_MMPROJ_REPO="prism-ml/Bonsai-27B-gguf" ;;
    *) die "Unknown --model-id '$1' (known: crack, ternary, onebit)" ;;
  esac
  MODEL_SET=1
}

fetch_hf() {  # <repo> <filename> <dest_path>
  local repo="$1" file="$2" dest="$3" dir tmp url
  dir="$(dirname "$dest")"; tmp="${dest}.part"
  mkdir -p "$dir"
  url="${HF_ENDPOINT%/}/${repo}/resolve/main/${file}?download=true"
  log "Downloading ${file}"
  printf '    from : %s/%s\n' "${HF_ENDPOINT%/}/${repo}" "$file"
  printf '    to   : %s\n' "$dest"
  if command -v hf >/dev/null 2>&1; then
    hf download "$repo" "$file" --local-dir "$dir" && [ -s "$dest" ] && return 0
  elif command -v huggingface-cli >/dev/null 2>&1; then
    huggingface-cli download "$repo" "$file" --local-dir "$dir" \
      --local-dir-use-symlinks False && [ -s "$dest" ] && return 0
  fi
  if command -v curl >/dev/null 2>&1; then
    local auth=(); [ -n "${HF_TOKEN:-}" ] && auth=( -H "Authorization: Bearer ${HF_TOKEN}" )
    if curl -fL --retry 4 --retry-delay 2 -C - "${auth[@]}" -o "$tmp" "$url" \
       || { rm -f "$tmp"; curl -fL --retry 4 --retry-delay 2 "${auth[@]}" -o "$tmp" "$url"; }; then
      mv -f "$tmp" "$dest"; [ -s "$dest" ] && return 0
    fi
    rm -f "$tmp"
  elif command -v wget >/dev/null 2>&1; then
    local wauth=(); [ -n "${HF_TOKEN:-}" ] && wauth=( --header "Authorization: Bearer ${HF_TOKEN}" )
    if wget -c "${wauth[@]}" -O "$tmp" "$url"; then
      mv -f "$tmp" "$dest"; [ -s "$dest" ] && return 0
    fi
    rm -f "$tmp"
  else
    die "No downloader found — install curl, wget, or the Hugging Face CLI."
  fi
  return 1
}

ensure_file() {  # <local_path> <filename> <repo-hint> <label>
  local dest="$1" file="$2" repo="$3" label="$4"
  if [ -f "$dest" ] && [ -s "$dest" ]; then ok "$label present: $dest"; return 0; fi
  [ -z "$repo" ] && repo="$(repo_for_file "$file")"
  if [ -z "$repo" ]; then
    die "$label not found: $dest
    Unknown Hugging Face repo for '$file' — place it manually, pass --hf-repo <owner/name>,
    or choose the downloadable model with --model-id onebit."
  fi
  case "$AUTO_DOWNLOAD" in
    0) die "$label not found: $dest  (auto-download disabled with --no-download)";;
    1) : ;;
    *) if [ -t 0 ]; then
         local a=""; read -rp "Download $label '$file' (~from $repo) now? [Y/n]: " a || true
         case "$a" in [Nn]*) die "Declined — place $dest manually and re-run." ;; esac
       else
         die "$label not found: $dest  (run interactively or pass --download to fetch it)"
       fi ;;
  esac
  fetch_hf "$repo" "$file" "$dest" || die "Download failed: $file from $repo"
  ok "$label ready: $dest"
}

usage() {
  cat <<EOF
${B}start_server_pi.sh${N} — launch the Prism llama.cpp Bonsai server on the LAN (Raspberry Pi).

Usage: ./start_server_pi.sh [options]

Model:
  --model-dir <path>   Folder with the .gguf files   (default: $MODEL_DIR)
  --model <file>       Language model filename        (default: $MODEL_FILE)
  --mmproj <file>      Vision projector filename       (default: $MMPROJ_FILE)
  --model-id <id>      Preset (all auto-download): 'crack' (dealignai 1-bit CRACK,
                                default), 'ternary' (dealignai Q2_0 CRACK), or
                                'onebit' (prism-ml/Bonsai-27B-gguf)

Download (Hugging Face):
  --download           Fetch a missing model/projector without asking
  --no-download        Never download; error if a file is missing
  --hf-repo <o/n>      Repo to fetch the model from    (default: auto by filename)
  --hf-mmproj-repo <o/n>  Repo to fetch the projector from (default: --hf-repo)
  --hf-endpoint <url>  HF mirror endpoint              (default: $HF_ENDPOINT)
  (set HF_TOKEN in the environment for gated/private repos)

Network:
  --host <addr>        Bind address (0.0.0.0 or 127.0.0.1)
  --lan                Bind 0.0.0.0 — reachable from the whole LAN (default)
  --local              Bind 127.0.0.1 — this Pi only
  --port <n>           Port                            (default: $PORT)

Inference:
  --ctx <n>            Context length in tokens        (default: $CTX_SIZE)
  --threads <n>        CPU threads                     (default: $THREADS)
  --ngl <n>            GPU layers (0 for CPU build)     (default: $NGL)
  --batch <n>          Prompt batch size               (default: $BATCH)
  --temp <f> --top-p <f> --top-k <n>   Sampling (defaults: $TEMP / $TOP_P / $TOP_K)
  --reasoning <mode>   Pass --reasoning <mode> ("" to omit; default: $REASONING)
  --no-jinja           Do not pass --jinja
  --chat-template <f>  Override chat template with a .jinja file

Memory:
  --low-mem            Memory-saver profile: ctx 2048, q8_0 KV cache, flash-attn on
  --mlock              Lock the model in RAM (needs headroom)
  --no-mmap            Load weights fully into RAM instead of mmap
  --kv-type <t>        KV cache type for K & V (e.g. q8_0, q4_0)

Image / vision:
  --image | --no-image  Force vision on/off (otherwise a menu asks at startup)

Other:
  --server-bin <path>  Path to llama-server (auto-detected otherwise)
  --extra "<args>"     Extra args appended to llama-server verbatim
  -y, --yes            Non-interactive: skip the menus and auto-download if needed
  -h, --help           Show this help
EOF
}

# --------------------------------------------------------------------------- #
# Argument parsing
# --------------------------------------------------------------------------- #
# Apply a preset chosen via the MODEL_ID env var first, so explicit flags win.
[ -n "$MODEL_ID" ] && apply_model_id "$MODEL_ID"

while [ $# -gt 0 ]; do
  case "$1" in
    --model-dir)     MODEL_DIR="$2"; shift ;;
    --model)         MODEL_FILE="$2"; MODEL_SET=1; shift ;;
    --mmproj)        MMPROJ_FILE="$2"; shift ;;
    --model-id)      apply_model_id "$2"; shift ;;
    --download)      AUTO_DOWNLOAD=1 ;;
    --no-download)   AUTO_DOWNLOAD=0 ;;
    --hf-repo)       HF_REPO="$2"; shift ;;
    --hf-mmproj-repo) HF_MMPROJ_REPO="$2"; shift ;;
    --hf-endpoint)   HF_ENDPOINT="$2"; shift ;;
    --host)          HOST="$2"; shift ;;
    --lan)           OPEN_TO_LAN=1; HOST="" ;;
    --local)         OPEN_TO_LAN=0; HOST="" ;;
    --port)          PORT="$2"; shift ;;
    --ctx|--ctx-size) CTX_SIZE="$2"; shift ;;
    --threads)       THREADS="$2"; shift ;;
    --ngl)           NGL="$2"; shift ;;
    --batch)         BATCH="$2"; shift ;;
    --temp)          TEMP="$2"; shift ;;
    --top-p)         TOP_P="$2"; shift ;;
    --top-k)         TOP_K="$2"; shift ;;
    --reasoning)     REASONING="$2"; shift ;;
    --no-jinja)      USE_JINJA=0 ;;
    --chat-template) CHAT_TEMPLATE="$2"; shift ;;
    --low-mem)       CTX_SIZE=2048; CACHE_TYPE_K="q8_0"; CACHE_TYPE_V="q8_0"; FLASH_ATTN=1 ;;
    --mlock)         USE_MLOCK=1 ;;
    --no-mmap)       USE_MMAP=0 ;;
    --kv-type)       CACHE_TYPE_K="$2"; CACHE_TYPE_V="$2"; FLASH_ATTN=1; shift ;;
    --image)         IMAGE_SUPPORT=1 ;;
    --no-image)      IMAGE_SUPPORT=0 ;;
    --server-bin)    SERVER_BIN="$2"; shift ;;
    --extra)         EXTRA_ARGS="$2"; shift ;;
    -y|--yes)        ASSUME_YES=1 ;;
    -h|--help)       usage; exit 0 ;;
    *)               die "Unknown option: $1 (try --help)";;
  esac
  shift
done

# --------------------------------------------------------------------------- #
# Locate the server binary
# --------------------------------------------------------------------------- #
if [ -z "$SERVER_BIN" ]; then
  for cand in \
    "$LLAMA_DIR/build/bin/llama-server" \
    "$SCRIPT_DIR/build/bin/llama-server" \
    "$LLAMA_DIR/build/bin/server" ; do
    [ -x "$cand" ] && SERVER_BIN="$cand" && break
  done
  [ -z "$SERVER_BIN" ] && command -v llama-server >/dev/null 2>&1 && SERVER_BIN="$(command -v llama-server)"
fi
[ -n "$SERVER_BIN" ] && [ -x "$SERVER_BIN" ] || \
  die "llama-server not found. Build it first with ./build_pi.sh (or pass --server-bin)."

# -y implies "download automatically if a selected model is missing".
[ "$ASSUME_YES" -eq 1 ] && [ "$AUTO_DOWNLOAD" = "ask" ] && AUTO_DOWNLOAD=1

# --------------------------------------------------------------------------- #
# Interactive model-selection menu
# --------------------------------------------------------------------------- #
choose_model() {
  if [ "$MODEL_SET" = "1" ] || [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then return; fi
  echo
  printf '%s\n' "${B}Bonsai 27B — select model${N}"
  printf '  %s1)%s Bonsai 27B CRACK · Q1_0   — dealignai/Bonsai-27b-1bit-CRACK-GGUF   (default)\n' "$C" "$N"
  printf '  %s2)%s Bonsai 27B · Q1_0 (1-bit) — prism-ml/Bonsai-27B-gguf\n' "$C" "$N"
  printf '     %sboth auto-download (~3.9 GB) if the .gguf is not already in vision_model/%s\n' "$Y" "$N"
  echo
  local choice=""
  read -rp "Enter choice [1-2] (default 1): " choice || true
  case "$choice" in
    1) apply_model_id crack;  ok "Selected Bonsai 27B CRACK Q1_0 (dealignai/Bonsai-27b-1bit-CRACK-GGUF)" ;;
    2) apply_model_id onebit; ok "Selected Bonsai 27B Q1_0 (prism-ml/Bonsai-27B-gguf)" ;;
    *) : ;;   # empty / other: keep current defaults (respects a custom MODEL_FILE)
  esac
}
choose_model

# --------------------------------------------------------------------------- #
# Interactive image-support menu
# --------------------------------------------------------------------------- #
choose_image_support() {
  if [ "$IMAGE_SUPPORT" = "1" ] || [ "$IMAGE_SUPPORT" = "0" ]; then return; fi
  if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
    IMAGE_SUPPORT="${IMAGE_SUPPORT:-0}"
    return
  fi
  echo
  printf '%s\n' "${B}Bonsai 27B — select server mode${N}"
  printf '  %s1)%s Text only            — chat / completions, streaming\n' "$C" "$N"
  printf '  %s2)%s Text + Image/Vision  — also loads the mmproj projector\n' "$C" "$N"
  printf '     %s(vision uses noticeably more RAM on an 8 GB Pi)%s\n' "$Y" "$N"
  echo
  local choice=""
  read -rp "Enter choice [1-2] (default 1): " choice || true
  case "$choice" in
    2) IMAGE_SUPPORT=1 ;;
    *) IMAGE_SUPPORT=0 ;;
  esac
}
choose_image_support

# --------------------------------------------------------------------------- #
# Resolve host / model paths and validate
# --------------------------------------------------------------------------- #
if [ -z "$HOST" ]; then
  if [ "$OPEN_TO_LAN" -eq 1 ]; then HOST="0.0.0.0"; else HOST="127.0.0.1"; fi
fi

MODEL_PATH="$MODEL_DIR/$MODEL_FILE"
MMPROJ_PATH="$MODEL_DIR/$MMPROJ_FILE"

# Make sure the model (and, for vision, the projector) are present — downloading
# them from Hugging Face if they are missing and a repo is known.
ensure_file "$MODEL_PATH"  "$MODEL_FILE"  "$HF_REPO"                     "Model"
if [ "$IMAGE_SUPPORT" = "1" ]; then
  ensure_file "$MMPROJ_PATH" "$MMPROJ_FILE" "${HF_MMPROJ_REPO:-$HF_REPO}" "Vision projector"
fi

# Gentle RAM check
MEM_KB="$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
MEM_GB=$(( MEM_KB / 1024 / 1024 ))
if [ "$MEM_GB" -gt 0 ] && [ "$MEM_GB" -lt 8 ]; then
  warn "Detected ${MEM_GB} GB RAM. If loading fails, try:  ./start_server_pi.sh --low-mem"
fi

# Best-effort LAN IP for the banner (never let this abort the script)
LAN_IP=""
if command -v ip >/dev/null 2>&1; then
  LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
fi
if [ -z "$LAN_IP" ] && command -v hostname >/dev/null 2>&1; then
  LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
fi
[ -z "$LAN_IP" ] && LAN_IP="127.0.0.1"

# --------------------------------------------------------------------------- #
# Assemble the llama-server command
# --------------------------------------------------------------------------- #
CMD=( "$SERVER_BIN"
  --model        "$MODEL_PATH"
  --host         "$HOST"
  --port         "$PORT"
  --ctx-size     "$CTX_SIZE"
  --threads      "$THREADS"
  --n-gpu-layers "$NGL"
  --batch-size   "$BATCH"
  --parallel     "$PARALLEL"
  --temp         "$TEMP"
  --top-p        "$TOP_P"
  --top-k        "$TOP_K"
  --cont-batching
  --metrics
)

# Memory flags
[ "$USE_MMAP"  = "0" ] && CMD+=( --no-mmap )
[ "$USE_MLOCK" = "1" ] && CMD+=( --mlock )
[ "$FLASH_ATTN" = "1" ] && CMD+=( --flash-attn )
[ -n "$CACHE_TYPE_K" ] && CMD+=( --cache-type-k "$CACHE_TYPE_K" )
[ -n "$CACHE_TYPE_V" ] && CMD+=( --cache-type-v "$CACHE_TYPE_V" )

# Vision projector
if [ "$IMAGE_SUPPORT" = "1" ]; then
  CMD+=( --mmproj "$MMPROJ_PATH" )
fi

# Chat template handling
if [ -n "$CHAT_TEMPLATE" ]; then
  CMD+=( --chat-template-file "$CHAT_TEMPLATE" )
elif [ "$USE_JINJA" = "1" ]; then
  CMD+=( --jinja )
fi

# Reasoning toggle
if [ -n "$REASONING" ]; then
  CMD+=( --reasoning "$REASONING" )
fi

# shellcheck disable=SC2206
[ -n "$EXTRA_ARGS" ] && CMD+=( $EXTRA_ARGS )

# --------------------------------------------------------------------------- #
# Startup banner
# --------------------------------------------------------------------------- #
MODE_LABEL="Text only"
[ "$IMAGE_SUPPORT" = "1" ] && MODE_LABEL="Text + Image/Vision"
echo
log "Starting Prism llama.cpp server (Raspberry Pi / CPU)"
printf '    Mode        : %s\n' "$MODE_LABEL"
printf '    Model       : %s\n' "$MODEL_PATH"
[ -n "${HF_REPO:-$(repo_for_file "$MODEL_FILE")}" ] && \
  printf '    Source      : %s\n' "${HF_REPO:-$(repo_for_file "$MODEL_FILE")} (Hugging Face)"
[ "$IMAGE_SUPPORT" = "1" ] && printf '    Projector   : %s\n' "$MMPROJ_PATH"
printf '    Bind        : %s:%s  (%s)\n' "$HOST" "$PORT" \
  "$([ "$HOST" = "0.0.0.0" ] && echo 'open to LAN' || echo 'local only')"
printf '    Context     : %s tokens   Threads: %s   Batch: %s\n' "$CTX_SIZE" "$THREADS" "$BATCH"
printf '    Memory      : mmap=%s mlock=%s kv_k=%s kv_v=%s flash_attn=%s\n' \
  "$USE_MMAP" "$USE_MLOCK" "${CACHE_TYPE_K:-f16}" "${CACHE_TYPE_V:-f16}" "$FLASH_ATTN"
printf '    Template    : %s\n' \
  "$([ -n "$CHAT_TEMPLATE" ] && echo "file:$CHAT_TEMPLATE" || { [ "$USE_JINJA" = 1 ] && echo 'embedded GGUF (jinja)' || echo 'built-in'; })"
echo
if [ "$HOST" = "0.0.0.0" ]; then
  printf '    %sWeb UI / API%s : http://%s:%s\n' "$B" "$N" "$LAN_IP" "$PORT"
  printf '    Local        : http://127.0.0.1:%s\n' "$PORT"
else
  printf '    %sWeb UI / API%s : http://127.0.0.1:%s\n' "$B" "$N" "$PORT"
fi
printf '    OpenAI API   : POST http://%s:%s/v1/chat/completions  (set "stream": true for streaming)\n' \
  "$([ "$HOST" = "0.0.0.0" ] && echo "$LAN_IP" || echo "127.0.0.1")" "$PORT"
printf '    Health/stats : /health  /props  /metrics\n'
echo
log "llama-server ${CMD[*]:1}"
echo
printf '%s\n' "  (the server prints model-load progress, then per-request timing/tok-s below)"
echo

# --------------------------------------------------------------------------- #
# Launch
# --------------------------------------------------------------------------- #
exec "${CMD[@]}"
