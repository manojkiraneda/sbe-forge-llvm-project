# RUN: not llvm-mc -triple=powerpc-unknown-elf -mcpu=ppe42 %s 2>&1 | FileCheck %s
# CHECK: error: invalid PPE42 virtual-doubleword register
rldicl 11, 3, 1, 1
# CHECK: error: invalid PPE42 virtual-doubleword register
rldicr 3, 27, 1, 62
# CHECK: error: invalid PPE42 virtual-doubleword register
sldi 11, 3, 1
