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

usage() {
  cat <<EOF
${B}start_server_pi.sh${N} — launch the Prism llama.cpp Bonsai server on the LAN (Raspberry Pi).

Usage: ./start_server_pi.sh [options]

Model:
  --model-dir <path>   Folder with the .gguf files   (default: $MODEL_DIR)
  --model <file>       Language model filename        (default: $MODEL_FILE)
  --mmproj <file>      Vision projector filename       (default: $MMPROJ_FILE)

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
  -y, --yes            Non-interactive: skip the menu
  -h, --help           Show this help
EOF
}

# --------------------------------------------------------------------------- #
# Argument parsing
# --------------------------------------------------------------------------- #
while [ $# -gt 0 ]; do
  case "$1" in
    --model-dir)     MODEL_DIR="$2"; shift ;;
    --model)         MODEL_FILE="$2"; shift ;;
    --mmproj)        MMPROJ_FILE="$2"; shift ;;
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

[ -f "$MODEL_PATH" ] || die "Model not found: $MODEL_PATH
    Place '$MODEL_FILE' in '$MODEL_DIR' (or pass --model-dir / --model)."

if [ "$IMAGE_SUPPORT" = "1" ]; then
  [ -f "$MMPROJ_PATH" ] || die "Vision projector not found: $MMPROJ_PATH
    Place '$MMPROJ_FILE' in '$MODEL_DIR', or start without vision (--no-image)."
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
