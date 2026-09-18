// RUN: not llvm-mc -triple=powerpc-unknown-elf -mcpu=ppe42 %s 2>&1 | FileCheck %s

// PPE42 does not implement lhzux, 64-bit rotates, or VSX paired-vector loads.
// CHECK: error: instruction use requires an option that is not enabled
        lhzux %r4, %r5, %r6
        rotldi %r4, %r5, 1
        lxvp %v4, 0(%r5)
