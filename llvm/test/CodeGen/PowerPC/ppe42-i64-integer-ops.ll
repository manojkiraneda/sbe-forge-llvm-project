; RUN: llc -mtriple=powerpc-unknown-elf -mcpu=ppe42 -verify-machineinstrs < %s | FileCheck %s

define i64 @bitwise_i64(i64 %a, i64 %b) {
; CHECK-LABEL: bitwise_i64:
; CHECK-NOT: and8
; CHECK-NOT: or8
; CHECK-NOT: xor8
  %and = and i64 %a, %b
  %or = or i64 %a, %b
  %xor = xor i64 %and, %or
  ret i64 %xor
}

define i64 @shifts_i64(i64 %a, i32 %amount) {
; CHECK-LABEL: shifts_i64:
; CHECK-NOT: rldicr
; CHECK-NOT: sld
; CHECK-NOT: srd
; CHECK-NOT: sradi
  %left = shl i64 %a, %amount
  %right = lshr i64 %a, %amount
  %signed = ashr i64 %a, %amount
  %or = or i64 %left, %right
  %result = xor i64 %or, %signed
  ret i64 %result
}
