; RUN: llc -mtriple=powerpc-none-eabi -mcpu=ppe42 -verify-machineinstrs %s -o - | FileCheck %s
; RUN: llc -mtriple=powerpc-none-eabi -mcpu=ppe42 -verify-machineinstrs -stop-after=ppc-ppe42-cr-spill %s -o - | FileCheck %s --check-prefix=MIR
; RUN: llc -mtriple=powerpc-none-eabi -mcpu=ppe42 -verify-machineinstrs -filetype=obj %s -o %t.o
; RUN: opt -passes=debugify %s -o %t.bc
; RUN: llc -mtriple=powerpc-none-eabi -mcpu=ppe42 -verify-machineinstrs %t.bc -o - | FileCheck %s
;
; The first condition is reused after a path containing a different compare.
; Preserve the one-word input, not a CR field. Never reload the original input
; from memory: it might have changed since the first comparison.
declare void @work()

define void @reuse(i32 %a, i32 %b) optsize {
; CHECK-LABEL: reuse:
; CHECK-NOT: mfcr
; CHECK-NOT: mtcr0
; CHECK: bl work
; CHECK-NOT: mfcr
; CHECK-NOT: mtcr0
; CHECK: blr
; MIR-LABEL: name: reuse
; MIR: CMPLWI %[[INPUT:[0-9]+]], 0
; MIR: bb.2.late:
; MIR: %[[COPY:[0-9]+]]:crrc = CMPLWI %[[INPUT]], 0
; MIR-NEXT: BCC 76, killed %[[COPY]],
entry:
  %c = icmp eq i32 %a, 0
  br i1 %c, label %late, label %middle
middle:
  %d = icmp ugt i32 %b, 2
  br i1 %d, label %exit, label %late
late:
  br i1 %c, label %exit, label %body
body:
  call void @work()
  br label %exit
exit:
  ret void
}
