; RUN: llc -mtriple=powerpc-unknown-elf -mcpu=ppe42 -verify-machineinstrs %s -o - | FileCheck %s --check-prefix=PPE --implicit-check-not=lhbrx --implicit-check-not=lwbrx --implicit-check-not=sthbrx --implicit-check-not=stwbrx
; RUN: llc -mtriple=powerpc-unknown-elf -mcpu=ppe42 -O0 -verify-machineinstrs %s -o - | FileCheck %s --check-prefix=PPE --implicit-check-not=lhbrx --implicit-check-not=lwbrx --implicit-check-not=sthbrx --implicit-check-not=stwbrx
; RUN: llc -mtriple=powerpc-unknown-elf -mcpu=ppe42 -filetype=obj %s -o %t.o
; RUN: llc -mtriple=powerpc-unknown-elf -mcpu=440 %s -o - | FileCheck %s --check-prefix=PPC
;
; PPE42 does not implement the byte-reversed load/store family. In particular,
; bswap(load i32) in the firmware decompressor must not become LWBRX.

declare i16 @llvm.bswap.i16(i16)
declare i32 @llvm.bswap.i32(i32)
declare i64 @llvm.bswap.i64(i64)

; PPE-LABEL: load16:
; PPE: blr
; PPC-LABEL: load16:
; PPC: lhbrx
define i16 @load16(ptr %p) {
 %v = load i16, ptr %p, align 2
 %r = call i16 @llvm.bswap.i16(i16 %v)
 ret i16 %r
}

; PPE-LABEL: store16:
; PPE: blr
; PPC-LABEL: store16:
; PPC: sthbrx
define void @store16(ptr %p, i16 %v) {
 %r = call i16 @llvm.bswap.i16(i16 %v)
 store i16 %r, ptr %p, align 2
 ret void
}

; PPE-LABEL: load16_volatile:
; PPE: blr
define i16 @load16_volatile(ptr %p) {
 %v = load volatile i16, ptr %p, align 2
 %r = call i16 @llvm.bswap.i16(i16 %v)
 ret i16 %r
}

; PPE-LABEL: store16_volatile:
; PPE: blr
define void @store16_volatile(ptr %p, i16 %v) {
 %r = call i16 @llvm.bswap.i16(i16 %v)
 store volatile i16 %r, ptr %p, align 2
 ret void
}

; PPE-LABEL: load32:
; PPE: blr
; PPC-LABEL: load32:
; PPC: lwbrx
define i32 @load32(ptr %p) {
 %v = load i32, ptr %p, align 4
 %r = call i32 @llvm.bswap.i32(i32 %v)
 ret i32 %r
}

; PPE-LABEL: store32:
; PPE: blr
; PPC-LABEL: store32:
; PPC: stwbrx
define void @store32(ptr %p, i32 %v) {
 %r = call i32 @llvm.bswap.i32(i32 %v)
 store i32 %r, ptr %p, align 4
 ret void
}

; PPE-LABEL: load32_volatile:
; PPE: blr
define i32 @load32_volatile(ptr %p) {
 %v = load volatile i32, ptr %p, align 4
 %r = call i32 @llvm.bswap.i32(i32 %v)
 ret i32 %r
}

; PPE-LABEL: store32_volatile:
; PPE: blr
define void @store32_volatile(ptr %p, i32 %v) {
 %r = call i32 @llvm.bswap.i32(i32 %v)
 store volatile i32 %r, ptr %p, align 4
 ret void
}

; PPE-LABEL: load64:
; PPE: blr
define i64 @load64(ptr %p) {
 %v = load i64, ptr %p, align 8
 %r = call i64 @llvm.bswap.i64(i64 %v)
 ret i64 %r
}

; PPE-LABEL: store64:
; PPE: blr
define void @store64(ptr %p, i64 %v) {
 %r = call i64 @llvm.bswap.i64(i64 %v)
 store i64 %r, ptr %p, align 8
 ret void
}

; PPE-LABEL: load64_volatile:
; PPE: blr
define i64 @load64_volatile(ptr %p) {
 %v = load volatile i64, ptr %p, align 8
 %r = call i64 @llvm.bswap.i64(i64 %v)
 ret i64 %r
}

; PPE-LABEL: store64_volatile:
; PPE: blr
define void @store64_volatile(ptr %p, i64 %v) {
 %r = call i64 @llvm.bswap.i64(i64 %v)
 store volatile i64 %r, ptr %p, align 8
 ret void
}
