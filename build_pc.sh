#!/usr/bin/env bash
# =============================================================================
# build_pc.sh
#
# Build the Prism ML fork of llama.cpp for a Linux Mint / Ubuntu MATE 64-bit
# (x86-64) desktop or laptop CPU. This fork carries the native low-bit
# (Q1_0 / Q2_0 ternary) kernels required by the Bonsai 27B "CRACK" GGUF model.
#
# What it does:
#   1. Verifies (and optionally installs) the build tools.
#   2. Clones (or updates) the Prism llama.cpp fork.
#   3. Configures and builds a CPU-optimised Release build.
#   4. Verifies llama-server / llama-cli were produced.
#
# After this finishes, start the server with ./start_server_cpu.sh
#
# Usage:
#   ./build_pc.sh [options]
#
# Options:
#   --install-deps     Install missing build tools with apt (uses sudo).
#   --dir <path>       Where to clone/build llama.cpp (default: ./llama.cpp).
#   --repo <url>       Git URL of the fork (default: Prism ML fork).
#   --branch <name>    Git branch/tag to check out (default: repo default).
#   --jobs <N>         Parallel compile jobs (default: all CPU cores).
#   --update           git pull an existing clone before building.
#   --clean            Remove the build/ directory and reconfigure from scratch.
#   --no-native        Do NOT use -march=native (portable but slower binary).
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
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
USE_NATIVE=1          # -DGGML_NATIVE=ON  (march=native for this CPU)
USE_CURL="auto"       # auto | on | off
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
    --no-native)    USE_NATIVE=0 ;;
    --no-curl)      USE_CURL="off" ;;
    -h|--help)      sed -n '2,40p' "$0"; exit 0 ;;
    *)              die "Unknown option: $1 (try --help)";;
  esac
  shift
done

# --------------------------------------------------------------------------- #
# 0. Show environment
# --------------------------------------------------------------------------- #
ARCH="$(uname -m)"
log "Prism llama.cpp — PC (CPU) build"
printf '    OS       : %s\n' "$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-$(uname -s)}" || uname -s)"
printf '    Arch     : %s\n' "$ARCH"
printf '    CPU cores: %s (using -j%s)\n' "$(nproc 2>/dev/null || echo '?')" "$JOBS"
printf '    Target   : %s\n' "$LLAMA_DIR"
case "$ARCH" in
  x86_64|amd64) : ;;
  *) warn "This script targets x86-64. Detected '$ARCH'. For a Raspberry Pi use build_pi.sh." ;;
esac

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
      echo "  Install them first, e.g. on Mint/Ubuntu MATE:"
      echo "      sudo apt-get update && sudo apt-get install -y $APT_PKGS"
      echo "  or re-run this script with:  ./build_pc.sh --install-deps"
      die "Prerequisites missing."
    fi
  fi
  ok "git   $(git --version | awk '{print $3}')"
  ok "cmake $(cmake --version | head -1 | awk '{print $3}')"
}

log "Checking prerequisites"
check_prereqs

# libcurl detection (only matters when USE_CURL=auto)
CMAKE_CURL_FLAG=""
if [ "$USE_CURL" = "off" ]; then
  CMAKE_CURL_FLAG="-DLLAMA_CURL=OFF"
  warn "libcurl disabled — models cannot be auto-downloaded by URL."
else
  if pkg-config --exists libcurl 2>/dev/null || ls /usr/include/curl/curl.h >/dev/null 2>&1; then
    CMAKE_CURL_FLAG="-DLLAMA_CURL=ON"
  else
    warn "libcurl dev headers not found — building with -DLLAMA_CURL=OFF."
    warn "  (install libcurl4-openssl-dev, or pass --install-deps, to enable URL downloads)"
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
  git clone "$REPO_URL" "$LLAMA_DIR"
fi
if [ -n "$BRANCH" ]; then
  log "Checking out branch/tag: $BRANCH"
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

NATIVE_FLAG="-DGGML_NATIVE=ON"
[ "$USE_NATIVE" -eq 0 ] && NATIVE_FLAG="-DGGML_NATIVE=OFF"

log "Configuring (CMake, CPU backend)"
cmake -S "$LLAMA_DIR" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
  -DGGML_CUDA=OFF \
  -DGGML_METAL=OFF \
  "$NATIVE_FLAG" \
  $CMAKE_CURL_FLAG \
  -DLLAMA_BUILD_SERVER=ON

log "Compiling with -j$JOBS (this can take several minutes)"
cmake --build "$BUILD_DIR" --config "$BUILD_TYPE" -j "$JOBS"

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
[ -x "$BUILD_DIR/bin/llama-bench" ] && printf '    llama-bench : %s\n' "$BUILD_DIR/bin/llama-bench"
echo
log "Next steps"
echo "  1. Place the model files in:   $SCRIPT_DIR/vision_model/"
echo "       - Bonsai-27b-1bit-CRACK-Q1_0.gguf        (language model)"
echo "       - mmproj-Bonsai-27b-1bit-CRACK-F16.gguf   (vision projector, optional)"
echo "  2. Start the LAN server:       ./start_server_cpu.sh"
echo
