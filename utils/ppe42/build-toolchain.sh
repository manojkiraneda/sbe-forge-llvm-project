#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
# Shared local/CI PPE42 toolchain build. Run --help for usage.
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/toolchain-environment.sh"

MLGO_MODEL_NAME=inlining-Oz-v1.1
MLGO_MODEL_URL="https://github.com/google/ml-compiler-opt/releases/download/$MLGO_MODEL_NAME/inlining-Oz-99f0063-v1.1.tar.gz"
MLGO_MODEL_SHA256=308e5fbe2c4382d6f9c154c7afbea46624dac32b95609144ba1160836e906cd2
MLGO_MODEL_INSTALL_DIR=share/mlgo/inliner-oz-v1.1
PPE42_PACKAGE_TOOLS=(clang ld.lld lldb llvm-ar llvm-objcopy llvm-objdump llvm-nm llvm-strip)
PPE42_BUILD_TARGETS=(clang lld lldb llc opt llvm-ar llvm-objcopy llvm-objdump
  llvm-nm llvm-strip llvm-mc llvm-readobj llvm-config llvm-isel-fuzzer
  FileCheck split-file not count)

extract_inliner_model() {
  # Release archive owner IDs may be unmapped in a rootless container.
  tar --no-same-owner -xzf "$DEPS_DIR/inliner.tar.gz" -C "$DEPS_DIR"
}

prepare_model() {
  mkdir -p "$DEPS_DIR"
  if [[ ! -f "$DEPS_DIR/inliner.tar.gz" ]]; then
    curl --fail --location --retry 3 \
      "$MLGO_MODEL_URL" \
      --output "$DEPS_DIR/inliner.tar.gz.partial"
    mv "$DEPS_DIR/inliner.tar.gz.partial" "$DEPS_DIR/inliner.tar.gz"
  fi
  printf '%s  %s\n' \
    "$MLGO_MODEL_SHA256" \
    "$DEPS_DIR/inliner.tar.gz" | sha256sum --check
  if [[ ! -f "$MLGO_MODEL_PATH/saved_model.pb" ]]; then
    extract_inliner_model
  fi
  test -f "$DEPS_DIR/model/saved_model.pb"
  printf 'MLGO_MODEL_PATH=%s\n' "$DEPS_DIR/model" >> "${GITHUB_ENV:-/dev/null}"
}

prepare() {
  prepare_tensorflow
  prepare_model
}

configure() {
  tensorflow_aot_path="$(python -c 'import os, tensorflow; print(os.path.dirname(tensorflow.__file__))')"
  host_options=()
  if [ "$RUNNER_OS" = macOS ]; then
    # TensorFlow 2.15's runtime declares a pre-3.5 CMake policy version.
    # Homebrew CMake 4 requires this compatibility floor for that subtree.
    host_options+=(
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5
      -DLLDB_BUILD_FRAMEWORK=OFF
      # The upstream Darwin host test suite requires an in-tree libc++.
      # PPE42 core/backtrace checks run directly in the steps below.
      -DLLDB_INCLUDE_TESTS=OFF
      -DLLDB_USE_SYSTEM_DEBUGSERVER=ON
      -DLLVM_PARALLEL_COMPILE_JOBS=2
      -DLLVM_PARALLEL_LINK_JOBS=1
    )
  elif [ -n "$FEDORA" ]; then
    # Fedora ships CMake 4, while TensorFlow's runtime requests 3.4.3.
    host_options+=(-DCMAKE_POLICY_VERSION_MINIMUM=3.5)
  fi
  # Bash 3.2 (macOS) treats an empty array as unset with nounset enabled.
  # The conditional expansion below omits it without adding an empty argument.
  cmake -S llvm -B "$BUILD_DIR" -G Ninja \
    -DLLVM_ENABLE_PROJECTS='clang;lld;lldb' \
    -DLLVM_TARGETS_TO_BUILD=PowerPC \
    -DLLVM_ENABLE_ASSERTIONS=ON \
    -DLLVM_CCACHE_BUILD=ON \
    -DLLVM_BUILD_LLVM_DYLIB=OFF \
    -DLLVM_LINK_LLVM_DYLIB=OFF \
    -DCLANG_LINK_CLANG_DYLIB=OFF \
    -DLLDB_ENABLE_PYTHON=OFF \
    -DLLDB_ENABLE_LIBEDIT=ON \
    -DLLDB_ENABLE_CURSES=OFF \
    -DTENSORFLOW_AOT_PATH="$tensorflow_aot_path" \
    -DTENSORFLOW_AOT_COMPILER="$(command -v saved_model_cli)" \
    -DLLVM_INLINER_MODEL_PATH="$MLGO_MODEL_PATH" \
    -DLLVM_RAEVICT_MODEL_PATH=none \
    -DLLVM_TF_AOT_SCALAR_RUNTIME=$SCALAR_RUNTIME \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PACKAGE_DIR" \
    ${host_options[@]+"${host_options[@]}"} "$@"
  grep -q '^LLDB_ENABLE_LIBEDIT:STRING=ON$' "$BUILD_DIR/CMakeCache.txt"
}

