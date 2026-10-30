; RUN: llc -mtriple=powerpc-none-eabi -mcpu=ppe42 -enable-machine-outliner=never -verify-machineinstrs %s -o - | FileCheck %s
; RUN: llc -mtriple=powerpc-none-eabi -mcpu=ppe42 -stop-after=ppc-ppe42-stack-align %s -o - | FileCheck %s --check-prefix=IR
; RUN: llc -mtriple=powerpc-none-eabi -mcpu=440 -stop-after=ppc-ppe42-stack-align %s -o - | FileCheck %s --check-prefix=OTHER
; RUN: llc -mtriple=powerpc-none-eabi -mcpu=ppe42 -verify-machineinstrs -filetype=obj %s -o %t.o
;
; A local byval source can be aligned independently of its type. Preserve the
; byval ABI attributes; use the known source and outgoing-slot alignment when
; lowering the copy. In particular, stronger loads must not still be split
; into halfword stores to an actually word-aligned outgoing slot.
%Header = type { i16, i16, i8, [3 x i8] }
%Packed = type <{ i8, i8, i16, i32 }>
%Large = type { i16, [5 x i16] }
%Short = type { i16 }
declare void @fill(ptr)
declare void @consume(ptr byval(%Header) align 2)
declare void @consume_packed(ptr byval(%Packed) align 1)
declare void @consume_short(ptr byval(%Short) align 2)

define void @local_half_aligned() optsize {
; IR-LABEL: define void @local_half_aligned()
; IR: alloca %Header, align 4
; IR: call void @consume(ptr byval(%Header) align 2
; OTHER-LABEL: define void @local_half_aligned()
; OTHER: alloca %Header, align 2
; CHECK-LABEL: local_half_aligned:
; CHECK: bl fill
; CHECK-NOT: lhz
; CHECK-NOT: sth
; CHECK: {{lwz|lvd}}
; CHECK-NOT: lhz
; CHECK-NOT: sth
; CHECK: {{stw|stvd}}
; CHECK-NOT: lhz
; CHECK-NOT: sth
; CHECK: bl consume
  %h = alloca %Header, align 2
  call void @fill(ptr %h)
  call void @consume(ptr byval(%Header) align 2 %h)
  ret void
}

define void @local_packed() optsize {
; IR-LABEL: define void @local_packed()
; IR: alloca %Packed, align 4
; IR: call void @consume_packed(ptr byval(%Packed) align 1
; CHECK-LABEL: local_packed:
; CHECK: bl fill
; CHECK-NOT: lbz
; CHECK-NOT: stb
; CHECK: {{lwz|lvd}}
; CHECK-NOT: lbz
; CHECK-NOT: stb
; CHECK: {{stw|stvd}}
; CHECK-NOT: lbz
; CHECK-NOT: stb
; CHECK: bl consume_packed
  %h = alloca %Packed, align 1
  call void @fill(ptr %h)
  call void @consume_packed(ptr byval(%Packed) align 1 %h)
  ret void
}

define void @external(ptr %p) optsize {
; IR-LABEL: define void @external(
; IR: call void @consume(ptr byval(%Header) align 2 %p)
; CHECK-LABEL: external:
; CHECK: lhz
; CHECK: bl consume
  call void @consume(ptr byval(%Header) align 2 %p)
  ret void
}

define void @offset_two() optsize {
; IR-LABEL: define void @offset_two()
; IR: alloca %Large, align 2
; CHECK-LABEL: offset_two:
; CHECK: lhz
; CHECK: bl consume
  %h = alloca %Large, align 2
  call void @fill(ptr %h)
  %p = getelementptr i8, ptr %h, i32 2
  call void @consume(ptr byval(%Header) align 2 %p)
  ret void
}

define void @short_copy() optsize {
; IR-LABEL: define void @short_copy()
; IR: alloca %Short, align 2
  %h = alloca %Short, align 2
  call void @fill(ptr %h)
  call void @consume_short(ptr byval(%Short) align 2 %h)
  ret void
}

define void @dynamic(i32 %n) optsize {
; IR-LABEL: define void @dynamic(
; IR: alloca %Header, i32 %n, align 2
  %h = alloca %Header, i32 %n, align 2
  call void @fill(ptr %h)
  call void @consume(ptr byval(%Header) align 2 %h)
  ret void
}

define void @multiple_objects() optsize {
; IR-LABEL: define void @multiple_objects()
; IR: alloca %Header, i32 2, align 2
  %h = alloca %Header, i32 2, align 2
  call void @fill(ptr %h)
  call void @consume(ptr byval(%Header) align 2 %h)
  ret void
}

define void @not_size_optimized() {
; IR-LABEL: define void @not_size_optimized()
; IR: alloca %Header, align 2
  %h = alloca %Header, align 2
  call void @fill(ptr %h)
  call void @consume(ptr byval(%Header) align 2 %h)
  ret void
}
