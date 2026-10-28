; RUN: llc -mtriple=powerpc-unknown-elf -mcpu=ppe42 -O2 -verify-machineinstrs < %s | FileCheck %s

; Four 64-bit results survive subsequent calls. PPE42 only has two disjoint
; callee-saved VDR pairs, so at least one result must spill. Preserve the
; high and low words together through allocation and reload them with LVD.

declare i64 @get(i32)
declare i32 @check()
declare void @use(i64)

define void @probe_many() #0 {
; CHECK-LABEL: probe_many:
; CHECK: stvd
; CHECK: lvd
entry:
  %a = call i64 @get(i32 1)
  %b = call i64 @get(i32 2)
  %c = call i64 @get(i32 3)
  %d = call i64 @get(i32 4)
  %condition = call i32 @check()
  %nonzero = icmp ne i32 %condition, 0
  br i1 %nonzero, label %then, label %done

then:
  call void @use(i64 %a)
  br label %done

done:
  call void @use(i64 %b)
  call void @use(i64 %c)
  call void @use(i64 %d)
  ret void
}

attributes #0 = { optsize "target-cpu"="ppe42" }
