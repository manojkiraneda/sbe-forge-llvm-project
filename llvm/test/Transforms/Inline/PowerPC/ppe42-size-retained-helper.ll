; RUN: opt -S -mtriple=powerpc-unknown-elf -mcpu=ppe42 -inlinehint-threshold=1000 -passes='default<Os>' %s | FileCheck %s --check-prefix=SIZE

declare void @sink(i64)
declare void @sink_right(i64)

; A noinline use keeps this body in the module even though only one eligible
; non-leaf caller uses it. Do not duplicate the body into that caller.
define dso_local i64 @retained_helper(i64 %x) #0 {
  %a = add i64 %x, 17
  %b = xor i64 %a, %x
  %c = shl i64 %b, 7
  %d = add i64 %c, %x
  %e = xor i64 %d, %a
  %f = lshr i64 %e, 3
  %g = and i64 %f, %d
  ret i64 %g
}

define void @retained_user(i64 %x) #0 {
; SIZE-LABEL: define{{.*}}@retained_user(
; SIZE: call{{.*}}@retained_helper(
  %y = call i64 @retained_helper(i64 %x)
  call void @sink(i64 %y)
  ret void
}

define i64 @forced_retainer(i64 %x) #0 {
; SIZE-LABEL: define{{.*}}@forced_retainer(
; SIZE: call{{.*}}@retained_helper(
  %y = call i64 @retained_helper(i64 %x) #1
  ret i64 %y
}

; A large local helper with only one visible use can still become smaller
; after inlining, especially when its arguments enable constant folding.
define internal void @complex_helper(ptr %p, i64 %x) #0 {
entry:
  %e0 = load volatile i32, ptr %p
  %e1 = load volatile i32, ptr %p
  %e2 = load volatile i32, ptr %p
  %e3 = load volatile i32, ptr %p
  %e4 = load volatile i32, ptr %p
  %e5 = load volatile i32, ptr %p
  %e6 = load volatile i32, ptr %p
  %e7 = load volatile i32, ptr %p
  call void @sink(i64 %x)
  %cond = icmp eq i64 %x, 0
  br i1 %cond, label %left, label %right

left:
  %l0 = load volatile i32, ptr %p
  %l1 = load volatile i32, ptr %p
  %l2 = load volatile i32, ptr %p
  %l3 = load volatile i32, ptr %p
  %l4 = load volatile i32, ptr %p
  %l5 = load volatile i32, ptr %p
  %l6 = load volatile i32, ptr %p
  %l7 = load volatile i32, ptr %p
  call void @sink(i64 1)
  br label %done

right:
  %r0 = load volatile i32, ptr %p
  %r1 = load volatile i32, ptr %p
  %r2 = load volatile i32, ptr %p
  %r3 = load volatile i32, ptr %p
  %r4 = load volatile i32, ptr %p
  %r5 = load volatile i32, ptr %p
  %r6 = load volatile i32, ptr %p
  %r7 = load volatile i32, ptr %p
  call void @sink_right(i64 2)
  br label %done

done:
  %d0 = load volatile i32, ptr %p
  %d1 = load volatile i32, ptr %p
  %d2 = load volatile i32, ptr %p
  %d3 = load volatile i32, ptr %p
  %d4 = load volatile i32, ptr %p
  %d5 = load volatile i32, ptr %p
  %d6 = load volatile i32, ptr %p
  %d7 = load volatile i32, ptr %p
  call void @sink(i64 3)
  ret void
}

define void @complex_user(ptr %p, i64 %x, i1 %flag) #0 {
; SIZE-LABEL: define{{.*}}@complex_user(
; SIZE-NOT: call{{.*}}@complex_helper(
; SIZE: }
entry:
  br i1 %flag, label %work, label %skip
work:
  call void @complex_helper(ptr %p, i64 %x)
  br label %exit
skip:
  call void @sink(i64 %x)
  br label %exit
exit:
  call void @sink(i64 4)
  ret void
}

; A reused bitfield constructor writes an address-taken result. Its IR body
; looks small, but inlining it four times duplicates address formation and
; stores in an already non-leaf PPE42 caller.
define dso_local void @target_constructor(ptr %result, ptr %source) #0 {
  %old = load i32, ptr %source, align 4
  %masked = and i32 %old, -16711713
  %updated = or i32 %masked, 2048
  store i32 %updated, ptr %result, align 4
  ret void
}

define void @target_constructor_user(ptr %a, ptr %b, ptr %c, ptr %d,
                                     ptr %source) #0 {
; SIZE-LABEL: define{{.*}}@target_constructor_user(
; SIZE-COUNT-4: call void @target_constructor(
  call void @target_constructor(ptr %a, ptr %source)
  call void @target_constructor(ptr %b, ptr %source)
  call void @target_constructor(ptr %c, ptr %source)
  call void @target_constructor(ptr %d, ptr %source)
  call void @sink(i64 0)
  ret void
}

attributes #0 = { inlinehint optsize "target-cpu"="ppe42" }
attributes #1 = { noinline }
