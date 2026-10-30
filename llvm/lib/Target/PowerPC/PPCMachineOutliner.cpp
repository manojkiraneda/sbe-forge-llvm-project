//===-- PPCMachineOutliner.cpp - PPE42 outlining ---------------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "PPCInstrInfo.h"
#include "PPCSubtarget.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/CodeGen/MachineInstrBuilder.h"
#include "llvm/CodeGen/MachineRegisterInfo.h"
#include "llvm/IR/Function.h"

using namespace llvm;

namespace {
enum PPE42OutlineKind { ReturnViaLR, TailCall };

// LR is reserved, and PPC does not propagate it through block live-in lists.
// Candidate's block-local availability query therefore cannot prove that a
// call is safe: a frameless loop may return through LR in a successor block.
// Follow every path until LR is overwritten, rejecting any intervening read.
static bool isLRDeadOnAllPaths(outliner::Candidate &C,
                              const TargetRegisterInfo &TRI) {
  using Position = std::pair<MachineBasicBlock *,
                             MachineBasicBlock::iterator>;
  SmallVector<Position, 16> Worklist;
  SmallPtrSet<MachineBasicBlock *, 32> Visited;
  Worklist.emplace_back(C.getMBB(), C.begin());
  unsigned Instructions = 0;
  while (!Worklist.empty()) {
    auto [MBB, It] = Worklist.pop_back_val();
    bool Overwritten = false;
    for (; It != MBB->end(); ++It) {
      if (It->isDebugInstr())
        continue;
      if (++Instructions > 4096 || It->readsRegister(PPC::LR, &TRI))
        return false;
      if (It->modifiesRegister(PPC::LR, &TRI)) {
        Overwritten = true;
        break;
      }
    }
    if (Overwritten)
      continue;
    // No known continuation cannot establish that LR is dead (e.g. an
    // indirect branch). Ordinary returns are rejected as reads above.
    if (MBB->succ_empty())
      return false;
    for (MachineBasicBlock *Succ : MBB->successors()) {
      if (!Visited.insert(Succ).second)
        continue;
      if (Visited.size() > 256)
        return false;
      Worklist.emplace_back(Succ, Succ->begin());
    }
  }
  return true;
}
}

bool PPCInstrInfo::isFunctionSafeToOutlineFrom(
    MachineFunction &MF, bool OutlineFromLinkOnceODRs) const {
  const Function &F = MF.getFunction();
  const auto &ST = MF.getSubtarget<PPCSubtarget>();
  return ST.isPPE42() && !ST.isPPC64() &&
         MF.getRegInfo().tracksLiveness() && !F.hasSection() &&
         !F.hasPersonalityFn() && !F.hasFnAttribute(Attribute::Naked) &&
         !F.hasFnAttribute("interrupt") &&
         (OutlineFromLinkOnceODRs || !F.hasLinkOnceODRLinkage());
}

bool PPCInstrInfo::shouldOutlineFromFunctionByDefault(
    MachineFunction &MF) const {
  return MF.getFunction().hasOptSize();
}

