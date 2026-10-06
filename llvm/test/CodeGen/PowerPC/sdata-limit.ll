; RUN: sed 's/SMALL_DATA_LIMIT/0/' %s | llc -mtriple=powerpc-unknown-elf -mcpu=ppe42 -o - | FileCheck %s --check-prefix=ZERO
; RUN: sed 's/SMALL_DATA_LIMIT/8/' %s | llc -mtriple=powerpc-unknown-elf -mcpu=ppe42 -o - | FileCheck %s --check-prefix=EIGHT

@small_data = global i32 1
@small_bss = global i32 0
@small_const = constant i32 2
@large_data = global [16 x i8] zeroinitializer
@external_small_data = external global i32
@external_large_data = external global [16 x i8]

define i32 @read_small_data() {
  %value = load i32, ptr @small_data
  ret i32 %value
}

define i32 @read_small_const() {
  %value = load volatile i32, ptr @small_const
  ret i32 %value
}

define i32 @read_external_small_data() {
  %value = load i32, ptr @external_small_data
  ret i32 %value
}

define i8 @read_external_large_data() {
  %value = load i8, ptr @external_large_data
  ret i8 %value
}

!llvm.module.flags = !{!0}
!0 = !{i32 8, !"SmallDataLimit", i32 SMALL_DATA_LIMIT}

; ZERO-NOT: .sdata
; ZERO-NOT: .sbss
; EIGHT: lwz {{[0-9]+}}, small_data@sda21(13)
; EIGHT: lwz {{[0-9]+}}, small_const@sda21(2)
; EIGHT: lwz {{[0-9]+}}, external_small_data@sda21(13)
; EIGHT-NOT: external_large_data@sda21
; EIGHT: .section .sdata
; EIGHT: small_data:
; EIGHT: .section .sbss
; EIGHT: small_bss:
; EIGHT: .section .sdata2
; EIGHT: small_const:
; EIGHT: .section .bss
; EIGHT: large_data:
