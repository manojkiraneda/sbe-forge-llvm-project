; RUN: llc -mtriple=powerpc-none-eabi -mcpu=ppe42 -verify-machineinstrs %s -o - | FileCheck %s
; RUN: llc -mtriple=powerpc-none-eabi -mcpu=ppe42 -stop-after=ppc-ppe42-stack-align %s -o - | FileCheck %s --check-prefix=IR
; RUN: llc -mtriple=powerpc-none-eabi -mcpu=440 -stop-after=ppc-ppe42-stack-align %s -o - | FileCheck %s --check-prefix=OTHER
; RUN: llc -mtriple=powerpc-none-eabi -mcpu=ppe42 -verify-machineinstrs -filetype=obj %s -o %t.o
;
; Stronger alignment of a local packed object must not change field offsets,
; external pointer alignment, or accesses whose field offset is misaligned.
%Header = type <{ i8, i8, i16, i32, i32, i32, i32 }>
%Misaligned = type <{ i8, i32 }>
declare void @fill(ptr)

define i32 @word() optsize {
; IR-LABEL: define i32 @word()
; IR: alloca %Header, align 4
; OTHER-LABEL: define i32 @word()
; OTHER: alloca %Header, align 1
; CHECK-LABEL: word:
; CHECK-NOT: lbz
; CHECK: lwz 3,
; CHECK-NOT: lbz
; CHECK: blr
  %h = alloca %Header, align 1
  call void @fill(ptr %h)
  %p = getelementptr %Header, ptr %h, i32 0, i32 3
  %v = load i32, ptr %p, align 1
  ret i32 %v
}

define i16 @halfword() optsize {
; IR-LABEL: define i16 @halfword()
; IR: alloca %Header, align 2
; CHECK-LABEL: halfword:
; CHECK-NOT: lbz
; CHECK: lhz 3,
; CHECK-NOT: lbz
; CHECK: blr
  %h = alloca %Header, align 1
  call void @fill(ptr %h)
  %p = getelementptr %Header, ptr %h, i32 0, i32 2
  %v = load i16, ptr %p, align 1
  ret i16 %v
}

define i32 @misaligned_field() optsize {
; IR-LABEL: define i32 @misaligned_field()
; IR: alloca %Misaligned, align 1
; CHECK-LABEL: misaligned_field:
; CHECK: lbz
; CHECK: blr
  %h = alloca %Misaligned, align 1
  call void @fill(ptr %h)
  %p = getelementptr %Misaligned, ptr %h, i32 0, i32 1
  %v = load i32, ptr %p, align 1
  ret i32 %v
}

define i32 @volatile_only() optsize {
; IR-LABEL: define i32 @volatile_only()
; IR: alloca %Header, align 1
  %h = alloca %Header, align 1
  call void @fill(ptr %h)
  %p = getelementptr %Header, ptr %h, i32 0, i32 3
  %v = load volatile i32, ptr %p, align 1
  ret i32 %v
}

define i32 @external(ptr %p) optsize {
; IR-LABEL: define i32 @external(
; IR: load i32, ptr %p, align 1
; CHECK-LABEL: external:
; CHECK: lbz
; CHECK: blr
  %v = load i32, ptr %p, align 1
  ret i32 %v
}

define i32 @variable_offset(i32 %i) optsize {
; IR-LABEL: define i32 @variable_offset(
; IR: alloca %Header, align 1
  %h = alloca %Header, align 1
  call void @fill(ptr %h)
  %p = getelementptr i8, ptr %h, i32 %i
  %v = load i32, ptr %p, align 1
  ret i32 %v
}

define i32 @multiple_objects() optsize {
; IR-LABEL: define i32 @multiple_objects()
; IR: alloca %Header, i32 2, align 1
  %h = alloca %Header, i32 2, align 1
  call void @fill(ptr %h)
  %p = getelementptr %Header, ptr %h, i32 0, i32 3
  %v = load i32, ptr %p, align 1
  ret i32 %v
}

define i32 @not_size_optimized() {
; IR-LABEL: define i32 @not_size_optimized()
; IR: alloca %Header, align 1
  %h = alloca %Header, align 1
  call void @fill(ptr %h)
  %p = getelementptr %Header, ptr %h, i32 0, i32 3
  %v = load i32, ptr %p, align 1
  ret i32 %v
}

define void @store_word(i32 %v) optsize {
; IR-LABEL: define void @store_word(
; IR: alloca %Header, align 4
; CHECK-LABEL: store_word:
; CHECK-NOT: stb
; CHECK: stw
; CHECK-NOT: stb
; CHECK: blr
  %h = alloca %Header, align 1
  %p = getelementptr %Header, ptr %h, i32 0, i32 3
  store i32 %v, ptr %p, align 1
  call void @fill(ptr %h)
  ret void
}
