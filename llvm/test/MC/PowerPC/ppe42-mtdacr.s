# RUN: llvm-mc -triple=powerpc-unknown-elf -mcpu=ppe42 -show-encoding %s | FileCheck %s --check-prefix=ENC
# RUN: llvm-mc -triple=powerpc-unknown-elf -mcpu=ppe42 -filetype=obj %s -o %t
# RUN: llvm-objdump -d --mcpu=ppe42 %t | FileCheck %s --check-prefix=DIS
# RUN: llvm-objdump -d --mcpu=ppc %t | FileCheck %s --check-prefix=GENERIC
# RUN: not llvm-mc -triple=powerpc-unknown-elf -mcpu=ppc %s 2>&1 | FileCheck %s --check-prefix=ERR

# PPE42 User's Manual v5.1, sections 8.10.3 and 9.4.57:
# mtdacr is the extended mnemonic for writing DACR (SPR 316).
        mtdacr 3
        mtdacr %r4
        mtspr 316, 3

# ENC: mtdacr 3{{.*}}encoding: [0x7c,0x7c,0x4b,0xa6]
# ENC: mtdacr 4{{.*}}encoding: [0x7c,0x9c,0x4b,0xa6]
# ENC: mtdacr 3{{.*}}encoding: [0x7c,0x7c,0x4b,0xa6]
# DIS: mtdacr 3
# DIS: mtdacr 4
# DIS: mtdacr 3
# GENERIC: mtspr 316, 3
# GENERIC: mtspr 316, 4
# GENERIC: mtspr 316, 3
# ERR: error: instruction requires: PPE42
# ERR: error: instruction requires: PPE42