build_deps() {
  cmake --build "$BUILD_DIR" --target \
    tf_xla_runtime lib/Analysis/InlinerSizeModel.o
}

build() {
  cmake --build "$BUILD_DIR" --target "${PPE42_BUILD_TARGETS[@]}"
}

runtime() {
  mkdir -p "$BUILD_DIR/ppe42-runtime"
  for width in 32 64; do
    "$BUILD_DIR/bin/clang" -target powerpc-unknown-elf -mcpu=ppe42 \
      -c "compiler-rt/lib/builtins/ppc/ppe42-div${width}.S" \
      -o "$BUILD_DIR/ppe42-runtime/ppe42-div${width}.o"
  done
  cmake -E rm -f "$BUILD_DIR/ppe42-runtime/libclang_rt.ppe42.a"
  "$BUILD_DIR/bin/llvm-ar" rcs \
    "$BUILD_DIR/ppe42-runtime/libclang_rt.ppe42.a" \
    "$BUILD_DIR/ppe42-runtime/ppe42-div32.o" \
    "$BUILD_DIR/ppe42-runtime/ppe42-div64.o"
  "$BUILD_DIR/bin/llvm-nm" --defined-only \
    "$BUILD_DIR/ppe42-runtime/libclang_rt.ppe42.a" | \
    "$BUILD_DIR/bin/FileCheck" \
      compiler-rt/test/builtins/ppc/ppe42-div-symbols.txt
}

# Bundle the complete non-glibc dependency closure on every Linux build host.
# In particular, Ubuntu's libxml2.so.2 is absent from newer Fedora images.
bundle_linux_dependencies() {
  local dependencies dependency tool
  if ! dependencies="$(
    for tool in "${PPE42_PACKAGE_TOOLS[@]}"; do
      ldd "$BUILD_DIR/bin/$tool" || exit 1
    done
    ldd "$BUILD_DIR/lib/liblldb.so"
  )"; then
    echo 'Unable to inspect toolchain shared-library dependencies' >&2
    return 1
  fi
  if printf '%s\n' "$dependencies" | grep -Eq '=>[[:space:]]+not found'; then
    printf '%s\n' "$dependencies" >&2
    echo 'Toolchain has unresolved shared-library dependencies' >&2
    return 1
  fi
  while IFS= read -r dependency; do
    case "$(basename "$dependency")" in
      libc.so.*|libm.so.*|libpthread.so.*|libdl.so.*|librt.so.*|libresolv.so.*|libutil.so.*|libanl.so.*)
        continue ;;
    esac
    cp -L "$dependency" "$PACKAGE_DIR/lib/$(basename "$dependency")"
  done < <(
    printf '%s\n' "$dependencies" | awk '$2 == "=>" && $3 ~ /^\// {
      sub(/^[^=]*=>[ \t]*/, ""); sub(/[ \t]+\([^)]*\)[ \t]*$/, ""); print
    }' | sort -u
  )
  for tool in "${PPE42_PACKAGE_TOOLS[@]}"; do
    patchelf --set-rpath '$ORIGIN/../lib' "$PACKAGE_DIR/bin/$tool"
  done
  find "$PACKAGE_DIR/lib" -maxdepth 1 -name '*.so*' -type f \
    -exec patchelf --set-rpath '$ORIGIN' {} +
}

