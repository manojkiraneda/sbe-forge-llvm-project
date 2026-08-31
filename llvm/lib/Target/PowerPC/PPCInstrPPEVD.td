//===-- PPCInstrPPEVD.td - PPE42 VD Instructions -----------*- tablegen -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This file describes the PPE42 Virtual Doubleword (VD) instructions.
// These instructions provide 64-bit load/store operations using VDR register
// pairs (Virtual Doubleword Registers).
//
//===----------------------------------------------------------------------===//

//===----------------------------------------------------------------------===//
// PPE42 VD Instruction Definitions
//===----------------------------------------------------------------------===//

// LVD/STVD are PPE42-only instructions.  Predicates = [IsPPE42] is required
// so that P9Model/P10Model UnsupportedFeatures = [IsPPE42] correctly excludes
// them from the CompleteModel scheduling check.
let Predicates = [IsPPE42] in {

// LVD - Load Virtual Doubleword
// Opcode: 5
// Format: D-Form
// Loads 64 bits from memory into a VDR register pair
def LVD : DForm_1<5, (outs vdrc:$RST), (ins (memri $D, $RA):$src),
                  "lvd $RST, $src", IIC_LdStLoad,
                  [(set i64:$RST, (load iaddr:$src))]> {
  let DecoderNamespace = "PPE42";
}

// STVD - Store Virtual Doubleword
// Opcode: 6
// Format: D-Form
// Stores 64 bits from a VDR register pair to memory
def STVD : DForm_1<6, (outs), (ins vdrc:$RST, (memri $D, $RA):$dst),
                   "stvd $RST, $dst", IIC_LdStStore,
                   [(store i64:$RST, iaddr:$dst)]> {
  let DecoderNamespace = "PPE42";
}
} // Predicates = [IsPPE42]

// PPE42 64-bit rotate and insert using VDR registers
// This is the PPE42 variant of RLDIMI that uses VDR register pairs
// The destination register $RA must be the same as input register $RTi
// (read-modify-write operation, similar to PPC64 RLDIMI)
// Pattern matching is done in C++ code (tryAsSingleRLDIMI)
let hasSideEffects = 0, Predicates = [IsPPE42] in {
def RLDIMI_VDR : MDForm_1<30, 3, (outs vdrc:$RA),
                          (ins vdrc:$RTi, vdrc:$RS, u6imm:$SH, u6imm:$MBE),
                          "rldimi $RA, $RS, $SH, $MBE", IIC_IntRotateDI,
                          []>,
                          RegConstraint<"$RTi = $RA">,
                          NoEncode<"$RTi"> {
  let DecoderNamespace = "PPE42";
}
}

// Pseudo-instruction to load 64-bit immediate into VDR register pair
// This will be expanded post-RA into LI/LIS for both GPRs
// Format: LI8_VDR vdrc, imm64
let isReMaterializable = 1, Predicates = [IsPPE42] in {
def LI8_VDR : PPCPostRAExpPseudo<(outs vdrc:$rD), (ins s16imm64:$imm),
                                 "#LI8_VDR", []>;
}
