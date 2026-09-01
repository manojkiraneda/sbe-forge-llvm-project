; RUN: llc -mtriple=powerpc-unknown-elf -mcpu=ppe42 -verify-machineinstrs < %s | FileCheck %s

define void @add_i64(ptr %lhs.ptr, ptr %rhs.ptr, ptr %result.ptr) {
; CHECK-LABEL: add_i64:
; CHECK:       addc
; CHECK-NEXT:  adde
  %lhs = load volatile i64, ptr %lhs.ptr, align 8
  %rhs = load volatile i64, ptr %rhs.ptr, align 8
  %result = add i64 %lhs, %rhs
  store volatile i64 %result, ptr %result.ptr, align 8
  ret void
}
