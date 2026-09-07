; RUN: llc -mtriple=powerpc-unknown-elf -mcpu=ppe42 -verify-machineinstrs < %s | FileCheck %s
; Illegal i64 values must reach type legalization without VDR machine nodes.

define void @integer_ops(ptr %p, i64 %a, i64 %b, i32 %shift) {
; CHECK-LABEL: integer_ops:
; CHECK: blr
  %n = zext i32 %shift to i64
  %sum = add i64 %a, %b
  %left = shl i64 %sum, %n
  %right = lshr i64 %a, %n
  %signed = ashr i64 %b, %n
  %bits = or i64 %left, %right
  %result = xor i64 %bits, %signed
  store volatile i64 %result, ptr %p, align 8
  ret void
}
