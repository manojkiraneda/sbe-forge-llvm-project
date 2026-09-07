// RUN: llvm-mc -triple=powerpc-unknown-elf -mcpu=ppe42 -show-encoding %s | FileCheck %s

// CHECK: mfisr 4                              # encoding: [0x7c,0x9c,0x0a,0xa6]
// CHECK: mfedr 4                              # encoding: [0x7c,0x9d,0x0a,0xa6]
        mfisr %r4
        mfedr %r4