outliner::InstrType
PPCInstrInfo::getOutliningTypeImpl(const MachineModuleInfo &,
                                   MachineBasicBlock::iterator &MIT,
                                   unsigned) const {
  const MachineInstr &MI = *MIT;
  const TargetRegisterInfo &TRI = getRegisterInfo();
  if (MI.isCFIInstruction() || MI.getFlag(MachineInstr::FrameSetup) ||
      MI.getFlag(MachineInstr::FrameDestroy))
    return outliner::Illegal;

  // A direct call can end a sequence: the outlined copy tail-branches to
  // the original callee, which returns directly to the original caller.
  if (MI.getOpcode() == PPC::BL &&
      (MI.getOperand(0).isGlobal() || MI.getOperand(0).isSymbol())) {
    // PPC call lowering models R1 as an implicit definition, even for an
    // ordinary ABI call. A frameless helper tail-branches to the same callee
    // with exactly the original stack pointer, so retain that definition on
    // the replacement call rather than treating it as a stack adjustment.
    // Explicit stack updates and overlapping tuple definitions remain illegal.
    for (const MachineOperand &MO : MI.operands())
      if (MO.isReg() && MO.isDef() && MO.getReg() &&
          TRI.regsOverlap(MO.getReg(), PPC::R1) &&
          !(MO.isImplicit() && MO.getReg() == PPC::R1))
        return outliner::Illegal;
    return outliner::LegalTerminator;
  }

  if (MI.modifiesRegister(PPC::R1, &TRI))
    return outliner::Illegal;

  // Only straight-line integer operations and ordinary memory accesses are
  // admitted. In particular, leave stack updates, inline assembly, branches,
  // barriers, special-register accesses and all relocatable pseudos in place.
  switch (MI.getOpcode()) {
  default:
    return outliner::Illegal;
  case PPC::LI:
  case PPC::LIS:
  case PPC::ADDI:
  case PPC::ADDIS:
  case PPC::ORI:
  case PPC::ORIS:
  case PPC::XORI:
  case PPC::XORIS:
  case PPC::OR:
  case PPC::AND:
  case PPC::ANDC:
  case PPC::XOR:
  case PPC::NOR:
  case PPC::ADD4:
  case PPC::SUBF:
  case PPC::NEG:
  case PPC::MULLI:
  case PPC::MULLW:
  case PPC::RLWINM:
  case PPC::RLWIMI:
  case PPC::SLW:
  case PPC::SRW:
  case PPC::SRAWI:
  case PPC::EXTSB:
  case PPC::EXTSH:
  case PPC::LWZ:
  case PPC::LHZ:
  case PPC::LBZ:
  case PPC::STW:
  case PPC::STH:
  case PPC::STB:
  case PPC::LVD:
  case PPC::STVD:
    break;
  }

  // HI/LO relocations may be paired with an instruction outside a sequence,
  // and target-specific relocations may rely on the containing function.
  if (llvm::any_of(MI.operands(), [](const MachineOperand &MO) {
        return !MO.isReg() && !MO.isImm();
      }))
    return outliner::Illegal;
  return outliner::Legal;
}

std::optional<std::unique_ptr<outliner::OutlinedFunction>>
PPCInstrInfo::getOutliningCandidateInfo(
    const MachineModuleInfo &, std::vector<outliner::Candidate> &Candidates,
    unsigned MinRepeats) const {
  const TargetRegisterInfo &TRI = getRegisterInfo();
  llvm::erase_if(Candidates, [&TRI](outliner::Candidate &C) {
    // A normal outlined call overwrites LR. The original value must be dead
    // throughout the sequence and afterwards. A sequence ending in BL already
    // overwrites LR and needs no additional save/restore.
    return C.back().getOpcode() != PPC::BL &&
           (!C.isAvailableAcrossAndOutOfSeq(PPC::LR, TRI) ||
            !isLRDeadOnAllPaths(C, TRI));
  });
  if (Candidates.size() < MinRepeats)
    return std::nullopt;

  unsigned Kind =
      Candidates.front().back().getOpcode() == PPC::BL ? TailCall : ReturnViaLR;
  unsigned SequenceSize = 0;
  for (const MachineInstr &MI : Candidates.front())
    SequenceSize += getInstSizeInBytes(MI);
  for (auto &C : Candidates)
    C.setCallInfo(Kind, /*CallOverhead=*/4);
  // Tail-call sequences already contain their final branch. Other sequences
  // need a four-byte BLR. No stack frame or scratch register is introduced.
  return std::make_unique<outliner::OutlinedFunction>(
      Candidates, SequenceSize, Kind == TailCall ? 0 : 4, Kind);
}

void PPCInstrInfo::buildOutlinedFrame(
    MachineBasicBlock &MBB, MachineFunction &MF,
    const outliner::OutlinedFunction &OF) const {
  MF.setAlignment(Align(4));
  if (OF.FrameConstructionID == TailCall) {
    MachineInstr &Call = MBB.back();
    BuildMI(MBB, Call, DebugLoc(), get(PPC::B)).add(Call.getOperand(0));
    Call.eraseFromParent();
    return;
  }
  MBB.addLiveIn(PPC::LR);
  BuildMI(MBB, MBB.end(), DebugLoc(), get(PPC::BLR));
}

MachineBasicBlock::iterator PPCInstrInfo::insertOutlinedCall(
    Module &, MachineBasicBlock &MBB, MachineBasicBlock::iterator &It,
    MachineFunction &MF, outliner::Candidate &C) const {
  auto Call = BuildMI(MBB, It, DebugLoc(), get(PPC::BL))
                  .addGlobalAddress(&MF.getFunction());
  // An ordinary outlined sequence preserves every register except its actual
  // outputs and LR; MachineOutliner adds those implicit uses/defs. If it ends
  // in an existing ABI call, retain that call's full clobber mask as well.
  if (C.CallConstructionID == TailCall)
    for (const MachineOperand &MO : C.back().operands())
      if (MO.isRegMask())
        Call.add(MO);
  It = Call->getIterator();
  return It;
}
