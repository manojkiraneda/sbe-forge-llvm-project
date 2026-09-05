# RUN: llvm-mc -triple=powerpc-unknown-elf -mcpu=ppe42 -show-encoding %s | FileCheck %s --check-prefix=ENC
# RUN: llvm-mc -triple=powerpc-unknown-elf -mcpu=ppe42 -filetype=obj %s -o %t
# RUN: llvm-objdump -d --mcpu=ppe42 %t | FileCheck %s --check-prefix=DIS

# Encodings are cross-checked against PPE42 firmware produced by the IBM GNU
# toolchain, including cmplwbge 4, 3, +16 and bwz 3, +36.
        cmplwbge %r4, %r3, 16
        bwltz %r4, 8
        bwz %r3, 36
        cmplwblt %r3, %r4, 12
        bwnz %r5, -4
        cmpwibc 1, 2, %r9, 0, 28
.Lback:
        nop
        bwz %r3, .Lback
        bwz %r4, .Lforward
        nop
.Lforward:

# ENC: cmplwbge 4, 3, {{.*}}encoding: [0x05,0x04,0x18,0x08]
# ENC: cmpwiblt 4, 0, {{.*}}encoding: [0x06,0x84,0x00,0x04]
# ENC: cmpwibeq 3, 0, {{.*}}encoding: [0x06,0xc3,0x00,0x12]
# ENC: cmplwblt 3, 4, {{.*}}encoding: [0x05,0x83,0x20,0x06]
# ENC: cmpwibne 5, 0, {{.*}}encoding: [0x06,0x45,0x07,0xfe]
# ENC: cmpwibeq 9, 0, {{.*}}encoding: [0x06,0xc9,0x00,0x0e]
# ENC: nop
# ENC: cmpwibeq 3, 0, .Lback
# ENC-NEXT: # fixup A - offset: 0, value: .Lback, kind: fixup_ppc_ppe42_br10
# ENC: cmpwibeq 4, 0, .Lforward
# ENC-NEXT: # fixup A - offset: 0, value: .Lforward, kind: fixup_ppc_ppe42_br10

# DIS: cmplwbge 4, 3, 16
# DIS: cmpwiblt 4, 0, 8
# DIS: cmpwibeq 3, 0, 36
# DIS: cmplwblt 3, 4, 12
# DIS: cmpwibne 5, 0, -4
# DIS: cmpwibeq 9, 0, 28
# DIS: nop
# DIS: cmpwibeq 3, 0, -4
# DIS: cmpwibeq 4, 0, 8
