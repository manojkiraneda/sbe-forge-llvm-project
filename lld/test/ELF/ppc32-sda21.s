# REQUIRES: ppc
# RUN: split-file %s %t
# RUN: llvm-mc -triple=powerpc-unknown-elf -mcpu=ppe42 -filetype=obj %t/main.s -o %t.be.o
# RUN: ld.lld -T %t/layout.ld %t.be.o -o %t.be
# RUN: llvm-objdump -s --section=.text %t.be | FileCheck %s --check-prefix=BE
# RUN: llvm-mc -triple=powerpcle-unknown-elf -mcpu=ppe42 -filetype=obj %t/main.s -o %t.le.o
# RUN: ld.lld -T %t/layout.ld %t.le.o -o %t.le
# RUN: llvm-objdump -s --section=.text %t.le | FileCheck %s --check-prefix=LE
# RUN: ld.lld -r %t.be.o -o %t.partial.o
# RUN: llvm-readobj -r %t.partial.o | FileCheck %s --check-prefix=PARTIAL
# RUN: ld.lld -T %t/layout.ld %t.partial.o -o %t.partial
# RUN: llvm-objdump -s --section=.text %t.partial | FileCheck %s --check-prefix=BE
# RUN: not ld.lld -shared %t.be.o -o /dev/null 2>&1 | FileCheck %s --check-prefix=PIC
# RUN: not ld.lld -pie %t.be.o -o /dev/null 2>&1 | FileCheck %s --check-prefix=PIC

## Check preservation of the opcode and destination/source register, selection
## of all three bases, signed boundary offsets, addends and high 32-bit addresses.
# BE:      Contents of section .text:
# BE-NEXT: 1000 148d8000 188d0008 8062fffc 90620000
# BE-NEXT: 1010 88c00100 98c00109 38ed7fff 810d8008
# LE:      Contents of section .text:
# LE-NEXT: 1000 00808d14 08008d18 fcff6280 00006290
# LE-NEXT: 1010 0001c088 0901c098 ff7fed38 08800d81
# PARTIAL: 0x0 R_PPC_EMB_SDA21
# PARTIAL: 0x1C R_PPC_EMB_SDA21
# PIC: R_PPC_EMB_SDA21 is not supported in shared objects or PIE

#--- main.s
.global _start
_start:
        lvd 4, data@sda21(0)
        stvd 4, bss+8@sda21(0)
        lwz 3, constant+4@sda21(0)
        stw 3, cbss@sda21(0)
        lbz 6, zero@sda21(0)
        stb 6, zerobss+1@sda21(0)
        addi 7, 0, data+65535@sda21
        lwz 8, (data+8)@sda21(13)
.section .sdata,"aw",@progbits
data: .space 8
.section .sbss,"aw",@nobits
bss: .space 16
.section .sdata2,"a",@progbits
constant: .space 8
.section .sbss2,"a",@nobits
cbss: .space 8
.section .PPC.EMB.sdata0,"aw",@progbits
zero: .space 8
.section .PPC.EMB.sbss0,"aw",@nobits
zerobss: .space 8

#--- layout.ld
SECTIONS {
  .PPC.EMB.sdata0 0x100 : { *(.PPC.EMB.sdata0) }
  .PPC.EMB.sbss0 0x108 : { *(.PPC.EMB.sbss0) }
  .text 0x1000 : { *(.text) }
  .sdata 0xfff00000 : { *(.sdata) }
  .sbss 0xfff08000 : { *(.sbss) }
  .sdata2 0xfff10000 : { *(.sdata2) }
  .sbss2 0xfff10008 : { *(.sbss2) }
  _SDA_BASE_ = ADDR(.sdata) + 0x8000;
  _SDA2_BASE_ = ADDR(.sdata2) + 8;
}
