//===-- ppe42-div32.S - PPE42 unsigned 32-bit division ------------------===//
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

        .section .text.__divsi3,"ax",@progbits
        .align 2
        .globl __divsi3
        .type __divsi3, @function
__divsi3:
        mflr    %r0
        stwu    %r1, -16(%r1)
        stw     %r0, 20(%r1)
        xor     %r6, %r3, %r4
        stw     %r6, 8(%r1)
        cmpwi   %r3, 0
        bge     .Ldivsi_dividend_ready
        subfic  %r3, %r3, 0
.Ldivsi_dividend_ready:
        cmpwi   %r4, 0
        bge     .Ldivsi_divisor_ready
        subfic  %r4, %r4, 0
.Ldivsi_divisor_ready:
        bl      __udivsi3
        lwz     %r6, 8(%r1)
        cmpwi   %r6, 0
        bge     .Ldivsi_result_ready
        subfic  %r3, %r3, 0
.Ldivsi_result_ready:
        lwz     %r0, 20(%r1)
        mtlr    %r0
        addi    %r1, %r1, 16
        blr
        .size __divsi3, .-__divsi3

        .section .text.__modsi3,"ax",@progbits
        .align 2
        .globl __modsi3
        .type __modsi3, @function
__modsi3:
        mflr    %r0
        stwu    %r1, -16(%r1)
        stw     %r0, 20(%r1)
        stw     %r3, 8(%r1)
        cmpwi   %r3, 0
        bge     .Lmodsi_dividend_ready
        subfic  %r3, %r3, 0
.Lmodsi_dividend_ready:
        cmpwi   %r4, 0
        bge     .Lmodsi_divisor_ready
        subfic  %r4, %r4, 0
.Lmodsi_divisor_ready:
        bl      __umodsi3
        lwz     %r6, 8(%r1)
        cmpwi   %r6, 0
        bge     .Lmodsi_result_ready
        subfic  %r3, %r3, 0
.Lmodsi_result_ready:
        lwz     %r0, 20(%r1)
        mtlr    %r0
        addi    %r1, %r1, 16
        blr
        .size __modsi3, .-__modsi3
