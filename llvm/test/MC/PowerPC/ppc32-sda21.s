# RUN: llvm-mc -triple=powerpc-unknown-elf -mcpu=ppe42 -filetype=obj %s -o %t.be
# RUN: llvm-readobj -r %t.be | FileCheck %s
# RUN: llvm-mc -triple=powerpcle-unknown-elf -mcpu=ppe42 -filetype=obj %s -o %t.le
# RUN: llvm-readobj -r %t.le | FileCheck %s

# Relocations cover the whole instruction, including the base register field,
# and must start at the instruction address for both byte orders.
        lvd %r4, data@sda21(0)
        stvd %r4, data+8@sda21(0)
        lwz %r3, data@sda21+4(0)
        stw %r3, (data+12)@sda21(0)
        addi %r5, 0, data@sda21
        lwz %r6, local@sda21(0)

.section .sdata,"aw",@progbits
local:
        .long 0

# CHECK:      Relocations [
# CHECK-NEXT:   Section {{.*}} .rela.text {
# CHECK-NEXT:     0x0 R_PPC_EMB_SDA21 data 0x0
# CHECK-NEXT:     0x4 R_PPC_EMB_SDA21 data 0x8
# CHECK-NEXT:     0x8 R_PPC_EMB_SDA21 data 0x4
# CHECK-NEXT:     0xC R_PPC_EMB_SDA21 data 0xC
# CHECK-NEXT:     0x10 R_PPC_EMB_SDA21 data 0x0
# CHECK-NEXT:     0x14 R_PPC_EMB_SDA21 .sdata 0x0
# CHECK-NEXT:   }
# CHECK-NEXT: ]
