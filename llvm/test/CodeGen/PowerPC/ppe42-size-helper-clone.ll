; RUN: opt -mtriple=powerpc-none-eabi -mcpu=ppe42 -passes='ppe42-size-clone-helpers,deadargelim' -S %s | FileCheck %s

; The externally visible ABI remains available. Local calls may use an
; internal copy whose unused pointer and scalar arguments are removed.
$helper = comdat any

define linkonce_odr dso_local i32 @helper(ptr nonnull %object, i32 %group, i32 %value) optsize comdat {
entry:
  %result = add i32 %value, 1
  ret i32 %result
}

define i32 @caller(ptr %object, i32 %value) optsize {
entry:
  %a = call i32 @helper(ptr nonnull %object, i32 7, i32 %value)
  %b = call i32 @helper(ptr nonnull %object, i32 7, i32 %a)
  %c = call i32 @helper(ptr nonnull %object, i32 7, i32 %b)
  ret i32 %c
}

; CHECK-LABEL: define linkonce_odr dso_local i32 @helper(ptr nonnull %object, i32 %group, i32 %value)
; CHECK-SAME: comdat
; CHECK-LABEL: define i32 @caller(ptr %object, i32 %value)
; CHECK: call i32 @helper.ppe42.size(i32 %value)
; CHECK: call i32 @helper.ppe42.size(i32 %a)
; CHECK: call i32 @helper.ppe42.size(i32 %b)
; CHECK-LABEL: define internal i32 @helper.ppe42.size(i32 %value)
