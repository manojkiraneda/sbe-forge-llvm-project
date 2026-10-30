; RUN: llc -mtriple=powerpc-none-eabi -mcpu=ppe42 -stop-after=ppc-ppe42-stack-align %s -o - | FileCheck %s --check-prefix=IR
; RUN: llc -mtriple=powerpc-none-eabi -mcpu=440 -stop-after=ppc-ppe42-stack-align %s -o - | FileCheck %s --check-prefix=OTHER
; RUN: llc -mtriple=powerpc-none-eabi -mcpu=ppe42 -enable-machine-outliner=never -verify-machineinstrs %s -o - | FileCheck %s
; RUN: llc -mtriple=powerpc-none-eabi -mcpu=ppe42 -verify-machineinstrs -filetype=obj %s -o %t.o
;
; Zero exactly bytes 13..19. Wider stores must stay within the memset range;
; the local object's alignment alone does not permit overwriting its neighbors.
declare void @llvm.memset.p0.i32(ptr, i8, i32, i1 immarg)
declare void @use(ptr)

define void @local_seven() optsize {
; IR-LABEL: define void @local_seven()
; IR: store i8 0, ptr {{.*}}, align 1
; IR: store i16 0, ptr {{.*}}, align 2
; IR: store i32 0, ptr {{.*}}, align 4
; IR-NOT: call void @llvm.memset
; IR: call void @use
; OTHER-LABEL: define void @local_seven()
; OTHER: call void @llvm.memset
; CHECK-LABEL: local_seven:
; CHECK-DAG: stb
; CHECK-DAG: sth
; CHECK-DAG: stw
; CHECK: bl use
  %h = alloca [20 x i8], align 4
  %p = getelementptr i8, ptr %h, i32 13
  call void @llvm.memset.p0.i32(ptr align 1 %p, i8 0, i32 7, i1 false)
  call void @use(ptr %h)
  ret void
}

define void @external(ptr %p) optsize {
; IR-LABEL: define void @external(
; IR: call void @llvm.memset
  call void @llvm.memset.p0.i32(ptr align 1 %p, i8 0, i32 7, i1 false)
  ret void
}

define void @volatile_fill() optsize {
; IR-LABEL: define void @volatile_fill()
; IR: call void @llvm.memset{{.*}}i1 true
  %h = alloca [20 x i8], align 4
  %p = getelementptr i8, ptr %h, i32 13
  call void @llvm.memset.p0.i32(ptr align 1 %p, i8 0, i32 7, i1 true)
  call void @use(ptr %h)
  ret void
}

define void @nonzero_fill() optsize {
; IR-LABEL: define void @nonzero_fill()
; IR: call void @llvm.memset{{.*}}i8 7
  %h = alloca [20 x i8], align 4
  %p = getelementptr i8, ptr %h, i32 13
  call void @llvm.memset.p0.i32(ptr align 1 %p, i8 7, i32 7, i1 false)
  call void @use(ptr %h)
  ret void
}

define void @unaligned_local() optsize {
; IR-LABEL: define void @unaligned_local()
; IR: alloca [20 x i8], align 1
; IR: call void @llvm.memset
  %h = alloca [20 x i8], align 1
  %p = getelementptr i8, ptr %h, i32 13
  call void @llvm.memset.p0.i32(ptr align 1 %p, i8 0, i32 7, i1 false)
  call void @use(ptr %h)
  ret void
}

define void @dynamic(i32 %n) optsize {
; IR-LABEL: define void @dynamic(
; IR: call void @llvm.memset
  %h = alloca [20 x i8], i32 %n, align 4
  %p = getelementptr i8, ptr %h, i32 13
  call void @llvm.memset.p0.i32(ptr align 1 %p, i8 0, i32 7, i1 false)
  call void @use(ptr %h)
  ret void
}

define void @variable_offset(i32 %n) optsize {
; IR-LABEL: define void @variable_offset(
; IR: call void @llvm.memset
  %h = alloca [20 x i8], align 4
  %p = getelementptr i8, ptr %h, i32 %n
  call void @llvm.memset.p0.i32(ptr align 1 %p, i8 0, i32 7, i1 false)
  call void @use(ptr %h)
  ret void
}

define void @not_size_optimized() {
; IR-LABEL: define void @not_size_optimized()
; IR: call void @llvm.memset
  %h = alloca [20 x i8], align 4
  %p = getelementptr i8, ptr %h, i32 13
  call void @llvm.memset.p0.i32(ptr align 1 %p, i8 0, i32 7, i1 false)
  call void @use(ptr %h)
  ret void
}
