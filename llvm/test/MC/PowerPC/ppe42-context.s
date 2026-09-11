# RUN: llvm-mc -triple=powerpc-unknown-elf -mcpu=ppe42 -show-encoding %s | FileCheck %s

        lcxu 1, 88(1)
        stcxu 1, -88(1)

# CHECK: lcxu 1, 88(1){{.*}}encoding: [0xe8,0x21,0x00,0x5f]
# CHECK: stcxu 1, -88(1){{.*}}encoding: [0xf8,0x21,0xff,0xaf]
