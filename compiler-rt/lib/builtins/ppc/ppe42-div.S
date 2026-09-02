//===-- ppe42-div.S - PPE42 unsigned integer division --------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

        .section .text.divide,"ax",@progbits
        .align 2
.Ludivmodsi4_loop:
        cmplw   %r4, %r3
        bge     .Ludiv_ready
        bdz     .Ludiv_overflow
        cmpwi   %r4, 0
        blt     .Ludiv_ready
        rlwinm  %r4, %r4, 1, 0, 30
        rlwinm  %r9, %r9, 1, 0, 30
        b       .Ludivmodsi4_loop
.Ludiv_overflow:
        li      %r9, 0
.Ludiv_ready:
        li      %r10, 0
.Ludiv_loop:
        cmpwi   %r9, 0
        beq     .Ludiv_done
        cmplw   %r3, %r4
        blt     .Ludiv_next
        subf    %r3, %r4, %r3
        or      %r10, %r10, %r9
.Ludiv_next:
        rlwinm  %r9, %r9, 31, 1, 31
        rlwinm  %r4, %r4, 31, 1, 31
        b       .Ludiv_loop
.Ludiv_done:
        cmpwi   %r5, 0
        bne     .Ludiv_return
        mr      %r3, %r10
.Ludiv_return:
        blr

        .globl __udivsi3
        .type __udivsi3, @function
__udivsi3:
        li      %r5, 0
        li      %r10, 33
        mtctr   %r10
        li      %r9, 1
        b       .Ludivmodsi4_loop
        .size __udivsi3, .-__udivsi3

        .globl __umodsi3
        .type __umodsi3, @function
__umodsi3:
        li      %r5, 1
        li      %r10, 33
        mtctr   %r10
        li      %r9, 1
        b       .Ludivmodsi4_loop
        .size __umodsi3, .-__umodsi3

        .section .text.__ppe42_udiv64,"ax",@progbits
        .align 2
        .type __ppe42_udiv64, @function
__ppe42_udiv64:
        li      %r9, 0
        li      %r10, 0
        li      %r0, 64
        mtctr   %r0
.Ludiv64_loop:
        addc    %r4, %r4, %r4
        adde    %r3, %r3, %r3
        adde    %r10, %r10, %r10
        adde    %r9, %r9, %r9
        cmplw   %r9, %r5
        blt     .Ludiv64_next
        bgt     .Ludiv64_subtract
        cmplw   %r10, %r6
        blt     .Ludiv64_next
.Ludiv64_subtract:
        subfc   %r10, %r6, %r10
        subfe   %r9, %r5, %r9
        ori     %r4, %r4, 1
.Ludiv64_next:
        bdnz    .Ludiv64_loop
        blr
        .size __ppe42_udiv64, .-__ppe42_udiv64

        .section .text.__udivdi3,"ax",@progbits
        .align 2
        .globl __udivdi3
        .type __udivdi3, @function
__udivdi3:
        b       __ppe42_udiv64
        .size __udivdi3, .-__udivdi3

        .section .text.__umoddi3,"ax",@progbits
        .align 2
        .globl __umoddi3
        .type __umoddi3, @function
__umoddi3:
        mflr    %r0
        stwu    %r1, -16(%r1)
        stw     %r0, 20(%r1)
        bl      __ppe42_udiv64
        mr      %r3, %r9
        mr      %r4, %r10
        lwz     %r0, 20(%r1)
        mtlr    %r0
        addi    %r1, %r1, 16
        blr
        .size __umoddi3, .-__umoddi3
