# RUN: not llvm-mc -triple=powerpc-unknown-elf -mcpu=ppe42 %s 2>&1 | FileCheck %s
# RUN: llvm-mc -triple=powerpc-unknown-elf -mcpu=440 -filetype=obj %s -o %t.o

# All four forms are omitted by PPE42, but remain available on ordinary PPC.
# CHECK: error: instruction use requires an option that is not enabled
# CHECK-NEXT: lha 3, 0(4)
# CHECK: error: instruction use requires an option that is not enabled
# CHECK-NEXT: lhau 3, 2(4)
# CHECK: error: instruction use requires an option that is not enabled
# CHECK-NEXT: lhax 3, 4, 5
# CHECK: error: instruction use requires an option that is not enabled
# CHECK-NEXT: lhaux 3, 4, 5
lha 3, 0(4)
lhau 3, 2(4)
lhax 3, 4, 5
lhaux 3, 4, 5
