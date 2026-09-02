; RUN: llc -mtriple=powerpc-unknown-elf -mcpu=ppe42 -verify-machineinstrs < %s | FileCheck %s

define void @sub_i64(ptr %lhs.ptr, ptr %rhs.ptr, ptr %result.ptr) {
; CHECK-LABEL: sub_i64:
; CHECK:       subc
; CHECK-NEXT:  subfe
  %lhs = load volatile i64, ptr %lhs.ptr, align 8
  %rhs = load volatile i64, ptr %rhs.ptr, align 8
  %result = sub i64 %lhs, %rhs
  store volatile i64 %result, ptr %result.ptr, align 8
  ret void
}

define void @mul_i64(ptr %lhs.ptr, ptr %rhs.ptr, ptr %result.ptr) {
; CHECK-LABEL: mul_i64:
; CHECK:       mullw
; CHECK:       mulhwu
; CHECK:       mullw
; CHECK:       mullw
  %lhs = load volatile i64, ptr %lhs.ptr, align 8
  %rhs = load volatile i64, ptr %rhs.ptr, align 8
  %result = mul i64 %lhs, %rhs
  store volatile i64 %result, ptr %result.ptr, align 8
  ret void
}
