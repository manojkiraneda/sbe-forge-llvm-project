# RUN: llvm-mc -triple=powerpc-unknown-elf -mcpu=ppe42 -show-encoding %s | FileCheck %s
# RUN: llvm-mc -triple=powerpc-unknown-elf -mcpu=ppe42 -mattr=-ppe42x-stack -show-encoding %s | FileCheck %s
# RUN: not llvm-mc -triple=powerpc-unknown-elf -mcpu=ppe42 -mattr=-ppe42x-rotate %s 2>&1 | FileCheck %s --check-prefix=DISABLED
# DISABLED: error: instruction requires PPE42X rotate support
# CHECK: rldicl d3, d5, 59, 5{{.*}}encoding: [0x78,0xa3,0xd9,0x42]
rldicl 3, 5, 59, 5
# CHECK: rldicr d3, d5, 5, 58{{.*}}encoding: [0x78,0xa3,0x2e,0xa4]
rldicr 3, 5, 5, 58
# CHECK: rldimi d3, d5, 5, 8{{.*}}encoding: [0x78,0xa3,0x2a,0x0c]
rldimi 3, 5, 5, 8
# CHECK: rldicl. d3, d5, 59, 5{{.*}}encoding: [0x78,0xa3,0xd9,0x43]
rldicl. 3, 5, 59, 5
# CHECK: rldicr. d3, d5, 5, 58{{.*}}encoding: [0x78,0xa3,0x2e,0xa5]
rldicr. 3, 5, 5, 58
# CHECK: rldimi. d3, d5, 5, 8{{.*}}encoding: [0x78,0xa3,0x2a,0x0d]
rldimi. 3, 5, 5, 8
