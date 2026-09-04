# RUN: llvm-mc -triple=powerpc-unknown-elf -mcpu=ppe42 -filetype=obj %s -o - | \
# RUN:   llvm-objdump -d --mcpu=ppe42 - | FileCheck %s

        .nolist
        .list

        stw r3, 0(r4)
        lvd d2, 8(r3)
        stvd d28, -8(r4)

# CHECK: stw 3, 0(4)
# CHECK: lvd 2, 8(3)
# CHECK: stvd 28, -8(4)
