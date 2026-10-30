; RUN: llc -mtriple=powerpc-unknown-elf -mcpu=ppe42 -verify-machineinstrs < %s | FileCheck %s --implicit-check-not=ldu
; RUN: llc -mtriple=powerpc-unknown-elf -mcpu=ppe42 -verify-machineinstrs -filetype=obj %s -o %t.o

; Ordinary aligned loads in a size-optimized function can be paired.
; Keep the LVD requirement here, rather than asking the pairing pass to merge
; volatile accesses. The pointer base also tests the adjacent pre-index case
; without depending on symbolic address folding.
define i64 @load_adjacent_i64(ptr %p) optsize {
; CHECK-LABEL: load_adjacent_i64:
; CHECK:       lvd
; CHECK:       lvd
; CHECK:       blr
  %lhs = load i64, ptr %p, align 8
  %rhs.ptr = getelementptr inbounds i64, ptr %p, i32 1
  %rhs = load i64, ptr %rhs.ptr, align 8
  %sum = add i64 %lhs, %rhs
  ret i64 %sum
}

; Retain the original volatile global-load reproducer as a negative pairing
; test. Legalization splits each i64 access; the pairing pass must not merge
; the resulting volatile word operations.
@operands = global [2 x i64] zeroinitializer, align 8
@result = global i64 0, align 8

define void @volatile_adjacent_i64() optsize {
; CHECK-LABEL: volatile_adjacent_i64:
; CHECK-NOT:   lvd
; CHECK:       lwz
; CHECK:       lwz
; CHECK:       lwz
; CHECK:       lwz
; CHECK-NOT:   lvd
; CHECK:       blr
  %lhs = load volatile i64, ptr @operands, align 8
  %rhs.ptr = getelementptr inbounds [2 x i64], ptr @operands, i32 0, i32 1
  %rhs = load volatile i64, ptr %rhs.ptr, align 8
  %sum = add i64 %lhs, %rhs
  store volatile i64 %sum, ptr @result, align 8
  ret void
}
