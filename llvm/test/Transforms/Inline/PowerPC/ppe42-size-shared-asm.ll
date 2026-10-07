; RUN: opt -S -mtriple=powerpc-unknown-elf -mcpu=ppe42 -passes='default<Os>' %s | FileCheck %s --check-prefix=SIZE
; RUN: opt -S -mtriple=powerpc-unknown-elf -mcpu=ppe42 -ppe42-size-shared-dso-local -passes='default<Os>' %s | FileCheck %s --check-prefix=EXTERNAL
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

; A repeated ordinary helper can also cost more when copied into a non-leaf
; caller. Keep its shared body even though it contains no inline assembly.
define internal void @ordinary_helper(ptr %p, i32 %x) #0 {
  %a = add i32 %x, 3
  %b = shl i32 %a, 2
  %c = xor i32 %b, %x
  %d = mul i32 %c, 7
  %e = and i32 %d, 255
  %f = or i32 %e, %a
  store volatile i32 %f, ptr %p, align 4
  ret void
}

define void @ordinary_repeated(ptr %p, i32 %x) #0 {
; SIZE-LABEL: define void @ordinary_repeated(
; SIZE: call{{.*}}@ordinary_helper
; SIZE: call{{.*}}@ordinary_helper
; SIZE: call{{.*}}@ordinary_helper
; SIZE: call{{.*}}@ordinary_helper
  %a = add i32 %x, 1
  %b = add i32 %x, 2
  %c = add i32 %x, 3
  call void @ordinary_helper(ptr %p, i32 %x)
  call void @ordinary_helper(ptr %p, i32 %a)
  call void @ordinary_helper(ptr %p, i32 %b)
  call void @ordinary_helper(ptr %p, i32 %c)
  call void @sink()
  ret void
}

; Externally visible firmware helpers can still be non-preemptible. Repeated
; calls to one such helper should retain its shared body in a size build.
define dso_local void @shared_external(ptr %p, i32 %x, i32 %y) #0 {
  %a = add i32 %x, %y
  %b = shl i32 %a, 2
  %c = xor i32 %b, %x
  %d = mul i32 %c, 7
  %e = and i32 %d, 255
  %f = or i32 %e, %a
  store volatile i32 %f, ptr %p, align 4
  ret void
}

define void @external_repeated(ptr %p, i32 %x, i32 %y) #0 {
; EXTERNAL-LABEL: define void @external_repeated(
; EXTERNAL: call{{.*}}@shared_external
; EXTERNAL: call{{.*}}@shared_external
; EXTERNAL: call{{.*}}@shared_external
; EXTERNAL: call{{.*}}@shared_external
; SPEED-LABEL: define void @external_repeated(
; SPEED-NOT: call{{.*}}@shared_external
; SPEED: store volatile i32
  %a = add i32 %x, 1
  %b = add i32 %x, 2
  %c = add i32 %x, 3
  call void @shared_external(ptr %p, i32 %x, i32 %y)
  call void @shared_external(ptr %p, i32 %a, i32 %y)
  call void @shared_external(ptr %p, i32 %b, i32 %y)
  call void @shared_external(ptr %p, i32 %c, i32 %y)
  call void @sink()
  ret void
}

; Small functions still use LLVM's regular inlining decision.
define internal void @tiny_helper(ptr %p, i32 %x) #0 {
  store volatile i32 %x, ptr %p, align 4
  ret void
}

define void @tiny_repeated(ptr %p, i32 %x) #0 {
; SIZE-LABEL: define void @tiny_repeated(
; SIZE-NOT: call{{.*}}@tiny_helper
; SIZE: store volatile i32
  call void @tiny_helper(ptr %p, i32 %x)
  call void @tiny_helper(ptr %p, i32 %x)
  call void @tiny_helper(ptr %p, i32 %x)
  call void @tiny_helper(ptr %p, i32 %x)
  call void @sink()
  ret void
}

attributes #0 = { optsize "target-cpu"="ppe42" }
