; RUN: llc -mtriple=powerpc-unknown-elf -mcpu=ppe42 < %s | FileCheck %s

define i32 @udiv32(i32 %a, i32 %b) {
; CHECK-LABEL: udiv32:
; CHECK: bl __udivsi3
  %result = udiv i32 %a, %b
  ret i32 %result
}

define i32 @urem32(i32 %a, i32 %b) {
; CHECK-LABEL: urem32:
; CHECK: bl __umodsi3
  %result = urem i32 %a, %b
  ret i32 %result
}

define i64 @udiv64(i64 %a, i64 %b) {
; CHECK-LABEL: udiv64:
; CHECK: bl __udivdi3
  %result = udiv i64 %a, %b
  ret i64 %result
}

define i64 @urem64(i64 %a, i64 %b) {
; CHECK-LABEL: urem64:
; CHECK: bl __umoddi3
  %result = urem i64 %a, %b
  ret i64 %result
}
