//===-- PPCBranchSelector.cpp - Emit long conditional branches ------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This file contains a pass that scans a machine function to determine which
// conditional branches need more than 16 bits of displacement to reach their
// target basic block.  It does this in two passes; a calculation of basic block
// positions pass, and a branch pseudo op to machine branch opcode pass.  This
// pass should be run last, just before the assembly printer.
//
//===----------------------------------------------------------------------===//

#include "MCTargetDesc/PPCPredicates.h"
#include "PPC.h"
#include "PPCInstrInfo.h"
#include "PPCSubtarget.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/Statistic.h"
#include "llvm/ADT/StringSwitch.h"
#include "llvm/CodeGen/LiveRegUnits.h"
#include "llvm/CodeGen/MachineFunctionPass.h"
#include "llvm/CodeGen/MachineRegisterInfo.h"
#include "llvm/CodeGen/TargetSubtargetInfo.h"
#include "llvm/Support/MathExtras.h"
#include "llvm/Target/TargetMachine.h"
#include <algorithm>
#include <iterator>
using namespace llvm;

#define DEBUG_TYPE "ppc-branch-select"

STATISTIC(NumExpanded, "Number of branches expanded to long format");
STATISTIC(NumPrefixed, "Number of prefixed instructions");
STATISTIC(NumPrefixedAligned,
          "Number of prefixed instructions that have been aligned");

namespace {
  struct PPCBSel : public MachineFunctionPass {
    static char ID;
    PPCBSel() : MachineFunctionPass(ID) {}

    // The sizes of the basic blocks in the function (the first
    // element of the pair); the second element of the pair is the amount of the
    // size that is due to potential padding.
    std::vector<std::pair<unsigned, unsigned>> BlockSizes;

    // The first block number which has imprecise instruction address.
    int FirstImpreciseBlock = -1;

    unsigned GetAlignmentAdjustment(MachineBasicBlock &MBB, unsigned Offset);
    unsigned ComputeBlockSizes(MachineFunction &Fn);
    void modifyAdjustment(MachineFunction &Fn);
    int computeBranchSize(MachineFunction &Fn,
                          const MachineBasicBlock *Src,
                          const MachineBasicBlock *Dest,
                          unsigned BrOffset);

    bool runOnMachineFunction(MachineFunction &Fn) override;

    MachineFunctionProperties getRequiredProperties() const override {
      return MachineFunctionProperties().setNoVRegs();
    }

    StringRef getPassName() const override { return "PowerPC Branch Selector"; }
  };
  char PPCBSel::ID = 0;
}

INITIALIZE_PASS(PPCBSel, "ppc-branch-select", "PowerPC Branch Selector",
                false, false)

/// createPPCBranchSelectionPass - returns an instance of the Branch Selection
/// Pass
///
FunctionPass *llvm::createPPCBranchSelectionPass() {
  return new PPCBSel();
}

/// In order to make MBB aligned, we need to add an adjustment value to the
/// original Offset.
unsigned PPCBSel::GetAlignmentAdjustment(MachineBasicBlock &MBB,
                                         unsigned Offset) {
  const Align Alignment = MBB.getAlignment();
  if (Alignment == Align(1))
    return 0;

  const Align ParentAlign = MBB.getParent()->getAlignment();

  if (Alignment <= ParentAlign)
    return offsetToAlignment(Offset, Alignment);

  // The alignment of this MBB is larger than the function's alignment, so we
  // can't tell whether or not it will insert nops. Assume that it will.
  if (FirstImpreciseBlock < 0)
    FirstImpreciseBlock = MBB.getNumber();
  return Alignment.value() + offsetToAlignment(Offset, Alignment);
}

/// We need to be careful about the offset of the first block in the function
/// because it might not have the function's alignment. This happens because,
/// under the ELFv2 ABI, for functions which require a TOC pointer, we add a
/// two-instruction sequence to the start of the function.
/// Note: This needs to be synchronized with the check in
/// PPCLinuxAsmPrinter::EmitFunctionBodyStart.
static inline unsigned GetInitialOffset(MachineFunction &Fn) {
  unsigned InitialOffset = 0;
  if (Fn.getSubtarget<PPCSubtarget>().isELFv2ABI() &&
      !Fn.getRegInfo().use_empty(PPC::X2))
    InitialOffset = 8;
  return InitialOffset;
}

/// Measure each MBB and compute a size for the entire function.
unsigned PPCBSel::ComputeBlockSizes(MachineFunction &Fn) {
  const PPCInstrInfo *TII =
      static_cast<const PPCInstrInfo *>(Fn.getSubtarget().getInstrInfo());
  unsigned FuncSize = GetInitialOffset(Fn);

  for (MachineBasicBlock &MBB : Fn) {
    // The end of the previous block may have extra nops if this block has an
    // alignment requirement.
    if (MBB.getNumber() > 0) {
      unsigned AlignExtra = GetAlignmentAdjustment(MBB, FuncSize);

      auto &BS = BlockSizes[MBB.getNumber()-1];
      BS.first += AlignExtra;
      BS.second = AlignExtra;

      FuncSize += AlignExtra;
    }

    unsigned BlockSize = 0;
    unsigned UnalignedBytesRemaining = 0;
    for (MachineInstr &MI : MBB) {
      unsigned MINumBytes = TII->getInstSizeInBytes(MI);
      if (MI.isInlineAsm() && (FirstImpreciseBlock < 0))
        FirstImpreciseBlock = MBB.getNumber();
      if (TII->isPrefixed(MI.getOpcode())) {
        NumPrefixed++;

        // All 8 byte instructions may require alignment. Each 8 byte
        // instruction may be aligned by another 4 bytes.
        // This means that an 8 byte instruction may require 12 bytes
        // (8 for the instruction itself and 4 for the alignment nop).
        // This will happen if an 8 byte instruction can be aligned to 64 bytes
        // by only adding a 4 byte nop.
        // We don't know the alignment at this point in the code so we have to
        // adopt a more pessimistic approach. If an instruction may need
        // alignment we assume that it does need alignment and add 4 bytes to
        // it. As a result we may end up with more long branches than before
        // but we are in the safe position where if we need a long branch we
        // have one.
        // The if statement checks to make sure that two 8 byte instructions
        // are at least 64 bytes away from each other. It is not possible for
        // two instructions that both need alignment to be within 64 bytes of
        // each other.
        if (!UnalignedBytesRemaining) {
          BlockSize += 4;
          UnalignedBytesRemaining = 60;
          NumPrefixedAligned++;
        }
      }
      UnalignedBytesRemaining -= std::min(UnalignedBytesRemaining, MINumBytes);
      BlockSize += MINumBytes;
    }

    BlockSizes[MBB.getNumber()].first = BlockSize;
    FuncSize += BlockSize;
  }

  return FuncSize;
}

