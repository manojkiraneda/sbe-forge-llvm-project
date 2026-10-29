; RUN: llc -mtriple=powerpc-none-eabi -mcpu=ppe42 -verify-machineinstrs %s -o - | FileCheck %s
; RUN: opt -passes=debugify %s -o %t.bc
; RUN: llc -mtriple=powerpc-none-eabi -mcpu=ppe42 -verify-machineinstrs %t.bc -o - | FileCheck %s
; RUN: llc -mtriple=powerpc-none-eabi -mcpu=ppe42 -filetype=obj %t.bc -o %t.o
;
; Real PPC32 call lowering adds implicit-def R1. It must not prevent the
; outliner from sharing call setup through a frameless tail-branch helper.
declare void @trace(i32, i32, i32, i32)

define void @call_setup() optsize {
; CHECK-LABEL: call_setup:
; CHECK-COUNT-6: bl OUTLINED_FUNCTION_0
; CHECK: blr
  call void @trace(i32 1, i32 0, i32 0, i32 0)
  call void @trace(i32 2, i32 0, i32 0, i32 0)
  call void @trace(i32 3, i32 0, i32 0, i32 0)
  call void @trace(i32 4, i32 0, i32 0, i32 0)
  call void @trace(i32 5, i32 0, i32 0, i32 0)
  call void @trace(i32 6, i32 0, i32 0, i32 0)
  call void asm sideeffect "", ""()
  ret void
}

; CHECK-LABEL: OUTLINED_FUNCTION_0:
; CHECK-NOT: stsku
; CHECK-NOT: stwu
; CHECK-NOT: bl trace
; CHECK: li 4, 0
; CHECK-NEXT: li 5, 0
; CHECK-NEXT: li 6, 0
; A debug location directive can precede the tail branch.
; CHECK: b trace
; CHECK-NOT: blr
