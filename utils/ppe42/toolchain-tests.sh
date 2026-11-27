#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
# Sourced by build-toolchain.sh. Test selection and fixtures live here for both
# local dev.sh builds and CI; this file performs no work when sourced.

toolchain_test_unit() {
  python -m unittest discover -s utils/ppe42 -p test_build_toolchain.py -v
  python -m unittest discover -s utils/ppe42 -p test_package_darwin.py -v
}

toolchain_test_tail_calls() {
  "$BUILD_DIR/bin/llc" -mtriple=powerpc-unknown-elf -mcpu=ppe42 \
    -verify-machineinstrs \
    < llvm/test/CodeGen/PowerPC/ppe42-tailcall-void.ll | \
    "$BUILD_DIR/bin/FileCheck" \
      llvm/test/CodeGen/PowerPC/ppe42-tailcall-void.ll
}

toolchain_test_branches() {
  "$BUILD_DIR/bin/llvm-lit" -v --show-all \
    llvm/test/CodeGen/PowerPC/ppe42-bit-branch.mir \
    llvm/test/CodeGen/PowerPC/ppe42-bit-test-context.ll \
    llvm/test/CodeGen/PowerPC/ppe42-immediate-compare-branch.mir \
    llvm/test/CodeGen/PowerPC/ppe42-register-compare-branch.mir \
    llvm/test/CodeGen/PowerPC/ppe42-subtract-branch.mir \
    llvm/test/CodeGen/PowerPC/ppe42-wide-boundary-compare.ll
}

toolchain_test_core_support() {
  python -m unittest discover -s lldb/utils/ppe42 -p 'test_*.py'
  python -c 'import pathlib,sys; data=bytearray(0x2000); data[0x1234:0x1238]=bytes.fromhex("7fe00008"); pathlib.Path(sys.argv[1]).write_bytes(data)' \
    "$DEPS_DIR/tests/pibmem.bin"
  cat > "$DEPS_DIR/tests/registers.txt" <<'EOF'
| iar | 0xfff81234 | r1 | 0xfff80000 |
| lr  | 0xfff8123c | cr | 0x20000000 |
EOF
  cat > "$DEPS_DIR/tests/fault.s" <<'EOF'
.text
.globl ppe42_fault
.type ppe42_fault, @function
ppe42_fault:
  .cfi_startproc
  .cfi_return_column 65
  trap
  .cfi_endproc
.size ppe42_fault, . - ppe42_fault
.globl ppe42_caller
.type ppe42_caller, @function
ppe42_caller:
  .cfi_startproc
  .cfi_return_column 65
  bl ppe42_fault
  blr
  .cfi_endproc
.size ppe42_caller, . - ppe42_caller
EOF
  "$BUILD_DIR/bin/llvm-mc" -triple=powerpc-unknown-elf \
    -mcpu=ppe42 -filetype=obj \
    "$DEPS_DIR/tests/fault.s" \
    -o "$DEPS_DIR/tests/fault.o"
  "$BUILD_DIR/bin/ld.lld" -m elf32ppc \
    -Ttext=0xfff81234 -e ppe42_fault \
    "$DEPS_DIR/tests/fault.o" \
    -o "$DEPS_DIR/tests/fault.elf"
  "$BUILD_DIR/bin/llvm-nm" "$DEPS_DIR/tests/fault.elf"
  symbol_address="$("$BUILD_DIR/bin/llvm-nm" "$DEPS_DIR/tests/fault.elf" | awk '$3 == "ppe42_fault" {print tolower($1)}')"
  test "$symbol_address" = fff81234
  python lldb/utils/ppe42/ppe42_core.py \
    --pibmem "$DEPS_DIR/tests/pibmem.bin" \
    --base 0xfff80000 \
    --registers "$DEPS_DIR/tests/registers.txt" \
    --elf "$DEPS_DIR/tests/fault.elf" \
    --output "$DEPS_DIR/tests/ppe42.core"
  "$BUILD_DIR/bin/lldb" --batch --no-lldbinit \
    --core "$DEPS_DIR/tests/ppe42.core" \
    --one-line 'register read pc r1 lr' \
    > "$DEPS_DIR/tests/lldb.log"
  grep -q '0xfff81234' "$DEPS_DIR/tests/lldb.log"
  grep -q '0xfff80000' "$DEPS_DIR/tests/lldb.log"
  "$BUILD_DIR/bin/lldb" --batch --no-lldbinit \
    --core "$DEPS_DIR/tests/ppe42.core" \
    "$DEPS_DIR/tests/fault.elf" \
    --one-line 'target modules list' \
    --one-line 'image lookup -a 0xfff81234' \
    --one-line bt | tee "$DEPS_DIR/tests/backtrace.log"
  grep -q 'frame #0:.*ppe42_fault' "$DEPS_DIR/tests/backtrace.log"
  grep -q 'frame #1:.*ppe42_caller' "$DEPS_DIR/tests/backtrace.log"
}

