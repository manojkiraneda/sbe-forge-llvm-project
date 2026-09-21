; RUN: opt -mtriple=powerpc-unknown-elf -mcpu=ppe42 -passes=loop-unroll -S %s | FileCheck %s

; PPE42 has a small register file and tightly constrained local storage. Do
; not unroll loops when the function is being optimized for size.

define void @runtime_loop(ptr nocapture %dst, ptr nocapture readonly %src,
                          i32 %count) optsize {
; CHECK-LABEL: define void @runtime_loop(
; CHECK: loop:
; CHECK: [[IV:%.*]] = phi i32 [ [[NEXT:%.*]], %loop ], [ 0, %loop.preheader ]
; CHECK: [[VALUE:%.*]] = load i32, ptr
; CHECK-COUNT-1: store i32 [[VALUE]], ptr
; CHECK: [[NEXT]] = add nuw i32 [[IV]], 1
; CHECK: br i1 {{.*}}, label %exit{{.*}}, label %loop
entry:
  %empty = icmp eq i32 %count, 0
  br i1 %empty, label %exit, label %loop

loop:
  %iv = phi i32 [ 0, %entry ], [ %next, %loop ]
  %src.ptr = getelementptr inbounds i32, ptr %src, i32 %iv
  %value = load i32, ptr %src.ptr, align 4
  %dst.ptr = getelementptr inbounds i32, ptr %dst, i32 %iv
  store i32 %value, ptr %dst.ptr, align 4
  %next = add nuw i32 %iv, 1
  %done = icmp eq i32 %next, %count
  br i1 %done, label %exit, label %loop

exit:
  ret void
}
