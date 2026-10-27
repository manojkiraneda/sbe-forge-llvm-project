; RUN: llc -mtriple=powerpc-unknown-elf -mcpu=ppe42 -verify-machineinstrs < %s | FileCheck %s

@handler = external global ptr

; Reuse the incoming LR when forwarding to a void handler. In particular,
; this must work for an indirect call, as used by the IOTA machine-check shim.
define void @indirect_void() {
; CHECK-LABEL: indirect_void:
; CHECK-NOT: stsku
; CHECK: lwz
; CHECK: mtctr
; CHECK-NEXT: bctr
; CHECK-NOT: blr
entry:
  %callee = load ptr, ptr @handler, align 4
  tail call void %callee()
  ret void
}

; A call carrying arguments is not covered by this restricted sibling-call
; rule; changing its stack argument area would need separate ABI analysis.
define void @indirect_with_argument(ptr %callee, i32 %value) {
; CHECK-LABEL: indirect_with_argument:
; CHECK: bctrl
; CHECK: blr
entry:
  tail call void %callee(i32 %value)
  ret void
}
