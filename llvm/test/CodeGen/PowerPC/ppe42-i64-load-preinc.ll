; RUN: llc -mtriple=powerpc-unknown-elf -mcpu=ppe42 -verify-machineinstrs < %s | FileCheck %s

@operands = global [2 x i64] zeroinitializer, align 8
@result = global i64 0, align 8

define void @load_adjacent_i64() {
; CHECK-LABEL: load_adjacent_i64:
; CHECK:       lvd
; CHECK:       lvd
; CHECK-NOT:   ldu
  %lhs = load volatile i64, ptr @operands, align 8
  %rhs.ptr = getelementptr inbounds [2 x i64], ptr @operands, i32 0, i32 1
  %rhs = load volatile i64, ptr %rhs.ptr, align 8
  %sum = add i64 %lhs, %rhs
  store volatile i64 %sum, ptr @result, align 8
  ret void
}
