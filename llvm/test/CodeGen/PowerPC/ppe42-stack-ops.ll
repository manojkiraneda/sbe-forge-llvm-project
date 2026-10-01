; RUN: llc -mtriple=powerpc-unknown-elf -mcpu=ppe42 -disable-tail-calls -verify-machineinstrs < %s | FileCheck %s

declare void @sink(ptr)

; The outgoing area occupies the first eight bytes of this 16-byte frame,
; leaving the VDR30 save slot free.
define void @caller(ptr %p) {
; CHECK-LABEL: caller:
; CHECK-NOT: mflr
; CHECK: stsku 1, -16(1)
; CHECK: .cfi_def_cfa_offset 16
; CHECK: .cfi_offset lr, 4
; CHECK: bl sink
; CHECK: lsku 1, 16(1)
; CHECK-NOT: mtlr
; CHECK-NEXT: blr
entry:
  call void @sink(ptr %p)
  ret void
}

; A local in the VDR30 save slot requires the ordinary frame sequence.
define i32 @leaf_stack(i32 %x) {
; CHECK-LABEL: leaf_stack:
; CHECK: stwu 1, -16(1)
; CHECK-NOT: stsku
; CHECK: stw 3, 12(1)
; CHECK: lwz 3, 12(1)
; CHECK: addi 1, 1, 16
; CHECK-NOT: lsku
; CHECK: blr
entry:
  %p = alloca i32, align 4
  store volatile i32 %x, ptr %p
  %v = load volatile i32, ptr %p
  ret i32 %v
}
