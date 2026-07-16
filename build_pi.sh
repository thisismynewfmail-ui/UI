#!/usr/bin/env bash
# =============================================================================
# build_pi.sh
#
# Build the Prism ML fork of llama.cpp on an 8 GB, 64-bit Raspberry Pi
# (Raspberry Pi OS 64-bit / Ubuntu, aarch64 — also works on a 64-bit x86 SBC).
# This fork carries the native low-bit (Q1_0 ternary) kernels required by the
# Bonsai 27B "CRACK" GGUF model.
#
# Compared with build_pc.sh this script is memory-aware: llama.cpp translation
# units are large, and running too many parallel compilers will OOM an 8 GB Pi.
# The job count is therefore derived from available RAM, and a swap-file check
# is included.
#
# After this finishes, start the server with ./start_server_pi.sh
#
# Usage:
#   ./build_pi.sh [options]
#
# Options:
#   --install-deps     Install missing build tools with apt (uses sudo).
#   --dir <path>       Where to clone/build llama.cpp (default: ./llama.cpp).
#   --repo <url>       Git URL of the fork (default: Prism ML fork).
#   --branch <name>    Git branch/tag to check out (default: repo default).
#   --jobs <N>         Force parallel compile jobs (default: RAM-based, capped).
#   --update           git pull an existing clone before building.
#   --clean            Remove the build/ directory and reconfigure from scratch.
#   --no-curl          Build without libcurl (disables model download-by-URL).
#   -h, --help         Show this help and exit.
# =============================================================================
set -euo pipefail

# --------------------------------------------------------------------------- #
# Editable defaults
# --------------------------------------------------------------------------- #
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL="${REPO_URL:-https://github.com/PrismML-Eng/llama.cpp}"
BRANCH="${BRANCH:-}"
LLAMA_DIR="${LLAMA_DIR:-$SCRIPT_DIR/llama.cpp}"
BUILD_TYPE="${BUILD_TYPE:-Release}"
JOBS="${JOBS:-}"          # empty => auto (RAM-based)
USE_CURL="auto"           # auto | on | off
INSTALL_DEPS=0
DO_UPDATE=0
DO_CLEAN=0

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
# Argument parsing
# --------------------------------------------------------------------------- #
while [ $# -gt 0 ]; do
  case "$1" in
    --install-deps) INSTALL_DEPS=1 ;;
    --dir)          LLAMA_DIR="$2"; shift ;;
    --repo)         REPO_URL="$2"; shift ;;
    --branch)       BRANCH="$2"; shift ;;
    --jobs)         JOBS="$2"; shift ;;
    --update)       DO_UPDATE=1 ;;
    --clean)        DO_CLEAN=1 ;;
    --no-curl)      USE_CURL="off" ;;
    -h|--help)      sed -n '2,44p' "$0"; exit 0 ;;
    *)              die "Unknown option: $1 (try --help)";;
  esac
  shift
done

# --------------------------------------------------------------------------- #
# Memory-aware default job count
# --------------------------------------------------------------------------- #
MEM_KB="$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
MEM_GB=$(( MEM_KB / 1024 / 1024 ))
CORES="$(nproc 2>/dev/null || echo 4)"
if [ -z "$JOBS" ]; then
  # ~1 compiler per 3 GB of RAM, at least 1, never more than the core count.
  JOBS=$(( MEM_GB / 3 ))
  [ "$JOBS" -lt 1 ] && JOBS=1
  [ "$JOBS" -gt "$CORES" ] && JOBS="$CORES"
fi

# --------------------------------------------------------------------------- #
# 0. Show environment
# --------------------------------------------------------------------------- #
ARCH="$(uname -m)"
log "Prism llama.cpp — Raspberry Pi (CPU) build"
printf '    OS       : %s\n' "$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-$(uname -s)}" || uname -s)"
printf '    Arch     : %s\n' "$ARCH"
printf '    RAM      : %s GB\n' "$MEM_GB"
printf '    CPU cores: %s (using -j%s to stay within RAM)\n' "$CORES" "$JOBS"
printf '    Target   : %s\n' "$LLAMA_DIR"
case "$ARCH" in
  aarch64|arm64) ok "64-bit ARM detected — native NEON/dotprod kernels will be used." ;;
  x86_64|amd64)  ok "64-bit x86 detected." ;;
  armv7l|armv6l) die "32-bit ARM ('$ARCH') is not supported. A 64-bit OS is required for this model." ;;
  *)             warn "Unrecognised arch '$ARCH' — attempting a generic native build." ;;
esac

# Swap advice — building (and later running) is far safer with swap on 8 GB.
SWAP_KB="$(awk '/SwapTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
SWAP_GB=$(( SWAP_KB / 1024 / 1024 ))
if [ "$SWAP_GB" -lt 2 ]; then
  warn "Only ${SWAP_GB} GB swap detected. If the build is killed (OOM), add swap:"
  echo "        sudo dphys-swapfile swapoff 2>/dev/null || true"
  echo "        sudo sed -i 's/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=4096/' /etc/dphys-swapfile 2>/dev/null || true"
  echo "        sudo dphys-swapfile setup && sudo dphys-swapfile swapon"
  echo "    (or:  sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile && \\"
  echo "          sudo mkswap /swapfile && sudo swapon /swapfile )"
fi

