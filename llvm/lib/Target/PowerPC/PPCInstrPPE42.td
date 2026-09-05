//===-- PPCInstrPPE42.td - PPE42 instructions -------------*- tablegen -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

let Predicates = [IsPPE42], DecoderNamespace = "PPE42", isBranch = 1,
    isTerminator = 1, hasSideEffects = 1, Defs = [CR0], Uses = [XER] in {
  def CMPLWBC : FCBForm<1, 0, (outs),
                        (ins u1imm:$PX, u2imm:$BIX, gprc:$RA, gprc:$RB,
                             ppe42brtarget:$BDX),
                        "cmplwbc $PX, $BIX, $RA, $RB, $BDX">;
  def CMPLWBCL : FCBForm<1, 1, (outs),
                         (ins u1imm:$PX, u2imm:$BIX, gprc:$RA, gprc:$RB,
                              ppe42brtarget:$BDX),
                         "cmplwbcl $PX, $BIX, $RA, $RB, $BDX"> {
    let Defs = [CR0, LR];
  }
  def CMPWIBC : FCBForm<2, 0, (outs),
                        (ins u1imm:$PX, u2imm:$BIX, gprc:$RA, u5imm:$RB,
                             ppe42brtarget:$BDX),
                        "cmpwibc $PX, $BIX, $RA, $RB, $BDX">;
  def CMPWIBCL : FCBForm<2, 1, (outs),
                         (ins u1imm:$PX, u2imm:$BIX, gprc:$RA, u5imm:$RB,
                              ppe42brtarget:$BDX),
                         "cmpwibcl $PX, $BIX, $RA, $RB, $BDX"> {
    let Defs = [CR0, LR];
  }
}

multiclass PPE42FCBRegAlias<string name, bits<1> px, bits<2> bix> {
  def : InstAlias<name#" $RA, $RB, $BDX",
                  (CMPLWBC px, bix, gprc:$RA, gprc:$RB,
                           ppe42brtarget:$BDX)>;
  def : InstAlias<name#"l $RA, $RB, $BDX",
                  (CMPLWBCL px, bix, gprc:$RA, gprc:$RB,
                            ppe42brtarget:$BDX)>;
}

defm : PPE42FCBRegAlias<"cmplwblt", 1, 0>;
defm : PPE42FCBRegAlias<"cmplwble", 0, 1>;
defm : PPE42FCBRegAlias<"cmplwbgt", 1, 1>;
defm : PPE42FCBRegAlias<"cmplwbge", 0, 0>;
defm : PPE42FCBRegAlias<"cmplwbeq", 1, 2>;
defm : PPE42FCBRegAlias<"cmplwbne", 0, 2>;

multiclass PPE42FCBImmAlias<string name, bits<1> px, bits<2> bix> {
  def : InstAlias<name#" $RA, $UIX, $BDX",
                  (CMPWIBC px, bix, gprc:$RA, u5imm:$UIX,
                           ppe42brtarget:$BDX)>;
  def : InstAlias<name#"l $RA, $UIX, $BDX",
                  (CMPWIBCL px, bix, gprc:$RA, u5imm:$UIX,
                            ppe42brtarget:$BDX)>;
}

defm : PPE42FCBImmAlias<"cmpwiblt", 1, 0>;
defm : PPE42FCBImmAlias<"cmpwible", 0, 1>;
defm : PPE42FCBImmAlias<"cmpwibgt", 1, 1>;
defm : PPE42FCBImmAlias<"cmpwibge", 0, 0>;
defm : PPE42FCBImmAlias<"cmpwibeq", 1, 2>;
defm : PPE42FCBImmAlias<"cmpwibne", 0, 2>;

multiclass PPE42FCBZeroAlias<string name, bits<1> px, bits<2> bix> {
  def : InstAlias<name#" $RA, $BDX",
                  (CMPWIBC px, bix, gprc:$RA, 0, ppe42brtarget:$BDX)>;
  def : InstAlias<name#"l $RA, $BDX",
                  (CMPWIBCL px, bix, gprc:$RA, 0, ppe42brtarget:$BDX)>;
}

defm : PPE42FCBZeroAlias<"bwltz", 1, 0>;
defm : PPE42FCBZeroAlias<"bwlez", 0, 1>;
defm : PPE42FCBZeroAlias<"bwgtz", 1, 1>;
defm : PPE42FCBZeroAlias<"bwgez", 0, 0>;
defm : PPE42FCBZeroAlias<"bwz", 1, 2>;
defm : PPE42FCBZeroAlias<"bwnz", 0, 2>;
