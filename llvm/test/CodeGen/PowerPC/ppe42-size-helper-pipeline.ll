; RUN: opt -mtriple=powerpc-none-eabi -mcpu=ppe42 -passes='default<Os>' -S %s | FileCheck %s
; RUN: opt -mtriple=powerpc-none-eabi -mcpu=ppe42 -ppe42-size-ipa=false -passes='default<Os>' -S %s | FileCheck %s --check-prefix=DISABLED
; RUN: opt -mtriple=powerpc-none-eabi -mcpu=ppe42 -passes='debugify,default<Os>,verify' -disable-output %s

; A template checking helper initially keeps 'this' live. Only after inlining
; that check can the size pass remove the unused pointer and group arguments.
; Exercise the normal pipeline rather than manually ordering the target pass.
$helper = comdat any
$check = comdat any

define linkonce_odr dso_local void @check(ptr %object) optsize comdat {
  ret void
}

define linkonce_odr dso_local i32 @helper(ptr %object, i32 %group, i32 %value) optsize comdat {
  call void @check(ptr %object)
  %bits = and i32 %value, 15
  %shift = mul i32 %bits, 69632
  %set = or i32 %shift, -2147483632
  %neg = icmp slt i32 %value, 0
  %selected = select i1 %neg, i32 %value, i32 %set
  %mask = and i32 %selected, -251658273
  %result = or i32 %mask, 150994976
  ret i32 %result
}

declare void @consume(i32)

define void @caller(ptr %object, i32 %a, i32 %b, i32 %c, i32 %d) optsize {
; CHECK-LABEL: define void @caller(
; CHECK: call i32 @helper.ppe42.size.a2.r32(i32 %a)
; CHECK: call i32 @helper.ppe42.size.a2.r32(i32 %b)
; CHECK: call i32 @helper.ppe42.size.a2.r32(i32 %c)
; CHECK: call i32 @helper.ppe42.size.a2.r32(i32 %d)
; CHECK-LABEL: define linkonce_odr dso_local i32 @helper.ppe42.size.a2.r32(i32 %value)
; CHECK-NOT: ppe42-size-arg
; CHECK-NOT: ppe42-size-original
; DISABLED-LABEL: define void @caller(
; DISABLED-NOT: ppe42.size
; DISABLED: call i32 @helper(ptr {{[^,]+}}, i32 7, i32 %a)
  %r0 = call i32 @helper(ptr %object, i32 7, i32 %a)
  call void @consume(i32 %r0)
  %r1 = call i32 @helper(ptr %object, i32 7, i32 %b)
  call void @consume(i32 %r1)
  %r2 = call i32 @helper(ptr %object, i32 7, i32 %c)
  call void @consume(i32 %r2)
  %r3 = call i32 @helper(ptr %object, i32 7, i32 %d)
  call void @consume(i32 %r3)
  ret void
}
