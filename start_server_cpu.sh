#!/usr/bin/env bash
# =============================================================================
# start_server_cpu.sh
#
# Launch the Prism llama.cpp server (OpenAI-compatible) for the Bonsai 27B
# "CRACK" GGUF model on a Linux Mint / Ubuntu MATE x86-64 CPU, exposed on the
# LAN. On startup it shows a small menu to choose Text-only or Text + Image
# (vision) mode.
#
# Every parameter below can be edited in three ways (later wins):
#   1. Edit the defaults in this file.
#   2. Export an environment variable, e.g.  PORT=9000 ./start_server_cpu.sh
#   3. Pass a command-line flag,        e.g.  ./start_server_cpu.sh --port 9000
#
# Run  ./start_server_cpu.sh --help  for the full option list.
# =============================================================================
set -euo pipefail

# --------------------------------------------------------------------------- #
# Editable defaults  (env vars of the same name override these)
# --------------------------------------------------------------------------- #
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Model files ----------------------------------------------------------- #
MODEL_DIR="${MODEL_DIR:-$SCRIPT_DIR/vision_model}"          # folder holding the .gguf files
MODEL_FILE="${MODEL_FILE:-Bonsai-27b-1bit-CRACK-Q1_0.gguf}"          # language model
MMPROJ_FILE="${MMPROJ_FILE:-mmproj-Bonsai-27b-1bit-CRACK-F16.gguf}"  # vision projector

# --- Network --------------------------------------------------------------- #
OPEN_TO_LAN="${OPEN_TO_LAN:-1}"      # 1 = bind 0.0.0.0 (whole LAN), 0 = 127.0.0.1 only
HOST="${HOST:-}"                     # explicit bind address (overrides OPEN_TO_LAN if set)
PORT="${PORT:-8080}"                 # server port

# --- Inference / context --------------------------------------------------- #
CTX_SIZE="${CTX_SIZE:-8192}"         # context length in tokens (-c)
NGL="${NGL:-0}"                      # GPU layers to offload; 0 for a CPU build
THREADS="${THREADS:-$(nproc 2>/dev/null || echo 4)}"   # generation threads (-t)
BATCH="${BATCH:-2048}"               # logical batch size for prompt processing (-b)
PARALLEL="${PARALLEL:-1}"            # number of parallel request slots (-np)

# --- Sampling defaults (model card: temp 0.7 / top-p 0.95 / top-k 20) ------ #
TEMP="${TEMP:-0.7}"
TOP_P="${TOP_P:-0.95}"
TOP_K="${TOP_K:-20}"

# --- Model behaviour ------------------------------------------------------- #
# The Bonsai model card runs every example with reasoning disabled.
# Set REASONING="" to omit the flag entirely if your fork does not accept it.
REASONING="${REASONING:-off}"
USE_JINJA="${USE_JINJA:-1}"          # 1 = --jinja (use the GGUF's embedded chat template)
CHAT_TEMPLATE="${CHAT_TEMPLATE:-}"   # optional override: path to a .jinja template file

# --- Image / vision support ------------------------------------------------ #
# Leave empty to be asked by the startup menu; "1" forces on, "0" forces off.
IMAGE_SUPPORT="${IMAGE_SUPPORT:-}"

# --- Server binary --------------------------------------------------------- #
LLAMA_DIR="${LLAMA_DIR:-$SCRIPT_DIR/llama.cpp}"
SERVER_BIN="${SERVER_BIN:-}"         # explicit path; auto-detected if empty

# --- Extra pass-through args ----------------------------------------------- #
EXTRA_ARGS="${EXTRA_ARGS:-}"         # anything extra appended verbatim to llama-server

ASSUME_YES=0                         # -y : skip the interactive menu

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
${B}start_server_cpu.sh${N} — launch the Prism llama.cpp Bonsai server on the LAN.

Usage: ./start_server_cpu.sh [options]

Model:
  --model-dir <path>   Folder with the .gguf files   (default: $MODEL_DIR)
  --model <file>       Language model filename        (default: $MODEL_FILE)
  --mmproj <file>      Vision projector filename       (default: $MMPROJ_FILE)

Network:
  --host <addr>        Bind address (e.g. 0.0.0.0 or 127.0.0.1)
  --lan                Bind 0.0.0.0 — reachable from the whole LAN (default)
  --local              Bind 127.0.0.1 — this machine only
  --port <n>           Port                            (default: $PORT)

