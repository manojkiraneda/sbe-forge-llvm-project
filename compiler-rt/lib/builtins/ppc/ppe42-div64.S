//===-- ppe42-div64.S - PPE42 unsigned 64-bit division ------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

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

        .section .text.__divdi3,"ax",@progbits
        .align 2
        .globl __divdi3
        .type __divdi3, @function
__divdi3:
        mflr    %r0
        stwu    %r1, -16(%r1)
        stw     %r0, 20(%r1)
        xor     %r7, %r3, %r5
        stw     %r7, 8(%r1)
        cmpwi   %r3, 0
        bge     .Ldivdi_dividend_ready
        subfic  %r4, %r4, 0
        subfze  %r3, %r3
.Ldivdi_dividend_ready:
        cmpwi   %r5, 0
        bge     .Ldivdi_divisor_ready
        subfic  %r6, %r6, 0
        subfze  %r5, %r5
.Ldivdi_divisor_ready:
        bl      __udivdi3
        lwz     %r7, 8(%r1)
        cmpwi   %r7, 0
        bge     .Ldivdi_result_ready
        subfic  %r4, %r4, 0
        subfze  %r3, %r3
.Ldivdi_result_ready:
        lwz     %r0, 20(%r1)
        mtlr    %r0
        addi    %r1, %r1, 16
        blr
        .size __divdi3, .-__divdi3

        .section .text.__moddi3,"ax",@progbits
        .align 2
        .globl __moddi3
        .type __moddi3, @function
__moddi3:
        mflr    %r0
        stwu    %r1, -16(%r1)
        stw     %r0, 20(%r1)
        stw     %r3, 8(%r1)
        cmpwi   %r3, 0
        bge     .Lmoddi_dividend_ready
        subfic  %r4, %r4, 0
        subfze  %r3, %r3
.Lmoddi_dividend_ready:
        cmpwi   %r5, 0
        bge     .Lmoddi_divisor_ready
        subfic  %r6, %r6, 0
        subfze  %r5, %r5
.Lmoddi_divisor_ready:
        bl      __umoddi3
        lwz     %r7, 8(%r1)
        cmpwi   %r7, 0
        bge     .Lmoddi_result_ready
        subfic  %r4, %r4, 0
        subfze  %r3, %r3
.Lmoddi_result_ready:
        lwz     %r0, 20(%r1)
        mtlr    %r0
        addi    %r1, %r1, 16
        blr
        .size __moddi3, .-__moddi3
