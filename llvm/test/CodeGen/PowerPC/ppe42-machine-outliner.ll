; RUN: llc -mtriple=powerpc-none-eabi -mcpu=ppe42 -verify-machineinstrs %s -o - | FileCheck %s
; RUN: llc -mtriple=powerpc-none-eabi -mcpu=ppe42 -enable-machine-outliner=never -verify-machineinstrs %s -o - | FileCheck %s --check-prefix=DISABLED
; RUN: llc -mtriple=powerpc-none-eabi -mcpu=440 -verify-machineinstrs %s -o - | FileCheck %s --check-prefix=DISABLED
; RUN: llc -mtriple=powerpc-none-eabi -mcpu=ppe42 -filetype=obj %s -o %t.on.o
; RUN: llc -mtriple=powerpc-none-eabi -mcpu=ppe42 -enable-machine-outliner=never -filetype=obj %s -o %t.off.o
; RUN: %python %S/Inputs/ppe42-outliner-size.py %t.off.o %t.on.o
; RUN: opt -passes=debugify %s -o %t.debug.bc
; RUN: llc -mtriple=powerpc-none-eabi -mcpu=ppe42 -verify-machineinstrs %t.debug.bc -o - | FileCheck %s
; RUN: llc -mtriple=powerpc-none-eabi -mcpu=ppe42 -verify-machineinstrs -filetype=obj %t.debug.bc -o %t.debug.o

; Size functions share repeated call setup without adding a stack frame to
; the outlined helper. Other PowerPC CPUs and non-size functions are excluded.
; DISABLED-NOT: OUTLINED_FUNCTION
declare void @trace(i32, i32, i32, i32)

define void @size_probe() optsize {
; CHECK-LABEL: size_probe:
; CHECK: bl OUTLINED_FUNCTION_
; CHECK: blr
  call void @trace(i32 1, i32 0, i32 0, i32 0)
  call void @trace(i32 2, i32 0, i32 0, i32 0)
  call void @trace(i32 3, i32 0, i32 0, i32 0)
  call void @trace(i32 4, i32 0, i32 0, i32 0)
  call void @trace(i32 5, i32 0, i32 0, i32 0)
  call void @trace(i32 6, i32 0, i32 0, i32 0)
  call void asm sideeffect "", ""()
  ret void
}

define void @speed_probe() {
; CHECK-LABEL: speed_probe:
; CHECK-NOT: OUTLINED_FUNCTION
; CHECK: blr
  call void @trace(i32 1, i32 0, i32 0, i32 0)
  call void @trace(i32 2, i32 0, i32 0, i32 0)
  call void @trace(i32 3, i32 0, i32 0, i32 0)
  call void @trace(i32 4, i32 0, i32 0, i32 0)
  call void @trace(i32 5, i32 0, i32 0, i32 0)
  call void @trace(i32 6, i32 0, i32 0, i32 0)
  call void asm sideeffect "", ""()
  ret void
}

; Model the sign/absolute-value sequences in ppe42_math.c's __divsi3 and
; __modsi3. Debugify places variable locations between these instructions,
; exercising debug operands inside a range selected by the real pipeline.
declare i32 @unsigned_div(i32, i32)
declare i32 @unsigned_mod(i32, i32)

define i32 @signed_div(i32 %a, i32 %b) optsize {
  %as = ashr i32 %a, 31
  %bs = ashr i32 %b, 31
  %ax = xor i32 %a, %as
  %aa = sub i32 %ax, %as
  %bx = xor i32 %b, %bs
  %ba = sub i32 %bx, %bs
  %sign = xor i32 %as, %bs
  %quotient = call i32 @unsigned_div(i32 %aa, i32 %ba)
  %qx = xor i32 %quotient, %sign
  %result = sub i32 %qx, %sign
  ret i32 %result
}

define i32 @signed_mod(i32 %a, i32 %b) optsize {
  %as = ashr i32 %a, 31
  %bs = ashr i32 %b, 31
  %ax = xor i32 %a, %as
  %aa = sub i32 %ax, %as
  %bx = xor i32 %b, %bs
  %ba = sub i32 %bx, %bs
  %remainder = call i32 @unsigned_mod(i32 %aa, i32 %ba)
  %rx = xor i32 %remainder, %as
  %result = sub i32 %rx, %as
  ret i32 %result
}