Inference:
  --ctx <n>            Context length in tokens        (default: $CTX_SIZE)
  --threads <n>        CPU threads                     (default: $THREADS)
  --ngl <n>            GPU layers (0 for CPU build)     (default: $NGL)
  --batch <n>          Prompt batch size               (default: $BATCH)
  --parallel <n>       Parallel request slots          (default: $PARALLEL)
  --temp <f>           Sampling temperature            (default: $TEMP)
  --top-p <f>          Top-p                           (default: $TOP_P)
  --top-k <n>          Top-k                           (default: $TOP_K)
  --reasoning <mode>   Pass --reasoning <mode> (default: $REASONING; "" to omit)
  --no-jinja           Do not pass --jinja (use built-in template handling)
  --chat-template <f>  Override chat template with a .jinja file

Image / vision:
  --image              Enable vision (loads the mmproj projector)
  --no-image           Text only
  (if neither is given, an interactive menu asks at startup)

Other:
  --server-bin <path>  Path to llama-server (auto-detected otherwise)
  --extra "<args>"     Extra args appended to llama-server verbatim
  -y, --yes            Non-interactive: skip the menu (uses current image setting)
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
    --parallel)      PARALLEL="$2"; shift ;;
    --temp)          TEMP="$2"; shift ;;
    --top-p)         TOP_P="$2"; shift ;;
    --top-k)         TOP_K="$2"; shift ;;
    --reasoning)     REASONING="$2"; shift ;;
    --no-jinja)      USE_JINJA=0 ;;
    --chat-template) CHAT_TEMPLATE="$2"; shift ;;
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
  die "llama-server not found. Build it first with ./build_pc.sh (or pass --server-bin)."

# --------------------------------------------------------------------------- #
# Interactive image-support menu
# --------------------------------------------------------------------------- #
choose_image_support() {
  # Already decided (flag/env), or told to skip? Don't prompt.
  if [ "$IMAGE_SUPPORT" = "1" ] || [ "$IMAGE_SUPPORT" = "0" ]; then return; fi
  if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
    IMAGE_SUPPORT="${IMAGE_SUPPORT:-0}"   # non-interactive default: text only
    return
  fi
  echo
  printf '%s\n' "${B}Bonsai 27B — select server mode${N}"
  printf '  %s1)%s Text only            — chat / completions, streaming\n' "$C" "$N"
  printf '  %s2)%s Text + Image/Vision  — also loads the mmproj projector\n' "$C" "$N"
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
  --cont-batching        # continuous batching keeps streaming smooth
  --metrics              # expose Prometheus stats at /metrics
)

# Vision projector
if [ "$IMAGE_SUPPORT" = "1" ]; then
  CMD+=( --mmproj "$MMPROJ_PATH" )
fi

# Chat template handling — honour the template embedded in the GGUF
if [ -n "$CHAT_TEMPLATE" ]; then
  CMD+=( --chat-template-file "$CHAT_TEMPLATE" )
elif [ "$USE_JINJA" = "1" ]; then
  CMD+=( --jinja )
fi

# Reasoning toggle (fork-specific flag; blank to omit)
if [ -n "$REASONING" ]; then
  CMD+=( --reasoning "$REASONING" )
fi

# Anything the user appended
# shellcheck disable=SC2206
[ -n "$EXTRA_ARGS" ] && CMD+=( $EXTRA_ARGS )

# --------------------------------------------------------------------------- #
# Startup banner
# --------------------------------------------------------------------------- #
MODE_LABEL="Text only"
[ "$IMAGE_SUPPORT" = "1" ] && MODE_LABEL="Text + Image/Vision"
echo
log "Starting Prism llama.cpp server (CPU)"
printf '    Mode        : %s\n' "$MODE_LABEL"
printf '    Model       : %s\n' "$MODEL_PATH"
[ "$IMAGE_SUPPORT" = "1" ] && printf '    Projector   : %s\n' "$MMPROJ_PATH"
printf '    Bind        : %s:%s  (%s)\n' "$HOST" "$PORT" \
  "$([ "$HOST" = "0.0.0.0" ] && echo 'open to LAN' || echo 'local only')"
printf '    Context     : %s tokens   Threads: %s   Slots: %s\n' "$CTX_SIZE" "$THREADS" "$PARALLEL"
printf '    Sampling    : temp %s  top-p %s  top-k %s\n' "$TEMP" "$TOP_P" "$TOP_K"
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
# Launch (exec so signals/Ctrl-C go straight to the server)
# --------------------------------------------------------------------------- #
exec "${CMD[@]}"