toolchain_test_inliner() {
  cat > "$DEPS_DIR/tests/smoke.c" <<'EOF'
static int helper(int value) { return value + 1; }
int entry(int value) { return helper(value); }
EOF
  "$BUILD_DIR/bin/clang" -target powerpc-unknown-elf -mcpu=ppe42 \
    -Oz -mllvm -enable-ml-inliner=release \
    -c "$DEPS_DIR/tests/smoke.c" \
    -o "$DEPS_DIR/tests/smoke.o"
  "$BUILD_DIR/bin/llvm-readobj" --file-headers \
    "$DEPS_DIR/tests/smoke.o" | grep -q 'Machine: EM_PPC'
}

toolchain_test_small_data() {
  "$BUILD_DIR/bin/llvm-lit" -v \
    llvm/test/MC/PowerPC/ppc32-sda21.s \
    llvm/test/MC/PowerPC/ppc32-sda21-invalid.s \
    llvm/test/CodeGen/PowerPC/sdata-limit.ll \
    clang/test/Driver/ppc-sdata.c \
    lld/test/ELF/ppc32-sda21.s \
    lld/test/ELF/ppc32-sda21-invalid.s
}

toolchain_test_fused_instructions() {
  "$BUILD_DIR/bin/llvm-lit" -v \
    llvm/test/MC/PowerPC/ppe42-fused-compare-branch.s \
    llvm/test/MC/PowerPC/ppe42-fused-compare-branch-invalid.s
}

toolchain_test_byte_reversed_memory() {
  "$BUILD_DIR/bin/llvm-lit" -v \
    llvm/test/CodeGen/PowerPC/ppe42-byte-reversed-memory.ll \
    llvm/test/MC/PowerPC/ppe42-byte-reversed-memory.s
}

toolchain_test_signed_loads() {
  "$BUILD_DIR/bin/llvm-lit" -v \
    llvm/test/CodeGen/PowerPC/ppe42-signed-halfword-loads.ll \
    llvm/test/CodeGen/PowerPC/ppe42-signed-halfword-peephole.mir \
    llvm/test/MC/PowerPC/ppe42-signed-halfword-loads.s
}

toolchain_test_size_inlining() {
  "$BUILD_DIR/bin/llvm-lit" -v \
    llvm/test/CodeGen/PowerPC/ppe42-packed-stack-align.ll \
    llvm/test/CodeGen/PowerPC/ppe42-byval-stack-align.ll \
    llvm/test/CodeGen/PowerPC/ppe42-small-zero-fill.ll \
    llvm/test/CodeGen/PowerPC/ppe42-late-size-patterns.mir \
    llvm/test/CodeGen/PowerPC/ppe42-cr-spill.mir \
    llvm/test/CodeGen/PowerPC/ppe42-update-copies.mir \
    llvm/test/MC/PowerPC/ppe42-vdr-rotate.s \
    llvm/test/MC/PowerPC/ppe42-vdr-rotate-invalid.s \
    llvm/test/CodeGen/PowerPC/ppe42-extra-size-folds.mir \
    llvm/test/CodeGen/PowerPC/ppe42-address-folds.mir \
    llvm/test/CodeGen/PowerPC/ppe42-hoisted-loop-update.mir \
    llvm/test/CodeGen/PowerPC/ppe42-generic-cr-equality.mir \
    llvm/test/CodeGen/PowerPC/ppe42-wide-branch.ll \
    llvm/test/CodeGen/PowerPC/ppe42-scalar-updates.mir \
    llvm/test/CodeGen/PowerPC/ppe42-immediate-updates.ll \
    llvm/test/CodeGen/PowerPC/ppe42-late-record-compare.mir \
    llvm/test/CodeGen/PowerPC/ppe42-branch-known-bits.mir \
    llvm/test/CodeGen/PowerPC/ppe42-two-bit-branch.mir \
    llvm/test/CodeGen/PowerPC/ppe42-cr-spill-large.mir \
    llvm/test/CodeGen/PowerPC/ppe42-cr-spill.ll \
    llvm/test/CodeGen/PowerPC/ppe42-const-spill.mir \
    llvm/test/CodeGen/PowerPC/ppe42-const-spill.ll \
    llvm/test/CodeGen/PowerPC/ppe42-tuple-scalar-constants.mir \
    llvm/test/CodeGen/PowerPC/ppe42-size-helper-clone.ll \
    llvm/test/CodeGen/PowerPC/ppe42-size-helper-pipeline.ll \
    llvm/test/Transforms/Inline/PowerPC/ppe42-size-shared-asm.ll \
    llvm/test/Transforms/Inline/PowerPC/ppe42-size-shared-wide.ll \
    llvm/test/Transforms/Inline/PowerPC/ppe42-size-retained-helper.ll
}

