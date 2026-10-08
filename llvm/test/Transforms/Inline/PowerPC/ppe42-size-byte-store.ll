; RUN: opt -S -mtriple=powerpc-unknown-elf -mcpu=ppe42 -passes='default<Os>' %s | FileCheck %s

; The IR looks like a 64-bit read/modify/write, but PPE42 lowers this
; full-byte replacement to one stb. Calls to a shared helper cost more.
define linkonce_odr dso_local ptr @byte_update(ptr %p, i64 %x) #0 {
  %old = load i64, ptr %p, align 8
  %newbyte = shl i64 %x, 56
  %keep = and i64 %old, 72057594037927935
  %new = or i64 %keep, %newbyte
  store i64 %new, ptr %p, align 8
  ret ptr %p
}

declare void @observe(ptr)

define void @many_byte_updates(ptr %p, i64 %x) #0 {
; CHECK-LABEL: define void @many_byte_updates(
; CHECK-NOT: call ptr @byte_update
; CHECK: ret void
  call ptr @byte_update(ptr %p, i64 %x)
  call void @observe(ptr %p)
  call ptr @byte_update(ptr %p, i64 %x)
  call void @observe(ptr %p)
  call ptr @byte_update(ptr %p, i64 %x)
  call void @observe(ptr %p)
  call ptr @byte_update(ptr %p, i64 %x)
  ret void
}

; A partial-byte update still needs a read/modify/write and remains subject
; to the shared-call rule.
define linkonce_odr dso_local ptr @nibble_update(ptr %p, i64 %x) #0 {
  %old = load i64, ptr %p, align 8
  %newbits = and i64 %x, 15
  %keep = and i64 %old, -16
  %new = or i64 %keep, %newbits
  store i64 %new, ptr %p, align 8
  ret ptr %p
}

define void @many_nibble_updates(ptr %p, i64 %x) #0 {
; CHECK-LABEL: define void @many_nibble_updates(
; CHECK: call ptr @nibble_update
  call ptr @nibble_update(ptr %p, i64 %x)
  call void @observe(ptr %p)
  call ptr @nibble_update(ptr %p, i64 %x)
  call void @observe(ptr %p)
  call ptr @nibble_update(ptr %p, i64 %x)
  call void @observe(ptr %p)
  call ptr @nibble_update(ptr %p, i64 %x)
  ret void
}

attributes #0 = { inlinehint optsize "target-cpu"="ppe42" }
