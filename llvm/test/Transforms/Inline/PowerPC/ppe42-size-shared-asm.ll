; RUN: opt -S -mtriple=powerpc-unknown-elf -mcpu=ppe42 -passes='default<Os>' %s | FileCheck %s --check-prefix=SIZE
; RUN: sed 's/optsize //' %s | opt -S -mtriple=powerpc-unknown-elf -mcpu=ppe42 -passes='default<O2>' | FileCheck %s --check-prefix=SPEED

; A frequently used assembly-heavy helper is smaller as one copy plus calls.
define internal void @helper(i32 %value) #0 {
  call void asm sideeffect "nop", "r"(i32 %value)
  call void asm sideeffect "nop", ""()
  call void asm sideeffect "nop", ""()
  call void asm sideeffect "nop", ""()
  ret void
}

declare void @sink()

define void @repeated() #0 {
; SIZE-LABEL: define void @repeated(
; SIZE: call{{.*}}@helper(i32 1)
; SIZE: call{{.*}}@helper(i32 2)
; SIZE: call{{.*}}@helper(i32 3)
; SIZE: call{{.*}}@helper(i32 4)
; SPEED-LABEL: define void @repeated(
; SPEED-NOT: call{{.*}}@helper
; SPEED: call void asm sideeffect
  call void @helper(i32 1)
  call void @helper(i32 2)
  call void @helper(i32 3)
  call void @helper(i32 4)
  call void @sink()
  ret void
}

; Outlining a leaf caller could introduce LR saves, so leave it to the
; ordinary inliner even when the helper is called repeatedly.
define void @leaf_repeated() #0 {
; SIZE-LABEL: define void @leaf_repeated(
; SIZE-NOT: call{{.*}}@helper
; SIZE: call void asm sideeffect
  call void @helper(i32 5)
  call void @helper(i32 6)
  call void @helper(i32 7)
  call void @helper(i32 8)
  ret void
}

; A one-use helper should still inline in a size build.
define internal void @single_helper() #0 {
  call void asm sideeffect "nop", ""()
  call void asm sideeffect "nop", ""()
  call void asm sideeffect "nop", ""()
  call void asm sideeffect "nop", ""()
  ret void
}

define void @single_use() #0 {
; SIZE-LABEL: define void @single_use(
; SIZE-NOT: call{{.*}}@single_helper
; SIZE: call void asm sideeffect
  call void @single_helper()
  call void @sink()
  ret void
}

attributes #0 = { optsize "target-cpu"="ppe42" }
