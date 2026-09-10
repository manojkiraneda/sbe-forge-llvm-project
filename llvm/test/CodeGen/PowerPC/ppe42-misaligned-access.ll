; RUN: llc -mtriple=powerpc-unknown-elf -mcpu=ppe42 -verify-machineinstrs < %s | FileCheck %s

; PPE42 requires naturally aligned scalar accesses. In particular, two
; adjacent halfword stores at an address with only two-byte alignment must not
; be combined into an unaligned word store.

define void @store_adjacent_halfwords(ptr %base, i16 %first, i16 %second) {
; CHECK-LABEL: store_adjacent_halfwords:
; CHECK:       sth {{[0-9]+}}, 22(3)
; CHECK:       sth {{[0-9]+}}, 24(3)
; CHECK-NOT:   stw {{[0-9]+}}, 22(3)
; CHECK:       blr
  %first.ptr = getelementptr inbounds i8, ptr %base, i32 22
  store i16 %first, ptr %first.ptr, align 2
  %second.ptr = getelementptr inbounds i8, ptr %base, i32 24
  store i16 %second, ptr %second.ptr, align 2
  ret void
}

define void @store_adjacent_constant_halfwords(ptr %base) {
; CHECK-LABEL: store_adjacent_constant_halfwords:
; CHECK:       sth {{[0-9]+}}, 22(3)
; CHECK:       sth {{[0-9]+}}, 24(3)
; CHECK-NOT:   stw {{[0-9]+}}, 22(3)
; CHECK:       blr
  %first.ptr = getelementptr inbounds i8, ptr %base, i32 22
  store i16 12303, ptr %first.ptr, align 2
  %second.ptr = getelementptr inbounds i8, ptr %base, i32 24
  store i16 14355, ptr %second.ptr, align 2
  ret void
}

define i32 @load_misaligned_word(ptr %base) {
; CHECK-LABEL: load_misaligned_word:
; CHECK:       lhz {{[0-9]+}}, 22(3)
; CHECK:       lhz {{[0-9]+}}, 24(3)
; CHECK-NOT:   lwz {{[0-9]+}}, 22(3)
; CHECK:       blr
  %ptr = getelementptr inbounds i8, ptr %base, i32 22
  %value = load i32, ptr %ptr, align 2
  ret i32 %value
}
