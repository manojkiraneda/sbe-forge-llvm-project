; RUN: llc -mtriple=powerpc-unknown-elf -mcpu=ppe42 -verify-machineinstrs %s -o - | FileCheck %s
; The real QME pattern: a bit test branches across application-context and
; interrupt-control assembly. These templates are all single instructions.
declare void @work()

define void @context_bit_test(i32 %flags) optsize {
; CHECK-LABEL: context_bit_test:
; CHECK-NOT: cmplwi
; CHECK: bb{{[01]}}wi
; CHECK-NOT: cmplwi
; CHECK: blr
  %masked = and i32 %flags, 1048576
  %clear = icmp eq i32 %masked, 0
  br i1 %clear, label %done, label %body
body:
  %old = call i32 asm sideeffect "mfmsr $0", "=r,~{memory}"()
  call void asm sideeffect "wrteei $0", "i,~{memory}"(i32 0)
  %ctx = call i32 asm sideeffect "mfspr $0, $1", "=r,i,~{memory}"(i32 272)
  call void asm sideeffect "mtspr $0, $1", "i,r,~{memory}"(i32 272, i32 %ctx)
  call void asm sideeffect "mtmsr $0", "r,~{memory}"(i32 %old)
  call void asm sideeffect "tw 0, $0, $1", "i,i"(i32 2, i32 0)
  call void @work()
  br label %done
done:
  ret void
}

define void @context_zero_test(i32 %value) optsize {
; CHECK-LABEL: context_zero_test:
; CHECK-NOT: cmplwi
; CHECK: cmpwib{{eq|ne}}
; CHECK-NOT: cmplwi
; CHECK: blr
  %zero = icmp eq i32 %value, 0
  br i1 %zero, label %done, label %body
body:
  call void asm sideeffect "tw 0, $0, $1", "i,i"(i32 2, i32 0)
  call void asm sideeffect "sync", "~{memory}"()
  call void @work()
  br label %done
done:
  ret void
}
