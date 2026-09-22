# RUN: llvm-mc -triple=powerpc-unknown-elf -mcpu=ppe42 -show-encoding %s | FileCheck %s

# PPE42 User's Manual, section 9.4.59: XO-form opcode 4, XO=392.
# CHECK: mullhw r3, r4, r5                  # encoding: [0x10,0x64,0x28,0x10]
# CHECK: mullhw. r3, r4, r5                # encoding: [0x10,0x64,0x28,0x11]
# CHECK: mullhwu r6, r7, r8                # encoding: [0x10,0xc7,0x40,0x10]
# CHECK: mullhwu. r6, r7, r8              # encoding: [0x10,0xc7,0x40,0x11]

        mullhw  r3, r4, r5
        mullhw. r3, r4, r5
        mullhwu r6, r7, r8
        mullhwu. r6, r7, r8