stage() {
  HOST_NAME="$(case "$RUNNER_OS" in macOS) echo darwin;; *) echo linux;; esac)-$(uname -m)"
  HOST_NAME="${HOST_NAME/darwin-aarch64/darwin-arm64}"
  mkdir -p "$PACKAGE_DIR/bin" "$PACKAGE_DIR/lib/clang"
  mkdir -p "$PACKAGE_DIR/lib/ppe42" "$PACKAGE_DIR/share/ppe42"
  mkdir -p "$PACKAGE_DIR/$MLGO_MODEL_INSTALL_DIR" \
    "$PACKAGE_DIR/share/doc"
  for tool in "${PPE42_PACKAGE_TOOLS[@]}"; do
    if [[ "$tool" == lldb ]]; then continue; fi
    cp -L "$BUILD_DIR/bin/$tool" "$PACKAGE_DIR/bin/$tool"
    if [ "$RUNNER_OS" != macOS ]; then
      strip "$PACKAGE_DIR/bin/$tool"
    fi
  done
  cp -L "$BUILD_DIR/bin/lldb" "$PACKAGE_DIR/bin/lldb"
  if [ "$RUNNER_OS" = macOS ]; then
    python utils/ppe42/package_darwin.py \
      --build-dir "$BUILD_DIR" --package-dir "$PACKAGE_DIR"
  else
    cp -a "$BUILD_DIR/lib/liblldb.so"* "$PACKAGE_DIR/lib/"
    # libedit is not installed on every toolchain host. Its non-glibc
    # dependencies also need to travel with the packaged LLDB.
    lldb_dependencies="$(ldd "$BUILD_DIR/lib/liblldb.so")"
    for name in libedit.so libtinfo.so libbsd.so libmd.so; do
      path="$(printf '%s\n' "$lldb_dependencies" | awk -v prefix="$name" \
        'index($1, prefix) == 1 {print $3; exit}')"
      if [ -n "$path" ]; then
        cp --dereference "$path" "$PACKAGE_DIR/lib/$(basename "$path")"
      elif [ "$name" = libedit.so ]; then
        echo 'LLDB was built without a dynamic libedit dependency' >&2
        exit 1
      fi
    done
    patchelf --set-rpath '$ORIGIN/../lib' "$PACKAGE_DIR/bin/lldb"
    find "$PACKAGE_DIR/lib" -maxdepth 1 -name 'liblldb.so*' -type f \
      -exec patchelf --set-rpath '$ORIGIN' {} +
    find "$PACKAGE_DIR/lib" -maxdepth 1 -type f \
      \( -name 'libedit.so*' -o -name 'libtinfo.so*' -o \
         -name 'libbsd.so*' -o -name 'libmd.so*' \) \
      -exec patchelf --set-rpath '$ORIGIN' {} +
    strip "$PACKAGE_DIR/bin/lldb"
    bundle_linux_dependencies
  fi
  ln -sfn clang "$PACKAGE_DIR/bin/clang++"

  resource_dir="$("$BUILD_DIR/bin/clang" --print-resource-dir)"
  cp -a "$resource_dir" "$PACKAGE_DIR/lib/clang/"
  cp "$BUILD_DIR/ppe42-runtime/libclang_rt.ppe42.a" \
    "$PACKAGE_DIR/lib/ppe42/"
  cp -a "$MLGO_MODEL_PATH/." \
    "$PACKAGE_DIR/$MLGO_MODEL_INSTALL_DIR/"
  cp llvm/docs/PPE42MLGO.rst "$PACKAGE_DIR/share/doc/"
  cp lldb/utils/ppe42/ppe42_core.py "$PACKAGE_DIR/share/ppe42/"
  cp lldb/utils/ppe42/README.md "$PACKAGE_DIR/share/doc/PPE42LLDB.md"

  jq \
    --arg llvm_sha "${GITHUB_SHA:-$(git rev-parse HEAD)}" \
    --arg llvm_ref "${GITHUB_REF_NAME:-$(git symbolic-ref --short -q HEAD || git rev-parse --short HEAD)}" \
    --arg host "$HOST_NAME" \
    --arg model "$MLGO_MODEL_NAME" \
    --arg model_dir "$MLGO_MODEL_INSTALL_DIR" \
    '.llvm_sha = $llvm_sha | .llvm_ref = $llvm_ref |
     .host = $host |
     .mlgo = {"inliner_model": $model,
              "mode": "embedded-aot",
              "activation": "-mllvm -enable-ml-inliner=release",
              "source_model": $model_dir}' \
    .github/ppe42-toolchain-manifest.json \
    > "$PACKAGE_DIR/manifest.json"

  du -sh "$PACKAGE_DIR"
}

