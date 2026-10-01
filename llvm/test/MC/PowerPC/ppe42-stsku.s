# RUN: llvm-mc -triple=powerpc-unknown-elf -mcpu=ppe42 -show-encoding %s | FileCheck %s
# RUN: llvm-mc -triple=powerpcle-unknown-elf -mcpu=ppe42 -show-encoding %s | FileCheck %s --check-prefix=LE
# RUN: echo '0xf8 0x21 0xff 0xab' | llvm-mc -triple=powerpc-unknown-elf -mcpu=ppe42 -disassemble | FileCheck %s --check-prefix=DIS

        stsku 1, -88(1)
        stsku 31, -32768(31)

# CHECK: stsku 1, -88(1){{.*}}encoding: [0xf8,0x21,0xff,0xab]
# CHECK: stsku 31, -32768(31){{.*}}encoding: [0xfb,0xff,0x80,0x03]
# LE: stsku 1, -88(1){{.*}}encoding: [0xab,0xff,0x21,0xf8]
# LE: stsku 31, -32768(31){{.*}}encoding: [0x03,0x80,0xff,0xfb]
# DIS: stsku 1, -88(1)
