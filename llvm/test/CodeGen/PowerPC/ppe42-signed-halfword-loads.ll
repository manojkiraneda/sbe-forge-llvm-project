; RUN: llc -mtriple=powerpc-unknown-elf -mcpu=ppe42 -verify-machineinstrs %s -o - | FileCheck %s --check-prefix=PPE --implicit-check-not='{{[[:space:]]lha}}'
; RUN: llc -mtriple=powerpc-unknown-elf -mcpu=ppe42 -O0 -verify-machineinstrs %s -o - | FileCheck %s --check-prefix=PPE --implicit-check-not='{{[[:space:]]lha}}'
; RUN: llc -mtriple=powerpc-unknown-elf -mcpu=ppe42 -verify-machineinstrs -filetype=obj %s -o %t.o
; RUN: llc -mtriple=powerpc-unknown-elf -mcpu=440 -verify-machineinstrs %s -o - | FileCheck %s --check-prefix=PPC

; PPE42 manual: LHA/LHAU/LHAX/LHAUX are not implemented. A signed halfword
; load must use LHZ/LHZX (or a supported update form), then EXTSH. Preserve
; unsigned load semantics and the single memory access of volatile loads.

@half = external global i16, align 2

define i32 @signed_direct(ptr %p) {
; PPE-LABEL: signed_direct:
; PPE: lhz
; PPE: extsh
; PPC-LABEL: signed_direct:
; PPC: lha
  %v = load i16, ptr %p, align 2
  %s = sext i16 %v to i32
  ret i32 %s
}

define i32 @signed_indexed(ptr %p, i32 %idx) {
; PPE-LABEL: signed_indexed:
; PPE: lhz
; PPE: extsh
; PPC-LABEL: signed_indexed:
; PPC: lhax
  %q = getelementptr i16, ptr %p, i32 %idx
  %v = load i16, ptr %q, align 2
  %s = sext i16 %v to i32
  ret i32 %s
}

define i32 @signed_volatile(ptr %p) {
; PPE-LABEL: signed_volatile:
; PPE: lhz
; PPE-NOT: lhz
; PPE: extsh
  %v = load volatile i16, ptr %p, align 2
  %s = sext i16 %v to i32
  ret i32 %s
}

define i64 @signed_wide(ptr %p) {
; PPE-LABEL: signed_wide:
; PPE: lhz
; PPE: extsh
  %v = load i16, ptr %p, align 2
  %s = sext i16 %v to i64
  ret i64 %s
}

define i32 @signed_global() {
; PPE-LABEL: signed_global:
; PPE: lhz
; PPE: extsh
  %v = load i16, ptr @half, align 2
  %s = sext i16 %v to i32
  ret i32 %s
}

define i32 @unsigned_direct(ptr %p) {
; PPE-LABEL: unsigned_direct:
; PPE: lhz
; PPE-NOT: extsh
; PPE: blr
  %v = load i16, ptr %p, align 2
  %u = zext i16 %v to i32
  ret i32 %u
}

define i32 @signed_loop(ptr %p, i32 %n) {
; PPE-LABEL: signed_loop:
; PPE: lhz
; PPE: extsh
  br label %loop
loop:
  %cur = phi ptr [ %p, %0 ], [ %next, %loop ]
  %left = phi i32 [ %n, %0 ], [ %dec, %loop ]
  %sum = phi i32 [ 0, %0 ], [ %add, %loop ]
  %next = getelementptr i16, ptr %cur, i32 1
  %v = load i16, ptr %next, align 2
  %s = sext i16 %v to i32
  %add = add i32 %sum, %s
  %dec = add i32 %left, -1
  %more = icmp ne i32 %dec, 0
  br i1 %more, label %loop, label %exit
exit:
  ret i32 %add
}
