# RUN: split-file %s %t
# RUN: llvm-mc -triple=powerpc-unknown-elf -mcpu=ppe42 -filetype=obj %t/global.s -o %t.o
# RUN: llvm-objdump -d --mcpu=ppe42 %t.o | FileCheck %s --check-prefix=ENC
# RUN: llvm-readobj -r %t.o | FileCheck %s --check-prefix=RELOC
# RUN: not llvm-mc -triple=powerpc-unknown-elf -mcpu=ppe42 -filetype=obj %t/cross-section.s -o /dev/null 2>&1 | FileCheck %s --check-prefix=UNRESOLVED
# RUN: not llvm-mc -triple=powerpc-unknown-elf -mcpu=ppe42 -filetype=obj %t/weak.s -o /dev/null 2>&1 | FileCheck %s --check-prefix=UNRESOLVED
# RUN: not llvm-mc -triple=powerpc-unknown-elf -mcpu=ppe42 -filetype=obj %t/range.s -o /dev/null 2>&1 | FileCheck %s --check-prefix=RANGE
# RUN: not llvm-mc -triple=powerpc-unknown-elf -mcpu=ppe42 -filetype=obj %t/alignment.s -o /dev/null 2>&1 | FileCheck %s --check-prefix=ALIGN

# A backward bwz to a global idle-thread entry must not become a branch to
# itself with an R_PPC_NONE relocation. Resolve forward targets and addends too.
# ENC: 4: 06 c3 07 fe
# ENC-NEXT: 8: 06 c4 38 06
# ENC-NEXT: c: 07 85 30 06
# ENC-NEXT: 10: 05 86 3f fa
# RELOC: Relocations [
# RELOC-NEXT: ]
# UNRESOLVED: error: PPE42 fused branch target must be locally resolvable
# RANGE: error: PPE42 branch target out of range
# ALIGN: error: PPE42 branch target must be 4-byte aligned

#--- global.s
.text
.globl back, forward
back:
  blr
  bwz 3, back
  cmpwibeq 4, 7, forward
  bb0wi 5, 6, forward+4
  cmplwblt 6, 7, back+4
forward:
  blr
  blr

#--- cross-section.s
.text
  bwz 3, other
.section .text.other,"ax"
.globl other
other:
  blr

#--- weak.s
.text
.weak replaceable
replaceable:
  blr
  bwz 3, replaceable

#--- range.s
.text
.globl far
  bwz 3, far
.space 2048
far:
  blr

#--- alignment.s
.text
.globl misaligned
  bwz 3, misaligned
.byte 0
misaligned:
  blr
