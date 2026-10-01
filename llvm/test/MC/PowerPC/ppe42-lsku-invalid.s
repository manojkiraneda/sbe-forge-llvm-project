# RUN: not llvm-mc -triple=powerpc-unknown-elf -mcpu=ppe42 %s 2>&1 | FileCheck %s

        lsku 1, 88(2)
        lsku 0, 88(0)
        lsku 1, -8(1)
        lsku 1, 7(1)
        lsku 1, 32768(1)

# CHECK-COUNT-5: error:
