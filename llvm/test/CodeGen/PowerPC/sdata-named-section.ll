; RUN: llc -mtriple=powerpc-unknown-elf -mcpu=ppe42 -o - %s | FileCheck %s

; Explicit per-symbol small-data sections must use the EABI base register too.
; Firmware sources use attributes such as section(".sdata.g_iota_intr_depth_count").
@named_data = global i32 1, section ".sdata.named_data"
@named_bss = global i32 0, section ".sbss.named_bss"
@named_const = constant i32 2, section ".sdata2.named_const"
@not_small = global i32 3, section ".data.named"

define i32 @read_named_data() {
  %value = load volatile i32, ptr @named_data
  ret i32 %value
}

define i32 @read_named_bss() {
  %value = load volatile i32, ptr @named_bss
  ret i32 %value
}

define i32 @read_named_const() {
  %value = load volatile i32, ptr @named_const
  ret i32 %value
}

define i32 @read_not_small() {
  %value = load volatile i32, ptr @not_small
  ret i32 %value
}

; CHECK-LABEL: read_named_data:
; CHECK: lwz {{[0-9]+}}, named_data@sda21(13)
; CHECK-LABEL: read_named_bss:
; CHECK: lwz {{[0-9]+}}, named_bss@sda21(13)
; CHECK-LABEL: read_named_const:
; CHECK: lwz {{[0-9]+}}, named_const@sda21(2)
; CHECK-LABEL: read_not_small:
; CHECK-NOT: not_small@sda21