# --------------------------------------------------------------------------- #
# 1. Prerequisites
# --------------------------------------------------------------------------- #
APT_PKGS="build-essential cmake git pkg-config"
[ "$USE_CURL" != "off" ] && APT_PKGS="$APT_PKGS libcurl4-openssl-dev"

install_deps_apt() {
  command -v apt-get >/dev/null 2>&1 || die "apt-get not found. Install manually: $APT_PKGS"
  log "Installing build tools via apt: $APT_PKGS"
  sudo apt-get update
  # shellcheck disable=SC2086
  sudo apt-get install -y $APT_PKGS
}

check_prereqs() {
  local missing=()
  command -v git   >/dev/null 2>&1 || missing+=("git")
  command -v cmake >/dev/null 2>&1 || missing+=("cmake")
  { command -v g++ >/dev/null 2>&1 || command -v c++ >/dev/null 2>&1; } || missing+=("g++/build-essential")
  { command -v make >/dev/null 2>&1 || command -v ninja >/dev/null 2>&1; } || missing+=("make")
  if [ "${#missing[@]}" -gt 0 ]; then
    warn "Missing build tools: ${missing[*]}"
    if [ "$INSTALL_DEPS" -eq 1 ]; then
      install_deps_apt
    else
      echo
      echo "  Install them first (Raspberry Pi OS / Ubuntu):"
      echo "      sudo apt-get update && sudo apt-get install -y $APT_PKGS"
      echo "  or re-run this script with:  ./build_pi.sh --install-deps"
      die "Prerequisites missing."
    fi
  fi
  ok "git   $(git --version | awk '{print $3}')"
  ok "cmake $(cmake --version | head -1 | awk '{print $3}')"
}

log "Checking prerequisites"
check_prereqs

CMAKE_CURL_FLAG=""
if [ "$USE_CURL" = "off" ]; then
  CMAKE_CURL_FLAG="-DLLAMA_CURL=OFF"
  warn "libcurl disabled — models cannot be auto-downloaded by URL."
else
  if pkg-config --exists libcurl 2>/dev/null || ls /usr/include/curl/curl.h >/dev/null 2>&1; then
    CMAKE_CURL_FLAG="-DLLAMA_CURL=ON"
  else
    warn "libcurl dev headers not found — building with -DLLAMA_CURL=OFF."
    CMAKE_CURL_FLAG="-DLLAMA_CURL=OFF"
  fi
fi

# --------------------------------------------------------------------------- #
# 2. Clone / update the fork
# --------------------------------------------------------------------------- #
if [ -d "$LLAMA_DIR/.git" ]; then
  ok "Fork already present at $LLAMA_DIR"
  if [ "$DO_UPDATE" -eq 1 ]; then
    log "Updating existing clone (git pull)"
    git -C "$LLAMA_DIR" pull --ff-only || warn "git pull failed — continuing with current checkout."
  fi
else
  log "Cloning $REPO_URL"
  git clone --depth 1 "$REPO_URL" "$LLAMA_DIR"   # shallow clone to save SD-card space
fi
if [ -n "$BRANCH" ]; then
  log "Checking out branch/tag: $BRANCH"
  git -C "$LLAMA_DIR" fetch --depth 1 origin "$BRANCH" 2>/dev/null || true
  git -C "$LLAMA_DIR" checkout "$BRANCH"
fi

# --------------------------------------------------------------------------- #
# 3. Configure + build
# --------------------------------------------------------------------------- #
BUILD_DIR="$LLAMA_DIR/build"
if [ "$DO_CLEAN" -eq 1 ] && [ -d "$BUILD_DIR" ]; then
  log "Removing previous build directory"
  rm -rf "$BUILD_DIR"
fi

log "Configuring (CMake, CPU backend, native ARM/x86 kernels)"
cmake -S "$LLAMA_DIR" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
  -DGGML_CUDA=OFF \
  -DGGML_METAL=OFF \
  -DGGML_NATIVE=ON \
  $CMAKE_CURL_FLAG \
  -DLLAMA_BUILD_SERVER=ON

log "Compiling with -j$JOBS (this can take 15-40 minutes on a Pi — be patient)"
if ! cmake --build "$BUILD_DIR" --config "$BUILD_TYPE" -j "$JOBS"; then
  warn "Build failed. If it was Killed/OOM, retry single-threaded:  ./build_pi.sh --jobs 1"
  die "Compilation failed."
fi

# --------------------------------------------------------------------------- #
# 4. Verify
# --------------------------------------------------------------------------- #
SERVER_BIN=""
for cand in "$BUILD_DIR/bin/llama-server" "$BUILD_DIR/bin/server" "$BUILD_DIR/llama-server"; do
  [ -x "$cand" ] && SERVER_BIN="$cand" && break
done
[ -n "$SERVER_BIN" ] || die "Build finished but llama-server was not found under $BUILD_DIR/bin."

echo
ok "Build complete."
printf '    llama-server: %s\n' "$SERVER_BIN"
[ -x "$BUILD_DIR/bin/llama-cli" ] && printf '    llama-cli   : %s\n' "$BUILD_DIR/bin/llama-cli"
echo
log "Next steps"
echo "  1. Place the model files in:   $SCRIPT_DIR/vision_model/"
echo "       - Bonsai-27b-1bit-CRACK-Q1_0.gguf        (language model, ~3.9 GB)"
echo "       - mmproj-Bonsai-27b-1bit-CRACK-F16.gguf   (vision projector, optional)"
echo "  2. Start the LAN server:       ./start_server_pi.sh"
echo
