; RUN: sed 's/SMALL_DATA_LIMIT/0/' %s | llc -mtriple=powerpc-unknown-elf -o - | FileCheck %s --check-prefix=ZERO
; RUN: sed 's/SMALL_DATA_LIMIT/8/' %s | llc -mtriple=powerpc-unknown-elf -o - | FileCheck %s --check-prefix=EIGHT

@small_data = global i32 1
@small_bss = global i32 0
@large_data = global [16 x i8] zeroinitializer

!llvm.module.flags = !{!0}
!0 = !{i32 8, !"SmallDataLimit", i32 SMALL_DATA_LIMIT}

; ZERO-NOT: .sdata
; ZERO-NOT: .sbss
; EIGHT: .section .sdata
; EIGHT: small_data:
; EIGHT: .section .sbss
; EIGHT: small_bss:
; EIGHT: .section .bss
; EIGHT: large_data:
