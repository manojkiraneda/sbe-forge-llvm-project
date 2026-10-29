; RUN: llc -mtriple=powerpc-none-eabi -mcpu=ppe42 -verify-machineinstrs %s -o - | FileCheck %s
; RUN: llc -mtriple=powerpc-none-eabi -mcpu=ppe42 -verify-machineinstrs -stop-after=ppc-ppe42-store-pairs %s -o - | FileCheck %s --check-prefix=MIR
; RUN: llc -mtriple=powerpc-none-eabi -mcpu=ppe42 -verify-machineinstrs -filetype=obj %s -o %t.o
; RUN: llvm-objdump -d --mcpu=ppe42 %t.o | FileCheck %s --check-prefix=OBJ
;
; These are immediate update forms, not the unavailable indexed update forms.
; In particular, the updated load base may not overlap either destination GPR.

define i64 @load_next(ptr %p, ptr %out) optsize {
; CHECK-LABEL: load_next:
; CHECK: lvdu d{{[0-9]+}}, 8({{[0-9]+}})
; CHECK: blr
; MIR-LABEL: name: load_next
; MIR: early-clobber %{{[0-9]+}}:vdrc, %{{[0-9]+}}:{{[^ ]+}} = LVDU 8,
; MIR-SAME: :: (load
; OBJ-LABEL: <load_next>:
; OBJ: lvdu
  %next = getelementptr i64, ptr %p, i32 1
  %v = load i64, ptr %next, align 8
  store ptr %next, ptr %out, align 4
  ret i64 %v
}

define ptr @store_next(ptr %p, i64 %v) optsize {
; CHECK-LABEL: store_next:
; CHECK: stvdu d{{[0-9]+}}, 8({{[0-9]+}})
; CHECK: blr
; MIR-LABEL: name: store_next
; MIR: STVDU {{.*}}8,
; MIR-SAME: :: (store
; OBJ-LABEL: <store_next>:
; OBJ: stvdu
  %next = getelementptr i64, ptr %p, i32 1
  store i64 %v, ptr %next, align 8
  ret ptr %next
}

define i64 @load_previous(ptr %p, ptr %out) optsize {
; CHECK-LABEL: load_previous:
; CHECK: lvdu d{{[0-9]+}}, -8({{[0-9]+}})
; CHECK: blr
  %next = getelementptr i64, ptr %p, i32 -1
  %v = load i64, ptr %next, align 8
  store ptr %next, ptr %out, align 4
  ret i64 %v
}

define i64 @load_indexed(ptr %p, i32 %index, ptr %out) optsize {
; CHECK-LABEL: load_indexed:
; CHECK-NOT: lvdu
; CHECK-NOT: ldux
; CHECK: blr
  %next = getelementptr i64, ptr %p, i32 %index
  %v = load i64, ptr %next, align 8
  store ptr %next, ptr %out, align 4
  ret i64 %v
}

define ptr @store_indexed(ptr %p, i32 %index, i64 %v) optsize {
; CHECK-LABEL: store_indexed:
; CHECK-NOT: stvdu
; CHECK-NOT: stdux
; CHECK: blr
  %next = getelementptr i64, ptr %p, i32 %index
  store i64 %v, ptr %next, align 8
  ret ptr %next
}

define i64 @load_unaligned(ptr %p, ptr %out) optsize {
; CHECK-LABEL: load_unaligned:
; CHECK-NOT: lvdu
; CHECK: blr
  %next = getelementptr i64, ptr %p, i32 1
  %v = load i64, ptr %next, align 4
  store ptr %next, ptr %out, align 4
  ret i64 %v
}

define ptr @store_unaligned(ptr %p, i64 %v) optsize {
; CHECK-LABEL: store_unaligned:
; CHECK-NOT: stvdu
; CHECK: blr
  %next = getelementptr i64, ptr %p, i32 1
  store i64 %v, ptr %next, align 4
  ret ptr %next
}

; A real induction variable, as used in doubleword copy loops. Both updated
; pointers feed the next iteration; there must be no separate pointer add.
define void @copy_loop(ptr %src, ptr %dst, i32 %count) optsize {
; CHECK-LABEL: copy_loop:
; CHECK: lvdu
; CHECK: stvdu
; CHECK: blr
  br label %loop
loop:
  %s = phi ptr [ %src, %0 ], [ %sn, %loop ]
  %d = phi ptr [ %dst, %0 ], [ %dn, %loop ]
  %i = phi i32 [ %count, %0 ], [ %in, %loop ]
  %sn = getelementptr i64, ptr %s, i32 1
  %dn = getelementptr i64, ptr %d, i32 1
  %v = load i64, ptr %sn, align 8
  store i64 %v, ptr %dn, align 8
  %in = add i32 %i, -1
  %done = icmp eq i32 %in, 0
  br i1 %done, label %exit, label %loop
exit:
  ret void
}
