# RUN: llvm-mc -triple=powerpc-unknown-elf -mcpu=ppe42 -show-encoding %s | FileCheck %s

        cmpwblt 3, 4, 12
        cmpwbge 4, 3, 16
        cmpwbeq 5, 6, 20
        cmpwbne 7, 8, 24
        subwibz 0, 1, 28
        subwibnz 4, 1, -4
        mtedr 2
        mtdbcr 5
        lvd 1, 0x2040(4)
        lvdu 5, 8(10)
        stvdu 6, 8(9)

# CHECK: cmpwblt 3, 4, {{.*}}encoding: [0x04,0x83,0x20,0x06]
# CHECK: cmpwbge 4, 3, {{.*}}encoding: [0x04,0x04,0x18,0x08]
# CHECK: cmpwbeq 5, 6, {{.*}}encoding: [0x04,0xc5,0x30,0x0a]
# CHECK: cmpwbne 7, 8, {{.*}}encoding: [0x04,0x47,0x40,0x0c]
# CHECK: subwibz 0, 1, {{.*}}encoding: [0x06,0xe0,0x08,0x0e]
# CHECK: subwibnz 4, 1, {{.*}}encoding: [0x06,0x64,0x0f,0xfe]
# CHECK: mtedr 2{{.*}}encoding: [0x7c,0x5d,0x0b,0xa6]
# CHECK: mtdbcr 5{{.*}}encoding: [0x7c,0xb4,0x4b,0xa6]
# CHECK: lvd 1, 8256(4){{.*}}encoding: [0x14,0x24,0x20,0x40]
# CHECK: lvdu 5, 8(10){{.*}}encoding: [0x24,0xaa,0x00,0x08]
# CHECK: stvdu 6, 8(9){{.*}}encoding: [0x58,0xc9,0x00,0x08]
