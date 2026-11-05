# RUN: not llvm-mc -triple=powerpc-unknown-elf -mcpu=ppe42 %s 2>&1 | FileCheck %s
# RUN: llvm-mc -triple=powerpc-unknown-elf -mcpu=440 -filetype=obj %s -o %t.o

# CHECK: error: instruction use requires an option to be enabled
lhbrx 3, 4, 5
# CHECK: error: instruction use requires an option to be enabled
lwbrx 3, 4, 5
# CHECK: error: instruction use requires an option to be enabled
sthbrx 3, 4, 5
# CHECK: error: instruction use requires an option to be enabled
stwbrx 3, 4, 5
