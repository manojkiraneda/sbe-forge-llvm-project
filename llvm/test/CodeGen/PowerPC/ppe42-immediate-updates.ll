; RUN: llc -mtriple=powerpc-none-eabi -mcpu=ppe42 -verify-machineinstrs %s -o - | FileCheck %s --check-prefix=ASM --implicit-check-not=lbzux --implicit-check-not=lhzux --implicit-check-not=lwzux --implicit-check-not=stbux --implicit-check-not=sthux --implicit-check-not=stwux --implicit-check-not=lhau
; RUN: llc -mtriple=powerpc-none-eabi -mcpu=ppe42 -verify-machineinstrs -stop-after=finalize-isel %s -o - | FileCheck %s --check-prefix=ISEL --implicit-check-not=:g8rc
; RUN: llc -mtriple=powerpc-none-eabi -mcpu=ppe42 -verify-machineinstrs -filetype=obj %s -o %t.o
;
; Immediate updates are legal; register-indexed updates and signed halfword
; update loads are not. Check selection before the late update peepholes.

define i32 @load_u8(ptr %p, ptr %out) optsize {
; ASM-LABEL: load_u8:
; ASM: lbzu {{[0-9]+}}, 1(
; ISEL-LABEL: name: load_u8
; ISEL: LBZU 1,
  %next = getelementptr i8, ptr %p, i32 1
  %v = load i8, ptr %next, align 1
  store ptr %next, ptr %out, align 4
  %wide = zext i8 %v to i32
  ret i32 %wide
}

define i32 @load_u16(ptr %p, ptr %out) optsize {
; ASM-LABEL: load_u16:
; ASM: lhzu {{[0-9]+}}, -2(
; ISEL-LABEL: name: load_u16
; ISEL: LHZU -2,
  %next = getelementptr i16, ptr %p, i32 -1
  %v = load i16, ptr %next, align 2
  store ptr %next, ptr %out, align 4
  %wide = zext i16 %v to i32
  ret i32 %wide
}

define i32 @load_u32(ptr %p, ptr %out) optsize {
; ASM-LABEL: load_u32:
; ASM: lwzu {{[0-9]+}}, 4(
; ISEL-LABEL: name: load_u32
; ISEL: LWZU 4,
  %next = getelementptr i32, ptr %p, i32 1
  %v = load i32, ptr %next, align 4
  store ptr %next, ptr %out, align 4
  ret i32 %v
}

define ptr @store_u8(ptr %p, i32 %v) optsize {
; ASM-LABEL: store_u8:
; ASM: stbu {{[0-9]+}}, 1(
; ISEL-LABEL: name: store_u8
; ISEL: STBU {{.*}}1,
  %next = getelementptr i8, ptr %p, i32 1
  %narrow = trunc i32 %v to i8
  store i8 %narrow, ptr %next, align 1
  ret ptr %next
}

define ptr @store_u16(ptr %p, i32 %v) optsize {
; ASM-LABEL: store_u16:
; ASM: sthu {{[0-9]+}}, 2(
; ISEL-LABEL: name: store_u16
; ISEL: STHU {{.*}}2,
  %next = getelementptr i16, ptr %p, i32 1
  %narrow = trunc i32 %v to i16
  store i16 %narrow, ptr %next, align 2
  ret ptr %next
}

define ptr @store_u32(ptr %p, i32 %v) optsize {
; ASM-LABEL: store_u32:
; ASM: stwu {{[0-9]+}}, 4(
; ISEL-LABEL: name: store_u32
; ISEL: STWU {{.*}}4,
  %next = getelementptr i32, ptr %p, i32 1
  store i32 %v, ptr %next, align 4
  ret ptr %next
}

define i32 @dynamic_load_u8(ptr %p, i32 %index, ptr %out) optsize {
; ASM-LABEL: dynamic_load_u8:
; ASM: blr
  %next = getelementptr i8, ptr %p, i32 %index
  %v = load i8, ptr %next, align 1
  store ptr %next, ptr %out, align 4
  %wide = zext i8 %v to i32
  ret i32 %wide
}

define ptr @dynamic_store_u8(ptr %p, i32 %index, i32 %v) optsize {
; ASM-LABEL: dynamic_store_u8:
; ASM: blr
  %next = getelementptr i8, ptr %p, i32 %index
  %narrow = trunc i32 %v to i8
  store i8 %narrow, ptr %next, align 1
  ret ptr %next
}

define i32 @dynamic_load_u16(ptr %p, i32 %index, ptr %out) optsize {
; ASM-LABEL: dynamic_load_u16:
; ASM: blr
  %next = getelementptr i16, ptr %p, i32 %index
  %v = load i16, ptr %next, align 2
  store ptr %next, ptr %out, align 4
  %wide = zext i16 %v to i32
  ret i32 %wide
}

define ptr @dynamic_store_u16(ptr %p, i32 %index, i32 %v) optsize {
; ASM-LABEL: dynamic_store_u16:
; ASM: blr
  %next = getelementptr i16, ptr %p, i32 %index
  %narrow = trunc i32 %v to i16
  store i16 %narrow, ptr %next, align 2
  ret ptr %next
}

define i32 @dynamic_load_u32(ptr %p, i32 %index, ptr %out) optsize {
; ASM-LABEL: dynamic_load_u32:
; ASM: blr
  %next = getelementptr i32, ptr %p, i32 %index
  %v = load i32, ptr %next, align 4
  store ptr %next, ptr %out, align 4
  ret i32 %v
}

define ptr @dynamic_store_u32(ptr %p, i32 %index, i32 %v) optsize {
; ASM-LABEL: dynamic_store_u32:
; ASM: blr
  %next = getelementptr i32, ptr %p, i32 %index
  store i32 %v, ptr %next, align 4
  ret ptr %next
}

define i32 @signed_half(ptr %p, ptr %out) optsize {
; ASM-LABEL: signed_half:
; ASM: blr
  %next = getelementptr i16, ptr %p, i32 1
  %v = load i16, ptr %next, align 2
  store ptr %next, ptr %out, align 4
  %wide = sext i16 %v to i32
  ret i32 %wide
}

define i32 @volatile_word(ptr %p, ptr %out) optsize {
; ASM-LABEL: volatile_word:
; ASM-NOT: lwzu
; ASM: blr
  %next = getelementptr i32, ptr %p, i32 1
  %v = load volatile i32, ptr %next, align 4
  store ptr %next, ptr %out, align 4
  ret i32 %v
}

define i32 @large_displacement(ptr %p, ptr %out) optsize {
; ASM-LABEL: large_displacement:
; ASM: blr
  %next = getelementptr i32, ptr %p, i32 8192
  %v = load i32, ptr %next, align 4
  store ptr %next, ptr %out, align 4
  ret i32 %v
}

define i64 @wide_result(ptr %p, ptr %out) optsize {
; ASM-LABEL: wide_result:
; ASM: blr
  %next = getelementptr i32, ptr %p, i32 1
  %v = load i32, ptr %next, align 4
  store ptr %next, ptr %out, align 4
  %wide = zext i32 %v to i64
  ret i64 %wide
}

define ptr @wide_truncation(ptr %p, i64 %v) optsize {
; ASM-LABEL: wide_truncation:
; ASM: blr
  %next = getelementptr i32, ptr %p, i32 1
  %low = trunc i64 %v to i32
  store i32 %low, ptr %next, align 4
  ret ptr %next
}

define i32 @unaligned_word(ptr %p, ptr %out) optsize {
; ASM-LABEL: unaligned_word:
; ASM-NOT: lwzu
; ASM: blr
  %next = getelementptr i8, ptr %p, i32 1
  %v = load i32, ptr %next, align 1
  store ptr %next, ptr %out, align 4
  ret i32 %v
}