check() {
  printf 'int helper(int x) { return x + 1; } int entry(int x) { return helper(x); }\n' > "$DEPS_DIR/package-smoke.c"
  "$PACKAGE_DIR/bin/clang++" --version
  "$PACKAGE_DIR/bin/lldb" --version
  "$PACKAGE_DIR/bin/clang" -target powerpc-unknown-elf -mcpu=ppe42 -Oz \
    -mllvm -enable-ml-inliner=release -c "$DEPS_DIR/package-smoke.c" -o "$DEPS_DIR/package-smoke.o"
}

archive() {
  asset="${ASSET_NAME:-sbe-ppe42-toolchain-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)}"
  # Use a fixed archive root even when a local install directory is named toolchain.
  python - "$PACKAGE_DIR" "$asset.tar.zst" <<'PYARCHIVE'
import pathlib, subprocess, sys, tarfile, hashlib
source, archive = map(pathlib.Path, sys.argv[1:])
with archive.open('wb') as output:
    with subprocess.Popen(['zstd', '-T0', '-q', '-c'], stdin=subprocess.PIPE, stdout=output) as zstd:
        with tarfile.open(fileobj=zstd.stdin, mode='w|') as tar:
            tar.add(source, arcname='ppe42-toolchain')
        zstd.stdin.close()
        if zstd.wait():
            raise SystemExit('zstd compression failed')
with archive.open('rb') as data:
    digest = hashlib.file_digest(data, 'sha256').hexdigest()
archive.with_suffix(archive.suffix + '.sha256').write_text(f'{digest}  {archive.name}\n')
PYARCHIVE
}

verify_host() {
  local actual
  actual="$(uname -m)"
  if [[ -n "${SBE_LLVM_EXPECTED_ARCH:-}" && "$actual" != "$SBE_LLVM_EXPECTED_ARCH" ]]; then
    echo "Expected host architecture $SBE_LLVM_EXPECTED_ARCH, got $actual" >&2
    return 1
  fi
  printf 'Toolchain host: %s %s\n' "$RUNNER_OS" "$actual"
}

cache_start() {
  ccache --show-config
  ccache --zero-stats
}

cache_report() {
  ccache --show-stats --verbose
}

load_test_helpers() {
  source "$SOURCE_DIR/utils/ppe42/toolchain-tests.sh"
}

test_unit() { load_test_helpers; toolchain_test_unit; }
test_compiler() { load_test_helpers; toolchain_test_compiler; }
test_package() { load_test_helpers; toolchain_test_package; }
test_all() { test_unit; test_compiler; check; test_package; }

build_and_test() {
  verify_host
  prepare
  test_unit
  cache_start
  trap 'cache_report || true' EXIT
  configure "$@"
  build_deps
  build
  runtime
  test_compiler
  stage
  check
  test_package
}

main() {
  local phase="${1:-all}"
  if [[ "$phase" == --help ]]; then
    echo 'Usage: build-toolchain.sh PHASE [CMake arguments]'
    echo 'Phases: all, deps, prepare, prepare-tensorflow, prepare-model, configure,'
    echo '  build-deps, build, build-test, runtime, stage, check, test, test-unit, test-compiler,'
    echo '  test-package, host, cache-start, cache-report, archive'
    echo 'Paths: SBE_LLVM_SOURCE_DIR, SBE_LLVM_BUILD_DIR, SBE_LLVM_INSTALL_DIR, SBE_LLVM_DEPS_DIR.'
    echo 'deps installs host dependencies; all prepares MLGO and builds, stages, checks and archives the toolchain.'
    return
  fi
  if (( $# )); then shift; fi
  initialize
  case "$phase" in
    all) build_and_test "$@"; archive;;
    build-test) build_and_test "$@";;
    host) verify_host;;
    cache-start) cache_start;;
    cache-report) cache_report;;
    prepare-tensorflow) prepare_tensorflow;;
    prepare-model) prepare_model;;
    test) test_all;;
    test-unit) test_unit;;
    test-compiler) test_compiler;;
    test-package) test_package;;
    build-deps) build_deps;;
    deps|prepare|configure|build|runtime|stage|check|archive) "$phase" "$@";;
    *) echo "Unknown build phase: $phase" >&2; return 2;;
  esac
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
