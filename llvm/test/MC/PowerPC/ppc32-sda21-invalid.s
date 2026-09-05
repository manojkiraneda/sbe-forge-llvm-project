# RUN: split-file %s %t
# RUN: not llvm-mc -triple=powerpc64-unknown-elf -filetype=obj %t/64.s -o /dev/null 2>&1 | FileCheck %s --check-prefix=PPC64
# RUN: not llvm-mc -triple=powerpc-unknown-elf -filetype=obj %t/invalid.s -o /dev/null 2>&1 | FileCheck %s --check-prefix=INVALID

# PPC64: error: @sda21 is only supported for 32-bit PowerPC ELF
# INVALID-COUNT-2: error: @sda21 requires a D-form instruction operand

#--- 64.s
lwz 3, data@sda21(0)

#--- invalid.s
.long data@sda21
b data@sda21
