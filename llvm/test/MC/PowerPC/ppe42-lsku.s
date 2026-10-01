# RUN: llvm-mc -triple=powerpc-unknown-elf -mcpu=ppe42 -show-encoding %s | FileCheck %s
# RUN: llvm-mc -triple=powerpcle-unknown-elf -mcpu=ppe42 -show-encoding %s | FileCheck %s --check-prefix=LE
# RUN: echo '0xe8 0x21 0x00 0x5b' | llvm-mc -triple=powerpc-unknown-elf -mcpu=ppe42 -disassemble | FileCheck %s --check-prefix=DIS

        lsku 1, 88(1)
        lsku 31, 32760(31)

# CHECK: lsku 1, 88(1){{.*}}encoding: [0xe8,0x21,0x00,0x5b]
# CHECK: lsku 31, 32760(31){{.*}}encoding: [0xeb,0xff,0x7f,0xfb]
# LE: lsku 1, 88(1){{.*}}encoding: [0x5b,0x00,0x21,0xe8]
# LE: lsku 31, 32760(31){{.*}}encoding: [0xfb,0x7f,0xff,0xeb]
# DIS: lsku 1, 88(1)
