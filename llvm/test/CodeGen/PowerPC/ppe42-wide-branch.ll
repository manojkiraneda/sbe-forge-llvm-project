; RUN: llc -mtriple=powerpc-none-eabi -mcpu=ppe42 -verify-machineinstrs -print-after=ppc-ppe42-wide-compare %s -o /dev/null 2>&1 | FileCheck %s
; RUN: llc -mtriple=powerpc-none-eabi -mcpu=ppe42 -verify-machineinstrs -filetype=obj %s -o %t.o

define i32 @branch_ult(i64 %a, i64 %b, i32 %x) optsize {
; CHECK-LABEL: define i32 @branch_ult
; CHECK: freeze i64 %a
; CHECK: freeze i64 %b
; CHECK: icmp eq i32
; CHECK: br i1 {{.*}}, label %wide.low, label %wide.high
; CHECK: wide.high:
; CHECK: icmp ult i32
; CHECK: wide.low:
; CHECK: icmp ult i32
entry:
  %c = icmp ult i64 %a, %b
  br i1 %c, label %yes, label %no
yes:
  %v = phi i32 [ %x, %entry ]
  ret i32 %v
no:
  ret i32 0
}

define i32 @branch_ule(i64 %a, i64 %b, i32 %x) optsize {
; CHECK-LABEL: define i32 @branch_ule
; CHECK: freeze i64 %a
; CHECK: freeze i64 %b
; CHECK: icmp eq i32
; CHECK: br i1 {{.*}}, label %wide.low, label %wide.high
; CHECK: wide.high:
; CHECK: icmp ule i32
; CHECK: wide.low:
; CHECK: icmp ule i32
entry:
  %c = icmp ule i64 %a, %b
  br i1 %c, label %yes, label %no
yes:
  %v = phi i32 [ %x, %entry ]
  ret i32 %v
no:
  ret i32 0
}

define i32 @branch_ugt(i64 %a, i64 %b, i32 %x) optsize {
; CHECK-LABEL: define i32 @branch_ugt
; CHECK: freeze i64 %a
; CHECK: freeze i64 %b
; CHECK: icmp eq i32
; CHECK: br i1 {{.*}}, label %wide.low, label %wide.high
; CHECK: wide.high:
; CHECK: icmp ugt i32
; CHECK: wide.low:
; CHECK: icmp ugt i32
entry:
  %c = icmp ugt i64 %a, %b
  br i1 %c, label %yes, label %no
yes:
  %v = phi i32 [ %x, %entry ]
  ret i32 %v
no:
  ret i32 0
}

define i32 @branch_uge(i64 %a, i64 %b, i32 %x) optsize {
; CHECK-LABEL: define i32 @branch_uge
; CHECK: freeze i64 %a
; CHECK: freeze i64 %b
; CHECK: icmp eq i32
; CHECK: br i1 {{.*}}, label %wide.low, label %wide.high
; CHECK: wide.high:
; CHECK: icmp uge i32
; CHECK: wide.low:
; CHECK: icmp uge i32
entry:
  %c = icmp uge i64 %a, %b
  br i1 %c, label %yes, label %no
yes:
  %v = phi i32 [ %x, %entry ]
  ret i32 %v
no:
  ret i32 0
}

define i32 @branch_slt(i64 %a, i64 %b, i32 %x) optsize {
; CHECK-LABEL: define i32 @branch_slt
; CHECK: freeze i64 %a
; CHECK: freeze i64 %b
; CHECK: icmp eq i32
; CHECK: br i1 {{.*}}, label %wide.low, label %wide.high
; CHECK: wide.high:
; CHECK: icmp slt i32
; CHECK: wide.low:
; CHECK: icmp ult i32
entry:
  %c = icmp slt i64 %a, %b
  br i1 %c, label %yes, label %no
yes:
  %v = phi i32 [ %x, %entry ]
  ret i32 %v
no:
  ret i32 0
}

define i32 @branch_sle(i64 %a, i64 %b, i32 %x) optsize {
; CHECK-LABEL: define i32 @branch_sle
; CHECK: freeze i64 %a
; CHECK: freeze i64 %b
; CHECK: icmp eq i32
; CHECK: br i1 {{.*}}, label %wide.low, label %wide.high
; CHECK: wide.high:
; CHECK: icmp sle i32
; CHECK: wide.low:
; CHECK: icmp ule i32
entry:
  %c = icmp sle i64 %a, %b
  br i1 %c, label %yes, label %no
yes:
  %v = phi i32 [ %x, %entry ]
  ret i32 %v
no:
  ret i32 0
}

define i32 @branch_sgt(i64 %a, i64 %b, i32 %x) optsize {
; CHECK-LABEL: define i32 @branch_sgt
; CHECK: freeze i64 %a
; CHECK: freeze i64 %b
; CHECK: icmp eq i32
; CHECK: br i1 {{.*}}, label %wide.low, label %wide.high
; CHECK: wide.high:
; CHECK: icmp sgt i32
; CHECK: wide.low:
; CHECK: icmp ugt i32
entry:
  %c = icmp sgt i64 %a, %b
  br i1 %c, label %yes, label %no
yes:
  %v = phi i32 [ %x, %entry ]
  ret i32 %v
no:
  ret i32 0
}

define i32 @branch_sge(i64 %a, i64 %b, i32 %x) optsize {
; CHECK-LABEL: define i32 @branch_sge
; CHECK: freeze i64 %a
; CHECK: freeze i64 %b
; CHECK: icmp eq i32
; CHECK: br i1 {{.*}}, label %wide.low, label %wide.high
; CHECK: wide.high:
; CHECK: icmp sge i32
; CHECK: wide.low:
; CHECK: icmp uge i32
entry:
  %c = icmp sge i64 %a, %b
  br i1 %c, label %yes, label %no
yes:
  %v = phi i32 [ %x, %entry ]
  ret i32 %v
no:
  ret i32 0
}

define i1 @boolean(i64 %a, i64 %b) optsize {
; CHECK-LABEL: define i1 @boolean
; CHECK-NOT: wide.high
; CHECK: icmp ult i64
  %c = icmp ult i64 %a, %b
  ret i1 %c
}

define i64 @wide_select(i1 %cond, i64 %a, i64 %b) optsize {
; CHECK-LABEL: define i64 @wide_select
; CHECK: freeze i1 %cond
; CHECK: br i1
; CHECK-NOT: select i1
; CHECK: phi i64
  %r = select i1 %cond, i64 %a, i64 %b
  ret i64 %r
}

define i64 @select_one_word(i1 %cond) optsize {
; CHECK-LABEL: define i64 @select_one_word
; CHECK: select i1 %cond
  %r = select i1 %cond, i64 9, i64 12
  ret i64 %r
}

define i32 @select_low_only(i1 %cond, i64 %a, i64 %b) optsize {
; CHECK-LABEL: define i32 @select_low_only
; CHECK: select i1 %cond
  %r = select i1 %cond, i64 %a, i64 %b
  %low = trunc i64 %r to i32
  ret i32 %low
}