/// Modify the basic block align adjustment.
void PPCBSel::modifyAdjustment(MachineFunction &Fn) {
  unsigned Offset = GetInitialOffset(Fn);
  for (MachineBasicBlock &MBB : Fn) {
    if (MBB.getNumber() > 0) {
      auto &BS = BlockSizes[MBB.getNumber()-1];
      BS.first -= BS.second;
      Offset -= BS.second;

      unsigned AlignExtra = GetAlignmentAdjustment(MBB, Offset);

      BS.first += AlignExtra;
      BS.second = AlignExtra;

      Offset += AlignExtra;
    }

    Offset += BlockSizes[MBB.getNumber()].first;
  }
}

/// Determine the offset from the branch in Src block to the Dest block.
/// BrOffset is the offset of the branch instruction inside Src block.
int PPCBSel::computeBranchSize(MachineFunction &Fn,
                               const MachineBasicBlock *Src,
                               const MachineBasicBlock *Dest,
                               unsigned BrOffset) {
  int BranchSize;
  Align MaxAlign = Align(4);
  bool NeedExtraAdjustment = false;
  if (Dest->getNumber() <= Src->getNumber()) {
    // If this is a backwards branch, the delta is the offset from the
    // start of this block to this branch, plus the sizes of all blocks
    // from this block to the dest.
    BranchSize = BrOffset;
    MaxAlign = std::max(MaxAlign, Src->getAlignment());

    int DestBlock = Dest->getNumber();
    BranchSize += BlockSizes[DestBlock].first;
    for (unsigned i = DestBlock+1, e = Src->getNumber(); i < e; ++i) {
      BranchSize += BlockSizes[i].first;
      MaxAlign = std::max(MaxAlign, Fn.getBlockNumbered(i)->getAlignment());
    }

    NeedExtraAdjustment = (FirstImpreciseBlock >= 0) &&
                          (DestBlock >= FirstImpreciseBlock);
  } else {
    // Otherwise, add the size of the blocks between this block and the
    // dest to the number of bytes left in this block.
    unsigned StartBlock = Src->getNumber();
    BranchSize = BlockSizes[StartBlock].first - BrOffset;

    MaxAlign = std::max(MaxAlign, Dest->getAlignment());
    for (unsigned i = StartBlock+1, e = Dest->getNumber(); i != e; ++i) {
      BranchSize += BlockSizes[i].first;
      MaxAlign = std::max(MaxAlign, Fn.getBlockNumbered(i)->getAlignment());
    }

    NeedExtraAdjustment = (FirstImpreciseBlock >= 0) &&
                          (Src->getNumber() >= FirstImpreciseBlock);
  }

  // We tend to over estimate code size due to large alignment and
  // inline assembly. Usually it causes larger computed branch offset.
  // But sometimes it may also causes smaller computed branch offset
  // than actual branch offset. If the offset is close to the limit of
  // encoding, it may cause problem at run time.
  // Following is a simplified example.
  //
  //              actual        estimated
  //              address        address
  //    ...
  //   bne Far      100            10c
  //   .p2align 4
  //   Near:        110            110
  //    ...
  //   Far:        8108           8108
  //
  //   Actual offset:    0x8108 - 0x100 = 0x8008
  //   Computed offset:  0x8108 - 0x10c = 0x7ffc
  //
  // This example also shows when we can get the largest gap between
  // estimated offset and actual offset. If there is an aligned block
  // ABB between branch and target, assume its alignment is <align>
  // bits. Now consider the accumulated function size FSIZE till the end
  // of previous block PBB. If the estimated FSIZE is multiple of
  // 2^<align>, we don't need any padding for the estimated address of
  // ABB. If actual FSIZE at the end of PBB is 4 bytes more than
  // multiple of 2^<align>, then we need (2^<align> - 4) bytes of
  // padding. It also means the actual branch offset is (2^<align> - 4)
  // larger than computed offset. Other actual FSIZE needs less padding
  // bytes, so causes smaller gap between actual and computed offset.
  //
  // On the other hand, if the inline asm or large alignment occurs
  // between the branch block and destination block, the estimated address
  // can be <delta> larger than actual address. If padding bytes are
  // needed for a later aligned block, the actual number of padding bytes
  // is at most <delta> more than estimated padding bytes. So the actual
  // aligned block address is less than or equal to the estimated aligned
  // block address. So the actual branch offset is less than or equal to
  // computed branch offset.
  //
  // The computed offset is at most ((1 << alignment) - 4) bytes smaller
  // than actual offset. So we add this number to the offset for safety.
  if (NeedExtraAdjustment)
    BranchSize += MaxAlign.value() - 4;

  return BranchSize;
}

