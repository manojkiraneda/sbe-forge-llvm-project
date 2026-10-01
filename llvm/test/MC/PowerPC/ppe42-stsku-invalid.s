# RUN: not llvm-mc -triple=powerpc-unknown-elf -mcpu=ppe42 %s 2>&1 | FileCheck %s

        stsku 1, -88(2)
        stsku 0, -88(0)
        stsku 1, 8(1)
        stsku 1, -7(1)
        stsku 1, -32776(1)

# CHECK-COUNT-3: error: stsku requires matching nonzero registers and a negative 8-byte aligned offset
# CHECK-COUNT-2: error: invalid operand for instruction
