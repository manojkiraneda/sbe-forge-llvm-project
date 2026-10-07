; RUN: opt -S -mtriple=powerpc-unknown-elf -mcpu=ppe42 -passes='default<Os>' %s | FileCheck %s --check-prefix=SIZE
; RUN: sed 's/optsize //' %s | opt -S -mtriple=powerpc-unknown-elf -mcpu=ppe42 -passes='default<O2>' | FileCheck %s --check-prefix=SPEED

; Wide arithmetic takes multiple PPE42 instructions. Two non-leaf call sites
; can therefore benefit from one shared copy of the helper.
define dso_local i64 @wide_two(i64 %x) #0 {
  %a = add i64 %x, 17
  %b = xor i64 %a, %x
  %c = shl i64 %b, 7
  %d = add i64 %c, %x
  %e = xor i64 %d, %a
  %f = lshr i64 %e, 3
  %g = and i64 %f, %d
  ret i64 %g
}

declare void @sink(i64)

define void @two_uses(i64 %x) #0 {
; SIZE-LABEL: define void @two_uses(
; SIZE: call i64 @wide_two(i64 %x)
; SIZE: call i64 @wide_two(i64 %a)
; SPEED-LABEL: define void @two_uses(
; SPEED-NOT: call i64 @wide_two
  %a = add i64 %x, 1
  %b = call i64 @wide_two(i64 %x)
  %c = call i64 @wide_two(i64 %a)
  call void @sink(i64 %b)
  call void @sink(i64 %c)
  ret void
}

; One call in each non-leaf caller still shares the same body.
define dso_local i64 @wide_shared(i64 %x) #0 {
  %a = add i64 %x, 19
  %b = xor i64 %a, %x
  %c = shl i64 %b, 7
  %d = add i64 %c, %x
  %e = xor i64 %d, %a
  %f = lshr i64 %e, 3
  %g = and i64 %f, %d
  ret i64 %g
}

define void @caller_one(i64 %x) #0 {
; SIZE-LABEL: define void @caller_one(
; SIZE: call i64 @wide_shared(i64 %x)
  %y = call i64 @wide_shared(i64 %x)
  call void @sink(i64 %y)
  ret void
}

define void @caller_two(i64 %x) #0 {
; SIZE-LABEL: define void @caller_two(
; SIZE: call i64 @wide_shared(i64 %a)
  %a = add i64 %x, 1
  %y = call i64 @wide_shared(i64 %a)
  call void @sink(i64 %y)
  ret void
}

; Three repeated assembly-heavy calls also pass the size test, even though
; the original four-call fast path does not apply.
define internal void @three_helper() #0 {
  call void asm sideeffect "nop", ""()
  call void asm sideeffect "nop", ""()
  call void asm sideeffect "nop", ""()
  call void asm sideeffect "nop", ""()
  call void asm sideeffect "nop", ""()
  call void asm sideeffect "nop", ""()
  call void asm sideeffect "nop", ""()
  call void asm sideeffect "nop", ""()
  call void asm sideeffect "nop", ""()
  call void asm sideeffect "nop", ""()
  ret void
}

define void @three_uses() #0 {
; SIZE-LABEL: define void @three_uses(
; SIZE: call{{.*}}@three_helper()
; SIZE: call{{.*}}@three_helper()
; SIZE: call{{.*}}@three_helper()
  call void @three_helper()
  call void @three_helper()
  call void @three_helper()
  call void @sink(i64 1)
  ret void
}

; A small two-use helper should retain the usual inlining behavior.
define internal i32 @tiny(i32 %x) #0 {
  %a = add i32 %x, 1
  ret i32 %a
}

define void @tiny_uses(i32 %x) #0 {
; SIZE-LABEL: define void @tiny_uses(
; SIZE-NOT: call i32 @tiny
; SIZE: call void @sink(i64
  %a = call i32 @tiny(i32 %x)
  %b = call i32 @tiny(i32 %a)
  %c = zext i32 %b to i64
  call void @sink(i64 %c)
  ret void
}

; A leaf caller can inline without introducing LR-save code.
define dso_local i64 @wide_leaf(i64 %x) #0 {
  %a = add i64 %x, 23
  %b = xor i64 %a, %x
  %c = shl i64 %b, 7
  %d = add i64 %c, %x
  %e = xor i64 %d, %a
  %f = lshr i64 %e, 3
  %g = and i64 %f, %d
  ret i64 %g
}

define i64 @leaf_use(i64 %x) #0 {
; SIZE-LABEL: define{{.*}}@leaf_use(
; SIZE-NOT: call i64 @wide_leaf
; SIZE: ret i64
  %a = call i64 @wide_leaf(i64 %x)
  ret i64 %a
}

attributes #0 = { inlinehint optsize "target-cpu"="ppe42" }
