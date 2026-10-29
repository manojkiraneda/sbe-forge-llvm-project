; RUN: llc -mtriple=powerpc-none-eabi -mcpu=ppe42 -verify-machineinstrs -stop-after=ppc-ppe42-const-spill %s -o %t.mir
; RUN: llc -mtriple=powerpc-none-eabi -mcpu=ppe42 -verify-machineinstrs -filetype=obj %s -o %t.o
; RUN: opt -passes=debugify %s -o %t.bc
; RUN: llc -mtriple=powerpc-none-eabi -mcpu=ppe42 -verify-machineinstrs -filetype=obj %t.bc -o %t.debug.o
;
; Exercise the real post-allocation insertion point, including live stack
; intervals, slot-index updates, subsequent coloring, and debug references.
declare void @clobber(i32, i32, i32, i32)

define void @constant_pressure(ptr %p, i32 %a, i32 %b, i32 %c, i32 %d,
                               i32 %count) optsize {
entry:
  br label %loop
loop:
  %i = phi i32 [ %count, %entry ], [ %next, %loop ]
  call void @clobber(i32 %a, i32 %b, i32 %c, i32 %d)
  %v = load volatile i32, ptr %p, align 4
  %masked = and i32 %v, -251658273
  %result = or i32 %masked, 134217760
  store volatile i32 %result, ptr %p, align 4
  call void @clobber(i32 %d, i32 %c, i32 %b, i32 %a)
  %w = load volatile i32, ptr %p, align 4
  %nibble = and i32 %w, 15
  %product = mul i32 %nibble, 69632
  %address = or i32 %product, -2147483584
  store volatile i32 %address, ptr %p, align 4
  %next = add i32 %i, -1
  %done = icmp eq i32 %next, 0
  br i1 %done, label %exit, label %loop
exit:
  ret void
}