bool PPCBSel::runOnMachineFunction(MachineFunction &Fn) {
  const PPCInstrInfo *TII =
      static_cast<const PPCInstrInfo *>(Fn.getSubtarget().getInstrInfo());
  // Give the blocks of the function a dense, in-order, numbering.
  Fn.RenumberBlocks();
  BlockSizes.resize(Fn.getNumBlockIDs());
  FirstImpreciseBlock = -1;

  // Measure each MBB and compute a size for the entire function.
  unsigned FuncSize = ComputeBlockSizes(Fn);

  // If the entire function is smaller than the displacement of a branch field,
  // we know we don't need to shrink any branches in this function.  This is a
  // common case.
  if (FuncSize < (1 << 15) && !Fn.getSubtarget<PPCSubtarget>().isPPE42()) {
    BlockSizes.clear();
    return false;
  }

  // For each conditional branch, if the offset to its destination is larger
  // than the offset field allows, transform it into a long branch sequence
  // like this:
  //   short branch:
  //     bCC MBB
  //   long branch:
  //     b!CC $PC+8
  //     b MBB
  //
  bool MadeChange = true;
  bool EverMadeChange = false;
  while (MadeChange) {
    // Iteratively expand branches until we reach a fixed point.
    MadeChange = false;

    for (MachineFunction::iterator MFI = Fn.begin(), E = Fn.end(); MFI != E;
         ++MFI) {
      MachineBasicBlock &MBB = *MFI;
      unsigned MBBStartOffset = 0;
      for (MachineBasicBlock::iterator I = MBB.begin(), E = MBB.end();
           I != E; ++I) {
        MachineBasicBlock *Dest = nullptr;
        if (I->getOpcode() == PPC::BCC && !I->getOperand(2).isImm())
          Dest = I->getOperand(2).getMBB();
        else if ((I->getOpcode() == PPC::BC || I->getOpcode() == PPC::BCn) &&
                 !I->getOperand(1).isImm())
          Dest = I->getOperand(1).getMBB();
        else if ((I->getOpcode() == PPC::BDNZ8 || I->getOpcode() == PPC::BDNZ ||
                  I->getOpcode() == PPC::BDZ8  || I->getOpcode() == PPC::BDZ) &&
                 !I->getOperand(0).isImm())
          Dest = I->getOperand(0).getMBB();

        if (!Dest) {
          MBBStartOffset += TII->getInstSizeInBytes(*I);
          continue;
        }

        // Determine the offset from the current branch to the destination
        // block.
        int BranchSize = computeBranchSize(Fn, &MBB, Dest, MBBStartOffset);

        // If this branch is in range, ignore it.
        if (isInt<16>(BranchSize)) {
          MBBStartOffset += 4;
          continue;
        }

        // Otherwise, we have to expand it to a long branch.
        MachineInstr &OldBranch = *I;
        DebugLoc dl = OldBranch.getDebugLoc();

        if (I->getOpcode() == PPC::BCC) {
          // The BCC operands are:
          // 0. PPC branch predicate
          // 1. CR register
          // 2. Target MBB
          PPC::Predicate Pred = (PPC::Predicate)I->getOperand(0).getImm();
          Register CRReg = I->getOperand(1).getReg();

          // Jump over the uncond branch inst (i.e. $PC+8) on opposite condition.
          BuildMI(MBB, I, dl, TII->get(PPC::BCC))
            .addImm(PPC::InvertPredicate(Pred)).addReg(CRReg).addImm(2);
        } else if (I->getOpcode() == PPC::BC) {
          Register CRBit = I->getOperand(0).getReg();
          BuildMI(MBB, I, dl, TII->get(PPC::BCn)).addReg(CRBit).addImm(2);
        } else if (I->getOpcode() == PPC::BCn) {
          Register CRBit = I->getOperand(0).getReg();
          BuildMI(MBB, I, dl, TII->get(PPC::BC)).addReg(CRBit).addImm(2);
        } else if (I->getOpcode() == PPC::BDNZ) {
          BuildMI(MBB, I, dl, TII->get(PPC::BDZ)).addImm(2);
        } else if (I->getOpcode() == PPC::BDNZ8) {
          BuildMI(MBB, I, dl, TII->get(PPC::BDZ8)).addImm(2);
        } else if (I->getOpcode() == PPC::BDZ) {
          BuildMI(MBB, I, dl, TII->get(PPC::BDNZ)).addImm(2);
        } else if (I->getOpcode() == PPC::BDZ8) {
          BuildMI(MBB, I, dl, TII->get(PPC::BDNZ8)).addImm(2);
        } else {
           llvm_unreachable("Unhandled branch type!");
        }

        // Uncond branch to the real destination.
        I = BuildMI(MBB, I, dl, TII->get(PPC::B)).addMBB(Dest);

        // Remove the old branch from the function.
        OldBranch.eraseFromParent();

        // Remember that this instruction is 8-bytes, increase the size of the
        // block by 4, remember to iterate.
        BlockSizes[MBB.getNumber()].first += 4;
        MBBStartOffset += 8;
        ++NumExpanded;
        MadeChange = true;
      }
    }

    if (MadeChange) {
      // If we're going to iterate again, make sure we've updated our
      // padding-based contributions to the block sizes.
      modifyAdjustment(Fn);
    }

    EverMadeChange |= MadeChange;
  }

  // The PPE42 immediate bit branch has a signed 12-bit byte displacement.
  // Do this after long-branch expansion, when block positions are final. Only
  // fold a single-bit mask whose result and comparison are killed by the
  // branch. A small margin covers the change in branch position and padding.
  // Unknown inline asm may contain directives or multiple instructions. Exact
  // templates for ordinary PPE42 instructions have a fixed four-byte size,
  // including the kernel's interrupt/context accesses and MARK_TAG trap form.
  // Check only the branch span: asm outside it cannot affect displacement.
  auto HasImpreciseAsm = [](MachineBasicBlock::const_iterator Begin,
                            MachineBasicBlock::const_iterator End) {
    return std::any_of(Begin, End, [](const MachineInstr &MI) {
      if (!MI.isInlineAsm())
        return false;
      StringRef Asm = MI.getOperand(0).getSymbolName();
      Asm = Asm.trim();
      // A single fixed-width access is precise even when its operands differ
      // from the common templates below. Reject separators and directives.
      auto Mnemonic = Asm.take_until([](char C) { return C == ' ' || C == '\t'; });
      bool FixedAccess = StringSwitch<bool>(Mnemonic)
                             .Cases("lbz", "lhz", "lwz", "stb", "sth", "stw", true)
                             .Cases("lvd", "stvd", "mfspr", "mtspr", true)
                             .Cases("mfmsr", "mtmsr", "wrteei", true)
                             .Default(false);
      if (FixedAccess && Asm.find_first_of("\n\r;#.") == StringRef::npos)
        return false;
      return !StringSwitch<bool>(Asm)
                  .Cases("nop", "trap", "sync", "isync", "eieio", true)
                  .Cases("tw 31, $0, $1", "tw 0, $0, $1", "tw 0, 0, 0", true)
                  .Cases("mfmsr $0", "mtmsr $0", "wrteei $0", true)
                  .Cases("mfspr $0, $1", "mtspr $0, $1", true)
                  .Cases("lvd $0, 0($1)", "stvd $0, 0($1)", "stvd $0, 0($2)",
                         true)
                  .Default(false);
    });
  };
  auto HasImpreciseBranchSpan = [&](const MachineInstr &Br,
                                    const MachineBasicBlock &Dest) {
    const MachineBasicBlock &Src = *Br.getParent();
    unsigned SrcNum = Src.getNumber();
    unsigned DestNum = Dest.getNumber();
    if (DestNum <= SrcNum) {
      if (HasImpreciseAsm(Dest.begin(),
                          DestNum == SrcNum ? Br.getIterator() : Dest.end()))
        return true;
      for (unsigned N = DestNum + 1; N < SrcNum; ++N) {
        const MachineBasicBlock *MBB = Fn.getBlockNumbered(N);
        if (MBB->getAlignment() > Align(4) ||
            HasImpreciseAsm(MBB->begin(), MBB->end()))
          return true;
      }
      return DestNum != SrcNum &&
             (Src.getAlignment() > Align(4) ||
              HasImpreciseAsm(Src.begin(), Br.getIterator()));
    }
    if (HasImpreciseAsm(std::next(Br.getIterator()), Src.end()))
      return true;
    for (unsigned N = SrcNum + 1; N < DestNum; ++N) {
      const MachineBasicBlock *MBB = Fn.getBlockNumbered(N);
      if (MBB->getAlignment() > Align(4) ||
          HasImpreciseAsm(MBB->begin(), MBB->end()))
        return true;
    }
    return Dest.getAlignment() > Align(4);
  };
  if (Fn.getSubtarget<PPCSubtarget>().isPPE42()) {
    const TargetRegisterInfo *TRI = Fn.getSubtarget().getRegisterInfo();
    // Kill flags can be absent after late physical-register transforms. Check
    // the actual register units instead, including other bits of a CR field.
    auto IsDeadAfter = [&](const MachineInstr &MI, MCRegister Reg) {
      if (!Fn.getRegInfo().tracksLiveness())
        return false;
      LiveRegUnits Live(*TRI);
      Live.addLiveOuts(*MI.getParent());
      for (auto It = MI.getParent()->rbegin(); &*It != &MI; ++It)
        if (!It->isDebugInstr())
          Live.stepBackward(*It);
      return Live.available(Reg);
    };
    // Do this after allocation: pre-RA record-form folding can create an
    // unallocatable physical CR0 live range on PPE42. Here an adjacent ANDI.
    // already supplies exactly the comparison's CR0, including XER.SO. Its
    // low-halfword result is nonnegative, so unsigned zero comparisons agree
    // as well. ANDIS. is only equivalent to a signed comparison.
    for (MachineBasicBlock &MBB : Fn) {
      for (auto I = MBB.begin(); I != MBB.end();) {
        MachineInstr &Cmp = *I++;
        if ((Cmp.getOpcode() != PPC::CMPWI && Cmp.getOpcode() != PPC::CMPLWI) ||
            Cmp.getOperand(0).getReg() != PPC::CR0 ||
            Cmp.getOperand(2).getImm() != 0 || Cmp.peekDebugInstrNum() ||
            Cmp.isBundledWithPred() || Cmp.isBundledWithSucc())
          continue;
        auto P = Cmp.getIterator();
        while (P != MBB.begin() && std::prev(P)->isDebugInstr())
          --P;
        if (P == MBB.begin())
          continue;
        MachineInstr &And = *--P;
        if ((And.getOpcode() != PPC::ANDI_rec &&
             !(And.getOpcode() == PPC::ANDIS_rec &&
               Cmp.getOpcode() == PPC::CMPWI)) ||
            And.getOperand(0).getReg() != Cmp.getOperand(1).getReg() ||
            And.isBundledWithPred() || And.isBundledWithSucc())
          continue;
        for (MachineOperand &MO : And.operands())
          if (MO.isReg() && MO.isDef() && MO.getReg() == PPC::CR0)
            MO.setIsDead(false);
        Cmp.eraseFromParent();
        BlockSizes[MBB.getNumber()].first -= 4;
        EverMadeChange = true;
      }
    }
    // Scheduling can put independent instructions between a compare and its
    // branch. Move the comparison to the branch only when its inputs are not
    // changed and CR0 is neither observed nor changed in between.
    auto PredicateCondition = [](const MachineInstr &Br) {
      return PPC::getPredicateCondition(
          static_cast<PPC::Predicate>(Br.getOperand(0).getImm()));
    };
    auto FindMovableCompare = [&](MachineInstr &Br) -> MachineInstr * {
      auto It = Br.getIterator();
      unsigned Seen = 0;
      while (It != Br.getParent()->begin() && Seen < 12) {
        --It;
        MachineInstr &MI = *It;
        if (MI.isDebugInstr())
          continue;
        if (MI.getOpcode() == PPC::CMPWI || MI.getOpcode() == PPC::CMPLWI ||
            MI.getOpcode() == PPC::CMPW || MI.getOpcode() == PPC::CMPLW) {
          if (MI.getOperand(0).getReg() != PPC::CR0)
            return nullptr;
          for (auto Between = std::next(It); Between != Br.getIterator();
               ++Between) {
            if (Between->isDebugInstr())
              continue;
            if (Between->readsRegister(PPC::CR0, TRI) ||
                Between->modifiesRegister(PPC::CR0, TRI))
              return nullptr;
            for (unsigned Op = 1; Op < MI.getNumOperands(); ++Op)
              if (MI.getOperand(Op).isReg() &&
                  (Between->modifiesRegister(MI.getOperand(Op).getReg(), TRI) ||
                   Between->killsRegister(MI.getOperand(Op).getReg(), TRI)))
                return nullptr;
          }
          return &MI;
        }
        if (MI.isCall() || MI.isTerminator() || MI.isInlineAsm() ||
            MI.hasUnmodeledSideEffects() || MI.readsRegister(PPC::CR0, TRI) ||
            MI.modifiesRegister(PPC::CR0, TRI))
          return nullptr;
        ++Seen;
      }
      return nullptr;
    };
    // Recover known-zero bits from reaching physical-register definitions.
    // At a join every predecessor must prove the bits; loops and long chains
    // conservatively exhaust the budget. Never derive a range from a compare.
    auto IsKnownNonNegative = [&](const MachineInstr &Cmp) {
      unsigned Budget = 96;
      auto KnownZero = [&](auto &&Self, const MachineBasicBlock &BB,
                           MachineBasicBlock::const_iterator At,
                           Register R) -> uint32_t {
        if (!Budget)
          return 0;
        --Budget;
        while (At != BB.begin()) {
          if (!Budget)
            return 0;
          --Budget;
          const MachineInstr &Def = *--At;
          if (Def.isDebugInstr())
            continue;
          if (Def.isCall() || Def.isInlineAsm() ||
              Def.hasUnmodeledSideEffects())
            return 0;
          if (!Def.modifiesRegister(R, TRI))
            continue;
          if (!Def.getNumOperands() || !Def.getOperand(0).isReg() ||
              Def.getOperand(0).getReg() != R ||
              llvm::any_of(Def.operands(), [](const MachineOperand &MO) {
                return MO.isReg() && MO.isUse() && MO.isUndef();
              }))
            return 0;
          auto Input = [&](unsigned Op) {
            return Self(Self, BB, At, Def.getOperand(Op).getReg());
          };
          switch (Def.getOpcode()) {
          case PPC::LBZ:
          case PPC::LBZU:
          case PPC::LBZX:
            return 0xffffff00u;
          case PPC::LHZ:
          case PPC::LHZU:
          case PPC::LHZX:
            return 0xffff0000u;
          case PPC::LI:
            return ~uint32_t(SignExtend64<16>(Def.getOperand(1).getImm()));
          case PPC::LIS:
            return ~(uint32_t(Def.getOperand(1).getImm()) << 16);
          case PPC::COPY:
            return Input(1);
          case PPC::OR: {
            if (Def.getOperand(1).getReg() == Def.getOperand(2).getReg())
              return Input(1);
            uint32_t Left = Input(1);
            return Left & Input(2);
          }
          case PPC::AND: {
            uint32_t Left = Input(1);
            return Left | Input(2);
          }
          case PPC::ORI:
            return Input(1) & ~uint32_t(Def.getOperand(2).getImm());
          case PPC::ORIS:
            return Input(1) & ~(uint32_t(Def.getOperand(2).getImm()) << 16);
          case PPC::ANDI_rec:
            return ~uint32_t(Def.getOperand(2).getImm());
          case PPC::ANDIS_rec:
            return ~(uint32_t(Def.getOperand(2).getImm()) << 16);
          case PPC::RLWINM:
          case PPC::RLWINM_rec: {
            unsigned MB = Def.getOperand(3).getImm();
            unsigned ME = Def.getOperand(4).getImm();
            uint32_t Mask =
                MB <= ME ? (UINT32_MAX >> MB) & (UINT32_MAX << (31 - ME))
                         : (UINT32_MAX >> MB) | (UINT32_MAX << (31 - ME));
            // A mask that clears the sign bit needs no input analysis.
            if (!(Mask & 0x80000000u))
              return ~Mask;
            return ~Mask |
                   llvm::rotl(Input(1), int(Def.getOperand(2).getImm()));
          }
          default:
            return 0;
          }
        }
        if (BB.pred_empty() || !Budget)
          return 0;
        uint32_t Bits = UINT32_MAX;
        for (const MachineBasicBlock *Pred : BB.predecessors()) {
          if (!Budget)
            return 0;
          Bits &= Self(Self, *Pred, Pred->end(), R);
          if (!Bits)
            break;
        }
        return Bits;
      };
      return bool(KnownZero(KnownZero, *Cmp.getParent(), Cmp.getIterator(),
                            Cmp.getOperand(1).getReg()) &
                  0x80000000u);
    };
    for (MachineBasicBlock &MBB : Fn) {
      unsigned Offset = 0;
      for (auto I = MBB.begin(); I != MBB.end();) {
        MachineInstr &Br = *I++;
        unsigned BrOffset = Offset;
        Offset += TII->getInstSizeInBytes(Br);
        bool IsBitBranch =
            Br.getOpcode() == PPC::BC || Br.getOpcode() == PPC::BCn;
        if (Br.getOpcode() != PPC::BCC && !IsBitBranch)
          continue;
        unsigned DestOp = IsBitBranch ? 1 : 2;
        if (!Br.getOperand(DestOp).isMBB() ||
            (IsBitBranch ? Br.getOperand(0).getReg() != PPC::CR0EQ
                         : Br.getOperand(1).getReg() != PPC::CR0 ||
                               (PredicateCondition(Br) != PPC::PRED_EQ &&
                                PredicateCondition(Br) != PPC::PRED_NE)))
          continue;

        MachineInstr *CmpPtr = FindMovableCompare(Br);
        if (!CmpPtr || !IsDeadAfter(Br, PPC::CR0))
          continue;
        MachineInstr &Cmp = *CmpPtr;
        if (Cmp.getOpcode() != PPC::CMPLWI && Cmp.getOpcode() != PPC::CMPWI)
          continue;

        Register MaskReg = Cmp.getOperand(1).getReg();
        if (!IsDeadAfter(Cmp, MaskReg))
          continue;
        // Look through debug locations and a few independent instructions.
        // Never cross another use/definition of the masked value or a barrier.
        MachineInstr *MaskPtr = nullptr;
        auto MaskIt = Cmp.getIterator();
        unsigned Seen = 0;
        while (MaskIt != MBB.begin() && Seen < 4) {
          MachineInstr &MI = *--MaskIt;
          if (MI.isDebugInstr())
            continue;
          if (MI.getOpcode() == PPC::RLWINM &&
              MI.getOperand(0).getReg() == MaskReg) {
            MaskPtr = &MI;
            break;
          }
          if (MI.isCall() || MI.isTerminator() || MI.isInlineAsm() ||
              MI.hasUnmodeledSideEffects() || MI.readsRegister(MaskReg, TRI) ||
              MI.modifiesRegister(MaskReg, TRI))
            break;
          ++Seen;
        }
        if (!MaskPtr)
          continue;
        MachineInstr &Mask = *MaskPtr;
        if (Mask.getOperand(3).getImm() != Mask.getOperand(4).getImm())
          continue;
        uint32_t Expected = Cmp.getOperand(2).getImm();
        if (Cmp.getOpcode() == PPC::CMPWI)
          Expected = SignExtend64<16>(Expected);
        uint32_t BitValue = uint32_t(1) << (31 - Mask.getOperand(3).getImm());
        if (Expected && Expected != BitValue)
          continue;
        Register SrcReg = Mask.getOperand(1).getReg();
        // The bit test executes at the branch. Its original source must still
        // be available there, and no instruction may observe the removed mask.
        bool Safe = true;
        for (auto It = std::next(Mask.getIterator()); It != Br.getIterator();
             ++It) {
          if (&*It == &Cmp || It->isDebugInstr())
            continue;
          if (It->readsRegister(MaskReg, TRI) ||
              It->readsRegister(SrcReg, TRI) ||
              It->modifiesRegister(SrcReg, TRI)) {
            Safe = false;
            break;
          }
        }
        if (!Safe)
          continue;

        int Distance = computeBranchSize(
            Fn, &MBB, Br.getOperand(DestOp).getMBB(), BrOffset);
        if (HasImpreciseBranchSpan(Br, *Br.getOperand(DestOp).getMBB()) ||
            Distance < -2036 || Distance > 2036)
          continue;

        unsigned Bit =
            (Mask.getOperand(3).getImm() + Mask.getOperand(2).getImm()) % 32;
        unsigned PX = IsBitBranch ? Br.getOpcode() == PPC::BC
                                  : PredicateCondition(Br) == PPC::PRED_EQ;
        if (Expected)
          PX ^= 1;
        BuildMI(MBB, Br.getIterator(), Br.getDebugLoc(), TII->get(PPC::BNBWI))
            .addImm(PX)
            .addReg(SrcReg, IsDeadAfter(Br, SrcReg) ? RegState::Kill : 0)
            .addImm(Bit)
            .addMBB(Br.getOperand(DestOp).getMBB());
        Mask.eraseFromParent();
        Cmp.eraseFromParent();
        Br.eraseFromParent();
        BlockSizes[MBB.getNumber()].first -= 8;
        Offset -= 8;
        EverMadeChange = true;
      }
    }

    // Fuse a register comparison with its immediately following CR0 branch.
    // The register forms preserve all signed/unsigned compare predicates.
    for (MachineBasicBlock &MBB : Fn) {
      unsigned Offset = 0;
      for (auto I = MBB.begin(); I != MBB.end();) {
        MachineInstr &Br = *I++;
        unsigned BrOffset = Offset;
        Offset += TII->getInstSizeInBytes(Br);
        bool IsBitBranch =
            Br.getOpcode() == PPC::BC || Br.getOpcode() == PPC::BCn;
        if (Br.getOpcode() != PPC::BCC && !IsBitBranch)
          continue;
        unsigned DestOp = IsBitBranch ? 1 : 2;
        if (!Br.getOperand(DestOp).isMBB() ||
            (IsBitBranch ? (Br.getOperand(0).getReg() != PPC::CR0LT &&
                            Br.getOperand(0).getReg() != PPC::CR0GT &&
                            Br.getOperand(0).getReg() != PPC::CR0EQ)
                         : Br.getOperand(1).getReg() != PPC::CR0) ||
            Br.getIterator() == MBB.begin())
          continue;

        MachineInstr *CmpPtr = FindMovableCompare(Br);
        if (!CmpPtr)
          continue;
        MachineInstr &Cmp = *CmpPtr;
        bool IsUnsigned = Cmp.getOpcode() == PPC::CMPLW;
        if ((!IsUnsigned && Cmp.getOpcode() != PPC::CMPW) ||
            Cmp.getOperand(0).getReg() != PPC::CR0)
          continue;

        unsigned PX = 0, BIX = 2;
        if (IsBitBranch) {
          PX = Br.getOpcode() == PPC::BC ? 1 : 0;
          Register Cond = Br.getOperand(0).getReg();
          BIX = Cond == PPC::CR0LT ? 0 : (Cond == PPC::CR0GT ? 1 : 2);
        } else {
          switch (PredicateCondition(Br)) {
          case PPC::PRED_LT:
            PX = 1;
            BIX = 0;
            break;
          case PPC::PRED_GE:
            PX = 0;
            BIX = 0;
            break;
          case PPC::PRED_GT:
            PX = 1;
            BIX = 1;
            break;
          case PPC::PRED_LE:
            PX = 0;
            BIX = 1;
            break;
          case PPC::PRED_EQ:
            PX = 1;
            BIX = 2;
            break;
          case PPC::PRED_NE:
            PX = 0;
            BIX = 2;
            break;
          default:
            continue;
          }
        }

        int Distance = computeBranchSize(
            Fn, &MBB, Br.getOperand(DestOp).getMBB(), BrOffset);
        if (HasImpreciseBranchSpan(Br, *Br.getOperand(DestOp).getMBB()) ||
            Distance < -2036 || Distance > 2036)
          continue;

        BuildMI(MBB, Br.getIterator(), Br.getDebugLoc(),
                TII->get(IsUnsigned ? PPC::CMPLWBC : PPC::CMPWBC))
            .addImm(PX)
            .addImm(BIX)
            .addReg(Cmp.getOperand(1).getReg(),
                    Cmp.getOperand(1).isKill() ? RegState::Kill : 0)
            .addReg(Cmp.getOperand(2).getReg(),
                    Cmp.getOperand(2).isKill() ? RegState::Kill : 0)
            .addMBB(Br.getOperand(DestOp).getMBB());
        Cmp.eraseFromParent();
        Br.eraseFromParent();
        BlockSizes[MBB.getNumber()].first -= 4;
        Offset -= 4;
        EverMadeChange = true;
      }
    }

    // CMPWIBC compares a GPR with a zero-extended five-bit immediate using
    // signed semantics. An unsigned comparison is equivalent only for EQ/NE.
    // Accept predicate branches and direct tests of CR0's LT/GT/EQ bits.
    for (MachineBasicBlock &MBB : Fn) {
      unsigned Offset = 0;
      for (auto I = MBB.begin(); I != MBB.end();) {
        MachineInstr &Br = *I++;
        unsigned BrOffset = Offset;
        Offset += TII->getInstSizeInBytes(Br);
        bool IsBitBranch =
            Br.getOpcode() == PPC::BC || Br.getOpcode() == PPC::BCn;
        if (Br.getOpcode() != PPC::BCC && !IsBitBranch)
          continue;
        unsigned DestOp = IsBitBranch ? 1 : 2;
        if (!Br.getOperand(DestOp).isMBB() ||
            (IsBitBranch ? (Br.getOperand(0).getReg() != PPC::CR0LT &&
                            Br.getOperand(0).getReg() != PPC::CR0GT &&
                            Br.getOperand(0).getReg() != PPC::CR0EQ)
                         : Br.getOperand(1).getReg() != PPC::CR0) ||
            Br.getIterator() == MBB.begin())
          continue;

        MachineInstr *CmpPtr = FindMovableCompare(Br);
        if (!CmpPtr)
          continue;
        MachineInstr &Cmp = *CmpPtr;
        if ((Cmp.getOpcode() != PPC::CMPWI && Cmp.getOpcode() != PPC::CMPLWI) ||
            Cmp.getOperand(0).getReg() != PPC::CR0 ||
            !Cmp.getOperand(2).isImm())
          continue;

        unsigned PX = 0, BIX = 2;
        if (IsBitBranch) {
          PX = Br.getOpcode() == PPC::BC ? 1 : 0;
          Register Cond = Br.getOperand(0).getReg();
          BIX = Cond == PPC::CR0LT ? 0 : (Cond == PPC::CR0GT ? 1 : 2);
        } else {
          switch (PredicateCondition(Br)) {
          case PPC::PRED_LT:
            PX = 1;
            BIX = 0;
            break;
          case PPC::PRED_GE:
            PX = 0;
            BIX = 0;
            break;
          case PPC::PRED_GT:
            PX = 1;
            BIX = 1;
            break;
          case PPC::PRED_LE:
            PX = 0;
            BIX = 1;
            break;
          case PPC::PRED_EQ:
            PX = 1;
            BIX = 2;
            break;
          case PPC::PRED_NE:
            PX = 0;
            BIX = 2;
            break;
          default:
            continue;
          }
        }
        // Unsigned x>0 is x!=0, including words with their sign bit set.
        // Invert the GT test and select EQ; never use signed GT for this.
        if (Cmp.getOpcode() == PPC::CMPLWI && Cmp.getOperand(2).getImm() == 0 &&
            BIX == 1) {
          PX ^= 1;
          BIX = 2;
        }
        int64_t Immediate = Cmp.getOperand(2).getImm();
        if (Cmp.getOpcode() == PPC::CMPWI)
          Immediate = SignExtend64<16>(Immediate);
        // x > -1 and x <= -1 are exactly the nonnegative/negative tests.
        // The comparison result changes, so no CR0 bit may remain live.
        if (Cmp.getOpcode() == PPC::CMPWI && Immediate == -1 && BIX == 1 &&
            IsDeadAfter(Br, PPC::CR0)) {
          Immediate = 0;
          BIX = 0;
          PX ^= 1;
        }
        // Signed and unsigned relational comparisons agree when the loaded
        // or masked input is nonnegative and the immediate fits five bits.
        // For EQ/NE, only live LT/GT bits can prevent equivalence.
        if (Cmp.getOpcode() == PPC::CMPLWI &&
            !(isUInt<5>(Immediate) && IsKnownNonNegative(Cmp)) &&
            (BIX != 2 || !IsDeadAfter(Br, PPC::CR0LT) ||
             !IsDeadAfter(Br, PPC::CR0GT)))
          continue;

        MachineInstr *Mask = nullptr;
        unsigned Shift = 0;
        if (!isUInt<5>(Immediate)) {
          // (rotl(x,R) & contiguous-mask) == K can instead extract the
          // field into low bits and compare K>>Shift. This exposes the
          // five-bit fused immediate without adding another instruction.
          if (Cmp.getOpcode() != PPC::CMPLWI || BIX != 2 || Immediate < 0 ||
              !IsDeadAfter(Cmp, Cmp.getOperand(1).getReg()))
            continue;
          auto P = Cmp.getIterator();
          for (unsigned Seen = 0; P != MBB.begin() && Seen < 4; ++Seen) {
            MachineInstr &MI = *--P;
            if (MI.isDebugInstr())
              continue;
            Register R = Cmp.getOperand(1).getReg();
            if (MI.getOpcode() == PPC::RLWINM &&
                MI.getOperand(0).getReg() == R) {
              Mask = &MI;
              break;
            }
            if (MI.isCall() || MI.isTerminator() || MI.isInlineAsm() ||
                MI.hasUnmodeledSideEffects() || MI.readsRegister(R, TRI) ||
                MI.modifiesRegister(R, TRI))
              break;
          }
          if (!Mask || Mask->peekDebugInstrNum() || Mask->isBundledWithPred() ||
              Mask->isBundledWithSucc())
            continue;
          unsigned MB = Mask->getOperand(3).getImm();
          unsigned ME = Mask->getOperand(4).getImm();
          if (MB > ME)
            continue;
          Shift = 31 - ME;
          uint32_t Bits = UINT32_MAX >> MB;
          Bits &= UINT32_MAX << Shift;
          if ((uint64_t(Immediate) & ~uint64_t(Bits)) ||
              !isUInt<5>(uint64_t(Immediate) >> Shift))
            continue;
          Immediate = uint64_t(Immediate) >> Shift;
        }

        int Distance = computeBranchSize(
            Fn, &MBB, Br.getOperand(DestOp).getMBB(), BrOffset);
        if (HasImpreciseBranchSpan(Br, *Br.getOperand(DestOp).getMBB()) ||
            Distance < -2036 || Distance > 2036)
          continue;

        if (Mask) {
          Mask->getOperand(2).setImm(
              (Mask->getOperand(2).getImm() + 32 - Shift) % 32);
          Mask->getOperand(3).setImm(Mask->getOperand(3).getImm() + Shift);
          Mask->getOperand(4).setImm(31);
        }
        BuildMI(MBB, Br.getIterator(), Br.getDebugLoc(), TII->get(PPC::CMPWIBC))
            .addImm(PX)
            .addImm(BIX)
            .addReg(Cmp.getOperand(1).getReg(),
                    Cmp.getOperand(1).isKill() ? RegState::Kill : 0)
            .addImm(Immediate)
            .addMBB(Br.getOperand(DestOp).getMBB());
        Cmp.eraseFromParent();
        Br.eraseFromParent();
        BlockSizes[MBB.getNumber()].first -= 4;
        Offset -= 4;
        EverMadeChange = true;
      }
    }

    // A two-bit equality mismatch is the OR of two individual bit mismatches.
    // Use two bit branches when a large comparison immediate prevented the
    // cheaper folds above. Three or more bit branches would not save code.
    for (MachineBasicBlock &MBB : Fn) {
      unsigned Offset = 0;
      for (auto I = MBB.begin(); I != MBB.end();) {
        MachineInstr &Br = *I++;
        unsigned BrOffset = Offset;
        Offset += TII->getInstSizeInBytes(Br);
        bool BitBranch = Br.getOpcode() == PPC::BCn &&
                         Br.getOperand(0).getReg() == PPC::CR0EQ;
        if ((!BitBranch && (Br.getOpcode() != PPC::BCC ||
                            Br.getOperand(1).getReg() != PPC::CR0 ||
                            PredicateCondition(Br) != PPC::PRED_NE)) ||
            Br.isBundled() || Br.peekDebugInstrNum())
          continue;
        unsigned DestOp = BitBranch ? 1 : 2;
        if (!Br.getOperand(DestOp).isMBB() || !IsDeadAfter(Br, PPC::CR0))
          continue;
        MachineInstr *Cmp = FindMovableCompare(Br);
        if (!Cmp ||
            (Cmp->getOpcode() != PPC::CMPWI &&
             Cmp->getOpcode() != PPC::CMPLWI) ||
            Cmp->peekDebugInstrNum() || Cmp->isBundled())
          continue;
        Register R = Cmp->getOperand(1).getReg();
        if (!IsDeadAfter(*Cmp, R))
          continue;
        MachineInstr *Mask = nullptr;
        auto P = Cmp->getIterator();
        for (unsigned Seen = 0; P != MBB.begin() && Seen < 8;) {
          MachineInstr &MI = *--P;
          if (MI.isDebugInstr())
            continue;
          ++Seen;
          if (MI.modifiesRegister(R, TRI)) {
            if (MI.getOpcode() == PPC::ANDI_rec &&
                MI.getOperand(0).getReg() == R && !MI.isBundled() &&
                !MI.peekDebugInstrNum())
              Mask = &MI;
            break;
          }
          if (MI.isCall() || MI.isInlineAsm() || MI.isTerminator() ||
              MI.hasUnmodeledSideEffects() || MI.readsRegister(R, TRI) ||
              MI.readsRegister(PPC::CR0, TRI) ||
              MI.modifiesRegister(PPC::CR0, TRI))
            break;
        }
        if (!Mask)
          continue;
        uint32_t Bits = uint32_t(Mask->getOperand(2).getImm()) & 0xffff;
        uint32_t Expected = Cmp->getOperand(2).getImm();
        if (Cmp->getOpcode() == PPC::CMPWI)
          Expected = SignExtend64<16>(Expected);
        if (llvm::popcount(Bits) != 2 || (Expected & ~Bits))
          continue;
        Register Src = Mask->getOperand(1).getReg();
        bool Safe = true;
        for (auto J = std::next(Mask->getIterator()); J != Br.getIterator();
             ++J) {
          if (&*J == Cmp || J->isDebugInstr())
            continue;
          if (J->readsRegister(R, TRI) || J->readsRegister(Src, TRI) ||
              J->modifiesRegister(Src, TRI)) {
            Safe = false;
            break;
          }
        }
        MachineBasicBlock *Dest = Br.getOperand(DestOp).getMBB();
        int Distance = computeBranchSize(Fn, &MBB, Dest, BrOffset);
        if (!Safe || HasImpreciseBranchSpan(Br, *Dest) || Distance < -2032 ||
            Distance > 2032)
          continue;
        for (unsigned N = 0; N != 2; ++N) {
          unsigned Bit = llvm::countr_zero(Bits);
          uint32_t BitMask = uint32_t(1) << Bit;
          BuildMI(MBB, Br.getIterator(), Br.getDebugLoc(), TII->get(PPC::BNBWI))
              .addImm(bool(Expected & BitMask))
              .addReg(Src, N == 1 && IsDeadAfter(Br, Src) ? RegState::Kill : 0)
              .addImm(31 - Bit)
              .addMBB(Dest);
          Bits &= ~BitMask;
        }
        Mask->eraseFromParent();
        Cmp->eraseFromParent();
        Br.eraseFromParent();
        BlockSizes[MBB.getNumber()].first -= 4;
        Offset -= 4;
        EverMadeChange = true;
      }
    }

    // BCC describes its input as a complete CR field, although an EQ/NE
    // predicate only observes EQ. Inspect that predicate rather than treating
    // the descriptor's conservative register use as a read of LT and GT.
    auto OnlyEqualityUsers = [&](const MachineInstr &Cmp) {
      const MachineBasicBlock &MBB = *Cmp.getParent();
      if (!Fn.getRegInfo().tracksLiveness())
        return false;
      for (const MachineBasicBlock *Succ : MBB.successors())
        for (const auto &LI : Succ->liveins())
          if (TRI->regsOverlap(LI.PhysReg, PPC::CR0LT) ||
              TRI->regsOverlap(LI.PhysReg, PPC::CR0GT))
            return false;
      for (auto J = std::next(Cmp.getIterator()); J != MBB.end(); ++J) {
        if (J->isDebugInstr())
          continue;
        if (J->isInlineAsm() || J->isCall() || J->isBundled())
          return false;
        if (J->readsRegister(PPC::CR0, TRI)) {
          bool Equality = false;
          if (J->getOpcode() == PPC::BCC && J->getOperand(1).getReg() == PPC::CR0) {
            unsigned Pred = PPC::getPredicateCondition(
                static_cast<PPC::Predicate>(J->getOperand(0).getImm()));
            Equality = Pred == PPC::PRED_EQ || Pred == PPC::PRED_NE;
          } else if (J->getOpcode() == PPC::BC || J->getOpcode() == PPC::BCn)
            Equality = J->getOperand(0).getReg() == PPC::CR0EQ;
          if (!Equality)
            return false;
        }
        if (J->modifiesRegister(PPC::CR0, TRI))
          return J->definesRegister(PPC::CR0);
      }
      return true;
    };

    // Prefer the fused branches above when possible. For the remaining zero
    // comparisons, reuse the producer's record form after register allocation.
    // This also handles a result overwritten between its compare and branch,
    // where moving the comparison into a fused branch would be incorrect.
    for (MachineBasicBlock &MBB : Fn) {
      for (auto I = MBB.begin(); I != MBB.end();) {
        MachineInstr &Cmp = *I++;
        if ((Cmp.getOpcode() != PPC::CMPWI && Cmp.getOpcode() != PPC::CMPLWI) ||
            Cmp.getOperand(0).getReg() != PPC::CR0 ||
            Cmp.getOperand(2).getImm() != 0 || Cmp.peekDebugInstrNum() ||
            Cmp.isBundled())
          continue;
        // A record form compares signed. EQ and SO agree for unsigned inputs;
        // LT/GT require proof that the input's sign bit is clear.
        if (Cmp.getOpcode() == PPC::CMPLWI && !IsKnownNonNegative(Cmp) &&
            (!IsDeadAfter(Cmp, PPC::CR0LT) || !IsDeadAfter(Cmp, PPC::CR0GT)) &&
            !OnlyEqualityUsers(Cmp))
          continue;
        Register R = Cmp.getOperand(1).getReg();
        auto P = Cmp.getIterator();
        for (unsigned Seen = 0; P != MBB.begin() && Seen < 12;) {
          MachineInstr &Def = *--P;
          if (Def.isDebugInstr())
            continue;
          ++Seen;
          if (Def.isCall() || Def.isInlineAsm() || Def.isTerminator() ||
              Def.hasUnmodeledSideEffects() || Def.isBundled() ||
              Def.peekDebugInstrNum())
            break;
          if (Def.modifiesRegister(R, TRI)) {
            if (!Def.getOperand(0).isReg() || Def.getOperand(0).getReg() != R)
              break;
            int RecordOpcode = -1;
            switch (Def.getOpcode()) {
            case PPC::RLWINM:
            case PPC::RLWNM:
            case PPC::AND:
            case PPC::ANDC:
            case PPC::OR:
            case PPC::ORC:
            case PPC::XOR:
            case PPC::EQV:
            case PPC::NAND:
            case PPC::NOR:
            case PPC::ADD4:
            case PPC::SUBF:
            case PPC::NEG:
            case PPC::SLW:
            case PPC::SRW:
            case PPC::SRAW:
            case PPC::SRAWI:
            case PPC::CNTLZW:
            case PPC::EXTSB:
              RecordOpcode = TII->getRecordFormOpcode(Def.getOpcode());
              break;
            case PPC::ANDI_rec:
            case PPC::ANDIS_rec:
            case PPC::RLWINM_rec:
            case PPC::RLWNM_rec:
              RecordOpcode = Def.getOpcode();
              break;
            default:
              break;
            }
            if (RecordOpcode == -1 || Def.readsRegister(PPC::CR0, TRI))
              break;
            bool AlreadyRecords = Def.modifiesRegister(PPC::CR0, TRI);
            Def.setDesc(TII->get(RecordOpcode));
            if (!AlreadyRecords)
              Def.addOperand(Fn,
                             MachineOperand::CreateReg(PPC::CR0, true, true));
            for (MachineOperand &MO : Def.operands())
              if (MO.isReg() && MO.isDef() && MO.getReg() == PPC::CR0)
                MO.setIsDead(false);
            Cmp.eraseFromParent();
            BlockSizes[MBB.getNumber()].first -= 4;
            EverMadeChange = true;
            break;
          }
          // Reusing earlier flags must not change any intervening observer,
          // and XER.SO must still have the value sampled by the comparison.
          if (Def.readsRegister(PPC::CR0, TRI) ||
              Def.modifiesRegister(PPC::CR0, TRI) ||
              Def.modifiesRegister(PPC::XER, TRI))
            break;
        }
      }
    }
  }

  // Fold an adjacent in-place decrement into a fused equality branch.
  // Restrict this to ADDI: ADDIC also changes XER.CA. The fused instruction
  // compares the old RA with the decrement and then writes the difference.
  if (Fn.getSubtarget<PPCSubtarget>().isPPE42()) {
    const TargetRegisterInfo *TRI = Fn.getSubtarget().getRegisterInfo();
    for (MachineBasicBlock &MBB : Fn) {
      for (auto I = MBB.begin(); I != MBB.end();) {
        MachineInstr &Br = *I++;
        if (Br.getOpcode() != PPC::CMPWIBC || Br.getOperand(1).getImm() != 2 ||
            Br.getOperand(3).getImm() != 0 || Br.peekDebugInstrNum() ||
            Br.isBundledWithPred() || Br.isBundledWithSucc())
          continue;
        auto P = Br.getIterator();
        while (P != MBB.begin() && std::prev(P)->isDebugInstr())
          --P;
        if (P == MBB.begin())
          continue;
        MachineInstr &Dec = *--P;
        Register R = Br.getOperand(2).getReg();
        if (Dec.getOpcode() != PPC::ADDI || Dec.getOperand(0).getReg() != R ||
            Dec.getOperand(1).getReg() != R || !Dec.getOperand(2).isImm() ||
            Dec.peekDebugInstrNum() || Dec.isBundledWithPred() ||
            Dec.isBundledWithSucc())
          continue;
        int64_t Amount = -SignExtend64<16>(Dec.getOperand(2).getImm());
        if (Amount <= 0 || !isUInt<5>(Amount))
          continue;
        LiveRegUnits Live(*TRI);
        Live.addLiveOuts(MBB);
        for (auto J = MBB.rbegin(); &*J != &Br; ++J)
          if (!J->isDebugInstr())
            Live.stepBackward(*J);
        // Relational CR bits are different at signed overflow boundaries.
        if (!Fn.getRegInfo().tracksLiveness() || !Live.available(PPC::CR0))
          continue;
        unsigned DefFlags = RegState::Define;
        if (Live.available(R))
          DefFlags |= RegState::Dead;
        BuildMI(MBB, Br.getIterator(), Br.getDebugLoc(), TII->get(PPC::SUBWIBC))
            .addReg(R, DefFlags)
            .addImm(Br.getOperand(0).getImm())
            .addReg(R, Dec.getOperand(1).isKill() ? RegState::Kill : 0)
            .addImm(Amount)
            .addMBB(Br.getOperand(4).getMBB());
        Dec.eraseFromParent();
        Br.eraseFromParent();
        EverMadeChange = true;
      }
    }
  }

  BlockSizes.clear();
  return EverMadeChange;
}
