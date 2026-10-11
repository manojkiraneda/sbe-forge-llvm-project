; RUN: llc -mtriple=powerpc-unknown-elf -mcpu=ppe42 -disable-tail-calls -verify-machineinstrs < %s | FileCheck %s
; RUN: llc -mtriple=powerpc-unknown-elf -mcpu=ppe42 -mattr=-ppe42x-stack -disable-tail-calls -verify-machineinstrs < %s | FileCheck %s --check-prefix=NO-STACK

declare void @sink(ptr)
declare void @sink_many(i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32)

; A call frame can use the stack pair to save LR alone.
define void @caller(ptr %p) {
; CHECK-LABEL: caller:
; CHECK: stsku 1, -16(1)
; CHECK: .cfi_def_cfa_offset 16
; CHECK: .cfi_offset lr, 4
; CHECK: bl sink
; CHECK: lsku 1, 16(1)
; CHECK: blr
; NO-STACK-LABEL: caller:
; NO-STACK-NOT: stsku
; NO-STACK: stwu 1,
; NO-STACK: bl sink
; NO-STACK-NOT: lsku
; NO-STACK: blr
entry:
  call void @sink(ptr %p)
  ret void
}

; The R30 spill occupies the VDR30 save area. STSKU/LSKU handle it directly.
define void @saved_r30(ptr %p) {
; CHECK-LABEL: saved_r30:
; CHECK: stsku 1, -16(1)
; CHECK-NOT: stw 30,
; CHECK: bl sink
; CHECK-NOT: lwz 30,
; CHECK: lsku 1, 16(1)
; CHECK-NEXT: blr
; NO-STACK-LABEL: saved_r30:
; NO-STACK-NOT: stsku
; NO-STACK: stwu 1,
; NO-STACK: stw 30,
; NO-STACK: bl sink
; NO-STACK: lwz 30,
; NO-STACK-NOT: lsku
; NO-STACK: blr
entry:
  call void asm sideeffect "", "~{r30}"()
  call void @sink(ptr %p)
  ret void
}

; The outgoing argument area needs room below STSKU's implicit GPR save
; slots. Grow this frame instead of falling back to mflr/stwu/stw.
define void @large_call_frame() {
; CHECK-LABEL: large_call_frame:
; CHECK-NOT: mflr
; CHECK: stsku 1, -{{[0-9]+}}(1)
; CHECK: bl sink_many
; CHECK: lsku 1, {{[0-9]+}}(1)
; CHECK: blr
; NO-STACK-LABEL: large_call_frame:
; NO-STACK-NOT: stsku
; NO-STACK: stwu 1,
entry:
  call void @sink_many(i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0)
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