toolchain_test_outlining() {
  "$BUILD_DIR/bin/llvm-lit" -v --show-all \
    llvm/test/CodeGen/PowerPC/ppe42-machine-outliner.mir \
    llvm/test/CodeGen/PowerPC/ppe42-machine-outliner.ll \
    llvm/test/CodeGen/PowerPC/ppe42-machine-outliner-calls.ll
}

toolchain_test_register_pairs() {
  "$BUILD_DIR/bin/llvm-lit" -v \
    llvm/test/CodeGen/PowerPC/ppe42-inline-asm-vdr.ll \
    llvm/test/CodeGen/PowerPC/ppe42-inline-asm-pairs.ll \
    llvm/test/CodeGen/PowerPC/ppe42-vdr-copy.mir \
    llvm/test/CodeGen/PowerPC/ppe42-pre-ra-stvd-pairs.mir \
    llvm/test/CodeGen/PowerPC/ppe42-pre-ra-lvd-pairs.mir \
    llvm/test/CodeGen/PowerPC/ppe42-symbolic-load-pairs.mir \
    llvm/test/CodeGen/PowerPC/ppe42-cached-sda-stores.mir \
    llvm/test/CodeGen/PowerPC/ppe42-equal-value-stores.mir \
    llvm/test/CodeGen/PowerPC/ppe42-sda-address-normalization.mir \
    llvm/test/CodeGen/PowerPC/ppe42-late-sda-updates.mir \
    llvm/test/CodeGen/PowerPC/ppe42-symbolic-load-pairs.ll \
    llvm/test/CodeGen/PowerPC/ppe42-vdr-update.ll \
    llvm/test/CodeGen/PowerPC/ppe42-vdr-update.mir \
    llvm/test/CodeGen/PowerPC/ppe42-i64-load-preinc.ll \
    llvm/test/CodeGen/PowerPC/ppe42-call-result-spills.ll \
    llvm/test/CodeGen/PowerPC/ppe42-lvd-load-pairs.mir
}

toolchain_test_stack_option() {
  "$BUILD_DIR/bin/llvm-lit" -v \
    llvm/test/CodeGen/PowerPC/ppe42-stack-ops.ll \
    clang/test/Driver/ppc-ppe42x-stack.c
}

toolchain_test_driver_linker() {
  "$BUILD_DIR/bin/llvm-lit" -v clang/test/Driver/ppc-elf-linker.c
}

