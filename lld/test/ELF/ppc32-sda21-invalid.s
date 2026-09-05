# REQUIRES: ppc
# RUN: split-file %s %t
# RUN: llvm-mc -triple=powerpc-unknown-elf -filetype=obj %t/main.s -o %t.o
# RUN: not ld.lld %t.o --image-base=0 --section-start=.sdata=0x10000 --defsym=_SDA_BASE_=0x8000 -o /dev/null 2>&1 | FileCheck %s --check-prefix=HIGH
# RUN: not ld.lld %t.o --image-base=0 --section-start=.sdata=0x10000 --defsym=_SDA_BASE_=0x18001 -o /dev/null 2>&1 | FileCheck %s --check-prefix=LOW
# RUN: not ld.lld %t.o -o /dev/null 2>&1 | FileCheck %s --check-prefix=MISSING
# RUN: not ld.lld %t.o -T %t/wrong-section.ld -o /dev/null 2>&1 | FileCheck %s --check-prefix=SECTION
# RUN: llvm-mc -triple=powerpc-unknown-elf -filetype=obj %t/ro.s -o %t.ro.o
# RUN: not ld.lld %t.ro.o -o /dev/null 2>&1 | FileCheck %s --check-prefix=MISSING2

# HIGH: relocation R_PPC_EMB_SDA21 out of range: 32768 is not in [-32768, 32767]
# LOW: relocation R_PPC_EMB_SDA21 out of range: -32769 is not in [-32768, 32767]
# MISSING: R_PPC_EMB_SDA21 requires _SDA_BASE_ to be defined
# MISSING2: R_PPC_EMB_SDA21 requires _SDA2_BASE_ to be defined
# SECTION: R_PPC_EMB_SDA21 against{{.*}}requires a small-data output section

#--- main.s
.global _start
_start:
        lwz 3, data@sda21(0)
.section .sdata,"aw",@progbits
data: .long 0

#--- ro.s
.global _start
_start:
        lwz 3, data@sda21(0)
.section .sdata2,"a",@progbits
data: .long 0

#--- wrong-section.ld
SECTIONS {
  .text 0x1000 : { *(.text) }
  .data 0x2000 : { *(.sdata) }
  _SDA_BASE_ = 0x2000;
}
