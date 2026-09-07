# RUN: llvm-mc -triple=powerpc-unknown-elf -mcpu=ppe42 -show-encoding %s | FileCheck %s
# PPE42 manual sections 9.4.48 and 9.4.94: eleven-bit XO 17 and 145.
# CHECK: lvdx d3, 3, 4{{.*}}encoding: [0x7c,0x63,0x20,0x11]
lvdx 3, 3, 4
# CHECK: stvdx d5, 3, 4{{.*}}encoding: [0x7c,0xa3,0x20,0x91]
stvdx 5, 3, 4
# CHECK: lvdx d3, 0, 4{{.*}}encoding: [0x7c,0x60,0x20,0x11]
lvdx 3, 0, 4
