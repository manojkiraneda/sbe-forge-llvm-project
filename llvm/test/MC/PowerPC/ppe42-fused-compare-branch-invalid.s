# RUN: split-file %s %t
# RUN: not llvm-mc -triple=powerpc-unknown-elf -mcpu=ppe42 %t/range.s 2>&1 | FileCheck %s --check-prefix=RANGE
# RUN: not llvm-mc -triple=powerpc-unknown-elf -mcpu=ppe42 %t/alignment.s 2>&1 | FileCheck %s --check-prefix=ALIGN
# RUN: not llvm-mc -triple=powerpc-unknown-elf -mcpu=ppe42 -filetype=obj %t/external.s -o /dev/null 2>&1 | FileCheck %s --check-prefix=EXTERNAL

# RANGE: error: invalid operand for instruction
# ALIGN: error: invalid operand for instruction
# EXTERNAL: error: PPE42 fused branch target must be locally resolvable

#--- range.s
bwz 3, 2048

#--- alignment.s
bwz 3, 2

#--- external.s
.globl external
bwz 3, external
