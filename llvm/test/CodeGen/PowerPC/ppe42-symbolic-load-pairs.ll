; RUN: llc -mtriple=powerpc-none-eabi -mcpu=ppe42 -verify-machineinstrs %s -o - | FileCheck %s
; RUN: llc -mtriple=powerpc-none-eabi -mcpu=ppe42 -verify-machineinstrs -filetype=obj %s -o %t.o
; RUN: llvm-objdump -dr --mcpu=ppe42 %t.o | FileCheck %s --check-prefix=OBJ
; RUN: opt -passes=debugify %s -o %t.bc
; RUN: llc -mtriple=powerpc-none-eabi -mcpu=ppe42 -verify-machineinstrs %t.bc -o - | FileCheck %s
;
; ReturnCode contains two words with an explicitly eight-byte-aligned first
; member. Do not lose the doubleword load merely because SDA/LO relocation
; folding gives its halves different-looking machine addresses.
@current_err = external global i64, align 8
@unaligned = external global i64, align 4
@large = external global [2 x i64], align 8

define i64 @aligned_sda() optsize {
; CHECK-LABEL: aligned_sda:
; CHECK-NOT: lwz
; CHECK-NOT: la
; CHECK: lvd d3, current_err@sda21(13)
; CHECK-NEXT: blr
; OBJ-LABEL: <aligned_sda>:
; OBJ: lvd
; OBJ: R_PPC_EMB_SDA21 current_err
  %v = load i64, ptr @current_err, align 8
  ret i64 %v
}

define i64 @aligned_absolute() optsize {
; CHECK-LABEL: aligned_absolute:
; CHECK: lis
; CHECK-NOT: lwz
; CHECK: lvd d3, large@l(
; CHECK-NEXT: blr
  %v = load i64, ptr @large, align 8
  ret i64 %v
}

define i64 @unaligned_sda() optsize {
; CHECK-LABEL: unaligned_sda:
; CHECK-NOT: lvd
; CHECK: lwz
; CHECK: lwz
; CHECK: blr
  %v = load i64, ptr @unaligned, align 4
  ret i64 %v
}

define i64 @volatile_sda() optsize {
; CHECK-LABEL: volatile_sda:
; CHECK-NOT: lvd
; CHECK: lwz
; CHECK: lwz
; CHECK: blr
  %v = load volatile i64, ptr @current_err, align 8
  ret i64 %v
}

!llvm.module.flags = !{!0}
!0 = !{i32 8, !"SmallDataLimit", i32 8}
