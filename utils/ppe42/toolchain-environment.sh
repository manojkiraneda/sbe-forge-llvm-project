#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
# Stable host dependency layer, shared by native builds and the development image.
set -euo pipefail

TENSORFLOW_VERSION=2.15.1

initialize() {
  SOURCE_DIR="${SBE_LLVM_SOURCE_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"
  cd "$SOURCE_DIR"
  BUILD_DIR="${SBE_LLVM_BUILD_DIR:-${BUILD_DIR:-$SOURCE_DIR/build/ppe42}}"
  PACKAGE_DIR="${SBE_LLVM_INSTALL_DIR:-${PACKAGE_DIR:-$SOURCE_DIR/package/ppe42-toolchain}}"
  DEPS_DIR="${SBE_LLVM_DEPS_DIR:-${RUNNER_TEMP:-$SOURCE_DIR/build}/ppe42-mlgo}"
  mkdir -p "$DEPS_DIR"
  DEPS_DIR="$(cd "$DEPS_DIR" && pwd)"
  MLGO_MODEL_PATH="$DEPS_DIR/model"
  RUNNER_OS="${RUNNER_OS:-$(case "$(uname -s)" in Darwin) echo macOS;; *) echo Linux;; esac)}"
  SCALAR_RUNTIME=OFF
  case "$(uname -m)" in aarch64|arm64) SCALAR_RUNTIME=ON;; esac
  FEDORA=
  if [[ -f /etc/fedora-release ]]; then FEDORA=1; fi
  export CCACHE_DIR="${CCACHE_DIR:-$HOME/.cache/ccache}"
  if [[ -x /opt/ppe42-python/bin/python ]]; then
    export PATH="/opt/ppe42-python/bin:$PATH"
  elif [[ -x "$DEPS_DIR/venv/bin/python" ]]; then
    export PATH="$DEPS_DIR/venv/bin:$PATH"
  fi
  export PATH="$HOME/.cargo/bin:$PATH"
  if [[ "$RUNNER_OS" == macOS ]] && command -v brew >/dev/null; then
    PPE42_BREW_PREFIX="${HOMEBREW_PREFIX:-$(brew --prefix)}"
    export PATH="$PPE42_BREW_PREFIX/opt/coreutils/libexec/gnubin:$PPE42_BREW_PREFIX/opt/gnu-tar/libexec/gnubin:$HOME/.cargo/bin:$PPE42_BREW_PREFIX/opt/rustup/bin:$PATH:$PPE42_BREW_PREFIX/opt/python@3.11/bin"
    export PKG_CONFIG_PATH="$PPE42_BREW_PREFIX/opt/libedit/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  fi
}

as_root() {
  if (( EUID == 0 )); then "$@"; else sudo "$@"; fi
}

deps() {
  if [ -n "$FEDORA" ]; then
    as_root dnf install -y \
      gcc gcc-c++ binutils cmake ccache git ninja-build libedit-devel \
      zlib-devel libzstd-devel libxml2-devel patchelf rustup \
      python3.11 python3-pip jq tar gzip zstd which findutils diffutils \
      curl-minimal ca-certificates
    # Installing newer headers can upgrade libzstd while leaving the image's
    # older CLI installed. zstd requires an exact runtime version match.
    as_root dnf upgrade -y zstd libzstd libzstd-devel
    zstd --version
    local venv="$DEPS_DIR/venv"
    if (( EUID == 0 )); then venv=/opt/ppe42-python; fi
    python3.11 -m venv "$venv"
    "$venv/bin/python" -m pip install --disable-pip-version-check --upgrade pip meson
    printf '%s\n' "$venv/bin" >> "${GITHUB_PATH:-/dev/null}"
    rustup-init -y --no-modify-path --profile minimal --default-toolchain none
    printf '%s\n' "$HOME/.cargo/bin" >> "${GITHUB_PATH:-/dev/null}"
    export PATH="$venv/bin:$HOME/.cargo/bin:$PATH"
  elif [ "$RUNNER_OS" = macOS ]; then
    brew install ccache cmake libedit ninja meson coreutils gnu-tar zstd pkgconf jq python@3.11 rustup
    printf 'PKG_CONFIG_PATH=%s\n' "$PKG_CONFIG_PATH" >> "${GITHUB_ENV:-/dev/null}"
    printf '%s\n' "$PPE42_BREW_PREFIX/opt/coreutils/libexec/gnubin" \
      "$PPE42_BREW_PREFIX/opt/gnu-tar/libexec/gnubin" \
      "$PPE42_BREW_PREFIX/opt/rustup/bin" >> "${GITHUB_PATH:-/dev/null}"
  elif [ -z "$FEDORA" ]; then
    as_root apt-get update
    as_root apt-get install -y build-essential binutils git ccache cmake libedit-dev \
      zlib1g-dev libzstd-dev libxml2-dev ninja-build meson patchelf rustup zstd jq curl ca-certificates
  fi
  # ccache otherwise defaults to ~/Library/Caches/ccache on macOS.
  printf 'CCACHE_DIR=%s\n' "$CCACHE_DIR" >> "${GITHUB_ENV:-/dev/null}"
  rustup toolchain install stable --profile minimal
  rustup default stable
  rustup target add powerpc-unknown-linux-gnu
}

prepare_tensorflow() {
  # TensorFlow 2.15 AOT wheels require Python 3.11. Isolate local installs.
  if [[ -z "${CI:-}" && -z "${VIRTUAL_ENV:-}" && ! -x /opt/ppe42-python/bin/python ]]; then
    if [[ ! -x "$DEPS_DIR/venv/bin/python" ]]; then
      "${SBE_LLVM_PYTHON:-python3.11}" -m venv "$DEPS_DIR/venv"
    fi
    export PATH="$DEPS_DIR/venv/bin:$PATH"
  fi
  python -c 'import sys; assert sys.version_info[:2] == (3, 11), "MLGO requires Python 3.11"'
  if ! python -c 'import importlib.metadata, sys; assert importlib.metadata.version("tensorflow") == sys.argv[1]' "$TENSORFLOW_VERSION" 2>/dev/null; then
    python -m pip install --disable-pip-version-check --only-binary=:all: "tensorflow==$TENSORFLOW_VERSION"
  fi
  # Every host wheel must include the AOT compiler and runtime sources.
  python - <<'PY'
from pathlib import Path
import tensorflow
from tensorflow.python import _pywrap_tfcompile
root = Path(tensorflow.__file__).parent
assert (root / 'xla_aot_runtime_src/CMakeLists.txt').is_file()
PY
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  initialize
  case "${1:-}" in
    deps) deps;;
    prepare-tensorflow) prepare_tensorflow;;
    *) echo 'Usage: toolchain-environment.sh [deps|prepare-tensorflow]' >&2; exit 2;;
  esac
fi
