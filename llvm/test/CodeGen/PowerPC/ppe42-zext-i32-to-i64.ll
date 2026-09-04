; RUN: llc -mtriple=powerpc-unknown-elf -mcpu=ppe42 < %s -o /dev/null

; A zero-extending i32 load must be represented in a PPE42 VDR tuple.  The
; generic PPC64 pattern selects LWZ8 with a G8RC result and crashes register
; allocation because that class has no PPE42 allocation order.

@input = global i32 0, align 4
@output = global i64 0, align 8

define void @zext_i32_load_to_i64() {
entry:
  %value = load volatile i32, ptr @input, align 4
  %extended = zext i32 %value to i64
  store volatile i64 %extended, ptr @output, align 8
  ret void
}