toolchain_test_compiler() {
  mkdir -p "$DEPS_DIR/tests"
  printf '%s\n' 'Test PPE42 void sibling call'
  toolchain_test_tail_calls
  printf '%s\n' 'Test PPE42 branch fusion and safety regressions'
  toolchain_test_branches
  printf '%s\n' 'Test PPE42 PIBMEM core support'
  toolchain_test_core_support
  printf '%s\n' 'Test embedded MLGO inliner'
  toolchain_test_inliner
  printf '%s\n' 'Test PowerPC small-data relocations'
  toolchain_test_small_data
  printf '%s\n' 'Test PPE42 fused compare-and-branch instructions'
  toolchain_test_fused_instructions
  printf '%s\n' 'Test PPE42 byte-reversed memory legalization'
  toolchain_test_byte_reversed_memory
  printf '%s\n' 'Test PPE42 signed halfword load legalization'
  toolchain_test_signed_loads
  printf '%s\n' 'Test PPE42 size-aware inlining'
  toolchain_test_size_inlining
  printf '%s\n' 'Test PPE42 machine outlining'
  toolchain_test_outlining
  printf '%s\n' 'Test PPE42 inline assembly register pairs'
  toolchain_test_register_pairs
  printf '%s\n' 'Test PPE42 stack option'
  toolchain_test_stack_option
  printf '%s\n' 'Test PowerPC ELF driver linker selection'
  toolchain_test_driver_linker
}

toolchain_test_package() {
    mkdir -p "$DEPS_DIR/tests"
    if [[ ! -f "$DEPS_DIR/tests/ppe42.core" || ! -f "$DEPS_DIR/tests/fault.elf" ]]; then
      toolchain_test_core_support
    fi
  if [ "$RUNNER_OS" != macOS ]; then
    if ldd "$PACKAGE_DIR/bin/clang" | grep -q 'not found'; then
      echo 'Packaged clang has a missing shared-library dependency' >&2
      exit 1
    fi
    if ldd "$PACKAGE_DIR/bin/lldb" | grep -q 'not found' || \
       ldd "$PACKAGE_DIR/lib/liblldb.so" | grep -q 'not found'; then
      echo 'Packaged lldb has a missing shared-library dependency' >&2
      exit 1
    fi
    ldd "$PACKAGE_DIR/lib/liblldb.so" | \
      grep -Fq "$(realpath "$PACKAGE_DIR/lib")/libedit.so"
  fi
  "$PACKAGE_DIR/bin/lldb" --batch --no-lldbinit \
    --core "$DEPS_DIR/tests/ppe42.core" \
    --one-line 'register read pc r1 lr' \
    > "$DEPS_DIR/tests/packaged-lldb.log"
  grep -q '0xfff81234' "$DEPS_DIR/tests/packaged-lldb.log"
  "$PACKAGE_DIR/bin/lldb" --batch --no-lldbinit \
    --core "$DEPS_DIR/tests/ppe42.core" \
    "$DEPS_DIR/tests/fault.elf" \
    --one-line bt | tee "$DEPS_DIR/tests/packaged-backtrace.log"
  grep -q 'frame #0:.*ppe42_fault' "$DEPS_DIR/tests/packaged-backtrace.log"
  grep -q 'frame #1:.*ppe42_caller' "$DEPS_DIR/tests/packaged-backtrace.log"
  "$PACKAGE_DIR/bin/clang" --target=powerpc-unknown-elf -mcpu=ppe42 \
    -Wl,--version | grep 'LLD'
  printf 'void _start(void) { for (;;) {} }\n' > "$DEPS_DIR/tests/ppe42-link.c"
  "$PACKAGE_DIR/bin/clang" --target=powerpc-unknown-elf -mcpu=ppe42 \
    -msoft-float -nostdlib -Wl,-e,_start \
    "$DEPS_DIR/tests/ppe42-link.c" -o "$DEPS_DIR/tests/ppe42-link.elf"
  "$BUILD_DIR/bin/llvm-readobj" --file-headers \
    "$DEPS_DIR/tests/ppe42-link.elf" | grep 'Machine: EM_PPC'
    local expected_arch expected_machine machine tool
    expected_arch="$(uname -m)"
    case "$expected_arch" in
      x86_64) expected_machine='Advanced Micro Devices X86-64';;
      aarch64|arm64) expected_machine=AArch64;;
      *) echo "Unsupported toolchain host architecture: $expected_arch" >&2; return 1;;
    esac
    for tool in "${PPE42_PACKAGE_TOOLS[@]}"; do
      if [[ "$RUNNER_OS" == macOS ]]; then
        test "$(lipo -archs "$PACKAGE_DIR/bin/$tool")" = "$expected_arch"
      else
        machine="$(LC_ALL=C readelf -h "$PACKAGE_DIR/bin/$tool" | sed -n 's/^ *Machine: *//p')"
        test "$machine" = "$expected_machine"
      fi
    done
}
